//
//  PointCloudRenderer.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import ARKit
import CompositorServices
import Foundation
import Metal
import simd

// MARK: - Buffer index constants (mirrors ShaderTypes.h)
private let kBufferIndexUniforms            = 2
private let kBufferIndexViewProjection      = 3
private let kBufferIndexPointCloudInput     = 4
private let kBufferIndexPointCloudOutput    = 5

/// Manages the compute + render pipeline for point cloud visualization.
/// - Loads PLY data from the app bundle
/// - Runs a compute shader to convert Unity → VisionOS coordinates
/// - Renders points as soft circular sprites with distance-based sizing
final class PointCloudRenderer {

    // MARK: - Metal objects

    private let device: MTLDevice
    private let computePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    // MARK: - Point cloud data

    private var pointCloudData: PointCloudData?
    private var isConverted = false  // compute shader has run once
    
    /// Check if point cloud data has been loaded
    var isDataLoaded: Bool {
        pointCloudData != nil
    }

    // MARK: - Animation

    private var animationTask: Task<Void, Never>?
    private let pendingLock = NSLock()
    private var _pendingFrame: PointCloudData? = nil

    // MARK: - Placement

    /// Model matrix: places the point cloud in the world.
    /// Updated by floor detection and user gestures.
    var modelMatrix: matrix_float4x4 = matrix_identity_float4x4

    // MARK: - Init

    init(device: MTLDevice, layerRenderer: LayerRenderer) throws {
        self.device = device

        let library = device.makeDefaultLibrary()!

        // Compute pipeline
        let computeFunction = library.makeFunction(name: "pointCloudConvert")!
        self.computePipeline = try device.makeComputePipelineState(function: computeFunction)

        // Render pipeline
        let vertexFunction   = library.makeFunction(name: "pointCloudVertex")!
        let fragmentFunction = library.makeFunction(name: "pointCloudFragment")!

        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.label                   = "PointCloud Render Pipeline"
        renderDescriptor.vertexFunction           = vertexFunction
        renderDescriptor.fragmentFunction         = fragmentFunction
        renderDescriptor.rasterSampleCount        = device.rasterSampleCount
        renderDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount

        // Enable alpha blending for soft circle edges
        let colorAttachment = renderDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat              = layerRenderer.configuration.colorFormat
        print("[PointCloudRenderer] colorFormat = \(layerRenderer.configuration.colorFormat.rawValue)")
        colorAttachment.isBlendingEnabled        = true
        colorAttachment.rgbBlendOperation        = .add
        colorAttachment.alphaBlendOperation      = .add
        colorAttachment.sourceRGBBlendFactor     = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor   = .sourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        renderDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        self.renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)

