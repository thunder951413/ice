<div align="center">
    <img src="Ice/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="160" height="160" alt="Ice">
    <h1>Ice</h1>
    <p>专为 macOS 27+ 打造的极简菜单栏图标管理工具：原生释放菜单栏空间，用轻盈的 Ice Bar 随时取用。</p>
</div>

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/thunder951413/ice/releases/latest)
![Platform](https://img.shields.io/badge/macOS-27.0%2B-blue?style=flat-square)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)

macOS 27 改用 `MenuBarAgent` 统一托管状态栏图标，传统“超宽分隔符挤压”与逐项窗口截图缓存方式已彻底过时。本版本彻底移除旧系统兼容包袱与冗余模块（外观遮罩、搜索面板、全局快捷键、悬停/滚轮监听、屏幕录制权限），聚焦最核心、最稳定的 **原生隐藏 + Ice Bar 浮层 + 极简中文三页设置**。

## 安装

1. 从 [最新 Release](https://github.com/thunder951413/ice/releases/latest) 下载 `Ice.zip`。
2. 退出正在运行的 Ice，将 `Ice.app` 放入 `/Applications`。
3. 从“应用程序”启动，按引导授予**辅助功能**权限（无需屏幕录制权限）。

> 请务必从 `/Applications` 运行：macOS 27 上从临时构建目录运行的副本可能被系统评估策略一并隐藏。

## 核心特性

### 1. 原生隐藏与三分区管理
- **真正腾出菜单栏宽度**：基于 macOS 27 原生进程级可见性断言隐藏第三方应用图标，退出或暂停隐藏即刻无损恢复。
- **两级/三级灵活分区**：默认提供 **常驻显示** 与 **隐藏** 两个分区，点击卡片即可一键切换；按需开启 **始终隐藏** 第三分区，按住 `⌥ Option` 点击或通过右键菜单打开。
- **右上角日期/日历与通知中心原生直通**：针对 macOS 27.2+ 原生弹窗机制专项适配，点击右上角日期或时间稳定弹出日历小组件与通知中心，绝不回缩闪烁。

### 2. 轻盈的 Ice Bar 悬浮面板
- **自然呼出**：左键点击菜单栏 Ice 图标或应用菜单右侧的空白菜单栏区域即可展开；智能识别应用菜单范围，绝不误触“文件/编辑”等菜单。
- **完整交互**：左键图标临时唤醒并打开对应菜单，右键图标呼出该应用自身的快捷菜单；支持键盘方向键切换、`Return`/`Space` 打开、`Esc` 收起。
- **外观与尺寸可调**：支持**磨砂毛玻璃**与**纯色面板**两种风格，可自由调节图标大小（`16–36 pt`）、图标间距（`0–12 pt`）与面板内边距（`2–12 pt`）。
- **自动收起与回隐**：支持点击外部窗口智能收起、定时收起、切换前台应用时收起，以及可调的临时唤醒保留时长。

### 3. 极简三页中文设置
- **常规**：开机自启、辅助功能权限状态、Ice 图标样式（含自定义图片）、空白处点击开关、Ice Bar 外观尺寸、自动收起策略、系统菜单栏图标全局间距调整。
- **图标管理**：实时显示隐藏状态，支持一键暂停/恢复隐藏、刷新列表、重置布局，以及直观的分区应用卡片切换。
- **关于**：版本信息与 Sparkle 自动更新检查。

## 构建与测试

需要 macOS 27 与 Xcode 27。

```sh
./Scripts/build-local.sh -quiet                       # Debug 构建
CONFIGURATION=Release ./Scripts/build-local.sh -quiet # Release 构建 (Apple Silicon arm64)
./Scripts/test-regressions.sh                         # 策略回归、发布包校验、原生桥接编译、Ice Bar 渲染检查
```

## 文档

- [macOS 27 架构与兼容性说明](Docs/macOS-27.md)
- [常见问题](FREQUENT_ISSUES.md)
- [发布指南](Docs/releasing.md)

## 致谢与许可证

Ice 起源于 [Jordan Baird 的 Ice](https://github.com/jordanbaird/Ice)，保留原作者及贡献者版权声明。macOS 27 可见性桥接参考了 [Thaw](https://github.com/thaw-app/Thaw) 的 GPL-3.0 实现并在对应源码中保留归属。

本项目遵循 [GPL-3.0](LICENSE) 许可证。
