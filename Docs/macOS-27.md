# macOS 27+ 架构与兼容性说明

Ice 目前专面向 **macOS 27.0+**（`MACOSX_DEPLOYMENT_TARGET = 27.0`），使用 Xcode 27 构建。

## 架构概览

macOS 27 通过 `MenuBarAgent` 统一托管菜单栏状态项，传统的逐项 WindowServer 窗口与超宽分隔符挤压机制已不适用。Ice 采用原生可见性断言与 Accessibility 发现管线：

- **原生隐藏桥接**（[IceMenuBarVisibility.m](../Ice/Bridging/IceMenuBarVisibility.m)、[HostedItemVisibilityManager.swift](../Ice/MenuBar/MenuBarItems/HostedItemVisibilityManager.swift)）：
  - 改编自 [Thaw](https://github.com/thaw-app/Thaw/tree/macos-27-preview.1/Thaw/MenuBar/HiddenSectionPatch)（GPL-3.0，保留版权归属），通过 `dlopen` 动态解析私有框架 `MenuBarClientCore` 中的 `MBAssessmentModeConfiguration` 与 `MBAssessmentModeAssertion`。
  - 仅通过内存中的进程级断言传入允许显示的 Bundle ID 白名单与系统核心项（`0...8`），不修改 `MenuBarAgent` 偏好文件、无需完全磁盘访问权限、不重启其他应用；暂停隐藏或正常退出时立即释放并恢复所有图标。
  - 若未来系统版本缺少对应私有类或激活失败，所有图标保持可见并在“图标管理”界面提示错误，不会导致应用崩溃。
- **托管菜单栏发现与渲染树追踪**（`Ice/MenuBar/MenuBarItems/`）：
  - [HostedMenuBarItemHandle.swift](../Ice/MenuBar/MenuBarItems/HostedMenuBarItemHandle.swift)：封装托管菜单栏项句柄、渲染区域解析与 `AXPress` 触发。
  - [HostedMenuBarBackend.swift](../Ice/MenuBar/MenuBarItems/HostedMenuBarBackend.swift)：核心状态存储（单锁保护）、隐藏集合同步与底层 AX 属性读取。
  - [HostedMenuBarBackend+Enumeration.swift](../Ice/MenuBar/MenuBarItems/HostedMenuBarBackend+Enumeration.swift)：在串行后台队列上按时间预算（总预算 1.5s / 单应用 0.35s）轮转扫描运行中应用的 `AXExtrasMenuBar`，防止卡顿应用阻塞主线程或饿死后续应用。
  - [HostedMenuBarBackend+RenderedSnapshot.swift](../Ice/MenuBar/MenuBarItems/HostedMenuBarBackend+RenderedSnapshot.swift)：单次遍历 `MenuBarAgent` 渲染树并缓存 250ms 快照，用于空白区域点击判定、时钟点击直通以及多屏环境下的精确元素匹配。
- **日期/时钟与通知中心直通**（[ClockPanelVisibilitySession.swift](../Ice/Events/ClockPanelVisibilitySession.swift)、[EventManager.swift](../Ice/Events/EventManager.swift)）：
  - 针对 `MBAssessmentModeAssertion` 在 macOS 27.x（含 27.2）上抑制 `com.apple.notificationcenterui` 弹出的行为，在检测到原生点击未于 80ms 内弹出面板时临时释放断言并通过 `CGEvent` 点击渲染坐标，待通知中心/日历确认关闭后再恢复断言（无强制 30s 关闭超时）。
- **Ice Bar 悬浮面板与精简依赖**：
  - 统一使用应用图标呈现隐藏项，彻底移除屏幕录制权限、`ScreenCaptureKit` 截图缓存、外观遮罩、搜索面板、全局快捷键及悬停/滚轮监听。
  - 设置界面收敛为三页中文面板：**常规**（`GeneralSettingsPane`）、**图标管理**（`MenuBarLayoutSettingsPane`）、**关于**（`AboutSettingsPane`），保留既有 `UserDefaults` 键与 `HostedSectionAssignments`。
  - 外部远端依赖收敛为 `Sparkle`（另含本地 vendored `Packages/CompactSlider`，带 Xcode 27 SwiftUI 重载消歧补丁）；登录项与辅助功能已全面迁移至原生 `SMAppService.mainApp` 与 `ApplicationServices`。

## 使用边界与已知限制

1. **安装位置**：请务必将 `Ice.app` 安装至 `/Applications` 后启动，并授予**辅助功能**权限（无需屏幕录制权限）。从 `DerivedData` 等临时目录运行的副本可能被系统评估策略隐藏自身图标。
2. **隐藏粒度**：`MenuBarClientCore` 按应用的 Bundle Identifier 粒度生效，同一应用注册的多个菜单栏图标会一同显示或隐藏。调整常驻图标顺序请按住 `⌘ Command` 直接在系统菜单栏拖动。
3. **系统扩展项**：尽管保留了 9 类核心系统控制项（`0...8`），部分 Apple 附加项（如专注模式、隔空投送）仍可能受私有断言影响；右键菜单选择**暂停隐藏菜单栏图标**或退出 Ice 可立即恢复。
4. **签名与分发**：当前本地构建为 `Apple Development` 签名、未公证；使用本地重签副本替换后可能需要在系统设置中重新勾选辅助功能权限。
5. **私有接口风险**：`MenuBarClientCore` 与 CGS/AX 私有符号依赖未公开系统实现，后续 macOS 更新可能需要相应适配。

## 构建与验证

```sh
./Scripts/build-local.sh -quiet                       # Debug 构建
CONFIGURATION=Release ./Scripts/build-local.sh -quiet # Release 构建
./Scripts/test-regressions.sh                         # 全部确定性策略回归、发布校验、原生桥接编译与 Ice Bar 渲染检查
./Scripts/test-hosted-snapshot.sh                     # 只读实时 MenuBarAgent 快照烟雾测试（需辅助功能权限）
./Scripts/test-hosted-visibility.sh                   # 原生隐藏/恢复周期烟雾测试（需先退出正在运行的 Ice）
```

## 演进与历史验收摘要

- **2026-09（v0.12.1–v0.12.5）**：建立 `MenuBarClientCore` 私有桥接、后台轮转 AX 枚举、独立 Ice Bar 磨砂/纯色渲染与紧凑尺寸调节、无损暂停隐藏、优雅退出、时钟弹窗保活以及公开发布/校验闭环；修复全部 P1/P2 可靠性缺陷。
- **2026-11（v0.12.6+）**：全面转向 **macOS 27.0+ 专属版本**，移除 macOS 14–26 兼容代码与非核心模块，适配 macOS 27.2 日期/通知中心弹窗与副屏 Ice Bar 点击；进一步移除 `LaunchAtLogin-Modern` 与 `AXSwift` 冗余依赖、拆分 `HostedMenuBarBackend` 并启用 `SWIFT_STRICT_CONCURRENCY = targeted`。
- **尚未自动化覆盖的系统场景**：物理显示器热插拔、睡眠/唤醒、多屏全屏/Spaces 组合、运行期撤销辅助功能权限及私有 API 故障注入等，仍需在实机环境定期抽检。
