//
//  Renderer.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import CompositorServices
import Metal
import simd

// The 256 byte aligned size of our uniform structure
nonisolated let alignedUniformsSize = (MemoryLayout<Uniforms>.size + 0xFF) & -0x100
nonisolated let alignedViewProjectionArraySize = (MemoryLayout<ViewProjectionArray>.size + 0xFF) & -0x100

nonisolated let maxBuffersInFlight = 3

enum RendererError: Error {
    case badVertexDescriptor
}
extension MTLDevice {
    nonisolated var supportsMSAA: Bool {
        supports32BitMSAA && supportsTextureSampleCount(4)
    }

    nonisolated var rasterSampleCount: Int {
        supportsMSAA ? 4 : 1
    }
}

extension LayerRenderer.Clock.Instant {
    nonisolated var timeInterval: TimeInterval {
        let components = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

final class RendererTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
          job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    nonisolated func asUnownedSerialExecutor() -> UnownedTaskExecutor {
        return UnownedTaskExecutor(ordinary: self)
    }

    static var shared: RendererTaskExecutor = RendererTaskExecutor()
}

actor Renderer {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    #if !targetEnvironment(simulator)
    let residencySets: [MTLResidencySet]
    let commandQueueResidencySet: MTLResidencySet
    #endif

    let dynamicUniformBuffer: MTLBuffer

    let endFrameEvent: MTLSharedEvent
    var committedFrameIndex: UInt64 = 0

    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>

    var perDrawableTarget = [LayerRenderer.Drawable.Target: DrawableTarget]()

    let worldTracking: WorldTrackingProvider
    let layerRenderer: LayerRenderer
    let appModel: AppModel
    
    // Cached display mode (updated from main actor)
    var currentDisplayMode: AppModel.DisplayMode = .pointCloud

    // Point cloud renderer
    let pointCloudRenderer: PointCloudRenderer
    
    // Axes renderer for placement mode
    let axesRenderer: AxesRenderer

    init(_ layerRenderer: LayerRenderer, appModel: AppModel) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.appModel = appModel
        
        // Use shared world tracking from appModel
        self.worldTracking = appModel.worldTracking

        let device = self.device
        self.commandQueue = self.device.makeCommandQueue()!

        #if !targetEnvironment(simulator)
        let residencySetDesc = MTLResidencySetDescriptor()
        residencySetDesc.initialCapacity = 3
        self.residencySets = (0...maxBuffersInFlight).map { _ in try! device.makeResidencySet(descriptor: residencySetDesc) }
        #endif

        self.endFrameEvent = device.makeSharedEvent()!
        self.endFrameEvent.signaledValue = UInt64(maxBuffersInFlight)
        committedFrameIndex = UInt64(maxBuffersInFlight)

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight
        self.dynamicUniformBuffer = device.makeBuffer(length: uniformBufferSize,
                                                      options: .storageModeShared)!
        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents())
            .bindMemory(to: Uniforms.self, capacity: 1)

        do {
            pointCloudRenderer = try PointCloudRenderer(device: device, layerRenderer: layerRenderer)
            // Initialize with default placement position
            pointCloudRenderer.modelMatrix = matrix4x4_translation(0, 0, -1.5)
            
            axesRenderer = try AxesRenderer(device: device, layerRenderer: layerRenderer)
            // Initialize axes at default placement position
            axesRenderer.modelMatrix = matrix4x4_translation(0, 0, -1.5)
        } catch {
            fatalError("Unable to create renderers: \(error)")
        }

