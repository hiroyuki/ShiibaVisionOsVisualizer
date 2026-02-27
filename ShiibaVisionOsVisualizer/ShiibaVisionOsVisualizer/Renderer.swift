//
//  Renderer.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import AVFoundation
import CompositorServices
import Metal
import os
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

struct SharedRenderState: Sendable {
    var displayMode: AppModel.DisplayMode = .pointCloud
    var anchorTransform: matrix_float4x4? = nil
}

nonisolated let sharedRenderState = OSAllocatedUnfairLock(initialState: SharedRenderState())

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
    
    // Cached simulator flag
    var isRunningOnSimulator: Bool = false

    // Point cloud renderer
    let pointCloudRenderer: PointCloudRenderer

    // Axes renderer for placement mode
    let axesRenderer: AxesRenderer

    // Audio player for synchronized playback
    var audioPlayer: AVPlayer?

    // Cached scan results (avoid repeated iCloud directory scans)
    private var cachedPLYURLs: [URL]?  // nil = not yet scanned

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
            let library = device.makeDefaultLibrary()!
            pointCloudRenderer = try PointCloudRenderer(device: device, library: library, layerRenderer: layerRenderer)
            // Initialize at origin - will be updated by world anchor
            pointCloudRenderer.modelMatrix = matrix_identity_float4x4
            print("[Renderer] ✅ PointCloudRenderer initialized with identity matrix")

            axesRenderer = try AxesRenderer(device: device, library: library, layerRenderer: layerRenderer)
            // Initialize axes at eye level, 1m in front (visible immediately)
            axesRenderer.modelMatrix = matrix4x4_translation(0, 0, -1.0)
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
        // Check if running on simulator
        if isRunningOnSimulator {
            print("[Renderer] 🖥️ Running on simulator - skipping ARKit monitoring")
            
            // Set up fake anchor for simulator
            let fakeTransform = await appModel.simulatorFakeAnchorTransform
            pointCloudRenderer.modelMatrix = fakeTransform
            
            print("[Renderer] 🖥️ Simulator mode: Point cloud fixed at 1m forward")
            return
        }
        
        // ARKit session is already running in AppModel, just start monitoring
        print("[Renderer] Using shared ARKit session from AppModel")
        
        // Start floor detection monitoring
        Task {
            await startFloorDetection()
        }
    }
    
    // Helper to set simulator flag from async context
    private func setSimulatorFlag(_ flag: Bool) {
        self.isRunningOnSimulator = flag
    }
    
    
    private var lastFloorDetectionTime: TimeInterval = 0
    private let floorDetectionInterval: TimeInterval = 0.5  // Check every 0.5 seconds
    
    // Start monitoring floor planes in background
    private func startFloorDetection() async {
        let planeDetection = await appModel.planeDetection
        
        print("[Renderer] Starting floor detection monitoring...")
        
        Task {
            for await update in planeDetection.anchorUpdates {
                guard let planeAnchor = update.anchor as? PlaneAnchor else { continue }
                
                // Only consider horizontal planes (floor candidates)
                if planeAnchor.alignment == .horizontal {
                    let planeTransform = planeAnchor.originFromAnchorTransform
                    let planeY = planeTransform.columns.3.y
                    
                    print("[Renderer] Horizontal plane detected at Y: \(planeY)")
                    
                    // Update floor Y if this is lower or first detection
                    await MainActor.run {
                        if appModel.detectedFloorY == nil || planeY < appModel.detectedFloorY! {
                            appModel.updateDetectedFloor(planeY)
                        }
                    }
                    
                    // Update cached floor Y for rendering
                    if cachedFloorY == nil || planeY < cachedFloorY! {
                        cachedFloorY = planeY
                    }
                }
            }
        }
    }

    @MainActor
    static func startRenderLoop(_ layerRenderer: LayerRenderer, appModel: AppModel, arSession: ARKitSession) {
        print("[Renderer] startRenderLoop called")
        Task(executorPreference: RendererTaskExecutor.shared) {
            print("[Renderer] Creating renderer...")
            let renderer = Renderer(layerRenderer, appModel: appModel)
            
            // Cache simulator flag
            let simulatorFlag = await appModel.isRunningOnSimulator
            await renderer.setSimulatorFlag(simulatorFlag)
            
            // Set initial display mode from shared state
            let initialMode = sharedRenderState.withLock { $0.displayMode }
            await renderer.updateDisplayMode(initialMode)
            print("[Renderer] Initial display mode: \(initialMode)")
            
            print("[Renderer] Starting AR session...")
            await renderer.startARSession(arSession)
            
            // Start animation or load single frame depending on available files
            if initialMode == .pointCloud {
                await renderer.scanAndStartAnimation()
            } else {
                print("[Renderer] Axes placement mode, skipping PLY load")
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
        // This is called from renderFrame which is already in the actor context
        // We need to synchronously access appModel data
        
        // For now, just use cached values that are updated elsewhere
        // The actual matrix updates happen in render() based on current mode
    }
    
    /// iCloud Drive の ShiibaAVP/Shimonju/ から PLY ファイルURLを昇順で返す。
    /// iCloudが使えない場合は Bundle.main にフォールバック。
    /// 結果はキャッシュされ、2回目以降はディレクトリスキャンをスキップする。
    private nonisolated func scanICloudPLYFiles() -> [URL] {
        if let base = ICloudContainer.shimojuURL {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ))?.filter { $0.pathExtension.lowercased() == "ply" }
              .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            if !urls.isEmpty {
                print("[Renderer] iCloud PLY: \(urls.count) files in Documents/Shimonju")
                return urls
            }
            print("[Renderer] iCloud directory empty or not found: Documents/Shimonju")
        } else {
            print("[Renderer] iCloud container not available (entitlement missing?)")
        }
        // Bundle fallback
        if let url = Bundle.main.url(forResource: "shimonju_sf_000001", withExtension: "ply") {
            print("[Renderer] Fallback: Bundle.main")
            return [url]
        }
        print("[Renderer] No PLY files found anywhere")
        return []
    }

    /// スキャン → アニメーション or 静的ロードを実行
    /// PLY URL のスキャン結果はキャッシュされ、モード切り替え時の再スキャンを防ぐ。
    private func scanAndStartAnimation() async {
        let urls: [URL]
        if let cached = cachedPLYURLs {
            urls = cached
        } else {
            urls = scanICloudPLYFiles()
            cachedPLYURLs = urls
        }

        // 音声ファイルを準備（まだ再生しない）
        if let audioURL = scanAudioFile() {
            prepareAudio(url: audioURL)
        }
        let player = self.audioPlayer  // actor内でキャプチャ

        if urls.count > 1 {
            pointCloudRenderer.startAnimation(frameURLs: urls, audioTime: {
                return player?.currentTime().seconds
            }, startPlayback: {
                player?.play()
            })
        } else if let url = urls.first {
            // シングルフレーム（シミュレーター等）: 従来方式
            await pointCloudRenderer.loadSingleFrame(url: url)
        }
    }

    /// iCloud フォルダから音声ファイルを1つ取得
    private nonisolated func scanAudioFile() -> URL? {
        guard let containerURL = ICloudContainer.shimojuURL else { return nil }
        let extensions = ["mp3", "wav", "m4a", "aac"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return files.first { extensions.contains($0.pathExtension.lowercased()) }
    }

    private func prepareAudio(url: URL) {
        audioPlayer = AVPlayer(url: url)
        // play()はstartPlaybackコールバック内で呼ぶ（最初のPLYフレームロード完了後）
        print("[Renderer] 🎵 Audio prepared: \(url.lastPathComponent)")
    }

    private func stopAudio() {
        audioPlayer?.pause()
        audioPlayer = nil
        print("[Renderer] 🔇 Audio stopped")
    }

    private func updateDisplayMode(_ mode: AppModel.DisplayMode) {
        if currentDisplayMode != mode {
            print("[Renderer] 🔄 Display mode changed: \(currentDisplayMode) -> \(mode)")
            
            // If switching to point cloud mode, start animation
            if mode == .pointCloud && currentDisplayMode == .axesPlacement {
                Task {
                    await scanAndStartAnimation()
                }
            } else if mode == .axesPlacement {
                pointCloudRenderer.stopAnimation()
                stopAudio()
            }
        }
        currentDisplayMode = mode
    }
    
    private func updateModelMatrices(_ matrix: matrix_float4x4) {
        pointCloudRenderer.modelMatrix = matrix
        axesRenderer.modelMatrix = matrix
        // Also update uniforms for current frame
        uniforms[0].modelMatrix = matrix
    }
    
    // Synchronous state update - returns (shouldRender, matrix)
    private func updateRenderState(deviceAnchor: DeviceAnchor?) -> (Bool, matrix_float4x4) {
        // This runs on the render thread, so we need to be careful with MainActor access
        // We'll use cached values and update them asynchronously
        
        // Simulator mode: always return fixed transform
        if isRunningOnSimulator {
            // Fixed position: 1m forward (0, 0, -1)
            let matrix = matrix4x4_translation(0, 0, -1.0)
            return (true, matrix)
        }
        
        if currentDisplayMode == .axesPlacement {
            // Axes placement mode
            if let deviceAnchor = deviceAnchor {
                let deviceTransform = deviceAnchor.originFromAnchorTransform
                
                // Extract device position
                let devicePosition = SIMD3<Float>(
                    deviceTransform.columns.3.x,
                    deviceTransform.columns.3.y,
                    deviceTransform.columns.3.z
                )
                
                // Extract Y-axis rotation from device transform
                let forward = SIMD3<Float>(
                    -deviceTransform.columns.2.x,
                    -deviceTransform.columns.2.y,
                    -deviceTransform.columns.2.z
                )
                
                // Project forward vector onto XZ plane for yaw calculation
                let forwardXZ = SIMD3<Float>(forward.x, 0, forward.z)
                let normalizedForwardXZ = normalize(forwardXZ)
                
                // Calculate yaw angle (rotation around Y axis) - negated to match device orientation
                let yaw = -atan2(normalizedForwardXZ.x, -normalizedForwardXZ.z)
                
                // Position: directly below device (same X, Z, but on floor)
                let previewPos = SIMD3<Float>(
                    devicePosition.x,
                    cachedFloorY ?? (devicePosition.y - 1.5),  // Floor or 1.5m below device
                    devicePosition.z
                )
                
                // Create transform matrix with Y-axis rotation only
                // Translation * Rotation(Y-axis)
                let rotationMatrix = matrix4x4_rotation(radians: yaw, axis: SIMD3<Float>(0, 1, 0))
                let translationMatrix = matrix4x4_translation(previewPos.x, previewPos.y, previewPos.z)
                let matrix = translationMatrix * rotationMatrix
                
                // Update AppModel asynchronously (for UI)
                Task { @MainActor in
                    appModel.updateDeviceTransform(deviceTransform)
                }
                
                if Int.random(in: 0..<240) == 0 {
                    print("[Renderer] 🎯 Axes directly below device at: \(previewPos), yaw: \(yaw * 180 / .pi)°")
                }
                
                return (true, matrix)
            }
        } else {
            // Point cloud mode - use anchor transform from sharedRenderState
            // WorldAnchorManager writes originFromAnchorTransform (with rotation) here
            let anchorTransform = sharedRenderState.withLock { $0.anchorTransform }
            if let matrix = anchorTransform {
                if Int.random(in: 0..<240) == 0 {
                    let pos = SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
                    print("[Renderer] ☁️ PointCloud at: \(pos)")
                }
                
                return (true, matrix)
            } else {
                if Int.random(in: 0..<240) == 0 {
                    print("[Renderer] ⚠️ No world anchor available for point cloud")
                }
                return (false, matrix_identity_float4x4)
            }
        }
        
        // Fallback
        return (true, matrix4x4_translation(0, 0, -1.0))
    }
    
    // Cache for floor Y coordinate (updated from floor detection)
    private var cachedFloorY: Float?

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
        
        // Query device anchor (on real device) or use nil (on simulator)
        let deviceAnchor: DeviceAnchor?
        #if targetEnvironment(simulator)
        // On simulator, WorldTrackingProvider doesn't work, so we can't get a device anchor
        // This will cause a warning from encodePresent, but it's unavoidable on simulator
        deviceAnchor = nil
        #else
        // On real device, query and set device anchor normally
        deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)
        drawable.deviceAnchor = deviceAnchor
        #endif
        
        // Read display mode from shared state (synchronous, no MainActor hop)
        let newMode = sharedRenderState.withLock { $0.displayMode }
        self.updateDisplayMode(newMode)
        
        // Synchronously update matrices before rendering
        let (shouldRender, matrixToUse) = self.updateRenderState(deviceAnchor: deviceAnchor)
        
        if shouldRender {
            // Update matrices immediately
            self.pointCloudRenderer.modelMatrix = matrixToUse
            self.axesRenderer.modelMatrix = matrixToUse
            self.uniforms[0].modelMatrix = matrixToUse
        }

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
            if Int.random(in: 0..<240) == 0 {
                print("[Renderer] 🎯 Rendering Axes (model matrix: \(axesRenderer.modelMatrix))")
            }
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

        #if targetEnvironment(simulator)
        // On simulator, encodePresent will produce a warning because we don't have deviceAnchor
        // This is expected and can be safely ignored - the rendering still works
        #endif
        drawable.encodePresent(commandBuffer: commandBuffer)
    }

    func renderLoop() {
        print("render loop started")
        while true {
            if layerRenderer.state == .invalidated {
                print("Layer is invalidated")
                pointCloudRenderer.stopAnimation()
                stopAudio()
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

nonisolated func matrix4x4_scale(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
    return .init(columns: (vector_float4(x, 0, 0, 0),
                           vector_float4(0, y, 0, 0),
                           vector_float4(0, 0, z, 0),
                           vector_float4(0, 0, 0, 1)))
}

