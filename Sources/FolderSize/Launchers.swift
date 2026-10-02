import SwiftUI
import AppKit

// MARK: - 自定义启动器

/// 用户自定义的目录启动器:在目标目录的新终端窗口里执行 command;
/// command 中的 {path} 会被替换为目录路径(shell 转义),不写则仅 cd 到该目录。
struct Launcher: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
}

@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var customs: [Launcher] = []

    private let defaults: UserDefaults
    private static let key = "FolderLaunchers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([Launcher].self, from: data) {
            customs = list
        } else {
            // 首次使用预置 cmux(不需要可在菜单里移除;删光后不会再次预置)
            customs = [Launcher(name: "cmux", command: "cmux")]
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customs) {
            defaults.set(data, forKey: Self.key)
        }
    }

    @discardableResult
    func add(name: String, command: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !c.isEmpty, !customs.contains(where: { $0.name == n }) else { return false }
        customs.append(Launcher(name: n, command: c))
        save()
        return true
    }

    func remove(id: UUID) {
        customs.removeAll { $0.id == id }
        save()
    }

    // MARK: 执行

    /// 终端里最终执行的 shell 行:cd 到目录 && 命令({path} 占位替换)
    static func shellLine(path: String, command: String) -> String {
        let cd = "cd \(shellQuoted(path))"
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return cd }
        return cd + " && " + trimmed.replacingOccurrences(of: "{path}", with: shellQuoted(path))
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 用系统终端(默认 Terminal.app)在目录处开新窗口
    static func openTerminal(at url: URL) {
        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
        }
    }

    /// 在 Terminal 新窗口的目录下执行命令(自定义启动器走这里;
    /// 首次使用系统会请求"控制终端"的自动化权限)
    static func runInTerminal(path: String, command: String) {
        let line = shellLine(path: path, command: command)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(line)"
        end tell
        """
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
        if let error {
            Diag.log("启动器执行失败: \(error)")
        }
    }
}

// MARK: - 可复用的"打开方式"菜单项(收藏夹行 / 树列表行共用)

struct LauncherMenuItems: View {
    let url: URL
    @EnvironmentObject private var launchers: LauncherStore

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Label("在访达中显示", systemImage: "folder")
        }
        Button {
            LauncherStore.openTerminal(at: url)
        } label: {
            Label("在终端中打开", systemImage: "terminal")
        }
        if !launchers.customs.isEmpty {
            Divider()
            ForEach(launchers.customs) { launcher in
                Button(launcher.name) {
                    LauncherStore.runInTerminal(path: url.path, command: launcher.command)
                }
            }
        }
        Divider()
        Button("添加自定义启动器…") {
            if let name = promptText("添加启动器", "显示名,如:cmux / VS Code / iTerm"),
               let command = promptText("启动命令", "在目标目录执行的命令;{path} 代表目录路径") {
                launchers.add(name: name, command: command)
            }
        }
        if !launchers.customs.isEmpty {
            Menu("移除启动器…") {
                ForEach(launchers.customs) { launcher in
                    Button(launcher.name, role: .destructive) {
                        launchers.remove(id: launcher.id)
                    }
                }
            }
        }
    }
}
