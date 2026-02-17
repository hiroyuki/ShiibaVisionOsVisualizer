//
//  PointCloudData.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import Foundation
import Metal
import simd

/// A single point in Unity's coordinate format, as read directly from the PLY binary.
/// Layout matches the packed binary format in the PLY file (27 bytes, no padding).
struct UnityPoint {
    var x: Float
    var y: Float
    var z: Float
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var vx: Float
    var vy: Float
    var vz: Float
}

/// Holds the raw point cloud data loaded from a PLY file,
/// along with a Metal buffer ready for GPU processing.
struct PointCloudData {

    /// Total number of points
    let pointCount: Int

    /// Raw points in Unity coordinate format
    let points: [UnityPoint]

    /// MTLBuffer containing the raw Unity-format point data.
    /// Used as input to the compute shader.
    let inputBuffer: MTLBuffer

    /// MTLBuffer that the compute shader writes converted (VisionOS-format) points into.
    /// Used as input to the vertex shader.
    let outputBuffer: MTLBuffer

    init?(points: [UnityPoint], device: MTLDevice) {
        guard !points.isEmpty else { return nil }

        self.pointCount = points.count
        self.points = points

        // Input buffer: raw Unity format (27 bytes per point, packed)
        // We copy into a buffer using the exact byte layout of UnityPoint
        let inputByteCount = points.count * MemoryLayout<UnityPoint>.stride
        guard let inputBuf = device.makeBuffer(bytes: points,
                                               length: inputByteCount,
                                               options: .storageModeShared) else {
            return nil
        }
        inputBuf.label = "PointCloud Input Buffer (Unity)"
        self.inputBuffer = inputBuf

        // Output buffer: converted VisionOS format (PointVertex: float3 position + float3 color = 24 bytes)
        let outputByteCount = points.count * (MemoryLayout<SIMD3<Float>>.stride * 2)
        guard let outputBuf = device.makeBuffer(length: outputByteCount,
                                                options: .storageModeShared) else {
            return nil
        }
        outputBuf.label = "PointCloud Output Buffer (VisionOS)"
        self.outputBuffer = outputBuf
    }
}
