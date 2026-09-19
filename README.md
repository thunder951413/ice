<div align="center">
    <img src="Ice/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="160" height="160" alt="Ice">
    <h1>Ice · macOS 27</h1>
    <p>隐藏菜单栏图标，用紧凑的 Ice Bar 随时访问。</p>
</div>

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/thunder951413/ice/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

这是 [jordanbaird/Ice](https://github.com/jordanbaird/Ice) 的个人维护分支，增加了 macOS 27 菜单栏适配，并改进 Ice Bar 的外观、尺寸与交互。下载和自动更新均使用 **[thunder951413/ice](https://github.com/thunder951413/ice)**，与原项目的发布渠道独立。

## 安装

1. 从本仓库的 [最新 Release](https://github.com/thunder951413/ice/releases/latest) 下载 `Ice.zip`。
2. 退出正在运行的 Ice，将解压后的 `Ice.app` 放到 `/Applications`，替换旧版本。
3. 从“应用程序”启动 Ice，并按应用提示授予辅助功能权限。

请从正式安装位置运行。macOS 27 上，从构建目录运行的副本可能被系统隐藏机制连同其他项目一起隐藏；本机已确认正式安装副本的 Ice 菜单栏图标可以保留。

当前发行包在本机使用 Apple Development 证书签名，**未经 Apple 公证**。系统可能要求通过“系统设置 → 隐私与安全性”确认打开。无需关闭 Gatekeeper。原项目的 Homebrew cask 安装的是上游版本，不会安装这个分支。

## 主要功能

- **真实隐藏菜单栏项目**：macOS 27 使用新的系统菜单栏托管接口，隐藏后释放原位置。
- **原生 Ice 图标**：在 General 中通过 Show Ice icon 和 Ice icon 选择显示状态及样式；点击图标或菜单栏空白区域展开。
- **紧凑 Ice Bar**：独立浅色／深色背景、磨砂或实色样式、圆角与阴影。
- **可调尺寸**：General → Use Ice Bar 下设置 Icon size、Icon spacing、Background padding；支持保存和 Reset sizes。
- **常用操作**：Escape 收起，方向键选择，Return／空格打开；右键 Bar 的背景可搜索、打开设置或暂停隐藏。右键应用图标保留该应用的次要操作。
- **分区管理**：Visible、Hidden、Always-Hidden；自动收起、快捷键和登录启动。
- **可关闭搜索**：General → Enable menu bar search。关闭后隐藏菜单栏搜索入口并释放搜索快捷键，保留快捷键配置；Ice 的搜索仅用于菜单栏图标。
- **无损暂停**：Pause Hiding 临时显示所有项目，Resume Hiding 恢复原分区；Reset Menu Bar Layout 是单独的确认操作。
- **响应与恢复**：串行后台扫描菜单栏，合并重复请求并限制扫描时间；搜索先显示再刷新。隐藏切换保留旧状态直到新状态生效，支持超时、重试和权限恢复。

默认图标为 **28 pt**，项目热区间距 **2 pt**，背景上下留白 **4 pt**，可见背景高度约 **40 pt**。尺寸范围分别为 16–36、0–12、2–12 pt。

若登录启动提示等待系统允许，点击 **Open Login Item Settings**，在“系统设置 → 通用 → 登录项与扩展”的后台 App 活动中允许 Ice。返回应用时开关会同步系统状态；注册失败会显示错误原因。

## macOS 27 使用说明

在 **Menu Bar Layout** 中点击或右键一个应用图标，为它选择所属分区。macOS 27 上同一应用的菜单栏项目按应用一起管理；布局页不支持逐项拖动排序，可在系统菜单栏中使用 Command 拖动。

该路径使用所属应用的图标预览，屏幕录制权限为可选。系统菜单栏图标不能任意隐藏，部分 Apple 菜单附加项可能受系统限制影响；Pause Hiding 或退出 Ice 可以恢复访问。

最低构建目标仍为 macOS 14。本轮实机验收在 macOS 27 / Apple Silicon 完成，通用包包含 arm64 和 x86_64；旧系统、Intel 实机、多屏热插拔、睡眠唤醒和所有全屏组合未完成运行验证。macOS 27 的隐藏实现依赖私有接口，系统更新可能改变行为。

详见 [兼容性与验证记录](Docs/macOS-27.md) 和 [Bartender 功能对照](Docs/Bartender-comparison.md)。Profiles、条件 Triggers、独立 Spacers、Widgets 和剪贴板历史尚未实现。

## 自动更新

Sparkle 更新源来自本仓库 `updates` 分支的 `appcast.xml`，更新包来自本仓库 GitHub Releases。发行包使用本分支独立的 **Ed25519 签名**，不再信任或检查原作者的更新源。

本仓库为公开仓库。0.12.1 起使用公开静态更新清单和 Release 下载地址，**无需 GitHub 令牌**，避免匿名 API 额度耗尽导致更新失败。旧版本保存的钥匙串记录不会被读取或发送。

若 0.12.0 的检查更新提示网络错误，请手动安装 0.12.1 一次，之后即可使用新更新通道。

从旧上游版本切换到本分支时，请先手动安装一次本仓库发行包，以切换更新源与签名公钥。仅修改网址无法让旧版本接受新的签名。

## 构建与验证

使用 Xcode 27 构建当前 macOS 27 适配：

```sh
./Scripts/build-local.sh -quiet
CONFIGURATION=Release ./Scripts/build-local.sh -quiet
./Scripts/test-hosted-visibility-policy.sh
./Scripts/test-menu-bar-click-policy.sh
./Scripts/test-hosted-enumeration-scan-policy.sh
./Scripts/test-visibility-assertion-session.sh
python3 Scripts/test-verify-release.py
./Scripts/test-icebar-surface.sh
# 先退出 Ice；该测试仅操作临时测试应用
./Scripts/test-hosted-visibility.sh
```

`build-local.sh` 自动使用本机 Apple Development 证书；没有证书时构建未签名版本。输出位于 `build/DerivedData`。CompactSlider 1.1.6 已保留许可证并随仓库提供，包含 Xcode 27 所需的重载消歧修正。

原生测试默认检查三轮隐藏／恢复；`ICE_TEST_ALLOWLIST=1` 可启用临时应用的严格允许列表诊断，该诊断在当前系统上仍有已知失败，不能等同于正式安装副本的测试。

发布流程与签名说明见 [发布指南](Docs/releasing.md)。GitHub Actions 校验已准备的发行包、签名和版本，再发布 Release 与更新源；Apple 签名私钥无需上传 GitHub。

## 来源与许可证

- 原始项目：[jordanbaird/Ice](https://github.com/jordanbaird/Ice)。保留原作者及贡献者版权。
- macOS 27 可见性桥接参考 [Thaw](https://github.com/thaw-app/Thaw) 的 GPL-3.0 实现，并在相应源文件中保留归属。
- 本项目遵循 [GPL-3.0](LICENSE)。依赖库保留各自许可证。
