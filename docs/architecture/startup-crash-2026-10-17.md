# 登录启动与风扇模式闪退诊断

2026-10-17，本机日志时间 UTC+8。

## 原因与证据

- 登录项有效。系统 20:21:43 启动，loginwindow 在 20:22:26.324 记录 `performAutolaunch, launching: /Applications/Ermi.app`，20:22:27.674 确认 Ermi PID 825。
- PID 825 的崩溃报告记录启动时间 20:22:27.6446，父进程 launchd；20:22:37.2729 捕获崩溃。因此表现为“未自启”的实际原因是自启后退出。
- 20:22:28.041 创建风扇 XPC 连接，20:22:36.543 应用取消连接，随后出现主队列断言。时序符合客户端 8 秒超时断连路径，但不据此断言服务未启动：helper 在 20:22:21 已运行。
- 两份用户崩溃报告（`Ermi-2026-10-17-202241.ips`、`Ermi-2026-10-17-202349.ips`）均为 `EXC_BREAKPOINT / SIGTRAP`，栈指向 `FanControlClient.request(_:)` 的 XPC error handler。闭包继承 MainActor，而 Foundation 在 XPC 后台队列调用它。

## 修复与验证

- 错误和成功回调显式标记 `@Sendable`，只通过已有加锁的 PendingFanReply 恢复 continuation；保留原有授权、超时、租约和登录项规则。
- 新增真实 XPC 回归测试，连接唯一的不存在服务，不接触真实风扇。`swift test --filter unavailableServiceReturnsErrorWithoutCrashing` 修复前以 signal 5 崩溃，修复后正确收到 `NSXPCConnectionInvalid`。
- `swift test`：106 项 Swift Testing 加 1 项 XCTest 全部通过。
- `scripts/build-app.sh`：release 构建及 strict 签名验证通过。
- 新构建 `--fan-service-status`：`authorized-build=true connected=true capabilities=2 error=none`；只读检查时设备已有控制状态为 applied，未改变用户风扇模式。

交付为 `output/native/Ermi.app`。未替换正在运行的 `/Applications/Ermi.app`，未重启电脑；完整重启验收以及弹窗实际点击验收尚未进行。

## 首次连接提速（后续优化）

用户批准移除同轮重复校验、并行本地数据加载，并增加分阶段计时。请求仍逐次校验客户端身份、受保护的授权文件与 helper 签名；不通过缓存结果绕过安全检查，不自动重发调速指令。

`--fan-service-status` 直接发送只读 inspect，由请求入口完成唯一一次校验，并输出 `FAN timing`：

- `authorization_ms`：授权检查及其后台队列等待。
- `connection_setup_ms`：本地连接对象准备与报文编码。
- `reply_ms`：发送至收到回包的等待，包括 XPC 首次握手、服务处理及回包调度，不能视作纯握手耗时。
- `total_ms`：本次请求总耗时，不包含 App 进程初始化；`succeeded` 表示收到并解码回包，不等同于硬件调速成功。

正常应用以 OSLog subsystem `app.ermi.local`、category `FanConnection` 记录相同字段。失败或至少 1 秒的慢请求使用 notice，快速请求使用 debug，日志不包含预设内容或签名规则。

```sh
output/native/Ermi.app/Contents/MacOS/Ermi --fan-service-status
log show --last 10m --predicate 'subsystem == "app.ermi.local" AND category == "FanConnection"'
```

实现结果：正常轮询直接调用 request，首条 inspect 后再 heartbeat；本地能力和预设在后台与连接并行。服务能力优先，睡眠/停止取消旧加载；保存/删除使用 revision 防止迟到的初始快照覆盖新编辑。

验证：全量 112 项 Swift Testing + 1 项 XCTest 通过；新增阻塞本地读取仍先完成连接、迟到能力优先级、stop/睡眠不发布、保存交错、未授权提示，以及逐请求校验/撤销拒绝写入测试。Release 构建与签名校验通过。

本机交替运行已安装版本与优化构建的只读探针，各 3 次，后台服务已运行：

| 构建 | 含进程初始化总耗时（秒） | 中位数（秒） |
| --- | --- | --- |
| 已安装版本 | 0.528 / 0.518 / 0.365 | 0.518 |
| 优化构建 | 2.282 / 0.349 / 0.339 | 0.349 |

