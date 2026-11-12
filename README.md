# <img src="docs/images/icon-256.png" width="64" alt="StylePolish 图标" /> StylePolish

A macOS writing assistant that polishes text while keeping your voice; you stay in control of sending.

在 macOS 任意输入框里，停笔后帮你润色，保留你的口吻，发送仍由你自己按。

**▶ 30 秒宣传片**（点图片播放）：

<a href="docs/media/promo.mp4"><img src="docs/images/promo-poster.jpg" width="640" alt="宣传片画面：输入框下方显示整句预览，按 Option + Enter 一次采纳" /></a>

<img src="docs/images/suggestions.png" width="280" alt="合成效果图：错字和赘词建议，可逐条采纳或忽略" />

*合成界面示意。输入框兼容性见下方限制。*

## 它做什么

小改（错字、用错的词）在原文下画线，点开采纳；需要理顺时，底部预览改好的整段，⌥Enter 替换。继续输入会作废旧建议，Esc 忽略。不自动发送。

## 安装

需要 macOS 13+。从 [GitHub Releases](https://github.com/bmdy6/stylepolish/releases/latest) 下载适合本机架构的 zip，解压后拖进「应用程序」。
没有 Apple 公证，第一次打开要右键 → 打开；信任来源后也可执行：

```sh
xattr -dr com.apple.quarantine /Applications/StylePolish.app
```

从源码构建需要 Swift 5.9+（Xcode Command Line Tools）：

```sh
git clone https://github.com/bmdy6/stylepolish
cd stylepolish
swift test
scripts/build-app.sh
```

产物为 `dist/StylePolish.app`。有本机专用签名身份时使用它，否则自动 `codesign -s -`（ad-hoc），无需作者证书。
首次构建不会创建钥匙串；可选运行 `scripts/setup-signing.sh` 创建空密码的专用签名钥匙串和本机自签名证书，并配置非交互 codesign 权限，不访问登录钥匙串。详见 [使用说明](docs/USAGE.md)。

## 第一次使用

在设置填 OpenAI 兼容接口地址、Key、模型；在系统设置 → 隐私与安全性 → 辅助功能授权，再启用目标 App。
Key 明文保存在 `~/.config/stylepolish/openai-key`，文件权限 `0600`、目录 `0700`；请保护本机账号。
高级用法：可选读取 `~/.config/ai-vault/vault.json` 中的 `OPENAI_PLATFORM_API_KEY`，优先于本地 Key 文件。

## 隐私

文字及可选口吻档案、词表只发送给你自己配置的接口；请核对该服务的隐私政策。
手改及采纳、忽略等记录只存在本机 `~/Library/Application Support/StylePolish/history.jsonl`（`0600`），包含原文和改写，可在设置中清空。
除模型请求外，没有遥测或额外上传；本机历史不会上传。
个人词表见 [合成模板](lexicon.example.json)，详细参数见 [使用说明](docs/USAGE.md)。

## 已知限制

- 长段「理顺」的效果还不稳定，默认模型主要擅长纠错。
- 只在微信等白名单 App 做过有限测试，完整采纳写回闭环未覆盖所有 App；任意输入框兼容性没有保证。
- 没有自动更新，升级需要重新下载；切换签名后可能需要重新授权辅助功能。
- 没有 Apple 公证；本机构建的 zip 仅包含构建机器的架构。

## 宣传片素材

- 背景音乐：[Upbeat Corporate](https://www.jamendo.com/track/1670486) — Soundrider/Dope，CC BY
- 配音：Microsoft Edge 在线音色 Xiaoyi（经 [edge-tts](https://github.com/rany2/edge-tts)）
- 画面：自制动画，聊天窗口为通用示意

## 许可证

[MIT License](LICENSE)。
