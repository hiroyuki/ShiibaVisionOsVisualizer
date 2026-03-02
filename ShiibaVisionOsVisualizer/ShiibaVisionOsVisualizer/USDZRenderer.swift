//
//  USDZRenderer.swift
//  ShiibaVisionOsVisualizer
//
//  Loads a USDZ file via ModelIO and renders it Unlit with Metal
//

import CompositorServices
import Metal
import MetalKit
import ModelIO
import simd

// Buffer / attribute indices (mirrors ShaderTypes.h)
private let kAttributePosition      = 0
private let kAttributeTexcoord      = 1
private let kBufferIndexUniforms    = 2
private let kBufferIndexViewProjection = 3
private let kTextureIndexColor      = 0

final class USDZRenderer {

    // MARK: - Metal objects

    private let device: MTLDevice
    private let renderPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let meshes: [MTKMesh]
    private let submeshTextures: [[MTLTexture]]
    private let fallbackTexture: MTLTexture

    // MARK: - Placement

    /// Base model matrix from world anchor
    var modelMatrix: matrix_float4x4 = matrix_identity_float4x4

    /// Position offset from the anchor (meters)
    var positionOffset = SIMD3<Float>(0, 0, 0)

    /// Rotation offset (radians, applied as X → Y → Z euler)
    var rotationOffset = SIMD3<Float>(0, .pi, 0)

    /// Final matrix combining anchor + offset
    var effectiveModelMatrix: matrix_float4x4 {
        let t = matrix4x4_translation(positionOffset.x, positionOffset.y, positionOffset.z)
        let rx = matrix4x4_rotation(radians: rotationOffset.x, axis: SIMD3<Float>(1, 0, 0))
        let ry = matrix4x4_rotation(radians: rotationOffset.y, axis: SIMD3<Float>(0, 1, 0))
        let rz = matrix4x4_rotation(radians: rotationOffset.z, axis: SIMD3<Float>(0, 0, 1))
        return modelMatrix * t * ry * rx * rz
    }

    // MARK: - Init