        #if !targetEnvironment(simulator)
        residencySetDesc.initialCapacity = 2
        let residencySet = try! device.makeResidencySet(descriptor: residencySetDesc)
        residencySet.addAllocations([dynamicUniformBuffer])
        residencySet.commit()
        commandQueueResidencySet = residencySet
        commandQueue.addResidencySet(residencySet)
        #endif
    }

    private func startARSession(_ arSession: ARKitSession) async {
        // ARKit session is already running in AppModel, just start monitoring
        print("[Renderer] Using shared ARKit session from AppModel")
        
        // Monitor world anchor updates to restore saved anchor (in background)
        Task {
            await monitorWorldAnchors()
        }
    }
    
    private func monitorWorldAnchors() async {
        guard let savedAnchorID = await appModel.worldAnchorID else {
            print("[Renderer] No saved anchor ID to monitor")
            return
        }
        
        print("[Renderer] Monitoring for world anchor: \(savedAnchorID)")
        
        for await update in worldTracking.anchorUpdates {
            print("[Renderer] Received anchor update: \(update.anchor.id), event: \(update.event)")
            
            guard let worldAnchor = update.anchor as? WorldAnchor else {
                print("[Renderer] Anchor is not a WorldAnchor, skipping")
                continue
            }
            
            print("[Renderer] WorldAnchor detected: \(worldAnchor.id)")
            
            // Check if this is our saved anchor
            if worldAnchor.id == savedAnchorID {
                switch update.event {
                case .added, .updated:
                    await appModel.updateWorldAnchor(worldAnchor)
                    
                    // Update point cloud renderer's model matrix
                    let transform = worldAnchor.originFromAnchorTransform
                    pointCloudRenderer.modelMatrix = transform
                    
                    let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
                    print("[Renderer] ✅ World anchor restored/updated at position: \(position)")
                case .removed:
                    print("[Renderer] World anchor removed: \(worldAnchor.id)")
                }
            } else {
                print("[Renderer] Different anchor ID, expected: \(savedAnchorID), got: \(worldAnchor.id)")
            }
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        print("[Renderer] startRenderLoop called")
        Task(executorPreference: RendererTaskExecutor.shared) {
            print("[Renderer] Creating renderer...")
            let renderer = Renderer(layerRenderer, appModel: appModel)
            
            // Set initial display mode
            let initialMode = await appModel.displayMode
            await renderer.updateDisplayMode(initialMode)
            print("[Renderer] Initial display mode: \(initialMode)")
            
            print("[Renderer] Starting AR session...")
            await renderer.startARSession(arSession)
            
            // Load PLY asynchronously only if we're in point cloud mode
            // (will be loaded later if user switches to point cloud mode)
            if await appModel.displayMode == .pointCloud {
                print("[Renderer] Loading PLY file...")
                await renderer.pointCloudRenderer.loadPLY(named: "shimonju_sf_000001")
                print("[Renderer] PLY file loaded")
            } else {
                print("[Renderer] Axes placement mode, skipping PLY load for now")
            }
            
            print("[Renderer] Starting render loop")
            await renderer.renderLoop()
        }
    }

    private func updateDynamicBufferState(frameIndex: UInt64) {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset)
            .bindMemory(to: Uniforms.self, capacity: 1)

        #if !targetEnvironment(simulator)
        residencySets[uniformBufferIndex].removeAllAllocations()
        residencySets[uniformBufferIndex].commit()
        #endif

        perDrawableTarget = perDrawableTarget.filter { $0.value.lastUsedFrameIndex + 90 > frameIndex }
    }

    private func updateGameState() {
        // Get the current modelMatrix from pointCloudRenderer or axesRenderer
        // It was updated in the previous frame or by monitorWorldAnchors
        uniforms[0].modelMatrix = pointCloudRenderer.modelMatrix
        
        // Cache current mode for comparison
        let cachedMode = currentDisplayMode
        
        // Asynchronously update for next frame
        Task { @MainActor in
            // Get new display mode from appModel
            let newMode = appModel.displayMode
            
            // Update cached display mode (back on actor)
            await updateDisplayMode(newMode)
            
            // If switching to point cloud mode and PLY not loaded yet, load it
            if newMode == .pointCloud && cachedMode == .axesPlacement {
                if await !pointCloudRenderer.isDataLoaded {
                    print("[Renderer] Switching to point cloud mode, loading PLY...")
                    await pointCloudRenderer.loadPLY(named: "shimonju_sf_000001")
                    print("[Renderer] PLY loaded")
                }
            }
            
            let newMatrix: matrix_float4x4
            
            if appModel.displayMode == .axesPlacement {
                // Placement mode: use placement position
                let position = appModel.placementPosition
                newMatrix = matrix4x4_translation(position.x, position.y, position.z)
                if Int.random(in: 0..<120) == 0 {
                    print("[Renderer] Axes placement mode - position: \(position)")
                }
            } else if let worldAnchor = appModel.worldAnchor {
                // Display mode: use world anchor
                newMatrix = worldAnchor.originFromAnchorTransform
                let position = SIMD3<Float>(newMatrix.columns.3.x, newMatrix.columns.3.y, newMatrix.columns.3.z)
                if Int.random(in: 0..<120) == 0 {
                    print("[Renderer] Display mode - anchor position: \(position)")
                }
            } else {
                // No anchor: use placement position as fallback
                let position = appModel.placementPosition
                newMatrix = matrix4x4_translation(position.x, position.y, position.z)
                if Int.random(in: 0..<120) == 0 {
                    print("[Renderer] No anchor - using placement position: \(position)")
                }
            }
            
            await updateModelMatrices(newMatrix)
        }
    }
    
    private func updateDisplayMode(_ mode: AppModel.DisplayMode) {
        currentDisplayMode = mode
    }
    
    private func updateModelMatrices(_ matrix: matrix_float4x4) {
        pointCloudRenderer.modelMatrix = matrix
        axesRenderer.modelMatrix = matrix
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        guard self.endFrameEvent.wait(untilSignaledValue: committedFrameIndex - UInt64(maxBuffersInFlight), timeoutMS: 10000) else {
            return
        }

        frame.startUpdate()

        self.updateDynamicBufferState(frameIndex: frame.frameIndex)
        self.updateGameState()

        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        #if !targetEnvironment(simulator)
        commandBuffer.useResidencySet(self.residencySets[uniformBufferIndex])
        #endif

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else { return }

        frame.startSubmission()

        for drawable in drawables {
            render(drawable: drawable, commandBuffer: commandBuffer, frameIndex: frame.frameIndex)
        }

        committedFrameIndex += 1

        commandBuffer.encodeSignalEvent(self.endFrameEvent, value: committedFrameIndex)

        commandBuffer.commit()

        frame.endSubmission()
    }

    func render(drawable: LayerRenderer.Drawable, commandBuffer: MTLCommandBuffer, frameIndex: UInt64) {
        let time = drawable.frameTiming.presentationTime.timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        if perDrawableTarget[drawable.target] == nil {
            perDrawableTarget[drawable.target] = .init(drawable: drawable)
        }
        let drawableTarget = perDrawableTarget[drawable.target]!

        drawableTarget.updateBufferState(uniformBufferIndex: uniformBufferIndex, frameIndex: frameIndex)
        drawableTarget.updateViewProjectionArray(drawable: drawable)

        // Build render pass descriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()

        if device.supportsMSAA {
            let renderTargets = drawableTarget.memorylessTargets[uniformBufferIndex]
            renderPassDescriptor.colorAttachments[0].resolveTexture = drawable.colorTextures[0]
            renderPassDescriptor.colorAttachments[0].texture        = renderTargets.color
            renderPassDescriptor.depthAttachment.resolveTexture     = drawable.depthTextures[0]
            renderPassDescriptor.depthAttachment.texture            = renderTargets.depth
            renderPassDescriptor.colorAttachments[0].storeAction    = .multisampleResolve
            renderPassDescriptor.depthAttachment.storeAction        = .multisampleResolve
        } else {
            renderPassDescriptor.colorAttachments[0].texture     = drawable.colorTextures[0]
            renderPassDescriptor.depthAttachment.texture         = drawable.depthTextures[0]
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.depthAttachment.storeAction     = .store
        }

        renderPassDescriptor.colorAttachments[0].loadAction  = .clear
        renderPassDescriptor.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.depthAttachment.loadAction      = .clear
        renderPassDescriptor.depthAttachment.clearDepth      = 0.0
        renderPassDescriptor.rasterizationRateMap            = drawable.rasterizationRateMaps.first

        if layerRenderer.configuration.layout == .layered {
            renderPassDescriptor.renderTargetArrayLength = drawable.views.count
        }

        #if !targetEnvironment(simulator)
        let residencySet = self.residencySets[uniformBufferIndex]
        residencySet.addAllocations([
            drawable.colorTextures[0],
            drawable.depthTextures[0],
            drawableTarget.viewProjectionBuffer
        ])
        residencySet.commit()
        #endif

        let viewports = drawable.views.map { $0.textureMap.viewport }

        // Encode appropriate renderer based on cached display mode
        if currentDisplayMode == .axesPlacement {
            // Render axes for placement
            print("[Renderer] Rendering AXES at mode: \(currentDisplayMode)")
            axesRenderer.encode(
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor,
                uniformsBuffer: dynamicUniformBuffer,
                uniformsOffset: uniformBufferOffset,
                viewProjectionBuffer: drawableTarget.viewProjectionBuffer,
                viewProjectionOffset: drawableTarget.viewProjectionBufferOffset,
                viewports: viewports,
                viewCount: drawable.views.count
            )
        } else {
            // Render point cloud
            if Int.random(in: 0..<120) == 0 {
                print("[Renderer] Rendering POINT CLOUD at mode: \(currentDisplayMode)")
            }
            pointCloudRenderer.encode(
                commandBuffer: commandBuffer,
                renderPassDescriptor: renderPassDescriptor,
                uniforms: uniforms[0],
                uniformsBuffer: dynamicUniformBuffer,
                uniformsOffset: uniformBufferOffset,
                viewProjectionBuffer: drawableTarget.viewProjectionBuffer,
                viewProjectionOffset: drawableTarget.viewProjectionBufferOffset,
                viewports: viewports,
                viewCount: drawable.views.count
            )
        }

        drawable.encodePresent(commandBuffer: commandBuffer)
    }

    func renderLoop() {
        print("render loop started")
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                Task { @MainActor in
                    appModel.immersiveSpaceState = .closed
                }
                return
            } else if layerRenderer.state == .paused {
                Task { @MainActor in
                    appModel.immersiveSpaceState = .inTransition
                }
                layerRenderer.waitUntilRunning()
                continue
            } else {
                Task { @MainActor in
                    if appModel.immersiveSpaceState != .open {
                        appModel.immersiveSpaceState = .open
                    }
                }
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

extension Renderer {
    class DrawableTarget {
        var lastUsedFrameIndex: UInt64

        let memorylessTargets: [(color: MTLTexture, depth: MTLTexture)]

        let viewProjectionBuffer: MTLBuffer

        var viewProjectionBufferOffset = 0

        var viewProjectionArray: UnsafeMutablePointer<ViewProjectionArray>

        nonisolated init(drawable: LayerRenderer.Drawable) {
            lastUsedFrameIndex = 0

            let device = drawable.colorTextures[0].device
            nonisolated func renderTarget(resolveTexture: MTLTexture) -> MTLTexture {
                assert(device.supportsMSAA)

                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: resolveTexture.pixelFormat,
                                                                          width: resolveTexture.width,
                                                                          height: resolveTexture.height,
                                                                          mipmapped: false)
                descriptor.usage = .renderTarget
                descriptor.textureType = .type2DMultisampleArray
                descriptor.sampleCount = device.rasterSampleCount
                descriptor.storageMode = .memoryless
                descriptor.arrayLength = resolveTexture.arrayLength
                return device.makeTexture(descriptor: descriptor)!
            }

            if device.supportsMSAA {
                memorylessTargets = .init(repeating: (renderTarget(resolveTexture: drawable.colorTextures[0]),
                                                      renderTarget(resolveTexture: drawable.depthTextures[0])),
                                          count: maxBuffersInFlight)
            } else {
                memorylessTargets = []
            }

            let bufferSize = alignedViewProjectionArraySize * maxBuffersInFlight

            viewProjectionBuffer = device.makeBuffer(length: bufferSize,
                                                     options: [MTLResourceOptions.storageModeShared])!
            viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)
        }
    }
}

