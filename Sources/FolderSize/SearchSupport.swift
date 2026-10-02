import Foundation
import Darwin

/// 搜索窗口的范围(传给 WindowGroup(for:),需 Codable+Hashable)
struct SearchScope: Codable, Hashable {
    let rootPath: String   // 扫描根的绝对路径
    let prefix: String     // 范围文件夹的相对路径("" = 全部)
    let scopeName: String  // 显示名

    /// 范围的完整绝对路径
    var absolutePath: String {
        prefix.isEmpty ? rootPath : rootPath + "/" + prefix
    }
}

/// 索引中的一条记录(文件或目录)
struct FileRecord: Identifiable, Sendable {
    let id: Int
    let relPath: String
    let lowercasedPath: String
    let isDirectory: Bool
    let logical: Int64
    let allocated: Int64

    var name: String { (relPath as NSString).lastPathComponent }
    var parentPath: String {
        let s = (relPath as NSString).deletingLastPathComponent
        return s.isEmpty ? "." : s
    }

    /// 还原为扫描事件(落盘用;字符串 CoW,复制代价低)
    var event: ScanEvent {
        ScanEvent(path: relPath, isDirectory: isDirectory, logical: logical, allocated: allocated)
    }
}

// MARK: - 查询语法

/// 解析后的查询:
///   普通词        → 路径子串 AND 匹配(不区分大小写)
///   *.pdf / IMG_* → 名称通配符(fnmatch)
///   ext:log       → 扩展名
///   size:>100mb / size:<1gb / size:>=2kb → 逻辑大小比较
///   folder: / folder:node → 只看文件夹(可带关键词)
///   file:         → 只看文件
struct ParsedQuery: Equatable {
    var terms: [String] = []
    var nameGlobs: [String] = []
    var extensions: [String] = []
    var minSize: Int64?
    var maxSize: Int64?
    var foldersOnly = false
    var filesOnly = false

    var isEmpty: Bool {
        self == ParsedQuery()
    }
}

