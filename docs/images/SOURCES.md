# README 图片来源

本次新增四图均为 **离屏渲染，合成数据**，由 App 的真实 AppKit / SwiftUI 视图绘制；未调用模型。建议及采纳/忽略记录是固定的自然对话样本，不代表模型输出质量、用户数据或真实采纳效果。图内没有附加免责声明；「只根据本机记录整理」等说明属于原有产品界面。

## 渲染与复现

在 macOS 13+、Swift 5.9+ 的仓库根目录运行（不安装 App）：

```sh
python3 docs/images/render-readme.py --output /tmp/stylepolish-readme
```

脚本将 `Package.swift`、`Sources/`、`Tests/` 复制到临时目录，增加仅用于取景和合成记录的 fixture，再将 DEBUG 的 `--capture-fixtures` 入口定向到它。通过 `swift build --product StylePolish` 构建命令行可执行文件，以 `.prohibited` 激活策略运行；没有创建或启动 `.app`、没有显示窗口，没有调用辅助功能或启动 AppController。临时副本和隔离的运行数据在结束后删除。

初次核对时，开发源码的 `Package.swift` 和 `Sources/` 共 65 个文件与公开仓库逐字节相同；随后开发工作区出现并行改动，最终出图改用公开仓库的隔离副本，回执中全部 65 个输入哈希与公开基线一致。公开基线为 `e54ab2a`；README 文字补充后建立的 illustrate 基线为 `491a5398f87c0b56741f412c8ccc067a9d722c9a`。源码哈希与命令回执保留在任务工作目录，不将机器绝对路径或临时日志提交到仓库。

- `inline-suggestions.png`：真实 `WaveView` 下划线与 `SuggestionCard`，放在两个离屏取景容器中；输入为「明天的安排我非长期待。」「这个书架我想确认一下怎么固定。」。卡片和下划线位置由 fixture 设置；没有微信窗口或交互。画布 800 × 270 pt。
- `sentence-preview.png`：真实 `AutomaticPreviewBar`，差异由真实 `SuggestionPreview` 计算，输入「这个方案的话，我们明天在讨论一下。」、目标「这个方案，我们明天再讨论。」。画布 800 × 48 pt。
- `my-habits.png`：真实 `HabitsView` 设置内容页，使用内存设置、隔离凭据目录和临时 `HistoryStore`。常写错显示历史累计次数（包含前七天），不是周报的七天次数。画布 560 × 590 pt。
- `weekly-report.png`：真实 `WeeklyReportView`，统计经 `HabitProfile` / `WeeklyReport` 计算；固定时间为 2026-11-12 12:00（Asia/Singapore），最近七天采纳 15、忽略 2，其中错字 9，前七天错字 12，采纳率四舍五入 88%。显式给报告 profile 同一个时钟，避免未来复现时数据被过期过滤。画布 720 × 740 pt。

SwiftUI 使用仓库现有的 `FixtureCapture.render`（`NSHostingView.cacheDisplay`），行内取景使用 `WaveView.cacheDisplay`。本机为 2× 输出；PNG 保留原始渲染结果，无后期合成或改字。视图本身使用浅色界面；README 的浅色和深色背景分别验证可读性，不将图片宣称为 App 原生深色主题。

## 对应源码

- [发布说明](../../release/notes.md)
- [习惯门槛、恢复候选与语境提醒](../../Sources/StylePolishCore/HabitProfile.swift)
- [七天报告与对比口径](../../Sources/StylePolishCore/WeeklyReport.swift)
- [行内卡片与预览条](../../Sources/StylePolishApp/InlineViews.swift)
- [下划线绘制](../../Sources/StylePolishApp/InlineOverlay.swift)
- [习惯设置页](../../Sources/StylePolishApp/HabitsView.swift)
- [报告页面](../../Sources/StylePolishApp/WeeklyReportView.swift)
- [离屏渲染路径](../../Sources/StylePolishApp/FixtureCapture.swift)
- [可复现脚本](render-readme.py) · [图片与插入清单](illustrate.json)

## 图片 SHA-256

| 文件 | SHA-256 |
|---|---|
| `inline-suggestions.png` | `6d30588362af035d767e3cc1972d237c365efb75237e276bfc5e4d4c733cde97` |
| `sentence-preview.png` | `d5a7953a55c72b0ca9d344ca85e7505dd1050cb92748f7be34a5ed1bcfe2c77a` |
| `my-habits.png` | `7c3f3d59abbde115a2802fbf51fb2beedc0013de93c6b8b05b173d82273553a3` |
| `weekly-report.png` | `9c216d81f9dc091542f8e0304393eeafdc4573127695e5cb4496a9baa2c6ba62` |

## 验证边界

此次仅验证文字来源、离屏布局和 README 渲染。未安装 App、未打开微信、未做微信输入框、焦点、滚动、快捷键或采纳写回的真机测试，也未执行 README 中的安装命令。顶部已有宣传片与合成示意图保持原样，不属于此次新增的离屏截图。PNG 可随 macOS 字体和渲染版本产生像素差异。
