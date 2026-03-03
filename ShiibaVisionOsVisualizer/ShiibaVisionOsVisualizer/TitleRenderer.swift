//
//  TitleRenderer.swift
//  ShiibaVisionOsVisualizer
//
//  Renders a title image (textured quad) for a fixed duration after /play
//

import CompositorServices
import Metal
import MetalKit
import simd

/// Vertex structure matching TitleShaders.metal
struct TitleVertex {
    var position: SIMD3<Float>
    var texcoord: SIMD2<Float>
}

/// Renders title.png as a textured quad for a set duration
final class TitleRenderer {

    // MARK: - Metal objects

    private let renderPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let texture: MTLTexture

    // MARK: - Timing

    private var showStartTime: CFAbsoluteTime = 0
    private var isShowing: Bool = false
    private let displayDuration: CFAbsoluteTime

    // MARK: - Init

    init(device: MTLDevice, library: MTLLibrary, layerRenderer: LayerRenderer) throws {
        // 1. Load title.png texture
        let textureLoader = MTKTextureLoader(device: device)
        guard let textureURL = Bundle.main.url(forResource: "title", withExtension: "png") else {
            throw NSError(domain: "TitleRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "title.png not found in bundle"])
        }
        self.texture = try textureLoader.newTexture(URL: textureURL, options: [
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
        ])

        self.displayDuration = CFAbsoluteTime(AppConfig.Rendering.titleDisplayDuration)

        // 2. Calculate quad size from aspect ratio
        let quadWidth: Float = AppConfig.Rendering.titleQuadWidth
        let aspect = Float(texture.height) / Float(texture.width)
        let quadHeight = quadWidth * aspect

        let hw = quadWidth / 2   // half width
        let hh = quadHeight / 2  // half height

        // 3. Create 6-vertex quad on XY plane (U flipped for -Z viewing)
        let vertices: [TitleVertex] = [
            // Triangle 1
            TitleVertex(position: SIMD3<Float>(-hw, -hh, 0), texcoord: SIMD2<Float>(1, 1)),
            TitleVertex(position: SIMD3<Float>( hw, -hh, 0), texcoord: SIMD2<Float>(0, 1)),
            TitleVertex(position: SIMD3<Float>( hw,  hh, 0), texcoord: SIMD2<Float>(0, 0)),
            // Triangle 2
            TitleVertex(position: SIMD3<Float>(-hw, -hh, 0), texcoord: SIMD2<Float>(1, 1)),
            TitleVertex(position: SIMD3<Float>( hw,  hh, 0), texcoord: SIMD2<Float>(0, 0)),
            TitleVertex(position: SIMD3<Float>(-hw,  hh, 0), texcoord: SIMD2<Float>(1, 0)),
        ]

        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<TitleVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            throw NSError(domain: "TitleRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create vertex buffer"])
        }
        self.vertexBuffer = buffer

        // 4. Render pipeline with alpha blending
        let vertexFunction = library.makeFunction(name: "titleVertex")!
        let fragmentFunction = library.makeFunction(name: "titleFragment")!

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.label = "Title Render Pipeline"
        pipelineDesc.vertexFunction = vertexFunction
        pipelineDesc.fragmentFunction = fragmentFunction
        pipelineDesc.rasterSampleCount = device.rasterSampleCount
        pipelineDesc.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        pipelineDesc.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat

        let colorAttachment = pipelineDesc.colorAttachments[0]!
        colorAttachment.pixelFormat = layerRenderer.configuration.colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .sourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        self.renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)

        // 5. Depth state (reverse-Z)
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .greater
        depthDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDesc)!

        print("[TitleRenderer] Initialized (quad \(quadWidth)m x \(quadWidth * aspect)m)")
    }

    // MARK: - Show / Hide

    func show() {
        showStartTime = CFAbsoluteTimeGetCurrent()
        isShowing = true
    }

    func hide() {
        isShowing = false
    }

    // MARK: - Should render

    var shouldRender: Bool {
        guard isShowing else { return false }
        let elapsed = CFAbsoluteTimeGetCurrent() - showStartTime
        if elapsed >= displayDuration {
            isShowing = false
            return false
        }
        return true
    }

    // MARK: - Render

    func renderInto(
        encoder: MTLRenderCommandEncoder,
        uniforms: Uniforms,
        viewProjectionBuffer: MTLBuffer,
        viewProjectionOffset: Int,
        viewports: [MTLViewport],
        viewCount: Int
    ) {
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

        var uniformsCopy = uniforms
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniformsCopy, length: MemoryLayout<Uniforms>.stride, index: 2)
        encoder.setVertexBuffer(viewProjectionBuffer, offset: viewProjectionOffset, index: 3)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
