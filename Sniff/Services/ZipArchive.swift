import Foundation
import Compression

/// 最小可用的 ZIP 读写（store 模式写入，读取支持 store / deflate）
/// 不依赖第三方库：写入走 stored（不压缩，兼容性最好），读取用 libcompression 解 deflate。
enum ZipError: Error, LocalizedError {
    case badArchive
    case unsupported(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badArchive: return "压缩包损坏或格式不支持"
        case .unsupported(let s): return "不支持的压缩方式：\(s)"
        case .io(let s): return s
        }
    }
}

enum ZipArchive {

    // MARK: - 解压

    static func unzip(_ archive: URL, to destination: URL) throws {
        let data = try Data(contentsOf: archive)
        guard data.count > 22 else { throw ZipError.badArchive }

        guard let eocd = findEOCD(data) else { throw ZipError.badArchive }
        let total = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))

        var extracted = 0
        for _ in 0..<total {
            guard offset + 46 <= data.count, read32(data, offset) == 0x02014b50 else { break }
            let method = read16(data, offset + 10)
            let usize = Int(read32(data, offset + 24))
            let csize = Int(read32(data, offset + 20))
            let nameLen = Int(read16(data, offset + 28))
            let extraLen = Int(read16(data, offset + 30))
            let commentLen = Int(read16(data, offset + 32))
            let localOffset = Int(read32(data, offset + 42))
            guard offset + 46 + nameLen <= data.count else { break }

            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLen))
            let name = decodeName(nameData)

            offset += 46 + nameLen + extraLen + commentLen

            guard !name.isEmpty, !name.hasPrefix("__MACOSX/") else { continue }

            // 目录
            if name.hasSuffix("/") {
                let dir = destination.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                continue
            }

            // 路径穿越防护
            let target = destination.appendingPathComponent(name)
            let base = destination.standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(base) else { continue }

            guard localOffset + 30 <= data.count, read32(data, localOffset) == 0x04034b50 else { continue }
            let lNameLen = Int(read16(data, localOffset + 26))
            let lExtraLen = Int(read16(data, localOffset + 28))
            let dataStart = localOffset + 30 + lNameLen + lExtraLen
            guard dataStart + csize <= data.count else { continue }

            let raw = data.subdata(in: dataStart..<(dataStart + csize))
            let payload: Data
            switch method {
            case 0:
                payload = raw
            case 8:
                payload = try inflate(raw, expected: usize)
            default:
                throw ZipError.unsupported("method \(method)")
            }

            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try payload.write(to: target)
            extracted += 1
        }

        if extracted == 0 { throw ZipError.badArchive }
    }

    // MARK: - 压缩（stored）

    static func zip(_ items: [URL], to zipURL: URL) throws {
        var body = Data()
        var central = Data()
        var count: UInt16 = 0
        let base = commonBase(items)

        var entries: [(String, URL)] = []
        for item in items {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = FileManager.default.enumerator(at: item,
                                                            includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { continue }
                for case let url as URL in e {
                    var d: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &d)
                    if d.boolValue { continue }
                    let rel = url.path.replacingOccurrences(of: base.path + "/", with: "")
                    entries.append((rel, url))
                }
            } else {
                let rel = item.lastPathComponent
                entries.append((rel, item))
            }
        }

        for (name, file) in entries {
            let payload = try Data(contentsOf: file)
            let crc = crc32(payload)
            let nameData = Data(name.utf8)
            let offset = UInt32(body.count)

            var local = Data()
            local.append(uint32: 0x04034b50)
            local.append(uint16: 10)          // version needed
            local.append(uint16: 0x0800)      // UTF-8 文件名
            local.append(uint16: 0)           // stored
            local.append(uint16: 0)           // time
            local.append(uint16: 0)           // date
            local.append(uint32: crc)
            local.append(uint32: UInt32(payload.count))
            local.append(uint32: UInt32(payload.count))
            local.append(uint16: UInt16(nameData.count))
            local.append(uint16: 0)
            local.append(nameData)
            body.append(local)
            body.append(payload)

            central.append(uint32: 0x02014b50)
            central.append(uint16: 20)        // version made by
            central.append(uint16: 10)
            central.append(uint16: 0x0800)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: crc)
            central.append(uint32: UInt32(payload.count))
            central.append(uint32: UInt32(payload.count))
            central.append(uint16: UInt16(nameData.count))
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint16: 0)
            central.append(uint32: 0)
            central.append(uint32: offset)
            central.append(nameData)
            count += 1
        }

        let cdOffset = UInt32(body.count)
        body.append(central)
        body.append(uint32: 0x06054b50)
        body.append(uint16: 0)
        body.append(uint16: 0)
        body.append(uint16: count)
        body.append(uint16: count)
        body.append(uint32: UInt32(central.count))
        body.append(uint32: cdOffset)
        body.append(uint16: 0)

        try? FileManager.default.removeItem(at: zipURL)
        try body.write(to: zipURL)
    }

    // MARK: - 内部

    private static func commonBase(_ items: [URL]) -> URL {
        guard let first = items.first else { return URL(fileURLWithPath: "/") }
        return first.deletingLastPathComponent()
    }

    private static func decodeName(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gbk = CFStringConvertEncodingToNSStringEncoding(0x0632)
        if let s = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return s }
        return ""
    }

    private static func findEOCD(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 65557)
        var i = data.count - 22
        while i >= lower {
            if read32(data, i) == 0x06054b50 { return i }
            i -= 1
        }
        return nil
    }

    private static func read16(_ d: Data, _ o: Int) -> UInt16 {
        guard o + 2 <= d.count else { return 0 }
        return UInt16(d[o]) | (UInt16(d[o + 1]) << 8)
    }

    private static func read32(_ d: Data, _ o: Int) -> UInt32 {
        guard o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }

    private static func inflate(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expected, s, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ZipError.badArchive }
        out.count = written
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 小端写入

private extension Data {
    mutating func append(uint16 v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func append(uint32 v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 24) & 0xFF))
    }
}
