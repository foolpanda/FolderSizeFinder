import SwiftUI
import AppKit

// MARK: - 收藏树节点

/// 收藏夹节点:目录收藏(path 非空)或分类节点(path 为 nil,仅作中间层容器)
struct FavoriteNode: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String?
    var children: [FavoriteNode] = []

    var isCategory: Bool { path == nil }
    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    static func folder(_ name: String, _ path: String) -> FavoriteNode {
        FavoriteNode(name: name, path: path)
    }
    static func category(_ name: String) -> FavoriteNode {
        FavoriteNode(name: name, path: nil)
    }
}

// MARK: - 收藏夹仓库

/// 收藏夹状态 + 持久化(JSON 存 UserDefaults)。整理操作(增删改名/移动)全部走这里,
/// 任何失败(重复路径、把分类移进自己的子孙、父节点不存在)都不改动状态并返回 nil/false。
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var roots: [FavoriteNode] = []
    @Published private(set) var expanded: Set<String> = []

    private let defaults: UserDefaults
    private static let treeKey = "FavoriteFoldersTree"
    private static let expandedKey = "FavoriteFoldersExpanded"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.treeKey),
           let tree = try? JSONDecoder().decode([FavoriteNode].self, from: data) {
            roots = tree
        }
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(roots) {
            defaults.set(data, forKey: Self.treeKey)
        }
        defaults.set(Array(expanded), forKey: Self.expandedKey)
    }

    // MARK: 查询

    /// 扁平列出所有分类节点(供"移动到分类/添加到分类"子菜单),title 带层级轨迹如"工作 / 视频";
    /// excluding: 排除以其为根的整棵子树(移动分类时不能列它自己和子孙)
    func categories(excluding: UUID? = nil) -> [(id: UUID, title: String)] {
        var out: [(id: UUID, title: String)] = []
        func walk(_ list: [FavoriteNode], trail: String) {
            for n in list where n.isCategory {
                if n.id == excluding { continue }
                let title = trail + n.name
                out.append((n.id, title))
                walk(n.children, trail: title + " / ")
            }
        }
        walk(roots, trail: "")
        return out
    }

    static func contains(id: UUID, in list: [FavoriteNode]) -> Bool {
        list.contains { $0.id == id || contains(id: id, in: $0.children) }
    }

    // MARK: 变更

    /// 收藏目录到顶层或某分类下;同一层不允许重复路径。成功返回 true。
    @discardableResult
    func addFolder(name: String, path: String, into parentID: UUID? = nil) -> Bool {
        let backup = roots
        let ok = editChildren(of: parentID) { list in
            guard !list.contains(where: { $0.path == path }) else { return false }
            list.append(.folder(name, path))
            return true
        }
        if ok {
            if let parentID { setExpanded(parentID, true) }
            save()
        } else {
            roots = backup
        }
        return ok
    }

    /// 新建分类(可嵌套),成功返回新节点 id。
    @discardableResult
    func addCategory(named name: String, into parentID: UUID? = nil) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let node = FavoriteNode.category(trimmed)
        let backup = roots
        let ok = editChildren(of: parentID) { list in
            list.append(node)
            return true
        }
        if ok {
            expanded.insert(node.id.uuidString)
            if let parentID { setExpanded(parentID, true) }
            save()
            return node.id
        }
        roots = backup
        return nil
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let backup = roots
        var removed = false
        func strip(_ list: inout [FavoriteNode]) -> Bool {
            let before = list.count
            list.removeAll { $0.id == id }
            if list.count < before { removed = true; return true }
            for i in list.indices where list[i].isCategory {
                if strip(&list[i].children) { return true }
            }
            return false
        }
        strip(&roots)
        if removed {
            expanded.remove(id.uuidString)
            save()
        } else {
            roots = backup
        }
        return removed
    }

    @discardableResult
    func rename(id: UUID, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let backup = roots
        var done = false
        func walk(_ list: inout [FavoriteNode]) -> Bool {
            for i in list.indices {
                if list[i].id == id { list[i].name = trimmed; return true }
                if list[i].isCategory, walk(&list[i].children) { return true }
            }
            return false
        }
        done = walk(&roots)
        if done { save() } else { roots = backup }
        return done
    }

    /// 移动节点到顶层(nil)或某分类下。禁止把分类移进它自己/子孙(防环);
    /// 目标层已有同路径收藏时拒绝(拒绝时整体回滚,节点留在原处)。
    @discardableResult
    func move(id: UUID, into parentID: UUID?) -> Bool {
        let backup = roots
        var extracted: FavoriteNode?
        func take(_ list: inout [FavoriteNode]) -> Bool {
            for i in list.indices where list[i].id == id {
                extracted = list.remove(at: i)
                return true
            }
            for i in list.indices where list[i].isCategory {
                if take(&list[i].children) { return true }
            }
            return false
        }
        guard take(&roots), let node = extracted else { roots = backup; return false }
        if let parentID, Self.contains(id: parentID, in: [node]) { roots = backup; return false }
        let ok = editChildren(of: parentID) { list in
            if let p = node.path, list.contains(where: { $0.path == p }) { return false }
            list.append(node)
            return true
        }
        if ok {
            if let parentID { setExpanded(parentID, true) }
            save()
        } else {
            roots = backup
        }
        return ok
    }

    // MARK: 展开状态

    func setExpanded(_ id: UUID, _ isExpanded: Bool) {
        if isExpanded { expanded.insert(id.uuidString) } else { expanded.remove(id.uuidString) }
        save()
    }

    func toggleExpanded(_ id: UUID) {
        setExpanded(id, !expanded.contains(id.uuidString))
    }

    func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.expanded.contains(id.uuidString) ?? false },
            set: { [weak self] in self?.setExpanded(id, $0) }
        )
    }

    // MARK: 树编辑工具

    /// 定位 parentID(nil = 顶层;只允许挂在分类下)对应的子列表并执行修改;
    /// 找不到父节点或 body 返回 false 都视为失败。
    private func editChildren(of parentID: UUID?, _ body: (inout [FavoriteNode]) -> Bool) -> Bool {
        func walk(_ list: inout [FavoriteNode]) -> Bool? {
            for i in list.indices where list[i].isCategory {
                if list[i].id == parentID { return body(&list[i].children) }
                if let r = walk(&list[i].children) { return r }
            }
            return nil
        }
        if parentID == nil { return body(&roots) }
        return walk(&roots) ?? false
    }
}

// MARK: - 简易文本输入对话框(重命名 / 新建分类共用)

@MainActor
func promptText(_ title: String, _ placeholder: String, initial: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
    field.stringValue = initial
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.addButton(withTitle: "确定")
    alert.addButton(withTitle: "取消")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
