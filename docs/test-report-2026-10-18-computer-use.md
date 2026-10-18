# FolderSize computer use 测试报告

- 日期：2026-10-18
- 被测：`dist/FolderSize.app`（debug 最新构建，含统一右键菜单 + 内置图片预览）
- 方式：macOS Accessibility（AXUIElement）+ CGEvent 真实鼠标/键盘注入，全程截图核对
- 环境：macOS 14，主屏 3024×1964（2x）；Terminal.app 已获「辅助功能 / 屏幕录制 / 输入监控」权限

## 测试夹具

`/tmp/fstest`

```
fstest/
├── big.bin            5,120,000 B
├── docs/
│   ├── note.txt           1,024 B
│   └── 子目录/
│       └── deep.txt     307,200 B
├── images/            a.png b.png c.png（各 316 B）
└── videos/
    └── clip.mp4       2,048,000 B
```

## 测试结果（全部通过）

| # | 动作 | 结果 |
|---|------|------|
| 1 | `--path /tmp/fstest --scan` 全量扫描 | ✅ 7 文件 / 7.5 MB / 0.4 s；树、环形图、明细一致 |
| 2 | 展开 `docs` → 露出 `子目录` | ✅ 行数 3→4，307 KB / 98.7% |
| 3 | 右键文件夹 `images` | ✅ 16 项菜单齐全（打开 / 打开方式 / 属性 / 在访达中显示简介 / 在访达中显示 / 在终端中打开 / cmux / 添加自定义启动器 / 移除启动器 / 添加到收藏夹 / 在此文件夹中搜索 / 进入此文件夹(浏览) / 以此文件夹为根重新扫描 / 拷贝路径 / 拷贝 / 移到废纸篓） |
| 4 | ⌘F → 输入 `png` | ✅ 命中 3 条，`0 ms`，索引 N 项 |
| 5 | 右键文件 `a.png`（主树） | ✅ 含「快速查看」「图片预览…」；无文件夹专属项 |
| 6 | 主树 → 图片预览 | ✅ 路径 `/private/tmp/fstest/images/a.png`，`a.png`，`1 / 3` |
| 7 | 预览内 ← / → | ✅ `1/3 → 2/3 → 3/3`，循环正确 |
| 8 | 复制全路径 / 复制父路径 | ✅ 剪贴板得到 `/private/tmp/fstest/images/b.png`、`/private/tmp/fstest/images` |
| 9 | 「上一级目录」 | ✅ 到 `/private/tmp/fstest`，显示「此目录没有图片」 |
| 10 | 「下一级目录」→ docs / images | ✅ 均成功跳转；进 `images` 自动显示首图 |
| 11 | 搜索结果右键 → 图片预览 | ✅ 路径 `/private/tmp/fstest/images/a.png`，`1 / 3` |

> 备注：曾出现「右键 a.png 却打开 c.png」的假象，经干净复现确认是**操作残留（旧预览窗 + 残留菜单）**导致，非产品缺陷。

## 遗留体验点（非崩溃，待定）

1. **搜索结果右键热区偏小**：只有精准点在单元格文字上才弹菜单，点行内空白/列间空白不弹。
   原因：`SearchWindowView` 把 `.contextMenu` 挂在每列 cell 内容上（约 191–214 行），而非整行。
   建议：改用 `.contextMenu(forSelectionType:)` 或挂到整行。
2. **统计模式（`--scan`）树里只列文件夹**：文件仅出现在浏览模式、最大文件榜、搜索里。
   README 有「统计树…文件与文件夹」的表述，易误解。若需统计树也列文件，需在
   `ScanStore.apply()` 的文件分支补建 `isFile` 子节点。

## 自动化工具（/tmp，未入库）

| 工具 | 用途 |
|------|------|
| `axtool.swift` | AX 树 dump / 按 role·title·value·desc 查找 / AXPress / AXShowMenu / 按菜单项标题点击 |
| `cg.swift` | 按 AX 元素中心真实左/右键点击、双击、按键、输入文本、行操作（rows / clickrow / rightclick / ctxpress） |
| `test_preview.swift` | 主树右键 → 图片预览 全链路 |
| `tsp3.swift` / `sr.swift` | 搜索结果右键 → 图片预览 全链路 |
| `childkey/childscan/childimg.swift` | 预览窗上/下一级目录导航 |
| `cleanwin.swift` | 关闭残留窗口 |

## 复现命令（示例）

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
# 打包 .app（同 CI）
open dist/FolderSize.app --args --path /tmp/fstest --scan
# 驱动
swift /tmp/cg.swift <pid> rows
swift /tmp/cg.swift <pid> clickrow images right
swift /tmp/axtool.swift <pid> press title "图片预览…"
```
