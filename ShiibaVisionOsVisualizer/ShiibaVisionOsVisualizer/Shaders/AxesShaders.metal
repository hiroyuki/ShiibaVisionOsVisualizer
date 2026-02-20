//
//  AxesShaders.metal
//  ShiibaVisionOsVisualizer
//
//  Created for displaying XYZ axes as lines in Metal
//

#include <metal_stdlib>
#include <simd/simd.h>
#include "../ShaderTypes.h"

using namespace metal;

struct AxisVertex {
    float3 position;
    float3 color;
};

struct AxisFragmentIn {
    float4 position [[position]];
    float3 color;
};

vertex AxisFragmentIn axesVertex(
    device const AxisVertex*          vertices        [[ buffer(0) ]],
    constant     Uniforms&            uniforms        [[ buffer(BufferIndexUniforms) ]],
    constant     ViewProjectionArray& viewProjection  [[ buffer(BufferIndexViewProjection) ]],
    ushort amp_id                                     [[ amplification_id ]],
    uint   vertexID                                   [[ vertex_id ]]
) {
    AxisVertex vert = vertices[vertexID];
    
    // Transform vertex position through model matrix
    float4 worldPos = uniforms.modelMatrix * float4(vert.position, 1.0);
    
    // Transform to clip space
    float4 clipPos = viewProjection.viewProjectionMatrix[amp_id] * worldPos;
    
    AxisFragmentIn out;
    out.position = clipPos;
    out.color = vert.color;
    return out;
}

fragment float4 axesFragment(
    AxisFragmentIn in [[ stage_in ]]
) {
    return float4(in.color, 1.0);
}
