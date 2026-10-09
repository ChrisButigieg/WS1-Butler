import Foundation
import Compression

nonisolated enum ZipError: LocalizedError, Equatable, Sendable {
    case notAZipArchive
    case corrupted(String)
    case unsupportedCompression(UInt16)
    case entryTooLarge(UInt64)
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .notAZipArchive: "The file is not a valid IPA (ZIP) archive."
        case .corrupted(let reason): "The archive is corrupted: \(reason)."
        case .unsupportedCompression(let method): "Unsupported ZIP compression method \(method)."
        case .entryTooLarge(let size): "Archive entry is unexpectedly large (\(size) bytes)."
        case .decompressionFailed: "Failed to decompress archive entry."
        }
    }
}

/// Minimal, read-only ZIP reader (ZIP and ZIP64) that seeks within the file instead of
/// loading it into memory. It only supports what IPAs use: stored and deflated entries.
nonisolated final class ZipArchiveReader {
    nonisolated struct Entry: Hashable, Sendable {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    /// Upper bound for any single entry we extract into memory (zip-bomb protection).
    static let maximumExtractedSize: UInt64 = 32 * 1024 * 1024
    /// Upper bound on the number of central directory entries we will parse.
    static let maximumEntryCount: UInt64 = 500_000

    private let handle: FileHandle
    private let fileSize: UInt64
    private(set) var entries: [Entry] = []

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        do {
            entries = try readCentralDirectory()
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    // MARK: Extraction

    func extract(_ entry: Entry, maximumSize: UInt64 = ZipArchiveReader.maximumExtractedSize) throws -> Data {
        guard entry.uncompressedSize <= maximumSize, entry.compressedSize <= maximumSize else {
            throw ZipError.entryTooLarge(max(entry.uncompressedSize, entry.compressedSize))
        }
        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard try header.readUInt32(at: 0) == 0x0403_4b50 else { throw ZipError.corrupted("bad local header") }
        let nameLength = UInt64(try header.readUInt16(at: 26))
        let extraLength = UInt64(try header.readUInt16(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        let compressed = try read(at: dataOffset, count: Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// Inflates raw DEFLATE data (`COMPRESSION_ZLIB` in Apple's Compression framework is raw RFC 1951).
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !data.isEmpty else { throw ZipError.decompressionFailed }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                      let srcBase = src.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(dstBase, expectedSize, srcBase, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.decompressionFailed }
        return output
    }

    // MARK: Central directory

    private func readCentralDirectory() throws -> [Entry] {
        guard fileSize >= 22 else { throw ZipError.notAZipArchive }

        // The End Of Central Directory record sits within the last 64 KiB + 22 bytes.
        let tailLength = min(fileSize, 65_557)
        let tailStart = fileSize - tailLength
        let tail = try read(at: tailStart, count: Int(tailLength))
        guard let eocdIndex = Self.lastIndex(of: 0x0605_4b50, in: tail) else { throw ZipError.notAZipArchive }

        var entryCount = UInt64(try tail.readUInt16(at: eocdIndex + 10))
        var directorySize = UInt64(try tail.readUInt32(at: eocdIndex + 12))
        var directoryOffset = UInt64(try tail.readUInt32(at: eocdIndex + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: the locator immediately precedes the classic EOCD record.
            let locatorIndex = eocdIndex - 20
            guard locatorIndex >= 0, try tail.readUInt32(at: locatorIndex) == 0x0706_4b50 else {
                throw ZipError.corrupted("missing ZIP64 locator")
            }
            let zip64Offset = try tail.readUInt64(at: locatorIndex + 8)
            let record = try read(at: zip64Offset, count: 56)
            guard try record.readUInt32(at: 0) == 0x0606_4b50 else { throw ZipError.corrupted("bad ZIP64 record") }
            entryCount = try record.readUInt64(at: 32)
            directorySize = try record.readUInt64(at: 40)
            directoryOffset = try record.readUInt64(at: 48)
        }

        guard entryCount <= Self.maximumEntryCount else { throw ZipError.corrupted("too many entries") }
        guard directoryOffset <= fileSize, directorySize <= fileSize - directoryOffset else {
            throw ZipError.corrupted("central directory out of bounds")
        }

        let directory = try read(at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var cursor = 0
        for _ in 0..<entryCount {
            guard try directory.readUInt32(at: cursor) == 0x0201_4b50 else {
                throw ZipError.corrupted("bad central directory entry")
            }
            let method = try directory.readUInt16(at: cursor + 10)
            var compressedSize = UInt64(try directory.readUInt32(at: cursor + 20))
            var uncompressedSize = UInt64(try directory.readUInt32(at: cursor + 24))
            let nameLength = Int(try directory.readUInt16(at: cursor + 28))
            let extraLength = Int(try directory.readUInt16(at: cursor + 30))
            let commentLength = Int(try directory.readUInt16(at: cursor + 32))
            var localOffset = UInt64(try directory.readUInt32(at: cursor + 42))

            let nameData = try directory.slice(at: cursor + 46, count: nameLength)
            let path = String(decoding: nameData, as: UTF8.self)

            // ZIP64 extended information extra field (header ID 0x0001).
            var extraCursor = cursor + 46 + nameLength
            let extraEnd = extraCursor + extraLength
            while extraCursor + 4 <= extraEnd {
                let headerID = try directory.readUInt16(at: extraCursor)
                let size = Int(try directory.readUInt16(at: extraCursor + 2))
                if headerID == 0x0001 {
                    var fieldCursor = extraCursor + 4
                    if uncompressedSize == 0xFFFF_FFFF {
                        uncompressedSize = try directory.readUInt64(at: fieldCursor); fieldCursor += 8
                    }
                    if compressedSize == 0xFFFF_FFFF {
                        compressedSize = try directory.readUInt64(at: fieldCursor); fieldCursor += 8
                    }
                    if localOffset == 0xFFFF_FFFF {
                        localOffset = try directory.readUInt64(at: fieldCursor)
                    }
                }
                extraCursor += 4 + size
            }

            entries.append(Entry(path: path, compressionMethod: method, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localHeaderOffset: localOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
            throw ZipError.corrupted("read beyond end of file")
        }
        if count == 0 { return Data() }
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw ZipError.corrupted("unexpected end of file")
        }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if (try? data.readUInt32(at: index)) == signature { return index }
            index -= 1
        }
        return nil
    }
}

// MARK: - Bounds-checked little-endian reads

nonisolated extension Data {
    func slice(at offset: Int, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= self.count - count else {
            throw ZipError.corrupted("field out of bounds")
        }
        let start = startIndex + offset
        return self[start..<(start + count)]
    }

    func readUInt16(at offset: Int) throws -> UInt16 {
        let bytes = try slice(at: offset, count: 2)
        return bytes.reduce(into: (UInt16(0), UInt16(0))) { acc, byte in
            acc.0 |= UInt16(byte) << (8 * acc.1); acc.1 += 1
        }.0
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        let bytes = try slice(at: offset, count: 4)
        return bytes.reduce(into: (UInt32(0), UInt32(0))) { acc, byte in
            acc.0 |= UInt32(byte) << (8 * acc.1); acc.1 += 1
        }.0
    }

    func readUInt64(at offset: Int) throws -> UInt64 {
        let bytes = try slice(at: offset, count: 8)
        return bytes.reduce(into: (UInt64(0), UInt64(0))) { acc, byte in
            acc.0 |= UInt64(byte) << (8 * acc.1); acc.1 += 1
        }.0
    }
}
