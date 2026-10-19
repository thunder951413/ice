# Ice 与 Bartender 7 功能差距审查

> 更新日期：2026-09-19
> Bartender 信息来源：[Bartender 官方网站](https://www.macbartender.com/)
> Ice 信息来源：当前工作树代码审查，以及本轮提供的编译、离屏渲染和实际应用操作结果。

## 证据口径

本文严格区分以下证据：

- **Bartender 官方宣称**：官网文案与官网演示页面表达的能力，不代表本文在本机实测过 Bartender 应用。
- **Bartender 官网展示检查**：官方演示页的 DOM/CSS 检查。连续截图超时，因此只把检查结果作为网页展示参数，不推断 Bartender 应用内部实现或真实窗口像素。
- **Ice 代码确认**：当前仓库中存在对应实现。
- **Ice 本机验证**：本轮实际完成的 Release 编译、NSHostingView 离屏渲染或应用交互检查。

Ice 本轮已补齐独立 Bar 外观、Bar 内搜索与 options 入口、设置页预览和 Escape 关闭。它仍未覆盖 Bartender 的全部能力；Profiles、条件 Triggers、Widgets、独立 Spacers 和 clipboard history 仍是明确差距。

## 后续紧凑布局调整

按用户的最新偏好，Ice Bar 改为只包住图标的紧凑背景：默认图标 28 pt、
项目热区 32 pt、热区间距 2 pt、上下背景留白 4 pt，可见背景高度 40 pt。
General → Use Ice Bar 新增 Icon size（16–36）、Icon spacing（0–12）和
Background padding（2–12）三个原生滑杆，并提供 Reset sizes；设置持久化。
搜索、设置和恢复入口移到 Bar 背景右键菜单，移除常驻工具按钮。
下表与前轮验证中的 44 pt 热区、56 pt 背景和工具区测量属于前一版本。

菜单栏继续使用 General 中的 Ice icon 样式。正式安装并运行
`/Applications/Ice.app` 后，真实 SItem 在其他项目隐藏时保留，点击打开 Bar
已实测通过；此前从 DerivedData 运行的副本仍存在被系统一并隐藏的问题。
临时测试应用的允许列表保留行为也有同样限制，原生测试脚本用
`ICE_TEST_ALLOWLIST=1` 提供严格的可选诊断，不把这一场景报告为通过。

## 功能对照

| 领域 | Bartender 7 官方宣称/官网展示 | Ice 当前实现 | 结论与优先级 |
| --- | --- | --- | --- |
| 独立 Bar 外观 | 官方宣称独立 Bar 与 Liquid Glass；官网演示 DOM/CSS 显示约 48 CSS px 高、图标间隔 6 CSS px、32 CSS px 圆角/pill、`blur(3px)`、约 0.25 白色 tint，并有内高光与阴影；页面还展示磨砂、白、黑、渐变样式 | `IceBarSurface` 是与菜单栏外观分离的独立 surface：固定 16 pt 连续圆角，浅/深配色、边框、阴影；Frosted 使用 popover 磨砂并叠加最低 0.86 色底，Solid 使用实色；Reduce Transparency 时强制实色 | **本轮已补齐核心差距**。设计参数与 Bartender 官网展示不同，不宣称像素级复刻或功能等价 |
| 外观设置与持久化 | 官网展示多种 Bar 样式 | 独立 `IceBarStyle` 提供 Frosted/Solid；General 设置页可选择并持久化到 `IceBarStyle` defaults；实测 Solid 写入值为 `1` | **已实现并验证持久化**；后续可按需求扩充颜色/渐变，而非当前阻塞项 |
| Bar 内操作 | Command Bar 可用键盘触发并搜索菜单项，还提供 clipboard history | Bar 内新增搜索按钮；点击会关闭 Bar 并打开现有模糊搜索面板。搜索面板也可由快捷键触发，支持上下选择和回车。options 菜单提供“Arrange hidden items… / Ice Bar settings… / Show All Hidden Items / Close Ice Bar” | 搜索入口和 options → Menu Bar Layout 均已实测通过。clipboard history 缺失，列为 **P3** |
| 设置页预览 | 未作本机 Bartender 对照 | General 设置页在启用 Ice Bar 时提供 “Show Ice Bar” 预览按钮；延迟自动 rehide 已用 presentation generation 防止旧任务关闭新预览 | **已实现**；竞态修复需继续纳入回归测试 |
| 不扰动鼠标 | 官方的 “Zero mouse interruptions / without touching your mouse” 指程序操作不干扰鼠标，而非完整纯键盘导航 | Ice 在可用时以 AXPress 执行左键动作，无需移动鼠标；右键动作和 AXPress 不可用时的合成事件回退尚未做到全路径不移动/不干扰鼠标 | 左键主路径部分对齐；右键与回退路径仍有差距，列为 **P1** |
| 关闭与键盘操作 | Command Bar 官方宣称 keyboard search trigger | Ice 搜索面板可由快捷键打开，并支持上下键、回车与 Escape；Ice Bar 可见时启动全局 Escape monitor，关闭时停止，实测 Escape 后 Bar 的 AX 窗口消失 | **搜索操作代码已实现，搜索入口与 Escape 已实测**。单个项目有回车/空格动作及辅助功能语义，但本文不宣称 Bar 已完成左右键焦点导航 |
| Bar 尺寸与项目命中区 | 官网演示约 48 CSS px 高、图标间隔 6 CSS px、pill 外观 | hosted app icon 保持 28×28，命中区保持 44×44，项目间距为 4；实际两项目 Bar 测得 207×80（含 surface 外的阴影留白与操作区） | 已保证可操作热区；与官网演示尺寸不同属于当前设计选择 |
| Bar 唤出 | 官方宣称 click、hover、hotkey，并可在需要的位置召唤 | 支持点击/悬停菜单栏空白区域、菜单栏滚动/滑动、隐藏分区快捷键；位置为 Dynamic、Mouse pointer、Ice icon | 基础入口齐全，但 click/hover 仍依赖菜单栏空白区域，不能据此声称与 Bartender“任意位置”体验相同，列为 **P1** |
| 无屏幕录制权限 | 官方宣称不录屏时使用 app icons | macOS 27 hosted 路径用所属应用图标；旧路径仍依赖屏幕捕获的菜单项图像 | 特定系统路径已有降级，尚非所有支持系统的通用能力，列为 **P1** |
| notch / 空间不足 | 官方宣称处理 notch 溢出 | Ice Bar 在菜单栏下方承载隐藏项目，宽度受限时横向滚动；当前 surface 最大宽度按屏幕宽度减 32 计算 | 核心场景已覆盖；多屏、不同缩放、自动隐藏菜单栏仍需持续实机验证 |
| 条件 Triggers | 官方宣称支持电源、Wi-Fi、会议条件 | README 标为未实现；未发现规则模型、编辑器或执行引擎 | 缺失，**P2** |
| Profiles | 官方宣称支持 Profiles | README 标为未实现；未发现 profile 模型、切换 UI 或布局快照应用逻辑 | 缺失，**P2** |
| Widgets | 官方宣称支持 Widgets | README 标为未实现；未发现 Bar widget 模型或容器 | 缺失，**P3** |
| Spacers | 官方宣称支持 Spacers | Ice 只有全局 `NSStatusItemSpacing` / `NSStatusItemSelectionPadding` 调整；README 将 individual spacer items 标为未实现 | 独立 Spacer 缺失，**P2** |
| Menu bar spacing | 官方宣称可调整菜单栏间距 | Ice 已有全局间距滑杆与应用逻辑，会写系统 defaults 并重启相关应用 | 主能力已有；影响全局且应用成本较高 |

## 本轮 Ice Bar 实现

### 独立 surface

- `Ice/UI/IceBar/IceBarSurface.swift` 负责背景、圆角、边框与阴影，不再从菜单栏截图推导 Bar 颜色。
- Frosted 模式使用 `.popover` material，并叠加浅色或深色的 0.86 opacity 底色，以保证复杂背景上的可读性；Solid 模式直接使用实色。
- 开启 Reduce Transparency 时，即使选择 Frosted 也使用实色。
- `IceBarStyle` 与 General settings 独立持久化，Ice Bar 不再复用 `MenuBarAppearanceConfigurationV2`。
- Ice Bar 的构造链已移除 `IceBarColorManager`；显示路径不再创建菜单栏截图颜色管理器，也不再为 Bar 外观运行其 5 秒刷新 timer。

### 操作区

- Bar 右侧固定提供搜索按钮和 options 菜单。
- 搜索按钮沿用已有 `MenuBarSearchPanel`，因此仍具备 Fuse 模糊搜索、上下选择、回车执行及设置入口。
- options 菜单可进入 Menu Bar Layout、General 中的 Ice Bar 设置、恢复全部隐藏项目，或直接关闭 Bar。
- General 设置页新增 “Show Ice Bar”，便于直接预览样式。

### 生命周期与竞态

- Ice Bar 仅在可见期间启动全局 Escape 监听；关闭后停止监听，避免常驻吞键。
- `presentationGeneration` 标记每次显示/关闭。旧的延迟 rehide 任务不能关闭随后新打开的设置页预览，修复了新 preview 被旧任务误关的竞态。
- 切换 Space、屏幕参数变化和系统自动隐藏菜单栏等原有关闭条件仍保留。

## 验证结果

本轮已经完成：

- Release（arm64 + x86_64）和 Debug 配置编译成功；签名验证、可见性策略回归与三轮原生隐藏/恢复测试通过。
- 对 light/dark × Frosted/Solid 共 4 组 `NSHostingView` 做真实离屏渲染；四组中心像素 alpha 均为 1.0，并通过 `view_image` 检查实际视觉结果。
- 实际 Ice Bar 在两个项目时测得 207×80；两个项目的命中区均为 44×44，hosted app icon 为 28×28。
- 实际点击 Bar 搜索入口可打开搜索面板。
- 实际按 Escape 后，Ice Bar 对应 AX 窗口消失。
- 实际切换 Solid 后，defaults 中 `IceBarStyle=1`。
- options 菜单的 “Arrange hidden items…” 已实测打开设置窗口并定位到 Menu Bar Layout。
- 验证后原有 Auto Rehide 开启状态已经恢复；当前用户运行实例保持 Solid，defaults 为 `IceBarStyle=1`。
- 最终构建开启 Smart Auto Rehide 时，从设置预览打开的 Bar 持续可见，随后 Escape 使其 AX 窗口消失，预览竞态回归通过。

这些结果验证了本轮实现的主要路径，但不代表所有 macOS 版本、权限组合、显示器配置或 Bartender 功能均已对齐。

## 保留差距与路线

### P1：入口一致性与无录屏覆盖

- 继续验证 click、hover、scroll、hotkey 在多显示器、全屏空间、notch、自动隐藏菜单栏下的目标屏幕、锚点和关闭行为。
- 若要在 macOS 14–26 也提供无屏幕录制 app icon，需要设计不依赖菜单栏截图的图标来源和点击语义。
- 扩大无需移动鼠标的激活覆盖面，重点处理右键菜单和 AXPress 不可用时的合成事件回退。
- 完成 Bar 焦点进入、左右键遍历和焦点可见性的专项设计及实测；当前只确认 Escape 和单项激活动作。

### P2：自动化与布局复用

- Profiles：保存分区、顺序、可见性和外观的命名快照，并支持快捷切换。
- Triggers：定义条件模型、冲突优先级和状态抖动策略，再接入电源、Wi-Fi、会议状态。
- 独立 Spacer：作为可拖放、可持久化、可随 profile 切换的布局实体，不与全局 spacing 混用。

### P3：扩展内容

- Widgets 需要先确定宿主 API、刷新周期、能耗和交互边界。
- Clipboard history 涉及敏感数据、应用排除、保存周期和清理策略，应作为独立功能设计，不直接附加在菜单项搜索实现上。

## 后续验收清单

- 普通屏与 notch 屏，单屏与多屏，不同缩放比例。
- 屏幕录制权限允许、拒绝、撤销后的 Bar 与搜索表现；分别覆盖 macOS 27 hosted 路径和 macOS 14–26 截图路径。
- click、hover、scroll、快捷键与设置页预览分别唤出；Escape、点击外部、切换 Space、自动 rehide 分别关闭。
- Frosted/Solid 在浅色、深色、Reduce Transparency、Increase Contrast 下的可读性。
- 搜索、布局设置、Ice Bar 设置、全部恢复和关闭五个 Bar 内入口。
- 项目数量为 0、少量、超出屏宽时的尺寸、滚动和操作区稳定性。
- VoiceOver 标签、焦点进入、左右键导航、回车与空格激活；在完成实测前不标记完整键盘导航为已实现。
