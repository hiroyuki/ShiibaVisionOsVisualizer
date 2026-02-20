//
//  AxesRenderer.swift
//  ShiibaVisionOsVisualizer
//
//  Created for rendering draggable XYZ axes using Metal
//

import ARKit
import CompositorServices
import Metal
import simd

/// Vertex structure matching AxesShaders.metal
struct AxisVertex {
    var position: SIMD3<Float>
    var color: SIMD3<Float>
}

/// Renders XYZ axes as colored lines using Metal
final class AxesRenderer {
    
    // MARK: - Metal objects
    
    private let device: MTLDevice
    private let renderPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    
    // MARK: - Placement
    
    /// Model matrix: places the axes in the world
    var modelMatrix: matrix_float4x4 = matrix_identity_float4x4
    
    // MARK: - Init
    
    init(device: MTLDevice, layerRenderer: LayerRenderer) throws {
        self.device = device
        
        let library = device.makeDefaultLibrary()!
        
        // Render pipeline
        let vertexFunction = library.makeFunction(name: "axesVertex")!
        let fragmentFunction = library.makeFunction(name: "axesFragment")!
        
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.label = "Axes Render Pipeline"
        renderDescriptor.vertexFunction = vertexFunction
        renderDescriptor.fragmentFunction = fragmentFunction
        renderDescriptor.rasterSampleCount = device.rasterSampleCount
        renderDescriptor.maxVertexAmplificationCount = layerRenderer.properties.viewCount
        
        let colorAttachment = renderDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = layerRenderer.configuration.colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        colorAttachment.sourceRGBBlendFactor = .sourceAlpha
        colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colorAttachment.sourceAlphaBlendFactor = .sourceAlpha
        colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        renderDescriptor.depthAttachmentPixelFormat = layerRenderer.configuration.depthFormat
        
        self.renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        
        // Depth state (reverse-Z)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDescriptor)!
        
        // Create vertices for XYZ axes as triangles (lines as thin quads)
        // Each axis is rendered as a cylinder approximation (thin rectangular prism)
        let axisLength: Float = 0.5  // 50cm - more visible
        let thickness: Float = 0.01  // 1cm thick - more visible
        
        var vertices: [AxisVertex] = []
        
        // Helper function to create a line as a quad (2 triangles = 6 vertices)
        func addLineQuad(from start: SIMD3<Float>, to end: SIMD3<Float>, color: SIMD3<Float>) {
            let direction = normalize(end - start)
            let perpendicular: SIMD3<Float>
            
            // Find a perpendicular vector
            if abs(direction.y) < 0.9 {
                perpendicular = normalize(cross(direction, SIMD3<Float>(0, 1, 0)))
            } else {
                perpendicular = normalize(cross(direction, SIMD3<Float>(1, 0, 0)))
            }
            
            let offset = perpendicular * thickness / 2
            
            // Create 4 corners of the quad
            let v0 = start + offset
            let v1 = start - offset
            let v2 = end + offset
            let v3 = end - offset
            
            // First triangle
            vertices.append(AxisVertex(position: v0, color: color))
            vertices.append(AxisVertex(position: v1, color: color))
            vertices.append(AxisVertex(position: v2, color: color))
            
            // Second triangle
            vertices.append(AxisVertex(position: v1, color: color))
            vertices.append(AxisVertex(position: v3, color: color))
            vertices.append(AxisVertex(position: v2, color: color))
        }
        
        // X axis (Red)
        addLineQuad(
            from: SIMD3<Float>(0, 0, 0),
            to: SIMD3<Float>(axisLength, 0, 0),
            color: SIMD3<Float>(1, 0, 0)
        )
        
        // Y axis (Green)
        addLineQuad(
            from: SIMD3<Float>(0, 0, 0),
            to: SIMD3<Float>(0, axisLength, 0),
            color: SIMD3<Float>(0, 1, 0)
        )
        
        // Z axis (Blue)
        addLineQuad(
            from: SIMD3<Float>(0, 0, 0),
            to: SIMD3<Float>(0, 0, axisLength),
            color: SIMD3<Float>(0, 0, 1)
        )
        
        guard let buffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<AxisVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            throw NSError(domain: "AxesRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create vertex buffer"])
        }
        
        self.vertexBuffer = buffer
        
        print("[AxesRenderer] Initialized with \(vertices.count) vertices (triangles)")
    }
    
    // MARK: - Per-frame encoding
    
    func encode(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor,
        uniformsBuffer: MTLBuffer,
        uniformsOffset: Int,
        viewProjectionBuffer: MTLBuffer,
        viewProjectionOffset: Int,
        viewports: [MTLViewport],
        viewCount: Int
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "Axes Render"
        
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
        
        // Bind vertex buffer
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // Bind uniforms (model matrix)
        encoder.setVertexBuffer(uniformsBuffer, offset: uniformsOffset, index: 2) // BufferIndexUniforms
        
        // Bind view-projection matrices
        encoder.setVertexBuffer(viewProjectionBuffer, offset: viewProjectionOffset, index: 3) // BufferIndexViewProjection
        
        // Draw as triangles (3 axes * 2 triangles per axis * 3 vertices per triangle = 18 vertices)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 18)
        
        encoder.endEncoding()
    }
}
