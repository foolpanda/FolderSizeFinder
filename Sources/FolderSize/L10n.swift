import SwiftUI
import AppKit

// MARK: - 语言选项

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return MainActor.assumeIsolated { L.t("settings.lang.system") }
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
    /// system 时的实际语言
    var resolved: AppLanguage {
        guard self == .system else { return self }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.hasPrefix("zh") ? .zh : .en
    }
}

// MARK: - 应用设置(语言;后续界面主题等也放这里)

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        language = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? ""
        ) ?? .system
    }
}

// MARK: - ID 键控文案
///
/// 每个显示元素一个稳定 ID:文字 t("toolbar.search"),tooltip tip("toolbar.search")
/// (自动查 "toolbar.search.tip",未定义则回落到文字本身)。
/// 组合文案用 f("status.summary", a, b, c),表值内含 %@ / %d 占位。
/// 新增语言 = 在表值字典里加一种语言。
enum L {
    static var lang: AppLanguage {
        MainActor.assumeIsolated { AppSettings.shared.language.resolved }
    }

    static func t(_ id: String) -> String {
        let entry = strings[id]
        let lang = MainActor.assumeIsolated { AppSettings.shared.language.resolved.rawValue }
        return entry?[lang]
            ?? entry?["zh"]
            ?? entry?["en"]
            ?? id
    }

    /// tooltip:查 "<id>.tip",未定义回落到文字本身
    static func tip(_ id: String) -> String {
        let tipID = id + ".tip"
        return strings[tipID] != nil ? t(tipID) : t(id)
    }

    /// 带占位的组合文案
    static func f(_ id: String, _ args: CVarArg...) -> String {
        String(format: t(id), arguments: args)
    }

    // MARK: 字符串表(ID → [语言: 文案])

