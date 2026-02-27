//
//  OSCMessage.swift
//  ShiibaVisionOsVisualizer
//
//  OSC (Open Sound Control) binary protocol parser and builder.
//  Spec: https://opensoundcontrol.stanford.edu/spec-1_0.html
//

import Foundation

struct OSCMessage: Sendable {
    let address: String
    let arguments: [OSCArgument]

    enum OSCArgument: Sendable {
        case int32(Int32)
    }

    init(address: String, arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    // MARK: - Parse from received UDP data (message or bundle)

    /// Parses an OSC message or extracts the first message from an OSC bundle.
    static func parse(data: Data) -> OSCMessage? {
        // Check for OSC bundle: starts with "#bundle\0"
        if data.count >= 16,
           String(data: data[0..<7], encoding: .utf8) == "#bundle",
           data[7] == 0 {
            return parseBundle(data: data)
        }
        // Plain OSC message
        return OSCMessage(data: data)
    }

    // MARK: - Parse plain OSC message

    init?(data: Data) {
        var offset = 0

        // 1) Address pattern (null-terminated, 4-byte aligned)
        guard let addr = OSCMessage.readString(data: data, offset: &offset) else { return nil }
        guard addr.hasPrefix("/") else { return nil }
        self.address = addr

        // 2) Type tag string (starts with ',')
        // Some implementations omit the type tag string
        guard offset < data.count else {
            self.arguments = []
            return
        }

        // Check if next bytes look like a type tag (starts with ',')
        if data[offset] != 0x2C /* ',' */ {
            // No type tag string — no arguments
            self.arguments = []
            return
        }

        guard let typeTags = OSCMessage.readString(data: data, offset: &offset) else {
            self.arguments = []
            return
        }

        // 3) Parse arguments based on type tags
        var args: [OSCArgument] = []
        for tag in typeTags.dropFirst() {
            switch tag {
            case "i":
                guard offset + 4 <= data.count else { return nil }
                let value = data.subdata(in: offset..<offset + 4)
                    .withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
                args.append(.int32(value))
                offset += 4
            case "f":
                // Skip float (4 bytes) - not used but don't fail
                offset += 4
            case "s":
                // Skip string argument
                _ = OSCMessage.readString(data: data, offset: &offset)
            default:
                break
            }
        }
        self.arguments = args
    }

    // MARK: - Serialize to binary for sending

    func toData() -> Data {
        var data = Data()

        // 1) Address
        OSCMessage.writeString(address, to: &data)

        // 2) Type tag string
        var typeTags = ","
        for arg in arguments {
            switch arg {
            case .int32: typeTags += "i"
            }
        }
        OSCMessage.writeString(typeTags, to: &data)

        // 3) Arguments
        for arg in arguments {
            switch arg {
            case .int32(let value):
                var bigEndian = value.bigEndian
                data.append(Data(bytes: &bigEndian, count: 4))
            }
        }

        return data
    }

    // MARK: - OSC Bundle parsing

    /// Extracts the first message from an OSC bundle.
    /// Bundle format: "#bundle\0" (8) + timetag (8) + [size (4) + message (size)]*
    private static func parseBundle(data: Data) -> OSCMessage? {
        var offset = 16  // skip "#bundle\0" + timetag

        while offset + 4 <= data.count {
            let size = data.subdata(in: offset..<offset + 4)
                .withUnsafeBytes { Int($0.load(as: Int32.self).bigEndian) }
            offset += 4

            guard size > 0, offset + size <= data.count else { break }

            let elementData = data.subdata(in: offset..<offset + size)
            offset += size

            // Recursively parse (could be nested bundle or message)
            if let message = OSCMessage.parse(data: elementData) {
                return message  // Return first valid message
            }
        }
        return nil
    }

    // MARK: - OSC string helpers (null-terminated, padded to 4-byte boundary)

    private static func readString(data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }

        // Find null terminator
        var nullIdx: Int? = nil
        for i in offset..<data.count {
            if data[i] == 0 {
                nullIdx = i
                break
            }
        }
        guard let nullIndex = nullIdx else { return nil }
        
        let stringData = data[offset..<nullIndex]
        guard let string = String(data: stringData, encoding: .utf8) else { return nil }

        // Advance past null + padding to 4-byte boundary
        let rawLength = nullIndex - offset + 1  // includes null
        offset += (rawLength + 3) & ~3  // pad to 4 bytes

        return string
    }

    private static func writeString(_ string: String, to data: inout Data) {
        var bytes = Array(string.utf8)
        bytes.append(0)  // null terminator
        // Pad to 4-byte boundary
        while bytes.count % 4 != 0 {
            bytes.append(0)
        }
        data.append(contentsOf: bytes)
    }
}
