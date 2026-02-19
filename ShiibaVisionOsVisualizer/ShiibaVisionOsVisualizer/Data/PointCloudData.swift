//
//  PointCloudData.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import Foundation
import Metal
import simd

/// Holds the raw point cloud data loaded from a PLY file,
/// along with a Metal buffer ready for GPU processing.
struct PointCloudData {

    /// Total number of points
    let pointCount: Int

    /// MTLBuffer containing the raw Unity-format point data.
    /// Used as input to the compute shader.
    let inputBuffer: MTLBuffer

    /// MTLBuffer that the compute shader writes converted (VisionOS-format) points into.
    /// Used as input to the vertex shader.
    let outputBuffer: MTLBuffer

    /// PLY バイナリデータを中間配列なしで直接 MTLBuffer に転送する。
    /// - Parameters:
    ///   - data: PLY ファイル全体の Data
    ///   - binaryStart: バイナリデータの開始オフセット（ヘッダの直後）
    ///   - pointCount: 頂点数
    ///   - device: MTLDevice
    init?(data: Data, binaryStart: Data.Index, pointCount: Int, device: MTLDevice) {
        guard pointCount > 0 else { return nil }

        self.pointCount = pointCount

        // Input buffer: PLY バイナリを1回のコピーで直接転送（中間配列なし）
        // 27 bytes/point (packed): float x,y,z + uchar r,g,b + float vx,vy,vz
        let bytesPerPoint = 27
        let inputByteCount = pointCount * bytesPerPoint

        guard let inputBuf = data.withUnsafeBytes({ rawBuffer -> MTLBuffer? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            // binaryStart は data.startIndex からの絶対位置
            // data.startIndex が 0 でない場合に備えて明示的に計算
            let byteOffset = binaryStart - data.startIndex
            let binaryPtr = baseAddress.advanced(by: byteOffset)
            return device.makeBuffer(bytes: binaryPtr,
                                     length: inputByteCount,
                                     options: .storageModeShared)
        }) else { return nil }

        inputBuf.label = "PointCloud Input Buffer (Unity)"
        self.inputBuffer = inputBuf

        // Output buffer: compute shader が書き込む VisionOS 形式
        // PointVertex: float4 position + float4 color = 32 bytes/point
        // SIMD3<Float>.stride = 16 bytes なので stride*2 = 32 bytes で一致
        let outputByteCount = pointCount * (MemoryLayout<SIMD3<Float>>.stride * 2)
        guard let outputBuf = device.makeBuffer(length: outputByteCount,
                                                options: .storageModeShared) else {
            return nil
        }
        outputBuf.label = "PointCloud Output Buffer (VisionOS)"
        self.outputBuffer = outputBuf
    }
}