        // Depth state (reverse-Z: greater, as used by the template)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled  = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
    }

    // MARK: - Loading

    /// Loads a PLY file from the app bundle asynchronously.
    func loadPLY(named name: String) async {
        let loader = PLYLoader()
        do {
            let data = try await loader.load(name: name, device: device)
            self.pointCloudData = data
            self.isConverted = false
            print("[PointCloudRenderer] Loaded \(data.pointCount) points from \(name).ply")
        } catch {
            print("[PointCloudRenderer] Failed to load PLY: \(error.localizedDescription)")
        }
    }

    /// 連番PLYアニメーション開始（ループ再生）
    func startAnimation(frameURLs: [URL]) {
        stopAnimation()
        guard !frameURLs.isEmpty else { return }

        animationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            let frameDuration = Duration.milliseconds(33)  // 30fps
            let loader = PLYLoader()
            var frameIndex = 0

            while !Task.isCancelled {
                let deadline = clock.now + frameDuration
                let url = frameURLs[frameIndex % frameURLs.count]

                do {
                    let data = try await loader.load(url: url, device: self.device)
                    self.pendingLock.withLock { self._pendingFrame = data }
                } catch {
                    if !Task.isCancelled {
                        print("[PCR] Frame \(frameIndex) load failed: \(error)")
                    }
                }

                frameIndex += 1
                if clock.now < deadline {
                    try? await Task.sleep(until: deadline, clock: clock)
                }
            }
        }
        print("[PCR] Animation started: \(frameURLs.count) frames")
    }

    /// アニメーション停止
    func stopAnimation() {
        animationTask?.cancel()
        animationTask = nil
        pendingLock.withLock { _pendingFrame = nil }
    }

    /// 単一フレームをURLからロード（シミュレーター用フォールバック）
    func loadSingleFrame(url: URL) async {
        let loader = PLYLoader()
        do {
            let data = try await loader.load(url: url, device: device)
            pointCloudData = data
            isConverted = false
            print("[PCR] Single frame loaded: \(url.lastPathComponent)")
        } catch {
            print("[PCR] Single frame load failed: \(error)")
        }
    }

    // MARK: - Per-frame encoding

    /// Encodes compute + render commands into the given command buffer.
    /// Call this once per frame from the main render loop.
    func encode(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        uniforms: Uniforms,
        uniformsBuffer: MTLBuffer,
        uniformsOffset: Int,
        viewProjectionBuffer: MTLBuffer,
        viewProjectionOffset: Int,
        viewports: [MTLViewport],
        viewCount: Int
    ) {
        // 新フレームが届いていれば取り込む
        let next: PointCloudData? = pendingLock.withLock {
            defer { _pendingFrame = nil }
            return _pendingFrame
        }
        if let next { pointCloudData = next; isConverted = false }

        guard let data = pointCloudData else { return }

        // Step 1: Compute pass (Unity → VisionOS conversion)
        // Only needs to run once since this is a static frame (Phase 1)
        if !isConverted {
            encodeCompute(commandBuffer: commandBuffer, data: data)
            isConverted = true
        }

        // Step 2: Render pass
        encodeRender(
            commandBuffer: commandBuffer,
            renderPassDescriptor: renderPassDescriptor,
            data: data,
            uniformsBuffer: uniformsBuffer,
            uniformsOffset: uniformsOffset,
            viewProjectionBuffer: viewProjectionBuffer,
            viewProjectionOffset: viewProjectionOffset,
            viewports: viewports,
            viewCount: viewCount
        )
    }

    // MARK: - Private

    private func encodeCompute(commandBuffer: MTLCommandBuffer, data: PointCloudData) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "PointCloud Compute"

        encoder.setComputePipelineState(computePipeline)
        encoder.setBuffer(data.inputBuffer,  offset: 0, index: kBufferIndexPointCloudInput)
        encoder.setBuffer(data.outputBuffer, offset: 0, index: kBufferIndexPointCloudOutput)

        let threadCount    = data.pointCount
        let threadsPerGroup = min(computePipeline.maxTotalThreadsPerThreadgroup, 512)
        let threadgroups   = MTLSize(width: (threadCount + threadsPerGroup - 1) / threadsPerGroup,
                                     height: 1, depth: 1)
        let threadsPerGroupSize = MTLSize(width: threadsPerGroup, height: 1, depth: 1)

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroupSize)
        encoder.endEncoding()
    }

    private func encodeRender(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        data: PointCloudData,
        uniformsBuffer: MTLBuffer,
        uniformsOffset: Int,
        viewProjectionBuffer: MTLBuffer,
        viewProjectionOffset: Int,
        viewports: [MTLViewport],
        viewCount: Int
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "PointCloud Render"

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setViewports(viewports)

        if viewCount > 1 {
            var viewMappings = (0..<viewCount).map {
                MTLVertexAmplificationViewMapping(
                    viewportArrayIndexOffset: UInt32($0),
                    renderTargetArrayIndexOffset: UInt32($0)
                )
            }
            encoder.setVertexAmplificationCount(viewCount, viewMappings: &viewMappings)
        }

        // Bind uniforms (model matrix)
        encoder.setVertexBuffer(uniformsBuffer,
                                offset: uniformsOffset,
                                index: kBufferIndexUniforms)

        // Bind view-projection matrices
        encoder.setVertexBuffer(viewProjectionBuffer,
                                offset: viewProjectionOffset,
                                index: kBufferIndexViewProjection)

        // Bind converted point data
        encoder.setVertexBuffer(data.outputBuffer,
                                offset: 0,
                                index: kBufferIndexPointCloudOutput)

        // Draw as instanced quads (6 vertices = 2 triangles per point)
        // .point is not allowed when a rasterization rate map is active (visionOS foveated rendering)
        encoder.drawPrimitives(type: .triangle,
                               vertexStart: 0,
                               vertexCount: 6,
                               instanceCount: data.pointCount)

        encoder.endEncoding()
    }
}
