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
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let points = try parsePLY(data: data)

        guard let pointCloudData = PointCloudData(points: points, device: device) else {
            throw PLYLoaderError.invalidHeader
        }
        return pointCloudData
    }

    // MARK: - Private

    private func parsePLY(data: Data) throws -> [UnityPoint] {
        // Find the end of the header ("end_header\n")
        guard let headerRange = findHeaderEnd(in: data) else {
            throw PLYLoaderError.invalidHeader
        }

        let headerData = data[data.startIndex..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw PLYLoaderError.invalidHeader
        }

        // Parse vertex count and validate format
        let vertexCount = try parseVertexCount(from: headerString)
        try validateFormat(header: headerString)

        // Binary data starts after "end_header\n"
        let binaryStart = headerRange.upperBound
        let binaryData = data[binaryStart...]

        // Each point is 27 bytes (packed):
        // float x,y,z (12) + uchar r,g,b (3) + float vx,vy,vz (12)
        let bytesPerPoint = 27
        let expectedBytes = vertexCount * bytesPerPoint

        guard binaryData.count >= expectedBytes else {
            throw PLYLoaderError.unexpectedDataSize(expected: expectedBytes, actual: binaryData.count)
        }

        return try parseBinaryPoints(data: binaryData, count: vertexCount)
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

    private func parseBinaryPoints(data: Data.SubSequence, count: Int) throws -> [UnityPoint] {
        var points = [UnityPoint]()
        points.reserveCapacity(count)

        // Work with raw bytes for performance
        try data.withUnsafeBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress!
            let bytesPerPoint = 27

            for i in 0..<count {
                let offset = i * bytesPerPoint

                // float x, y, z (4 bytes each, little-endian)
                let x = ptr.loadUnaligned(fromByteOffset: offset + 0, as: Float.self)
                let y = ptr.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = ptr.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)

                // uchar r, g, b (1 byte each)
                let r = ptr.load(fromByteOffset: offset + 12, as: UInt8.self)
                let g = ptr.load(fromByteOffset: offset + 13, as: UInt8.self)
                let b = ptr.load(fromByteOffset: offset + 14, as: UInt8.self)

                // float vx, vy, vz (4 bytes each, little-endian)
                let vx = ptr.loadUnaligned(fromByteOffset: offset + 15, as: Float.self)
                let vy = ptr.loadUnaligned(fromByteOffset: offset + 19, as: Float.self)
                let vz = ptr.loadUnaligned(fromByteOffset: offset + 23, as: Float.self)

                points.append(UnityPoint(x: x, y: y, z: z,
                                         r: r, g: g, b: b,
                                         vx: vx, vy: vy, vz: vz))
            }
        }

        return points
    }
}
