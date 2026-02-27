//
//  PLYLoader.swift
//  ShiibaVisionOsVisualizer
//
//  Created by 堀宏行 on 2026/02/17.
//

import Foundation
import Metal

enum PLYLoaderError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidHeader
    case unsupportedFormat
    case unexpectedDataSize(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "PLY file not found: \(name)"
        case .invalidHeader:
            return "PLY header is invalid or could not be parsed."
        case .unsupportedFormat:
            return "Only binary_little_endian PLY format is supported."
        case .unexpectedDataSize(let expected, let actual):
            return "Data size mismatch: expected \(expected) bytes, got \(actual) bytes."
        }
    }
}

/// Loads a PLY file from the app bundle and returns a PointCloudData ready for GPU use.
actor PLYLoader {

    /// Loads a PLY file by resource name from the main bundle.
    /// - Parameters:
    ///   - name: Resource name without extension (e.g. "frame_0001")
    ///   - extension: File extension (default: "ply")
    ///   - device: MTLDevice to allocate buffers on
    /// - Returns: PointCloudData with input/output MTLBuffers
    func load(name: String, extension ext: String = "ply", device: MTLDevice) async throws -> PointCloudData {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            throw PLYLoaderError.fileNotFound("\(name).\(ext)")
        }
        return try await load(url: url, device: device)
    }

    /// Loads a PLY file from an arbitrary URL.
    func load(url: URL, device: MTLDevice) async throws -> PointCloudData {
        // ① ディスク読み込み
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // ② ヘッダパース（頂点数・フォーマット確認のみ）
        let (pointCount, binaryStart) = try parsePLYHeader(data: data)

        // ③ MTLBuffer 確保 + ディスクデータを直接コピー（中間配列なし）
        guard let pointCloudData = PointCloudData(
            data: data,
            binaryStart: binaryStart,
            pointCount: pointCount,
            device: device
        ) else {
            throw PLYLoaderError.invalidHeader
        }

        return pointCloudData
    }

    // MARK: - Private

    /// ヘッダのみをパースし、頂点数とバイナリデータの開始位置を返す。
    /// 中間配列を作らず、バイナリデータはそのまま MTLBuffer に渡す。
    private func parsePLYHeader(data: Data) throws -> (pointCount: Int, binaryStart: Data.Index) {
        guard let headerRange = findHeaderEnd(in: data) else {
            throw PLYLoaderError.invalidHeader
        }

        let headerData = data[data.startIndex..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw PLYLoaderError.invalidHeader
        }

        let vertexCount = try parseVertexCount(from: headerString)
        try validateFormat(header: headerString)

        let binaryStart = headerRange.upperBound
        let bytesPerPoint = 27
        let expectedBytes = vertexCount * bytesPerPoint
        let actualBytes = data.count - binaryStart

        guard actualBytes >= expectedBytes else {
            throw PLYLoaderError.unexpectedDataSize(expected: expectedBytes, actual: actualBytes)
        }

        return (vertexCount, binaryStart)
    }

    private func findHeaderEnd(in data: Data) -> Range<Data.Index>? {
        let marker = "end_header\n"
        guard let markerData = marker.data(using: .utf8) else { return nil }
        return data.range(of: markerData)
    }

    private func parseVertexCount(from header: String) throws -> Int {
        let lines = header.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("element vertex") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 3, let count = Int(parts[2]) {
                    return count
                }
            }
        }
        throw PLYLoaderError.invalidHeader
    }

    private func validateFormat(header: String) throws {
        guard header.contains("format binary_little_endian") else {
            throw PLYLoaderError.unsupportedFormat
        }
    }
}
