import Foundation
#if canImport(Compression)
import Compression
#elseif canImport(CZlib)
import CZlib
#endif

/// Random-access reader for a large ZIP (ecu.zip).
///
/// The Java version streamed the whole archive once with ZipInputStream to build
/// an index file (ecu.idx). Here the ZIP central directory is read directly,
/// which is fast enough (tens of ms for ~100k entries) that no index cache is needed.
public final class ZipFileSystem {
    struct Entry {
        let localHeaderOffset: UInt64
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let method: UInt16
    }

    public let path: String
    private let handle: FileHandle
    private let fileSize: UInt64
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init(path: String) throws {
        self.path = path
        guard let h = FileHandle(forReadingAtPath: path) else {
            throw EcuError.database("Archive (ecu.zip) file not found")
        }
        handle = h
        fileSize = try h.seekToEnd()
        try readCentralDirectory()
    }

    deinit { try? handle.close() }

    public var entryNames: [String] { Array(entries.keys) }
    public var count: Int { entries.count }

    public func fileExists(_ name: String) -> Bool { entries[name] != nil }

    public func string(_ name: String) -> String? {
        guard let d = data(name) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    public func data(_ name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        lock.lock(); defer { lock.unlock() }
        do {
            let local = try read(at: e.localHeaderOffset, count: 30)
            guard local.u32(0) == 0x04034b50 else { return nil }
            let dataStart = e.localHeaderOffset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28))
            let raw = try read(at: dataStart, count: Int(e.compressedSize))
            switch e.method {
            case 0: return raw
            case 8: return Self.inflateRaw(raw, expectedSize: Int(e.uncompressedSize))
            default: return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - Central directory

    private func read(at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let d = try handle.read(upToCount: count) ?? Data()
        guard d.count == count else { throw EcuError.database("Truncated ZIP archive") }
        return d
    }

    private func readCentralDirectory() throws {
        let tailSize = Int(min(fileSize, 65_557))
        let tail = try read(at: fileSize - UInt64(tailSize), count: tailSize)
        guard tailSize >= 22, let eocd = Self.findSignature(0x06054b50, in: tail, minRemaining: 22) else {
            throw EcuError.database("ecu.zip is not a valid ZIP archive")
        }
        var totalEntries = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))

        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64: locator sits right before the EOCD record
            let locatorPos = eocd - 20
            guard locatorPos >= 0, tail.u32(locatorPos) == 0x07064b50 else {
                throw EcuError.database("Unsupported ZIP64 layout")
            }
            let z64Offset = tail.u64(locatorPos + 8)
            let z64 = try read(at: z64Offset, count: 56)
            guard z64.u32(0) == 0x06064b50 else { throw EcuError.database("Bad ZIP64 record") }
            totalEntries = z64.u64(32)
            cdSize = z64.u64(40)
            cdOffset = z64.u64(48)
        }

        let cd = try read(at: cdOffset, count: Int(cdSize))
        var pos = 0
        var map = [String: Entry]()
        map.reserveCapacity(Int(totalEntries))
        while pos + 46 <= cd.count, cd.u32(pos) == 0x02014b50 {
            let flags = cd.u16(pos + 8)
            let method = cd.u16(pos + 10)
            var compSize = UInt64(cd.u32(pos + 20))
            var size = UInt64(cd.u32(pos + 24))
            let nameLen = Int(cd.u16(pos + 28))
            let extraLen = Int(cd.u16(pos + 30))
            let commentLen = Int(cd.u16(pos + 32))
            var lho = UInt64(cd.u32(pos + 42))
            let nameStart = pos + 46
            guard nameStart + nameLen + extraLen <= cd.count else { break }
            let nameData = cd.subdata(in: (cd.startIndex + nameStart)..<(cd.startIndex + nameStart + nameLen))
            let name: String
            if flags & 0x0800 != 0 {
                name = String(decoding: nameData, as: UTF8.self)
            } else {
                name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            }

            if size == 0xFFFF_FFFF || compSize == 0xFFFF_FFFF || lho == 0xFFFF_FFFF {
                var ep = nameStart + nameLen
                let extraEnd = ep + extraLen
                while ep + 4 <= extraEnd {
                    let id = cd.u16(ep), len = Int(cd.u16(ep + 2))
                    if id == 0x0001 {
                        var fp = ep + 4
                        if size == 0xFFFF_FFFF { size = cd.u64(fp); fp += 8 }
                        if compSize == 0xFFFF_FFFF { compSize = cd.u64(fp); fp += 8 }
                        if lho == 0xFFFF_FFFF { lho = cd.u64(fp) }
                        break
                    }
                    ep += 4 + len
                }
            }

            if !name.hasSuffix("/") {
                map[name] = Entry(localHeaderOffset: lho, compressedSize: compSize, uncompressedSize: size, method: method)
            }
            pos = nameStart + nameLen + extraLen + commentLen
        }
        guard !map.isEmpty else { throw EcuError.database("ecu.zip is empty or unreadable") }
        entries = map
    }

    private static func findSignature(_ sig: UInt32, in d: Data, minRemaining: Int) -> Int? {
        var i = d.count - minRemaining
        while i >= 0 {
            if d.u32(i) == sig { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Inflate (raw DEFLATE)

    static func inflateRaw(_ src: Data, expectedSize: Int) -> Data? {
        if expectedSize == 0 { return Data() }
        if src.isEmpty { return nil }
        #if canImport(Compression)
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return out
        #elseif canImport(CZlib)
        var out = Data(count: expectedSize)
        var stream = z_stream()
        var status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var input = src
        status = input.withUnsafeMutableBytes { (inp: UnsafeMutableRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = inp.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inp.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else { return nil }
        return out
        #else
        return nil
        #endif
    }
}

extension Data {
    @inline(__always) func u16(_ o: Int) -> UInt16 {
        let b = startIndex + o
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    @inline(__always) func u32(_ o: Int) -> UInt32 {
        let b = startIndex + o
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    @inline(__always) func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | UInt64(u32(o + 4)) << 32
    }
}
