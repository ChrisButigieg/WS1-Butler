#if DEBUG
import Foundation
import Compression

/// Writes small ZIP archives for tests and demo mode. Independent of `ZipArchiveReader`
/// so the reader is verified against a separate implementation.
nonisolated enum ZipFixtureWriter {
    nonisolated struct Entry {
        var path: String
        var data: Data
        var deflate: Bool = false
    }

    static func archive(_ entries: [Entry], zip64: Bool = false) -> Data {
        var output = Data()
        var central = Data()

        for entry in entries {
            let name = Data(entry.path.utf8)
            let payload: Data
            let method: UInt16
            if entry.deflate, let compressed = deflate(entry.data) {
                payload = compressed
                method = 8
            } else {
                payload = entry.data
                method = 0
            }
            let crc = crc32(entry.data)
            let offset = UInt64(output.count)

            output.append(le32(0x0403_4b50))
            output.append(le16(20)); output.append(le16(0)); output.append(le16(method))
            output.append(le16(0)); output.append(le16(0x21))
            output.append(le32(crc))
            output.append(le32(UInt32(payload.count))); output.append(le32(UInt32(entry.data.count)))
            output.append(le16(UInt16(name.count))); output.append(le16(0))
            output.append(name)
            output.append(payload)

            var extra = Data()
            if zip64 {
                extra.append(le16(0x0001)); extra.append(le16(24))
                extra.append(le64(UInt64(entry.data.count)))
                extra.append(le64(UInt64(payload.count)))
                extra.append(le64(offset))
            }
            central.append(le32(0x0201_4b50))
            central.append(le16(45)); central.append(le16(45)); central.append(le16(0)); central.append(le16(method))
            central.append(le16(0)); central.append(le16(0x21))
            central.append(le32(crc))
            central.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(payload.count)))
            central.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(entry.data.count)))
            central.append(le16(UInt16(name.count))); central.append(le16(UInt16(extra.count))); central.append(le16(0))
            central.append(le16(0)); central.append(le16(0)); central.append(le32(0))
            central.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(offset)))
            central.append(name)
            central.append(extra)
        }

        let centralOffset = UInt64(output.count)
        output.append(central)

        if zip64 {
            let zip64Offset = UInt64(output.count)
            output.append(le32(0x0606_4b50)); output.append(le64(44))
            output.append(le16(45)); output.append(le16(45)); output.append(le32(0)); output.append(le32(0))
            output.append(le64(UInt64(entries.count))); output.append(le64(UInt64(entries.count)))
            output.append(le64(UInt64(central.count))); output.append(le64(centralOffset))
            output.append(le32(0x0706_4b50)); output.append(le32(0)); output.append(le64(zip64Offset)); output.append(le32(1))
        }

        output.append(le32(0x0605_4b50))
        output.append(le16(0)); output.append(le16(0))
        output.append(le16(zip64 ? 0xFFFF : UInt16(entries.count)))
        output.append(le16(zip64 ? 0xFFFF : UInt16(entries.count)))
        output.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(central.count)))
        output.append(le32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset)))
        output.append(le16(0))
        return output
    }

    /// Builds a minimal IPA with a binary Info.plist.
    static func ipa(bundleID: String?, version: String = "1.1.0", build: String = "42",
                    name: String = "Mission Planner", appFolder: String = "MissionPlanner.app",
                    deviceFamilies: [Int] = [2], deflate: Bool = true, zip64: Bool = false) -> Data {
        var plist: [String: Any] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "CFBundleDisplayName": name,
            "MinimumOSVersion": "17.0",
            "UIDeviceFamily": deviceFamilies
        ]
        if let bundleID { plist["CFBundleIdentifier"] = bundleID }
        let plistData = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)) ?? Data()
        let nested = (try? PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.framework"], format: .xml, options: 0)) ?? Data()
        return archive([
            Entry(path: "Payload/", data: Data()),
            Entry(path: "Payload/\(appFolder)/Frameworks/Kit.framework/Info.plist", data: nested, deflate: deflate),
            Entry(path: "Payload/\(appFolder)/Info.plist", data: plistData, deflate: deflate),
            Entry(path: "Payload/\(appFolder)/MissionPlanner", data: Data(repeating: 0xCF, count: 4096), deflate: deflate)
        ], zip64: zip64)
    }

    // MARK: Helpers

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var buffer = Data(count: capacity)
        let size = buffer.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0 else { return nil }
        return buffer.prefix(size)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le64(_ value: UInt64) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
#endif
