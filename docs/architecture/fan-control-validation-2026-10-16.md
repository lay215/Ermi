# 风扇控制实施与验证 · 2026-10-16

## 最终真机结果：固定 4000 RPM 与恢复通过

2026-10-16 用户在新终端重新执行安装脚本后，授权探针确认 `authorized-build=true`。随后运行 `Ermi --fan-control-check`：`apply=applied`，两只风扇均为 manual、目标均为 4000 RPM；约两秒时实测 3984.42/3987.77 RPM，后续三次采样为 3983.09/4009.94、3995.21/3999.02、4015.97/3998.58 RPM。最终输出 `reached-target=true restored=true message=none`。本轮固定转速真实写入、机械响应和正常恢复已验收；温控曲线、强退、睡眠唤醒等场景仍未由这一轮证明。

本次修复针对写入成功后立即单次回读导致的误判，为接管模式、目标寄存器及恢复模式分别增加最多 450ms 的只读等待。仍要求模式和目标确认，不循环写入强抢，也不使用未知解锁键。全量 54 项测试通过。下方“交付边界”等内容保留早期记录，应以上述最新真机证据为准。

安装过程注意：重复 `open` 同一个 `.command` 可能只回到旧终端窗口；本轮曾观察到窗口进程和授权文件都仍为 15:49，而 App 已为 15:52 构建。应在新终端明确执行 `bash "<App>/Contents/Resources/InstallLocalFanControl.command"` 并以授权指纹校验为完成标准，不能仅凭窗口打开或 `open` 返回成功判断更新完成。

## 追加诊断：实际应用失败

2026-10-16 后续本机授权和 XPC 握手已成功。用户应用固定 4000 RPM 后，已授权诊断命令读到 `phase=failed`、`control-message=手动模式未确认`。随后硬件探针读到两只风扇均为 system，目标约 2317/2502 RPM，实测约 2322/2501 RPM。因此这次失败在模式写入后的确认阶段，不能继续归因为未授权或已有外部手动模式；是否为固件延迟生效仍待真机区分。

模式确认改为最多 450ms 的只读等待，超时保留具体 key、写入值及回读值；不绕过确认，不猜测其他解锁键。增加延迟生效与写入被忽略两项设备层测试，原实现失败、修改后全量 51 项测试通过。测试只证明模拟边界处理，不证明实际调速已修复。

增加显式真机验收命令 `output/native/Ermi.app/Contents/MacOS/Ermi --fan-control-check`：没有既有 Ermi 接管时，应用 4000 RPM，续租并在八秒内读取五次硬件状态，最后恢复系统并回读。此命令会真实调速，仅在明确验证调速的任务中使用；`--fan-service-status` 仍只读。验收要求最终实际转速在 4000±200 RPM、手动模式及目标值一致、随后恢复确认。新构建仍须管理员更新精确构建授权后才可执行。

首次自动验收（15:50 左右）：模式确认通过后出现 `目标RPM回读不一致`，首次回滚出现 `系统模式尚未回读确认`，最终输出 `reached-target=false restored=true`。独立只读探针确认两只风扇均已回到 system。因此模式等待并未单独修复整条控制链路。后续对目标值及恢复模式也加入最多 450ms 的只读确认，目标等待期间丢失手动模式立即失败，恢复等待忽略任务取消以保证清理。新增三项测试在修复前失败、修复后全量 54 项通过；这一版仍待安装后真机验收，不得将模拟测试视为硬件通过。

## 交付边界

已实现原生界面 → XPC → 独立 root helper → AppleSMC 的控制代码，支持统一/逐风扇固定 RPM、两点线性温控、预设持久化、显式恢复系统。当前本机构建是 ad-hoc 签名，未安装 helper、未执行真实风扇写入，不能据此宣布真机调速验收完成。

Ermi 监控、进程管理与风扇写入权限分离。首次启动、加载及保存预设均不接管。只在明确应用后写硬件，以模式和目标回读确认 applied；实际 RPM 仍来自传感器，允许机械响应延迟。读取或写入异常、失联、10 秒租约过期、退出时尝试恢复。恢复方法成功且系统模式回读成立后才清除待恢复状态。

## 实现

