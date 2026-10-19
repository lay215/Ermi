# 菜单栏图标整理

2026-10-16，本机 macOS 27.0.1（26A434）。

## 实现

- `MenuBarOrganizer` 是主线程控制器，拥有菜单栏箭头、旧系统分隔符、可见性断言和计时任务；`IconOrganizerView` 提供正式界面，原有设计预览保留。
- macOS 27 使用公开 Accessibility `AXExtrasMenuBar` 读取第三方 App 的入口数量，后台逐 App 读取，超时 150 ms。不读取截图或监听键盘内容；用户主动点击授权按钮才请求辅助功能权限。
- `MenuBarVisibilityPlan` 从当前运行 App 构建白名单，只扣除用户选中、本次已识别且仍在运行的 App。Ermi 和系统控件始终保护。尚未读取到或已退出的旧配置不能触发隐藏。
- `ErmiMenuBarBridge` 用 Objective-C 隔离私有 `MenuBarClientCore`，运行时校验类和 selectors，并捕获异常。`MBAssessmentModeConfiguration` 的白名单由系统控件编号 0–63 和允许的 bundle IDs 组成；这些编号及协议来自 Hidden Bar 已有实现，并非 Apple 公共契约。
- 创建断言后才显示“已收起”；异步请求按 generation 废弃旧结果，5 秒超时。展开、停用、刷新、分组更改、App 启停、屏幕变化和退出释放断言。新 App 启动先恢复全部，避免白名单隐藏未选择的新入口。
- macOS 14–26 扩大分隔符，将左侧图标移出菜单栏。收起前检查分隔线在箭头左侧；宽度以所有屏幕最大宽度计算，上限 10000 pt。此分支未在旧系统实机验证。
- `icons.enabled`、`icons.folded`、`icons.delay` 存于 UserDefaults；启动不恢复隐藏断言。延时只在用户展开时启动，菜单栏鼠标停留、拖动或按修饰键时延后。

## 限制

macOS 27 隐藏按 bundle 生效，不能独立管理同一 App 的多个图标；系统控件全部保留。它依赖私有接口，属于独立分发构建的实验功能；后续系统可能改变接口，不能视为 App Store 可发布能力。辅助功能未授权时仅展示授权引导，不伪造 App 列表。独立展开栏已实现于 `MenuBarTray.swift`：真实 App 图标、逐个 AX 入口及 AXPress/AXShowMenu，先恢复系统显隐再访问。权限和刘海场景的真实菜单响应待验收，不能将实现等同于兼容性验证。旧系统的加宽法不能解决刘海遮挡。

## 复现验证

```sh
swift test
scripts/build-app.sh
output/native/Ermi.app/Contents/MacOS/Ermi --icon-smoke-test
output/native/Ermi.app/Contents/MacOS/Ermi --capture-preview output/native/icons-organizer.png --detail-page icons --include-chrome
open output/native/Ermi.app --args --show-icons
```

`--icon-smoke-test` 使用独立临时 UserDefaults，验证启动、开关、持久化和退出状态；原生断言探针允许所有运行 App，验证创建/释放接口，不验证第三方图标实际隐藏。真实分组收纳须在用户授予 Ermi 辅助功能权限后验证。单元测试覆盖白名单选择、过期分组、不可读入口及自身/系统控件保护。

诊断分支在 model.start 前返回，未接管风扇；结束时直接允许退出，避免进入正常模式的异步风扇退出确认。正常启动的退出恢复流程保持原有规则。

## 一手参考

- [Hidden Bar native engine](https://github.com/dwarvesf/hidden/blob/master/hidden/Features/StatusBar/Engine/NativeVisibilityEngine.swift)
- [Hidden Bar Objective-C bridge](https://github.com/dwarvesf/hidden/blob/master/hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m)
- [Hidden Bar Accessibility inventory](https://github.com/dwarvesf/hidden/blob/master/hidden/Features/StatusBar/Layout/AccessibilityMenuBarInventory.swift)
- [Apple NSStatusItem autosaveName](https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename-swift.property)

桥接协议参考 Hidden Bar（Dwarves Foundation），MIT 许可见 `hidden-bar-LICENSE`。

## 本次验证结果

- `swift test`：44 项通过（包含本轮 3 项白名单规则测试）。
- Release 构建与本机 ad-hoc 签名成功。
- `--icon-smoke-test`：启停/偏好恢复通过，macOS 27 原生接口可用，断言创建与释放通过。
- 980 pt / 600 pt 正式页面截图已检查，授权引导与操作区未发生裁切。
- 本机 `accessibility=false`，实际第三方入口列表和隐藏效果待用户授权后验证。macOS 14–26 未做旧系统实机验证。

## 授权后空列表排查（2026-10-16）

用户确认权限提示已消失但列表为空，不能将此现象直接归为未授权。此次增加页面可见期间的授权变化同步（仅变化时刷新，避免打断收纳），macOS 27 引导名称改为「设备控制和数据访问」。列表为空时展示扫描 App 数及 AX 返回码计数，保留实际错误，避免继续要求重复授权。

当前发布构建与 49 项测试通过；真实 GUI 进程的 AX 返回码尚待新版界面采集，空列表根因与实际隐藏效果仍未验收。命令行探针不能替代 GUI 进程授权状态。诊断中的权限授予/撤销模拟只验证状态同步，不证明系统授权或真实图标读取成功。