    static let strings: [String: [String: String]] = [
        // 通用
        "app.title": ["zh": "文件夹大小", "en": "Folder Size"],
        "detail.donutA11y": ["zh": "子文件夹大小构成环形图", "en": "Donut chart of subfolder sizes"],
        "common.cancel": ["zh": "取消", "en": "Cancel"],
        "common.ok": ["zh": "确定", "en": "OK"],

        // 菜单(File 菜单)
        "menu.pickFolder": ["zh": "选择文件夹…", "en": "Open Folder…"],
        "menu.rescan": ["zh": "重新扫描", "en": "Rescan"],
        "menu.stopScan": ["zh": "停止扫描", "en": "Stop Scanning"],
        "menu.exportIndex": ["zh": "导出索引…", "en": "Export Index…"],
        "menu.importIndex": ["zh": "打开索引…", "en": "Import Index…"],

        // 工具栏
        "toolbar.pickFolder": ["zh": "选择文件夹…", "en": "Open Folder…"],
        "toolbar.pickFolder.tip": ["zh": "选择要打开的文件夹", "en": "Choose a folder to open"],
        "toolbar.rescan": ["zh": "重新扫描", "en": "Rescan"],
        "toolbar.rescan.tip": ["zh": "统计此目录的大小(⌘R;有缓存则秒载)", "en": "Compute sizes for this folder (⌘R; instant when cached)"],
        "toolbar.stop": ["zh": "停止", "en": "Stop"],
        "toolbar.stop.tip": ["zh": "停止扫描(⌘.)", "en": "Stop scanning (⌘.)"],
        "toolbar.search": ["zh": "搜索", "en": "Search"],
        "toolbar.search.tip": ["zh": "打开 Everything 式搜索窗口(⌘F)", "en": "Open the Everything-style search window (⌘F)"],
        "toolbar.sizeMode.tip": ["zh": "磁盘占用 = 实际分配的块大小;逻辑大小 = 文件字节数", "en": "Disk used = allocated blocks; logical = file bytes"],
        "toolbar.hiddenFiles": ["zh": "隐藏文件", "en": "Hidden Files"],
        "toolbar.hiddenFiles.tip": ["zh": "是否包含以 . 开头的隐藏文件(切换后重新扫描)", "en": "Include dot-prefixed hidden files (rescans on change)"],

        // 大小口径
        "sizemode.allocated": ["zh": "磁盘占用", "en": "Disk Used"],
        "sizemode.logical": ["zh": "逻辑大小", "en": "Logical"],

        // 浏览条
        "browse.bar": ["zh": "浏览模式:未统计大小(文件夹显示直接数量,文件显示自身大小)", "en": "Browse mode: sizes not computed (folders show direct counts, files show their own size)"],
        "browse.scan": ["zh": "统计大小", "en": "Size Up"],
        "browse.scan.tip": ["zh": "统计此目录的大小(⌘R;有缓存则秒载)", "en": "Compute sizes for this folder (⌘R; instant when cached)"],

        // 树表列
        "col.name": ["zh": "名称", "en": "Name"],
        "col.size": ["zh": "大小", "en": "Size"],
        "col.percent": ["zh": "占比", "en": "%"],
        "col.files": ["zh": "文件", "en": "Files"],
        "col.dirs": ["zh": "文件夹", "en": "Folders"],

        // 树表右键菜单
        "tree.reveal": ["zh": "在访达中显示", "en": "Reveal in Finder"],
        "tree.openTerminal": ["zh": "在终端中打开", "en": "Open in Terminal"],
        "tree.search": ["zh": "在此文件夹中搜索…", "en": "Search in This Folder…"],
        "tree.copyPath": ["zh": "拷贝路径", "en": "Copy Path"],
        "tree.enter": ["zh": "进入此文件夹(浏览)", "en": "Enter Folder (Browse)"],
        "tree.sizeThis": ["zh": "统计此文件夹大小", "en": "Size This Folder"],
        "tree.rescanRoot": ["zh": "以此文件夹为根重新扫描", "en": "Rescan Rooted Here"],
        "tree.browseNote.tip": ["zh": "(浏览模式,未统计大小)", "en": "(browse mode, sizes not computed)"],

        // 启动器
        "launch.add": ["zh": "添加自定义启动器…", "en": "Add Custom Launcher…"],
        "launch.remove": ["zh": "移除启动器…", "en": "Remove Launcher…"],
        "launch.add.name": ["zh": "添加启动器", "en": "Add Launcher"],
        "launch.add.name.ph": ["zh": "显示名,如:cmux / VS Code / iTerm", "en": "Display name, e.g. cmux / VS Code / iTerm"],
        "launch.add.cmd": ["zh": "启动命令", "en": "Command"],
        "launch.add.cmd.ph": ["zh": "在目标目录执行的命令;{path} 代表目录路径", "en": "Command to run in the folder; {path} is the folder path"],

        // 收藏夹
        "fav.add": ["zh": "添加到收藏夹", "en": "Add to Favorites"],
        "fav.addTop": ["zh": "收藏到顶层", "en": "Favorite to Top Level"],
        "fav.newCategory": ["zh": "新建分类…", "en": "New Category…"],
        "fav.newCategory.ph": ["zh": "分类名称,如:工作 / 视频", "en": "Category name, e.g. Work / Video"],
        "fav.rename": ["zh": "重命名…", "en": "Rename…"],
        "fav.rename.name": ["zh": "重命名", "en": "Rename"],
        "fav.rename.ph": ["zh": "名称", "en": "Name"],
        "fav.newSub": ["zh": "新建子分类…", "en": "New Subcategory…"],
        "fav.move": ["zh": "移动到分类…", "en": "Move to Category…"],
        "fav.top": ["zh": "顶层", "en": "Top Level"],
        "fav.delete": ["zh": "从收藏夹删除", "en": "Remove from Favorites"],
        "fav.missing": ["zh": "目录不存在或已移动", "en": "Folder missing or moved"],

        // 详情面板
        "detail.tab.breakdown": ["zh": "构成", "en": "Breakdown"],
        "detail.tab.topFiles": ["zh": "最大文件", "en": "Largest Files"],
        "detail.finder": ["zh": "Finder", "en": "Finder"],
        "detail.copyPath": ["zh": "拷贝路径", "en": "Copy Path"],
        "detail.setRoot": ["zh": "设为根", "en": "Set as Root"],
        "detail.search": ["zh": "搜索", "en": "Search"],
        "detail.search.tip": ["zh": "打开 Everything 式搜索窗口,范围限定此文件夹", "en": "Open the Everything-style search scoped to this folder"],
        "detail.logical": ["zh": "逻辑大小", "en": "Logical"],
        "detail.allocated": ["zh": "磁盘占用", "en": "Disk Used"],
        "detail.fileCount": ["zh": "文件数", "en": "Files"],
        "detail.dirCount": ["zh": "子文件夹", "en": "Subfolders"],
        "detail.ofRoot": ["zh": "占根目录", "en": "% of Root"],
        "detail.other": ["zh": "其他(%d 项 + 文件)", "en": "Other (%d items + files)"],
        "detail.total": ["zh": "合计", "en": "Total"],
        "detail.browseHint": ["zh": "浏览模式:未统计大小", "en": "Browse mode: sizes not computed"],
        "detail.browseHint2": ["zh": "点树表右上「统计大小」开始", "en": "Click “Size Up” above the tree to start"],
        "detail.noSubfolders": ["zh": "此文件夹没有子文件夹", "en": "No subfolders"],
        "detail.collecting": ["zh": "正在收集…", "en": "Collecting…"],
        "detail.nodata": ["zh": "暂无数据", "en": "No Data"],

        // 状态栏
        "status.scanning": ["zh": "正在扫描…", "en": "Scanning…"],
        "status.loadingCache": ["zh": "正在载入缓存…", "en": "Loading cache…"],
        "status.browse": ["zh": "浏览模式 · 未统计大小", "en": "Browse · sizes not computed"],
        "status.cached": ["zh": "已载入缓存", "en": "Cached"],
        "status.cached.tip": ["zh": "数据来自本地索引缓存(保存于 %@)。\n点击工具栏\"重新扫描\"获取最新数据。", "en": "Data comes from the local index cache (saved %@).\nClick “Rescan” in the toolbar for fresh data."],
        "status.stopped": ["zh": "已停止", "en": "Stopped"],
        "status.done": ["zh": "完成", "en": "Done"],
        "status.noFolder": ["zh": "未选择文件夹", "en": "No Folder"],
        "status.browseSummary": ["zh": "%d 个子文件夹 · 未统计", "en": "%d subfolders · not computed"],
        "status.summary": ["zh": "%@ 个文件 · %@ · %.1f s", "en": "%@ files · %@ · %.1f s"],
        "status.errors": ["zh": "%@ 项无法读取", "en": "%@ items unreadable"],
        "status.errors.tip": ["zh": "%@\n(通常是无权限的系统目录)", "en": "%@\n(usually system folders without permission)"],
        "status.reveal.tip": ["zh": "在 Finder 中显示", "en": "Reveal in Finder"],

        // 侧栏
        "sidebar.quick": ["zh": "常用位置", "en": "Quick Locations"],
        "sidebar.volumes": ["zh": "卷", "en": "Volumes"],
        "sidebar.favorites": ["zh": "收藏夹", "en": "Favorites"],
        "sidebar.favEmpty": ["zh": "在中间树列表右键文件夹\n→「添加到收藏夹」", "en": "Right-click a folder in the tree\n→ “Add to Favorites”"],
        "loc.home": ["zh": "主文件夹", "en": "Home"],
        "loc.downloads": ["zh": "下载", "en": "Downloads"],
        "loc.documents": ["zh": "文稿", "en": "Documents"],
        "loc.desktop": ["zh": "桌面", "en": "Desktop"],
        "loc.apps": ["zh": "应用程序", "en": "Applications"],
        "loc.workspace": ["zh": "工作区", "en": "workspace"],

        // 欢迎页
        "welcome.title": ["zh": "文件夹大小", "en": "Folder Size"],
        "welcome.subtitle": ["zh": "统计任意文件夹中每个子文件夹与文件的大小占用,\n边扫描边出结果。", "en": "See how much every subfolder and file takes up,\nwith results streaming in as it scans."],
        "welcome.pick": ["zh": "选择文件夹…", "en": "Open Folder…"],
        "welcome.pick.tip": ["zh": "选择要打开的文件夹(⌘O)", "en": "Choose a folder to open (⌘O)"],
        "welcome.quickStart": ["zh": "快速开始:", "en": "Quick start:"],
        "welcome.drop": ["zh": "或将文件夹拖到此处", "en": "or drop a folder here"],

        // 打开面板
        "openpanel.message": ["zh": "选择要打开的文件夹(打开后可再点「统计大小」)", "en": "Choose a folder to open (click “Size Up” later to compute sizes)"],
        "openpanel.prompt": ["zh": "打开", "en": "Open"],

        // 搜索窗口
        "search.title": ["zh": "搜索 — %@", "en": "Search — %@"],
        "search.placeholder": ["zh": "输入关键词,例如:png / *.pdf / size:>100mb / folder:", "en": "Type a query, e.g. png / *.pdf / size:>100mb / folder:"],
        "search.copyPath.tip": ["zh": "拷贝此路径", "en": "Copy this path"],
        "search.clear.tip": ["zh": "清空关键词", "en": "Clear the query"],
        "search.examples": ["zh": "搜索示例", "en": "Examples"],
        "search.examples.tip": ["zh": "浮出面板展示各种搜索场景示例,点击即用", "en": "Show example queries; click to use"],
        "search.syntax": ["zh": "语法:多词空格 = AND · *.通配符 · ext:扩展名 · size:>10mb · size:<1gb · folder: 只看文件夹", "en": "Syntax: space = AND · * wildcards · ext:ext · size:>10mb · size:<1gb · folder: folders only"],
        "search.collapse": ["zh": "收起", "en": "Collapse"],
        "search.examplesTitle": ["zh": "点击示例填入搜索框(覆盖常用场景):", "en": "Click an example to fill the search box:"],
        "search.recent": ["zh": "最近搜索:", "en": "Recent:"],
        "search.rootChanged": ["zh": "根目录已变更(%@)\n请回到主窗口重新打开搜索", "en": "Root has changed (%@)\nReopen search from the main window"],
        "search.browseHint": ["zh": "点\"搜索示例\"浮出面板参考写法,或直接输入关键词\n空格分隔多个关键词(AND),按相对路径匹配,输入即出结果", "en": "Open “Examples” for samples, or just type\nSpace separates keywords (AND); matches relative paths as you type"],
        "search.searching": ["zh": "搜索中…", "en": "Searching…"],
        "search.indexing": ["zh": "正在后台扫描建立索引,结果将随扫描实时出现…", "en": "Building the index in the background — results will stream in…"],
        "search.noMatch": ["zh": "没有匹配项", "en": "No matches"],
        "search.col.parent": ["zh": "所在文件夹", "en": "Folder"],
        "search.hits": ["zh": "命中 %@ 条", "en": "%@ hits"],
        "search.hitsCapped": ["zh": "(显示前 %@)", "en": "(showing first %@)"],
        "search.sort": ["zh": "排序", "en": "Sort"],
        "sort.name": ["zh": "名称", "en": "Name"],
        "sort.size": ["zh": "大小", "en": "Size"],
        "sort.path": ["zh": "路径", "en": "Path"],
        "sort.asc.tip": ["zh": "当前升序", "en": "Ascending"],
        "sort.desc.tip": ["zh": "当前降序", "en": "Descending"],
        "search.indexCount": ["zh": "索引 %@ 项", "en": "Index: %@ items"],
        "search.cache": ["zh": "缓存", "en": "Cache"],
        "search.cache.tip": ["zh": "索引来自本地缓存,保存于 %@", "en": "Index from local cache, saved %@"],

        // 搜索示例说明(按 SearchExample.all 顺序)
        "example.note.1": ["zh": "名称或路径包含 png(不区分大小写)", "en": "name or path contains png (case-insensitive)"],
        "example.note.2": ["zh": "多关键词用空格分隔,需同时包含", "en": "space-separated keywords, all required"],
        "example.note.3": ["zh": "按名称通配符匹配", "en": "wildcard match on name"],
        "example.note.4": ["zh": "按扩展名过滤(等同 *.log)", "en": "filter by extension (same as *.log)"],
        "example.note.5": ["zh": "逻辑大小超过 100 MB 的文件", "en": "files larger than 100 MB (logical)"],
        "example.note.6": ["zh": "大小落在区间内", "en": "size within a range"],
        "example.note.7": ["zh": "只列出文件夹", "en": "folders only"],
        "example.note.8": ["zh": "名字包含 node 的文件夹", "en": "folders whose name contains node"],
        "example.note.9": ["zh": "关键词与条件自由组合", "en": "combine keywords and conditions"],

        // 设置
        "settings.language": ["zh": "语言", "en": "Language"],
        "settings.lang.system": ["zh": "跟随系统", "en": "System"],
        "settings.hint": ["zh": "切换立即生效。后续设置项(如界面主题)也会出现在这里。", "en": "Applies immediately. Future options (e.g. theme) will appear here too."],
    ]
}

// MARK: - 设置窗口

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Picker(L.t("settings.language"), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .frame(width: 280)

            Text(L.t("settings.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
