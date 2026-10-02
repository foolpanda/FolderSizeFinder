import AppKit

/// App 激活(把键盘焦点从其他应用手里拿过来)
///
/// macOS 14 起改为"协作式激活":从前台应用(终端、IDE 等)拉起的进程调用
/// `NSApp.activate(ignoringOtherApps:)` 时,系统会把激活请求合并给前台应用——
/// 窗口照样显示,但键盘输入仍进终端,直到前台应用"让位"。表现就是:
/// 终端启动本应用后打字,字全部进了终端;而由普通 GUI 应用(如 ZCode)
/// 后台拉起时不受此限制。因此按强度递进尝试:
/// 1. 常规激活(多数场景仍然有效);
/// 2. 新 API `activate(from:)`,借当前前台应用之手完成"协作让渡"(Wine 同款做法);
/// 3. 激活策略翻转(accessory→regular),迫使窗口服务器重新授予前台资格。
/// 每一步都写入 Diag 日志,便于在出问题的机器上定位走到哪一级。
enum AppFocus {
    /// 激活请求异步生效,故分档延迟升级,直到 `NSApp.isActive` 为止;
    /// 已处于活动状态则直接返回,不做任何事。
    static func activateApp(context: String) {
        if NSApp.isActive { return }
        NSApp.activate(ignoringOtherApps: true)

        // 第 2 档:借前台应用之手 cooperative 激活
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard !NSApp.isActive else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication
            Diag.log("[\(context)] 常规激活失败(frontmost=\(frontmost?.bundleIdentifier ?? "nil")),"
                + "尝试 cooperative 激活")
            NSRunningApplication.current.activate(
                from: frontmost ?? NSRunningApplication.current, options: [])

            // 第 3 档:激活策略翻转兜底
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                guard !NSApp.isActive else {
                    Diag.log("[\(context)] cooperative 激活成功")
                    return
                }
                Diag.log("[\(context)] cooperative 激活仍失败,翻转激活策略重试")
                NSApp.setActivationPolicy(.accessory)
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Diag.log("[\(context)] 兜底激活后 isActive=\(NSApp.isActive)")
                }
            }
        }
    }
}
