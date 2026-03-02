//
//  USDZShaders.metal
//  ShiibaVisionOsVisualizer
//
//  Unlit shaders for rendering USDZ models with texture
//

#include <metal_stdlib>
#include <simd/simd.h>
#include "../ShaderTypes.h"

using namespace metal;

struct USDZVertexIn {
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texcoord [[attribute(VertexAttributeTexcoord)]];
};

struct USDZFragmentIn {
    float4 position [[position]];
    float2 texcoord;
};

vertex USDZFragmentIn usdzVertex(
    USDZVertexIn in                              [[stage_in]],
    constant Uniforms&            uniforms       [[buffer(BufferIndexUniforms)]],
    constant ViewProjectionArray& viewProjection [[buffer(BufferIndexViewProjection)]],
    ushort amp_id                                [[amplification_id]]
) {
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);

    USDZFragmentIn out;
    out.position = viewProjection.viewProjectionMatrix[amp_id] * worldPos;
    out.texcoord = float2(in.texcoord.x, 1.0 - in.texcoord.y);  // USD V-flip: bottom-left → top-left
    return out;
}

fragment float4 usdzFragment(
    USDZFragmentIn in                       [[stage_in]],
    texture2d<float> baseColor              [[texture(TextureIndexColor)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, mip_filter::linear);
    return baseColor.sample(texSampler, in.texcoord);
}
