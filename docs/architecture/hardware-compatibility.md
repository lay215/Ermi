# Mac 硬件兼容（2026-10-19）

## 范围

本次将 M1 Max 专用实现扩展为按芯片温度映射和设备风扇能力工作的实现。应用最低系统版本仍为 macOS 14；构建产物为 arm64 + x86_64 Universal App 和 helper，不包含 PowerPC 或 macOS 13 及更早系统支持。已发布的 v0.1.0 arm64 预览下载不随源码修改自动更新。

| 能力 | 当前实现 | 边界 |
| --- | --- | --- |
| 温度 | Intel、上游明确定义的 M1–M6/A18 Pro 芯片变体 | 未知芯片或缺失传感器显示不可用，不猜测相似 key |
| Apple Silicon 调速 | 实际存在的 per-fan md/Md、可选 Ftst | 验证类型、范围、模式与目标回读；固件拒绝接管时明确失败并恢复 |
| Intel 调速 | FS! 位掩码及可选 F?Md | FS! 缺失或类型未知时拒绝写入，不推断纯 per-fan Intel 协议 |
| 风扇数量 | FNum=0...10，动态单/多风扇 | 无风扇保留监测；超出单字符键范围明确拒绝 |
| 独立目标 | 按实际设备索引编辑并校验全部目标 | 不再固定两只风扇，也不从索引猜测左右位置 |

所有可写设备仍需管理员安装 helper；监测不需要管理员权限。CPU/GPU 温度缺失时，依赖该传感器的自动温控仍拒绝应用，不能静默切换到另一种温控策略。固定转速使用硬件范围，是否能写入最终取决于固件回读结果。

## 行为与兼容

- 无上次接管记录时，helper 启动不再先检查机型并退出；客户端通过 inspect 得到能力或具体错误，避免把机型限制表现为请求超时。
- XPC 增加可选 `capabilityProbeCompleted`。inspect 的空能力是明确结果；heartbeat 的默认空数组不是无风扇。新客户端仍可解码旧 helper 回包。
- 恢复日志保留接管协议与设备索引，兼容原双风扇日志。Intel 只更新对应 FS! 位，保留其他风扇位；旧日志部分恢复和持久化失败后仍可重试。
- 不抢占其他控制器，写前记录恢复候选，模式/目标必须回读确认。保留租约、退出/睡眠恢复与用户操作优先规则。
- 设备能力错误不随普通心跳被抹掉，用户可重试连接；无风扇或明确无法控制时不提交调速，仍保留交还系统的恢复路径。

## 来源与验证边界

具体协议语义、芯片映射和固定上游 commit 见：

- [温度映射依据](../research/temperature-compatibility.md)
- [风扇协议依据](../research/fan-protocol-compatibility.md)

自动测试覆盖硬件模拟协议、动态风扇数量、未知/非法类型、Intel 位掩码隔离、旧日志恢复、空能力与心跳区别、界面提交拦截和旧行为回归。构建检查覆盖两种 CPU 架构。本机硬件为 MacBookPro18,4 / Apple M1 Max，只能进行该机型只读探测；未对其他机型实际写入验证。

因此这是跨机型兼容实现，不是“每一款 Mac 已完成真机调速验证”。未知固件、未来机型、缺少已知协议的设备会保留监测并显示限制，不能通过关闭校验宣称全覆盖。

### 本次实际执行结果

- `swift test`：141 项 Swift Testing、1 项 XCTest 全通过。
- `scripts/build-app.sh`：release Universal 构建成功；App/helper 均通过 `lipo -verify_arch arm64 x86_64` 和深度严格签名检查。
- 打包 App `--smoke-test`、debug helper `--inspect`：本机 M1 Max 正常读取 CPU/GPU 温度及两只风扇范围，未发起硬件写入。
- `scripts/package-dmg.sh output/native/Ermi-0.1.0-universal-compat-preview.dmg`：生成本地安装包与 SHA-256 清单，`hdiutil verify` 通过。未上传或发布。
- 使用新版 App 后须在风扇页面更新 helper 授权，已安装的旧 helper 不随构建替换；本轮未修改系统已安装服务。
