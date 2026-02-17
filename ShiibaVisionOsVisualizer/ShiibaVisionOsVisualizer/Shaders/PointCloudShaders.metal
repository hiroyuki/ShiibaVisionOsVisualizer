//
//  PointCloudShaders.metal
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

#include <metal_stdlib>
#include <simd/simd.h>
#include "../ShaderTypes.h"

using namespace metal;

// MARK: - Data Structures

/// Input point in Unity's packed binary format (27 bytes, no padding)
struct UnityPointData {
    packed_float3 position;  // 12 bytes (x, y, z in Unity left-handed coords)
    uchar3        color;     //  3 bytes (r, g, b as 0-255)
    packed_float3 velocity;  // 12 bytes (vx, vy, vz in Unity coords)
} __attribute__((packed));   // total: 27 bytes

/// Output point in VisionOS format, written by compute shader, read by vertex shader
struct PointVertex {
    float3 position;  // VisionOS right-handed coordinate
    float3 color;     // Linear color (0.0 - 1.0)
};

/// Vertex shader output / fragment shader input
struct PointFragIn {
    float4 position [[position]];
    float3 color;
    float  pointSize [[point_size]];
};

// MARK: - Compute Shader

/// Converts point cloud data from Unity format to VisionOS format.
/// - Coordinate system: Unity left-handed (-x, y, z) → VisionOS right-handed
/// - Color: uchar 0-255 → float 0.0-1.0, sRGB → Linear (pow 2.2)
/// - Velocity: same coordinate conversion as position (reserved for future use)
kernel void pointCloudConvert(
    device const UnityPointData* inputPoints  [[ buffer(BufferIndexPointCloudInput)  ]],
    device       PointVertex*    outputPoints [[ buffer(BufferIndexPointCloudOutput) ]],
    uint index [[ thread_position_in_grid ]]
) {
    UnityPointData src = inputPoints[index];

    // Unity (left-handed) → VisionOS (right-handed): negate X axis
    outputPoints[index].position = float3(-src.position.x,
                                           src.position.y,
                                           src.position.z);

    // sRGB (0-255) → Linear float (0.0-1.0)
    float3 srgb = float3(src.color) / 255.0;
//    outputPoints[index].color = pow(srgb, float3(2.2));
    outputPoints[index].color = float3(src.color) / 255.0;
}

// MARK: - Vertex Shader

/// Renders each point as a point sprite.
/// Point size scales with distance: closer points appear larger.
vertex PointFragIn pointCloudVertex(
    device const PointVertex*      points            [[ buffer(BufferIndexPointCloudOutput) ]],
    constant     Uniforms&         uniforms          [[ buffer(BufferIndexUniforms)         ]],
    constant     ViewProjectionArray& viewProjection [[ buffer(BufferIndexViewProjection)   ]],
    ushort amp_id                                    [[ amplification_id                    ]],
    uint   vertexID                                  [[ vertex_id                           ]]
) {
    PointVertex point = points[vertexID];

    float4 worldPos = uniforms.modelMatrix * float4(point.position, 1.0);
    float4 clipPos  = viewProjection.viewProjectionMatrix[amp_id] * worldPos;

    // Distance-based point size: closer = larger, farther = smaller
    // Clamp between 2 and 12 pixels
    float dist      = length(worldPos.xyz);
    float pointSize = clamp(8.0 / dist, 2.0, 12.0);

    PointFragIn out;
    out.position  = clipPos;
    out.color     = point.color;
    out.pointSize = pointSize;
    return out;
}

// MARK: - Fragment Shader

/// Renders each point as a soft circle (circular clipping + edge fade).
fragment float4 pointCloudFragment(
    PointFragIn in          [[ stage_in      ]],
    float2      pointCoord  [[ point_coord   ]]
) {
    // pointCoord is (0,0) top-left to (1,1) bottom-right of the point sprite
    // Convert to [-1, 1] range and compute distance from center
    float2 uv   = pointCoord * 2.0 - 1.0;
    float  dist = length(uv);

    // Discard pixels outside the circle
    if (dist > 1.0) {
        discard_fragment();
    }

    // Soft edge fade
    float alpha = 1.0 - smoothstep(0.7, 1.0, dist);

    return float4(in.color, alpha);
}
