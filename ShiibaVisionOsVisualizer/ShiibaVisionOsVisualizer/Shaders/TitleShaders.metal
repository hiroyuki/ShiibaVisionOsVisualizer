//
//  TitleShaders.metal
//  ShiibaVisionOsVisualizer
//
//  Metal shaders for rendering a textured quad (title image)
//

#include <metal_stdlib>
#include <simd/simd.h>
#include "../ShaderTypes.h"

using namespace metal;

struct TitleVertex {
    float3 position;
    float2 texcoord;
};

struct TitleFragIn {
    float4 position [[position]];
    float2 texcoord;
};

vertex TitleFragIn titleVertex(
    device const TitleVertex*          vertices        [[ buffer(0) ]],
    constant     Uniforms&             uniforms        [[ buffer(BufferIndexUniforms) ]],
    constant     ViewProjectionArray&  viewProjection  [[ buffer(BufferIndexViewProjection) ]],
    ushort amp_id                                      [[ amplification_id ]],
    uint   vertexID                                    [[ vertex_id ]]
) {
    TitleVertex vert = vertices[vertexID];

    float4 worldPos = uniforms.modelMatrix * float4(vert.position, 1.0);
    float4 clipPos  = viewProjection.viewProjectionMatrix[amp_id] * worldPos;

    TitleFragIn out;
    out.position = clipPos;
    out.texcoord = vert.texcoord;
    return out;
}

fragment float4 titleFragment(
    TitleFragIn              in       [[ stage_in ]],
    texture2d<float>         tex      [[ texture(TextureIndexColor) ]]
) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.texcoord);
}
