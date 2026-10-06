import Foundation
import CryptoKit

/// 索引落盘:紧凑二进制格式(.fsidx)
///
/// 布局(小端):
///   magic "FSIDX" | u8 version | u32 rootPathLen + utf8 | f64 savedAt | u64 count
///   每条记录:u8 isDir | i64 logical | i64 allocated | u32 pathLen + utf8
/// 记录保持扫描时的先序顺序——重放即可原样重建整棵树。
enum IndexCache {
    static let magic = "FSIDX"
    static let version: UInt8 = 1

    struct Loaded {
        let rootPath: String
        let savedAt: Date
        let events: [ScanEvent]
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FolderSize/Indexes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for root: URL) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).fsidx")
    }

    /// 该根目录是否已有缓存(供打开时决定直接载缓存还是进浏览模式)
    static func exists(for root: URL) -> Bool {
        FileManager.default.fileExists(atPath: cacheURL(for: root).path)
    }

    /// 缓存的修改时间(nil = 无缓存)——供"新鲜度"判断决定是否需要后台刷新
    static func modificationDate(for root: URL) -> Date? {
        try? FileManager.default.attributesOfItem(
            atPath: cacheURL(for: root).path)[.modificationDate] as? Date
    }

    // MARK: - 写

    static func write(url: URL, rootPath: String, savedAt: Date, events: [ScanEvent]) throws {
        var data = Data(capacity: 64 + events.count * 40)
        data.append(contentsOf: Array(magic.utf8))
        appendUInt8(&data, version)
        appendString(&data, rootPath)
        appendDouble(&data, savedAt.timeIntervalSince1970)
        appendUInt64(&data, UInt64(events.count))
        for event in events {
            appendUInt8(&data, event.isDirectory ? 1 : 0)
            appendInt64(&data, event.logical)
            appendInt64(&data, event.allocated)
            appendString(&data, event.path)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: - 读

    static func read(url: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var offset = 0

        func read(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            defer { offset += count }
            return data.subdata(in: offset..<offset + count)
        }
        func readUInt8() -> UInt8? {
            guard let d = read(1) else { return nil }
            return d[d.startIndex]
        }
        func readUInt32() -> UInt32? {
            guard let d = read(4) else { return nil }
            var v: UInt32 = 0
            withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0) }
            return UInt32(littleEndian: v)
        }
        func readUInt64() -> UInt64? {
            guard let d = read(8) else { return nil }
            var v: UInt64 = 0
            withUnsafeMutableBytes(of: &v) { d.copyBytes(to: $0) }
            return UInt64(littleEndian: v)
        }
        func readInt64() -> Int64? {
            guard let v = readUInt64() else { return nil }
            return Int64(bitPattern: v)
        }
        func readDouble() -> Double? {
            guard let v = readUInt64() else { return nil }
            return Double(bitPattern: v)
        }
        func readString() -> String? {
            guard let len = readUInt32(), let d = read(Int(len)) else { return nil }
            return String(data: d, encoding: .utf8)
        }

        guard let magicData = read(magic.utf8.count),
              String(data: magicData, encoding: .utf8) == magic,
              readUInt8() == version,
              let rootPath = readString(),
              let interval = readDouble(),
              let count = readUInt64(),
              count <= 50_000_000,
              count * 14 <= UInt64(data.count - offset)
        else { return nil }

        var events: [ScanEvent] = []
        events.reserveCapacity(Int(min(count, 1_000_000)))
        for _ in 0..<count {
            guard let isDirByte = readUInt8(),
                  let logical = readInt64(),
                  let allocated = readInt64(),
                  let path = readString()
            else { return nil }
            events.append(ScanEvent(
                path: path,
                isDirectory: isDirByte != 0,
                logical: logical,
                allocated: allocated
            ))
        }
        return Loaded(
            rootPath: rootPath,
            savedAt: Date(timeIntervalSince1970: interval),
            events: events
        )
    }

    // MARK: - 编码辅助

    private static func appendUInt8(_ data: inout Data, _ v: UInt8) {
        data.append(v)
    }
    private static func appendUInt32(_ data: inout Data, _ v: UInt32) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    private static func appendUInt64(_ data: inout Data, _ v: UInt64) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    private static func appendInt64(_ data: inout Data, _ v: Int64) {
        appendUInt64(&data, UInt64(bitPattern: v))
    }
    private static func appendDouble(_ data: inout Data, _ v: Double) {
        appendUInt64(&data, v.bitPattern)
    }
    private static func appendString(_ data: inout Data, _ s: String) {
        appendUInt32(&data, UInt32(s.utf8.count))
        data.append(contentsOf: Array(s.utf8))
    }
}

extension Array {
    /// 定长切片
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
