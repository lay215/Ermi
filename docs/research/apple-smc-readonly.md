# AppleSMC 温度与风扇只读接入

> 本文保留 2026-10-16 的历史验证记录。2026-10-19 已扩展跨机型实现，当前范围见 [硬件兼容说明](../architecture/hardware-compatibility.md)。

2026-10-16。本机验证：MacBookPro18,4 / Apple M1 Max / macOS 27.0.1。此次仅接入读数，不安装 helper，不接管或修改风扇模式与转速。

## 数据契约与来源

自行实现最小只读协议，没有引入第三方运行依赖。参考的是 Stats 的协议事实与维护映射，固定到 commit `4ecf4f736056eb488c75aa2fa62e749abd87c4a4`，不将它视为 Apple 承诺的公开硬件契约。

- [传输结构](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/SMC/smc.swift#L56)、[读取流程](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/SMC/smc.swift#L638)：AppleSMC service，open type 0，selector 2；命令9读取metadata、5读取payload。80字节消息以固定偏移序列化：key0、size28、type32、result40、command42、payload48。不暴露任意命令或写接口。
- [M1温度映射](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/Modules/Sensors/values.swift#L389)：CPU效率核 Tp09/Tp0T，性能核 Tp01/Tp05/Tp0D/Tp0H/Tp0L/Tp0P/Tp0X/Tp0b；GPU Tg05/Tg0D/Tg0L/Tg0T。当前以M1 Max品牌和MacBookPro18,2/18,4匹配此profile，仅18,4已实际验证。
- [风扇读取](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/Modules/Sensors/readers.swift#L350)：FNum为数量，F{i}Ac为实测RPM，F{i}ID为描述。本机未返回可用名称，显示“风扇1/2”，不从编号猜左右位置。不用目标转速代替实测。
- [Stats许可](https://github.com/exelban/stats/blob/4ecf4f736056eb488c75aa2fa62e749abd87c4a4/LICENSE)：MIT。本实现按协议独立编写，没有复制其风扇写入实现，也未引入GPL组件。

## 本机探针结果

FNum=`ui8 `、值2；F0Ac/F1Ac及所选温度key均为`flt `。本机按小端IEEE754解码；整数与fpe2按其类型规则解码。CPU的10个与GPU的4个映射传感器均读取成功，风扇实测读数随系统负载变化。当前快照见 `output/native/sensor-snapshot.json`，不把某次值当作固定设备属性。

显示温度为本轮可用核心传感器的算术均值，不称CPU Package温度。快照保留参与key与聚合说明，界面caption和tooltip明确均值口径。温度0、非有限值及越界值视为不可用；RPM的0是有效停转值，不能替换成缺失。未知type/错误长度拒绝解码。

IOKit返回码与固件result均检查；0x84为缺失key。内核连接失败时关闭旧连接、清空metadata并延后5秒重连。每轮不保留上次成功温度/RPM作为实时值。未知芯片不套用M1 Max温度映射。

## 接入与验证

`SystemSampler`后台actor统一采样；同一快照驱动菜单栏温度、主浮层CPU/GPU温度、风扇RPM和详情GPU温度。可见2秒/隐藏5秒的既有刷新策略继续使用。没有周期启动shell命令。

16项测试通过，新增覆盖字节序、NaN/长度错误、部分温度均值、缺失后不沿用旧值、零RPM、描述缺失、错误数量和未知设备映射；真实只读探针核实类型和数值。原有进程测试只结束自行创建的sleep子进程。

尚未验证：其他机型、系统升级后的协议兼容性、实际睡眠唤醒长时回归。调速、温控策略应用、GPU利用率和系统内存压力仍未实现。
