import Foundation

/// 大小统计口径
enum SizeMode: String, CaseIterable, Identifiable {
    case allocated = "磁盘占用"
    case logical = "逻辑大小"

    var id: String { rawValue }
}

/// 树节点:一个文件夹
final class Node: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL          // 绝对路径
    let relPath: String   // 相对扫描根的路径
    weak var parent: Node?

    var logical: Int64 = 0       // 逻辑大小(字节)
    var allocated: Int64 = 0     // 磁盘占用(字节)
    var files = 0         // 直接+间接文件数
    var dirs = 0          // 直接子文件夹数

    var children: [String: Node] = [:]
    var sorted: [Node] = []

    init(url: URL, relPath: String, parent: Node? = nil) {
        self.url = url
        self.relPath = relPath
        self.parent = parent
        let last = url.lastPathComponent
        self.name = last.isEmpty ? "/" : last
    }

    func size(_ mode: SizeMode) -> Int64 {
        mode == .allocated ? allocated : logical
    }

    /// Table 的 children keyPath:空目录不显示展开箭头
    var tableChildren: [Node]? {
        sorted.isEmpty ? nil : sorted
    }

    static func == (lhs: Node, rhs: Node) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// 在子树中按 id 查找节点
    static func find(_ id: UUID, in node: Node) -> Node? {
        if node.id == id { return node }
        for child in node.children.values {
            if let hit = find(id, in: child) { return hit }
        }
        return nil
    }
}

/// 全局"最大文件"榜单条目
struct FileHit: Identifiable {
    let id = UUID()
    let path: String   // 相对扫描根
    let logical: Int64
    let allocated: Int64

    var name: String { (path as NSString).lastPathComponent }

    func size(_ mode: SizeMode) -> Int64 {
        mode == .allocated ? allocated : logical
    }
}