extension Renderer.DrawableTarget {
    nonisolated func updateBufferState(uniformBufferIndex: Int, frameIndex: UInt64) {
        viewProjectionBufferOffset = alignedViewProjectionArraySize * uniformBufferIndex

        viewProjectionArray = UnsafeMutableRawPointer(viewProjectionBuffer.contents() + viewProjectionBufferOffset).bindMemory(to: ViewProjectionArray.self, capacity: 1)

        lastUsedFrameIndex = frameIndex
    }

    nonisolated func updateViewProjectionArray(drawable: LayerRenderer.Drawable) {
        let simdDeviceAnchor = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        nonisolated func viewProjection(forViewIndex viewIndex: Int) -> float4x4 {
            let view = drawable.views[viewIndex]
            let viewMatrix = (simdDeviceAnchor * view.transform).inverse
            let projectionMatrix = drawable.computeProjection(viewIndex: viewIndex)

            return projectionMatrix * viewMatrix
        }

        viewProjectionArray[0].viewProjectionMatrix.0 = viewProjection(forViewIndex: 0)
        if drawable.views.count > 1 {
            viewProjectionArray[0].viewProjectionMatrix.1 = viewProjection(forViewIndex: 1)
        }
    }
}

// Generic matrix math utility functions
nonisolated func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return .init(columns: (vector_float4(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                           vector_float4(x * y * ci - z * st, ct + y * y * ci, z * y * ci + x * st, 0),
                           vector_float4(x * z * ci + y * st, y * z * ci - x * st, ct + z * z * ci, 0),
                           vector_float4(                  0, 0, 0, 1)))
}

nonisolated func matrix4x4_translation(_ translationX: Float, _ translationY: Float, _ translationZ: Float) -> matrix_float4x4 {
    return .init(columns: (vector_float4(1, 0, 0, 0),
                           vector_float4(0, 1, 0, 0),
                           vector_float4(0, 0, 1, 0),
                           vector_float4(translationX, translationY, translationZ, 1)))
}