优化构建请求自身总耗时为 84.51 / 93.82 / 80.92 ms，其中授权 8.36–14.26 ms，XPC 等待 65.89–79.71 ms。新包首次进程启动仍有请求之外的开销，不能据三次小样本或热服务数据宣称重启后的冷连接已达到相同速度。所有探针保持原有 applied 状态，不应用或恢复风扇模式。

优化包仍位于 `output/native/Ermi.app`，本轮未替换 `/Applications/Ermi.app`、未重启系统或 helper。

## 默认恢复上次成功应用的配置

2026-10-17 用户明确要求默认开启，不增加设置开关。这取代此前“启动只监控、不应用任何配置”的应用层约定；helper 启动本身仍先恢复系统控制，只有经过校验的 App 请求才能重新接管。

- 记录成功应用的完整配置快照，包括固定 RPM、逐风扇 RPM、温度来源和两点温控参数；不以名称查找后来编辑的预设，也不把仅保存的预设当作运行选择。
- 新进程首次连接成功后，仅在服务处于 system 且没有新的用户操作时尝试一次。未授权或无法连接不弹安装窗；已有 applied/needsRecovery 状态不覆盖、不抢占。
- 主动切回系统自动并确认成功后清除记录；退出、睡眠的临时 restore 不清除。睡眠唤醒不重放启动恢复。
- 用户选择、安装/卸载、停止和退出使待恢复机会失效。恢复失败不循环重发 apply。
- 旧安装没有记录，保持 system；首次在新版本成功应用后才开始记忆。读取损坏记录不猜测配置，写入请求仍由 helper 检查当前硬件能力与控制归属。

实现使用现有注入 UserDefaults 的 `ermi.lastAppliedFanPreset` 保存 JSON 配置；仅完整匹配的 applied 成功回包更新。生命周期会取消自动应用 Task，阻止验签挂起期间退出后才发出写入；用户连续切换则保留在途回包确认，串行完成系统恢复。退出同时丢弃队列，防止迟到任务的收尾再次调速。

验证：新增跨模型的固定/分风扇/温控快照恢复，主动 system 与退出/睡眠区别，失败/不匹配不保存，失败不重试，授权等待、用户操作、睡眠/退出取消，以及在途自动应用时选择 system 的回归。退出队列测试修复前发现再次 apply，修复后通过；全量 121 项 Swift Testing + 1 项 XCTest 通过。风扇模型测试使用隔离 UserDefaults suite，不污染用户偏好。

签名 release 构建完成，打包版本只读探针 `connected=true authorized-build=true capabilities=2 error=none`（本次请求 24.26 ms）。未触发真实自动调速、未替换已安装 App，也未重启电脑；重启后的硬件恢复仍需使用新构建验收。


## 2026-10-18 息屏睡眠后模式重置

用户反馈息屏后模式重置。本机偏好仍有“积极散热”（maxCPUAndGPU、50–70°C）完整快照，pmset 在 20:40:59 记录 Clamshell Sleep、20:41:41 记录 FullWake 与亮屏。代码仅监听系统 willSleep/didWake，不监听纯显示器息屏；现有路径睡前恢复系统并取消恢复机会，唤醒却未重新启用，导致配置还在但控制模式停留 system。

本次修正取代上文“唤醒不恢复”的旧约定：真实唤醒使旧会话失效后重新获得一次恢复机会，复用已保存配置、连接确认、授权校验、用户操作优先、不抢占及失败不重试规则。重复 didWake 因 sleeping guard 被忽略，未成功的在途操作不作为恢复来源，主动 system 无记录则不应用。

回归命令 `swift test --filter connectionFailureCanRecoverOnceWithoutOpeningAuthorization` 修复前出现 3 个断言失败（没有第二次 apply，phase 仍为 system）。新增多次睡眠/重复唤醒通知、三类配置、主动 system 及唤醒等待期间用户操作的测试。

验证结果：全量 123 项 Swift Testing + 1 项 XCTest 通过，release 构建与签名校验通过。本轮未替换 /Applications/Ermi.app、未主动息屏或休眠；安装包与工作区构建哈希不同，真实合盖唤醒仍待新包验收。
