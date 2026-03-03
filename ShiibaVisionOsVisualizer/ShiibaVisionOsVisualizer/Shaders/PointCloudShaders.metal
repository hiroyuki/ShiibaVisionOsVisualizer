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

/// Input point in Unity's packed binary format (15 bytes, no padding)
/// NOTE: uchar3 は Metal で 4バイトアライメントされるため使用不可。
///       r, g, b を個別の uchar として定義することで packed 15バイトを正確に読む。
struct UnityPointData {
    packed_float3 position;  // 12 bytes: x, y, z
    uchar         r;         //  1 byte
    uchar         g;         //  1 byte
    uchar         b;         //  1 byte
} __attribute__((packed));   // total: 15 bytes

/// Output point in VisionOS format, written by compute shader, read by vertex shader
/// NOTE: float3 は GPU 上で 16 バイトアライメントされるため、
///       明示的に float4 を使い Swift 側と byte layout を一致させる。
///       w 成分はそれぞれ 1.0 / 0.0 で埋める（未使用）。
struct PointVertex {
    float4 position;  // VisionOS right-handed coordinate (w = 1.0)
    float4 color;     // Linear color (0.0 - 1.0)        (w = 0.0)
};

/// Vertex shader output / fragment shader input
struct PointFragIn {
    float4 position [[position]];
    float3 color;
    float2 uv;       // [-1, 1] range, used for circular clipping in fragment shader
};

// MARK: - Background Overlay

/// Full-screen triangle for semi-transparent background overlay.
/// Uses a single oversized triangle (3 vertices) to cover the entire viewport.
struct OverlayOut {
    float4 position [[position]];
};

vertex OverlayOut overlayVertex(uint vertexID [[ vertex_id ]]) {
    // Oversized triangle covering the full NDC quad [-1,1]
    float2 pos[3] = {
        float2(-1.0, -3.0),
        float2(-1.0,  1.0),
        float2( 3.0,  1.0)
    };
    OverlayOut out;
    out.position = float4(pos[vertexID], 0.0001, 1.0);
    return out;
}

fragment float4 overlayFragment(
    constant RenderParams& params [[ buffer(0) ]]
) {
    return float4(0.0, 0.0, 0.0, params.overlayAlpha);
}

// MARK: - Compute Shader

/// Converts point cloud data from Unity format to VisionOS format.
/// - Coordinate system: Unity left-handed (-x, y, z) → VisionOS right-handed
/// - Color: uchar 0-255 → float 0.0-1.0
kernel void pointCloudConvert(
    device const UnityPointData* inputPoints  [[ buffer(BufferIndexPointCloudInput)  ]],
    device       PointVertex*    outputPoints [[ buffer(BufferIndexPointCloudOutput) ]],
    constant     RenderParams&   params       [[ buffer(BufferIndexRenderParams)     ]],
    uint index [[ thread_position_in_grid ]]
) {
    UnityPointData src = inputPoints[index];

    // Unity (left-handed) → VisionOS (right-handed): negate X axis
    // Y座標フィルタリング: 閾値以下のポイントは w=0.0 で無効化（床面ノイズ除去）
    float yThreshold = params.floorNoiseThreshold;
    float w = (src.position.y >= yThreshold) ? 1.0 : 0.0;

    outputPoints[index].position = float4(-src.position.x,
                                           src.position.y,
                                           src.position.z,
                                           w);

    // PLY の色データ (sRGB, 0-255) を正規化して渡す。
    outputPoints[index].color = float4(float(src.r) / 255.0,
                                       float(src.g) / 255.0,
                                       float(src.b) / 255.0,
                                       0.0);
}

// MARK: - Vertex Shader

/// Renders each point as a billboard quad (2 triangles) using instancing.
/// - instanceID: indexes into the point cloud buffer
/// - vertexID (0-5): defines the 6 vertices of the quad (2 triangles)
/// Compatible with rasterization rate map (foveated rendering on visionOS).
vertex PointFragIn pointCloudVertex(
    device const PointVertex*         points            [[ buffer(BufferIndexPointCloudOutput) ]],
    constant     Uniforms&            uniforms          [[ buffer(BufferIndexUniforms)         ]],
    constant     ViewProjectionArray& viewProjection    [[ buffer(BufferIndexViewProjection)   ]],
    constant     RenderParams&        params            [[ buffer(BufferIndexRenderParams)     ]],
    ushort amp_id                                       [[ amplification_id                    ]],
    uint   vertexID                                     [[ vertex_id                           ]],
    uint   instanceID                                   [[ instance_id                         ]]
) {
    PointVertex point = points[instanceID];

    // 無効化されたポイント（w=0.0）はクリップ空間外に配置してカリング
    if (point.position.w == 0.0) {
        PointFragIn out;
        out.position = float4(0, 0, -2, 1);
        out.color = float3(0);
        out.uv = float2(0);
        return out;
    }

    float4 worldPos = uniforms.modelMatrix * float4(point.position.xyz, 1.0);

    // Quad corners in UV space [-1, 1]
    // Two triangles: (0,1,2) and (3,4,5)
    //  3(=-1,+1)  1(=+1,+1)
    //  2(=-1,-1)  0(=+1,-1)
    const float2 uvs[6] = {
        float2( 1.0, -1.0),  // triangle 0
        float2( 1.0,  1.0),
        float2(-1.0, -1.0),
        float2(-1.0, -1.0),  // triangle 1
        float2( 1.0,  1.0),
        float2(-1.0,  1.0),
    };
    float2 uv = uvs[vertexID];

    // Billboard: build quad in world space using camera right/up vectors
    // extracted from the view-projection matrix rows.
    // physicalSize is the half-extent in meters → 1cm total diameter
    float3 camRight = float3(viewProjection.viewProjectionMatrix[amp_id][0][0],
                             viewProjection.viewProjectionMatrix[amp_id][1][0],
                             viewProjection.viewProjectionMatrix[amp_id][2][0]);
    float3 camUp    = float3(viewProjection.viewProjectionMatrix[amp_id][0][1],
                             viewProjection.viewProjectionMatrix[amp_id][1][1],
                             viewProjection.viewProjectionMatrix[amp_id][2][1]);

    float  physicalSize = params.pointPhysicalSize;
    float3 worldOffset  = (camRight * uv.x + camUp * uv.y) * physicalSize;
    float4 clipPos      = viewProjection.viewProjectionMatrix[amp_id]
                          * (worldPos + float4(worldOffset, 0.0));

    PointFragIn out;
    out.position = clipPos;
    out.color    = point.color.rgb;
    out.uv       = uv;
    return out;
}

// MARK: - Fragment Shader

/// Renders each point as an opaque circle (circular clipping, no alpha fade).
fragment float4 pointCloudFragment(
    PointFragIn in [[ stage_in ]]
) {
    float dist = length(in.uv);
    if (dist > 1.0) {
        discard_fragment();
    }
    return float4(in.color, 1.0);
}
