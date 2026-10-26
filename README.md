<div align="center">
    <img src="Ice/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="160" height="160" alt="Ice">
    <h1>Ice</h1>
    <p>为 macOS 27 重新设计的菜单栏管理器：隐藏菜单栏图标，用紧凑的 Ice Bar 随时取用。</p>
</div>

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/thunder951413/ice/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20optimized%20for%2027-blue?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

macOS 27 改用 MenuBarAgent 托管状态栏图标，以往靠“超宽分隔符”把图标挤出屏幕的做法已经失效。Ice 针对这套新机制重写了发现、隐藏和点击链路，并围绕它重新设计了 Ice Bar 与设置页面。macOS 26 及更早版本继续使用经典的分隔符方式。

## 安装

1. 从 [最新 Release](https://github.com/thunder951413/ice/releases/latest) 下载 `Ice.zip`。
2. 退出正在运行的 Ice，把解压出的 `Ice.app` 放到 `/Applications`。
3. 从“应用程序”启动，按提示授予**辅助功能**权限。

请从 `/Applications` 运行。macOS 27 上，从构建目录运行的副本可能被系统连同其他项目一起隐藏。

发行包使用 Apple Development 证书签名，**未经 Apple 公证**。首次打开如被拦截，到“系统设置 → 隐私与安全性”确认即可，无需关闭 Gatekeeper。Homebrew cask 安装的是其他项目，不是这个版本。

## 功能

**隐藏与访问**
- **真正释放菜单栏空间**：macOS 27 上使用系统托管接口隐藏项目，隐藏后原位置腾出。
- **三个分区**：Visible、Hidden、Always-Hidden，支持自动收起、快捷键和登录启动。
- **Ice Bar**：点击 Ice 图标或菜单栏空白处，在菜单栏下方展开一条紧凑的浮层，里面是被隐藏的项目。
- **应用菜单不误触**：点击“文件／编辑”等应用菜单及其间隙不会展开；无法确认菜单范围时，保留应用自身的点击行为。

**Ice Bar 交互**
- 左键图标：临时显示并触发该应用，右键图标：触发该应用自己的右键菜单。
- 右键 Bar 的空白背景：搜索菜单栏项目、打开布局或设置、暂停隐藏、关闭 Bar。
- 键盘：方向键选择，Return／空格打开，Escape 关闭。
- 浅色／深色、磨砂或实色背景，圆角与阴影；开启“降低透明度”时自动改用实色。
- 尺寸可调：Icon size 16–36 pt（默认 28）、Icon spacing 0–12 pt（默认 2）、Background padding 2–12 pt（默认 4），可一键 Reset sizes。

**搜索**
- 全局快捷键打开菜单栏项目搜索，模糊匹配，上下选择，回车触发；先显示结果，再在后台刷新。
- 不需要时可在 General 中关闭，同时释放该快捷键并保留其配置。

**布局与恢复**
- Menu Bar Layout 中点击或右键应用图标，选择它所属的分区。
- **暂停隐藏**会临时显示全部项目，恢复时回到原分区；**重置菜单栏布局**是单独的、需确认的操作。
- 隐藏切换在新状态生效前保留旧状态，支持超时、重试和权限恢复；运行期间撤销权限会自动释放限制，重新授权后恢复。

**外观**
- 菜单栏自定义外观：纯色、渐变、分隔线、圆角形状、阴影与边框。

## macOS 27 说明

- 在 Menu Bar Layout 中，**同一应用的所有菜单栏项目一起管理**，不支持逐项排序；需要精细排列时，在系统菜单栏中按住 Command 拖动。
- 预览使用所属应用的图标，**屏幕录制权限是可选的**。
- 部分 Apple 菜单附加项（如专注模式、隔空投送）可能受系统限制；遇到时用“暂停隐藏”或退出 Ice 即可恢复。
- 隐藏功能依赖私有接口，系统更新可能改变其行为。接口缺失或启用失败时，图标保持可见，并在 Menu Bar Layout 中提示原因。
- 最低构建目标为 macOS 14，通用包含 arm64 与 x86_64。实机验收在 macOS 27 / Apple Silicon 上完成；旧系统、Intel、多屏热插拔、睡眠唤醒和各种全屏组合尚未逐一验证。

详见 [macOS 27 兼容性记录](Docs/macOS-27.md)。

## 自动更新

使用 Sparkle。更新清单位于本仓库 `updates` 分支的 `appcast.xml`，安装包来自 GitHub Releases，使用独立的 Ed25519 签名校验，**无需 GitHub 令牌**。请不要删除或改写 `updates` 分支，否则已安装的版本将无法检查更新。

## 构建与测试

需要 Xcode 27。

```sh
./Scripts/build-local.sh -quiet                       # Debug 构建
CONFIGURATION=Release ./Scripts/build-local.sh -quiet # Release 构建
./Scripts/test-regressions.sh                         # 策略回归、发布包校验、桥接编译、Ice Bar 渲染
```

`build-local.sh` 优先使用本机 Apple Development 证书，没有则构建未签名版本，产物在 `build/DerivedData`（该目录体积较大，已被 git 忽略，可随时删除）。

需要 macOS 27 与辅助功能权限的实机测试（只读快照、隐藏／恢复）见 `Scripts/test-hosted-*.sh`。CI 在推送到 `main` 时运行 SwiftLint、发布脚本测试、逻辑测试与 Debug 构建。

## 文档

- [macOS 27 兼容性记录](Docs/macOS-27.md)
- [发布指南](Docs/releasing.md)
- [质量复查记录](Docs/quality-review-2026-09-19.md)
- [常见问题](FREQUENT_ISSUES.md)

## 尚未实现

Profiles、条件 Triggers、独立 Spacers、Widgets 和剪贴板历史。

## 致谢与许可证

Ice 起源于 [Jordan Baird 的 Ice](https://github.com/jordanbaird/Ice)，保留原作者及贡献者的版权。macOS 27 的可见性桥接参考了 [Thaw](https://github.com/thaw-app/Thaw) 的 GPL-3.0 实现，并在相应源文件中保留归属。

本项目遵循 [GPL-3.0](LICENSE)，依赖库保留各自许可证。
