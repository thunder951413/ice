<div align="center">
    <img src="Ice/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="160" height="160" alt="Ice">
    <h1>Ice · macOS 27</h1>
    <p>隐藏菜单栏图标，用紧凑的 Ice Bar 随时访问。</p>
</div>

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/thunder951413/ice/releases/latest)
![Platform](https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

这是 [jordanbaird/Ice](https://github.com/jordanbaird/Ice) 的个人维护分支，增加了 macOS 27 菜单栏适配，并改进 Ice Bar 的外观、尺寸与交互。下载和自动更新均使用 **[thunder951413/ice](https://github.com/thunder951413/ice)**，与原项目的发布渠道独立。

当前发行版本为 **[v0.12.0](https://github.com/thunder951413/ice/releases/tag/v0.12.0)**。macOS 27 适配源码位于 **[codex/macos27-compat](https://github.com/thunder951413/ice/tree/codex/macos27-compat)** 分支；`main` 保留原有开发历史。构建本发行版时，请检出 `v0.12.0` 标签。

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
- **常用操作**：Escape 收起；右键 Bar 的背景可搜索、打开布局设置、打开 Bar 设置或恢复隐藏项目。右键应用图标保留该应用的次要操作。
- **分区管理**：Visible、Hidden、Always-Hidden；自动收起、快捷键和登录启动。
- **降低空闲开销**：共享短时菜单栏快照，移除不需要的图像与背景取色轮询。

默认图标为 **28 pt**，项目热区间距 **2 pt**，背景上下留白 **4 pt**，可见背景高度约 **40 pt**。尺寸范围分别为 16–36、0–12、2–12 pt。

## macOS 27 使用说明

在 **Menu Bar Layout** 中点击或右键一个应用图标，为它选择所属分区。macOS 27 上同一应用的菜单栏项目按应用一起管理；布局页不支持逐项拖动排序，可在系统菜单栏中使用 Command 拖动。

该路径使用所属应用的图标预览，屏幕录制权限为可选。系统菜单栏图标不能任意隐藏，部分 Apple 菜单附加项可能受系统限制影响；Show All Hidden Items 或退出 Ice 可以恢复访问。

最低构建目标仍为 macOS 14。本轮实机验收在 macOS 27 / Apple Silicon 完成，通用包包含 arm64 和 x86_64；旧系统、Intel 实机、多屏热插拔、睡眠唤醒和所有全屏组合未完成运行验证。macOS 27 的隐藏实现依赖私有接口，系统更新可能改变行为。

详见 [兼容性与验证记录](https://github.com/thunder951413/ice/blob/v0.12.0/Docs/macOS-27.md) 和 [Bartender 功能对照](https://github.com/thunder951413/ice/blob/v0.12.0/Docs/Bartender-comparison.md)。Profiles、条件 Triggers、独立 Spacers、Widgets 和剪贴板历史尚未实现。

## 自动更新

Sparkle 更新源来自本仓库 `updates` 分支的 `appcast.xml`，更新包来自本仓库 GitHub Releases。发行包使用本分支独立的 **Ed25519 签名**，不再信任或检查原作者的更新源。

仓库若为私有，需要有仓库读取权限的 GitHub 令牌。在 **About → GitHub updates** 中保存令牌；推荐仅授予此仓库 **Contents: Read-only** 的细粒度令牌。令牌只保存在本机钥匙串中，不写入普通偏好设置或发行包。公开仓库无需令牌。

从旧上游版本切换到本分支时，请先手动安装一次本仓库发行包，以切换更新源与签名公钥。仅修改网址无法让旧版本接受新的签名。

## 构建与验证

使用 Xcode 27 构建当前 macOS 27 适配：

```sh
git checkout v0.12.0
./Scripts/build-local.sh -quiet
CONFIGURATION=Release ./Scripts/build-local.sh -quiet
./Scripts/test-hosted-visibility-policy.sh
./Scripts/test-icebar-surface.sh
# 先退出 Ice；该测试仅操作临时测试应用
./Scripts/test-hosted-visibility.sh
```

`build-local.sh` 自动使用本机 Apple Development 证书；没有证书时构建未签名版本。输出位于 `build/DerivedData`。CompactSlider 1.1.6 已保留许可证并随仓库提供，包含 Xcode 27 所需的重载消歧修正。

原生测试默认检查三轮隐藏／恢复；`ICE_TEST_ALLOWLIST=1` 可启用临时应用的严格允许列表诊断，该诊断在当前系统上仍有已知失败，不能等同于正式安装副本的测试。

发布流程与签名说明见 [发布指南](https://github.com/thunder951413/ice/blob/codex/macos27-compat/Docs/releasing.md)。GitHub Actions 校验已准备的发行包、签名和版本，再发布 Release 与更新源；Apple 签名私钥无需上传 GitHub。

## 来源与许可证

- 原始项目：[jordanbaird/Ice](https://github.com/jordanbaird/Ice)。保留原作者及贡献者版权。
- macOS 27 可见性桥接参考 [Thaw](https://github.com/thaw-app/Thaw) 的 GPL-3.0 实现，并在相应源文件中保留归属。
- 本项目遵循 [GPL-3.0](LICENSE)。依赖库保留各自许可证。