enum QueryParser {
    static func parse(_ query: String) -> ParsedQuery {
        var p = ParsedQuery()
        for raw in query.lowercased().split(whereSeparator: \.isWhitespace) {
            let token = String(raw)
            if token == "folder:" {
                p.foldersOnly = true
            } else if token.hasPrefix("folder:") {
                p.foldersOnly = true
                let rest = String(token.dropFirst("folder:".count))
                if !rest.isEmpty { p.terms.append(rest) }
            } else if token == "file:" || token.hasPrefix("file:") {
                p.filesOnly = true
                let rest = String(token.dropFirst("file:".count))
                if !rest.isEmpty { p.terms.append(rest) }
            } else if token.hasPrefix("ext:") {
                let ext = String(token.dropFirst("ext:".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !ext.isEmpty { p.extensions.append(ext) }
            } else if token.hasPrefix("size:") {
                let expr = token.dropFirst("size:".count)
                if expr.hasPrefix(">="), let v = parseSize(expr.dropFirst(2)) {
                    p.minSize = v
                } else if expr.hasPrefix("<="), let v = parseSize(expr.dropFirst(2)) {
                    p.maxSize = v
                } else if expr.hasPrefix(">"), let v = parseSize(expr.dropFirst(1)) {
                    p.minSize = v
                } else if expr.hasPrefix("<"), let v = parseSize(expr.dropFirst(1)) {
                    p.maxSize = v
                }
            } else if token.contains("*") || token.contains("?") {
                p.nameGlobs.append(token)
            } else {
                p.terms.append(token)
            }
        }
        return p
    }

    /// "100mb" "1.5gb" "512kb" "2t" "1048576" → 字节数
    static func parseSize(_ input: some StringProtocol) -> Int64? {
        var number = ""
        var unit = ""
        for ch in input {
            if ch.isNumber || ch == "." { number.append(ch) } else { unit.append(ch) }
        }
        guard !number.isEmpty, let v = Double(number), v >= 0 else {
            return nil
        }
        let mult: Double
        switch unit {
        case "", "b": mult = 1
        case "k", "kb": mult = 1024
        case "m", "mb": mult = 1024 * 1024
        case "g", "gb": mult = 1024 * 1024 * 1024
        case "t", "tb": mult = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((v * mult).rounded())
    }
}

// MARK: - 搜索示例

struct SearchExample: Identifiable {
    let id = UUID()
    let display: String
    let query: String
    let noteKey: String   // L10n ID(example.note.*)
    var note: String { L.t(noteKey) }
}

extension SearchExample {
    static let all: [SearchExample] = [
        .init(display: "png", query: "png", noteKey: "example.note.1"),
        .init(display: "报告 2024", query: "报告 2024", noteKey: "example.note.2"),
        .init(display: "*.pdf", query: "*.pdf", noteKey: "example.note.3"),
        .init(display: "ext:log", query: "ext:log", noteKey: "example.note.4"),
        .init(display: "size:>100mb", query: "size:>100mb", noteKey: "example.note.5"),
        .init(display: "size:>10mb size:<100mb", query: "size:>10mb size:<100mb", noteKey: "example.note.6"),
        .init(display: "folder:", query: "folder:", noteKey: "example.note.7"),
        .init(display: "folder:node", query: "folder:node", noteKey: "example.note.8"),
        .init(display: "mp4 size:>500mb", query: "mp4 size:>500mb", noteKey: "example.note.9"),
    ]
}

// MARK: - 过滤

enum SortKey: String, CaseIterable, Identifiable {
    case name, size, path
    var id: String { rawValue }
    var titleID: String { "sort." + rawValue }
}

/// 纯函数过滤器,便于测试
enum SearchFilter {
    struct Outcome {
        var items: [FileRecord]
        var total: Int
        var millis: Int
    }

    static func filter(
        records: [FileRecord],
        prefix: String,
        query: String,
        cap: Int,
        key: SortKey,
        descending: Bool
    ) -> Outcome {
        let parsed = QueryParser.parse(query)
        let started = DispatchTime.now().uptimeNanoseconds

        var hits: [FileRecord] = []
        var total = 0
        for rec in records {
            // 范围:该文件夹自身 + 其子树
            if !prefix.isEmpty,
               rec.relPath != prefix,
               !rec.relPath.hasPrefix(prefix + "/") {
                continue
            }
            guard matches(rec, parsed: parsed) else { continue }
            total += 1
            hits.append(rec)
        }

        hits.sort { less($0, $1, key: key, descending: descending) }
        let items = Array(hits.prefix(cap))
        let millis = Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000)
        return Outcome(items: items, total: total, millis: millis)
    }

    private static func matches(_ rec: FileRecord, parsed: ParsedQuery) -> Bool {
        if parsed.foldersOnly && !rec.isDirectory { return false }
        if parsed.filesOnly && rec.isDirectory { return false }
        if let minS = parsed.minSize, rec.logical < minS { return false }
        if let maxS = parsed.maxSize, rec.logical > maxS { return false }

        for term in parsed.terms where !rec.lowercasedPath.contains(term) {
            return false
        }
        if !parsed.extensions.isEmpty {
            let lowerName = rec.name.lowercased()
            for ext in parsed.extensions
            where !(lowerName.hasSuffix("." + ext) || lowerName == ext) {
                return false
            }
        }
        for glob in parsed.nameGlobs where fnmatch(glob, rec.name, FNM_CASEFOLD) != 0 {
            return false
        }
        return true
    }

    private static func less(
        _ a: FileRecord, _ b: FileRecord,
        key: SortKey, descending: Bool
    ) -> Bool {
        let result: ComparisonResult
        switch key {
        case .name:
            result = a.name.localizedStandardCompare(b.name)
        case .size:
            result = a.logical == b.logical ? .orderedSame
                : (a.logical < b.logical ? .orderedAscending : .orderedDescending)
        case .path:
            result = a.relPath.localizedStandardCompare(b.relPath)
        }
        if result == .orderedSame { return a.id < b.id }
        let ascending = result == .orderedAscending
        return descending ? !ascending : ascending
    }
}