- `ErmiCore/FanControl.swift`：有限状态控制器、范围校验、CPU/GPU/二者最大值策略、可选转速变化速率、操作期间续租、恢复等待与重试。
- `ErmiCore/FanPresetStore.swift`：JSON 原子保存，坏文件保持原样；保存与应用分离。
- `ErmiCore/SMCFanDevice.swift`：只允许已核实的 M1 Max MacBookPro18,2/18,4，读取设备上下限；写入前检查 root、类型及长度，不覆盖已被其他控制器设为手动的风扇。
- `ErmiFanHelper`：有限领域 XPC 命令、单连接租约、独立采温、每秒 watchdog、签名校验、SIGTERM 恢复。断开会同步标记会话已失效，拒绝排队中的新控制请求。
- `Ermi/FanControlClient.swift`：SMAppService 启用、系统批准入口、连接代次与超时处理。两端要求相同 TeamID 和指定 bundle identifier；临时签名构建显示说明。
- helper 以 root 独占目录 `/var/db/app.ermi.fan-helper/ownership.json` 记下写前接管候选。启动先恢复日志中的候选，再开放 XPC；失败时退出并由 launchd 重试。硬杀 helper 无法立即执行清理，依赖服务重启，尚需真机故障测试。

## 本机只读事实

- 两只风扇范围：0 → 1200–5779 RPM；1 → 1200–6241 RPM。
- `F0Md/F1Md` 为 `ui8 `、1 byte；小写 `F0md/F1md` 不存在。
- `Mn/Mx/Tg/Ac` 为 `flt `、4 bytes。
- `Ftst` 不存在：本机仅尝试直接模式写入；缺失该键时不得猜测使用 `FTST` 或其他未知键。只有明确存在且格式正确时才允许有界解锁路径。
- 读取时两只风扇已为 manual，目标值还在变化；并非本次实现写入。真实验证前需通过原控制器将其恢复系统自动，Ermi 不强抢控制。

## 验证与未验收项

全量 `swift test` 为 45 项通过，其中控制器 18 项、SMC设备层 8 项。覆盖真实只读探针和 fake 设备控制；生产读写编码、外部接管拒绝、部分失败回滚、全局解锁释放、日志写失败禁止硬件写、异步采样时钟、租约续期/超时、shutdown 等待与尾部恢复失败均有测试。单元测试不证明当前机器接受写入。

发布构建与辅助服务打包可用：

```sh
scripts/build-app.sh
# 有可用签名证书后，使用同一身份签名 App 与 helper：
ERMI_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
# 无需提权的只读诊断：
output/native/Ermi.app/Contents/MacOS/ErmiFanHelper --inspect
```

当前钥匙串没有可用 codesigning identity。导入开发者签名身份、完成分发所需公证后，在「风扇预设 → 启用风扇控制」注册服务并完成 macOS 后台服务批准。这是本项目 TeamID 身份验证方案的前提，不声称 macOS 所有开发方式都不支持 ad-hoc。

下一步真机验收必须确认：固定目标写入和实测响应；两点温控随温度变化；恢复系统；App 强退、helper 重启、睡眠/唤醒和权限失效后的恢复。没有这些证据前保留“尚未完成真实调速验收”的状态。

协议参考：[Stats 固定版本 SMC 实现](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/SMC/smc.swift)、[Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)。本机实际键和类型优先于第三方机型假设。

## 角色记忆待处理

CTO 增量已提交但未完成：`hermes-cto`，operation `3dff9904-0b1d-5f54-9f7b-a8e11dd73860`，document `role:c3b5360a135ac46b609ac70f`。等待超时，子任务报告配置的 `gpt-6-luna` 不受服务账户支持（404）。后续修复记忆服务配置后查询原操作；不要重复创建写入。

待保存原文：2026-10-16 Ermi macOS风扇控制：异步控制的输入时间不能直接作为采样完成时间；应以同一可注入单调时钟在await之后检查新鲜度与租约，保留操作期间已接受的心跳。恢复成功必须同时满足device.restore完整执行成功和系统模式回读，不能因mode已变system而忽略后续目标清理、全局解锁释放或日志持久化失败。macOS13+双向XPC身份验证可使用公开listener建连与connection逐消息签名要求，避免私有auditToken KVC。仅限代码和fake验证经验；真实硬件写入、root日志与硬崩恢复仍未验收。

提交元数据：项目 `mac-menu-bar`；日期 `2026-10-16`；范围「macOS特权硬件控制、异步租约及恢复协议」；依据「FanControlTests 17项、SMCFanDeviceTests 8项通过；Foundation SDK NSXPCConnection.h；本次helper代码审查」。该提交时控制器为17项，随后新增已有外部接管的前置拒绝测试，当前为18项。项目会话记忆待 Stop hook 自动保存，与上述角色提交独立。
