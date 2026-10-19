# Ermi 原生架构提案

日期：2026-10-16。状态：用户已确认推荐方案，原生首个切片开发中。详见 `../adr/0001-native-macos-distribution.md`。

## 推荐结构

- SwiftUI：主浮层、详情、图表、设置与系统动效。
- AppKit：NSStatusItem、透明 NSPanel 与窗口生命周期，承载 SwiftUI 内容。初稿评估 NSPopover；2026-10-16 依据严格还原 R4 的要求改用透明 NSPanel，以免系统气泡箭头与白色衬底改变外壳。
- 后台采样 actor：统一 CPU、内存和进程快照，最近 60 秒使用有界缓冲；避免周期启动 shell，隐藏时降低刷新负担。
- ProcessService：区分退出 App 与终止单个进程；操作前复核 PID 和启动时间，操作后观察退出结果。
- FanBackend：按设备能力隔离温度、RPM 和调速协议。普通监控不依赖管理员权限；需要权限的风扇写入由 SMAppService LaunchDaemon 经 XPC 提供最小接口，校验调用方身份与输入。
- MenuBarOrganizer：独立模块，验证第三方图标的访问、刘海、多屏、全屏和权限撤销；不把图标截图当作可操作展开栏。

项目以开源方式维护，支持从源码构建本机 App。App Store 沙盒限制与结束其他 App 的需求冲突。暂不引入服务端或插件框架。

## 第一个开发切片

原生菜单栏入口 → R4 浮层 → 真实 CPU/内存与趋势 → 进程列表排序 → 自建测试进程的退出验证。未验证温度和风扇显示不可用，不混用演示值。

能力验证单独推进：先只读探测本机温度和风扇，再验证调速、主动恢复系统控制、异常退出、传感器失效及睡眠唤醒。未验证前不承诺跨机型支持或崩溃后自动恢复。

验收：可构建运行；开关窗口不产生重复采样；指标口径明确；已退出进程、PID 复用和权限拒绝有处理；无管理员权限可使用基础监控。

## 用户确认（2026-10-16）

1. 接受独立分发与按需授权风扇辅助服务。
2. 首个验证版本先针对本机 M1 Max；其他系统版本与机型需分别验证。
3. 监控先可用，风扇与图标整理通过能力验证后分阶段接入；总体范围不变。

## 官方依据

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [NSPopover](https://developer.apple.com/documentation/appkit/nspopover)
- [host_processor_info](https://developer.apple.com/documentation/kernel/1502854-host_processor_info)
- [NSRunningApplication.forceTerminate](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate())：沙盒 App 无法终止其他 App。
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)：2.4.5 与 2.5.1。
- [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) 与 [register](https://developer.apple.com/documentation/servicemanagement/smappservice/register())：服务注册和管理员批准。
- [签名与公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