    init(device: MTLDevice, library: MTLLibrary, layerRenderer: LayerRenderer) throws {
        self.device = device

        // -- Vertex Descriptor --
        let mtlVertexDescriptor = MTLVertexDescriptor()
        // Position: float3
        mtlVertexDescriptor.attributes[kAttributePosition].format = .float3
        mtlVertexDescriptor.attributes[kAttributePosition].offset = 0
        mtlVertexDescriptor.attributes[kAttributePosition].bufferIndex = 0
        // UV: float2
        mtlVertexDescriptor.attributes[kAttributeTexcoord].format = .float2
        mtlVertexDescriptor.attributes[kAttributeTexcoord].offset = 12
        mtlVertexDescriptor.attributes[kAttributeTexcoord].bufferIndex = 0
        // Layout
        mtlVertexDescriptor.layouts[0].stride = 20  // float3 (12) + float2 (8)

        // -- Render Pipeline --
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.label = "USDZ Render Pipeline"
        pipelineDesc.vertexFunction = library.makeFunction(name: "usdzVertex")!
        pipelineDesc.fragmentFunction = library.makeFunction(name: "usdzFragment")!
        pipelineDesc.vertexDescriptor = mtlVertexDescriptor
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

        // -- Depth State (reverse-Z) --
        let depthDesc = MTLDepthStencilDescriptor()
        depthDesc.depthCompareFunction = .greater
        depthDesc.isDepthWriteEnabled = true
        self.depthState = device.makeDepthStencilState(descriptor: depthDesc)!

        // -- Fallback texture (1x1 white) --
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        texDesc.usage = .shaderRead
        guard let fallback = device.makeTexture(descriptor: texDesc) else {
            throw NSError(domain: "USDZRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create fallback texture"])
        }
        let white: [UInt8] = [255, 255, 255, 255]
        fallback.replace(
            region: MTLRegion(origin: .init(), size: .init(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0, withBytes: white, bytesPerRow: 4)
        self.fallbackTexture = fallback

        // -- Load USDZ --
        guard let url = Bundle.main.url(forResource: "kozaki", withExtension: "usdz") else {
            throw NSError(domain: "USDZRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "kozaki.usdz not found in bundle"])
        }

        let mdlVertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVertexDescriptor)
        (mdlVertexDescriptor.attributes[0] as! MDLVertexAttribute).name = MDLVertexAttributePosition
        (mdlVertexDescriptor.attributes[1] as! MDLVertexAttribute).name = MDLVertexAttributeTextureCoordinate

        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: mdlVertexDescriptor, bufferAllocator: allocator)
        asset.loadTextures()  // .url/.string → .texture に変換

        let (mdlMeshes, mtkMeshes) = try MTKMesh.newMeshes(asset: asset, device: device)
        self.meshes = mtkMeshes

        // -- Extract textures --
        let textureLoader = MTKTextureLoader(device: device)
        var allSubmeshTextures: [[MTLTexture]] = []

        for mdlMesh in mdlMeshes {
            var meshTextures: [MTLTexture] = []
            if let submeshes = mdlMesh.submeshes as? [MDLSubmesh] {
                for submesh in submeshes {
                    var texture: MTLTexture = fallback
                    if let material = submesh.material {
                        // Try baseColor first, then scan all properties
                        let mdlTexture: MDLTexture? = {
                            if let prop = material.property(with: .baseColor),
                               prop.type == .texture,
                               let tex = prop.textureSamplerValue?.texture {
                                return tex
                            }
                            for i in 0..<material.count {
                                if let prop = material[i],
                                   prop.type == .texture,
                                   let tex = prop.textureSamplerValue?.texture {
                                    return tex
                                }
                            }
                            return nil
                        }()

                        if let mdlTexture {
                            do {
                                texture = try textureLoader.newTexture(
                                    texture: mdlTexture,
                                    options: [
                                        .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                                        .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
                                        .SRGB: true
                                    ])
                            } catch {
                                print("[USDZRenderer] Failed to load texture: \(error)")
                            }
                        }
                    }
                    meshTextures.append(texture)
                }
            }
            allSubmeshTextures.append(meshTextures)
        }
        self.submeshTextures = allSubmeshTextures

        let totalSubmeshes = allSubmeshTextures.reduce(0) { $0 + $1.count }
        let texturedCount = allSubmeshTextures.flatMap { $0 }.filter { $0 !== fallback }.count
        print("[USDZRenderer] Loaded kozaki.usdz: \(meshes.count) mesh(es), \(totalSubmeshes) submesh(es), \(texturedCount) textured")
    }

    // MARK: - Per-frame encoding

    func renderInto(
        encoder: MTLRenderCommandEncoder,
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

        // Use setVertexBytes to inline the model matrix — avoids shared uniform buffer race
        var usdzUniforms = Uniforms(modelMatrix: effectiveModelMatrix)
        encoder.setVertexBytes(&usdzUniforms, length: MemoryLayout<Uniforms>.stride, index: kBufferIndexUniforms)
        encoder.setVertexBuffer(viewProjectionBuffer, offset: viewProjectionOffset, index: kBufferIndexViewProjection)

        for (meshIndex, mesh) in meshes.enumerated() {
            let vertexBuffer = mesh.vertexBuffers[0]
            encoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: 0)

            for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
                let texture: MTLTexture
                if meshIndex < submeshTextures.count && submeshIndex < submeshTextures[meshIndex].count {
                    texture = submeshTextures[meshIndex][submeshIndex]
                } else {
                    texture = fallbackTexture
                }
                encoder.setFragmentTexture(texture, index: kTextureIndexColor)

                encoder.drawIndexedPrimitives(
                    type: submesh.primitiveType,
                    indexCount: submesh.indexCount,
                    indexType: submesh.indexType,
                    indexBuffer: submesh.indexBuffer.buffer,
                    indexBufferOffset: submesh.indexBuffer.offset
                )
            }
        }
    }
}
