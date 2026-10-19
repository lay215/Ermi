# 原生首个切片验证

2026-10-16，本机 Apple M1 Max。已构建 arm64 Release `output/native/Ermi.app`，本机 ad-hoc 签名严格校验通过；未签 Developer ID、未公证。

- `swift test`：10 项测试通过，含真实读取与自行创建的 sleep 子进程 TERM / KILL。测试没有结束用户应用。
- Release `--smoke-test`：真实 CPU 差分、64 GB 物理内存、当前用户可读进程与热状态读取成功。
- `--capture-preview`：同一原生 SwiftUI 浮层导出 `output/native/preview.png`，已检查 Logo、排序分段、关闭按钮与读数布局。导出只含短时真实样本，完整一分钟趋势需运行积累。
- 原生 Computer Use 运行验证：内存 → CPU → 内存排序，打开真实进程的确认框后 Escape 取消，进程仍在列表；设置入口成功打开风扇预设，真实窗口无侧栏、双卡等高、原生关闭/最小化/缩放按钮存在。没有在视觉回归中结束用户应用。
- 透明 NSPanel 运行截图已检查，370×693 pt 无白色系统气泡衬底。详情使用 48pt 自定义标题栏区域和真实 NSWindow 按钮。点击关闭后 AX 读取因没有可见窗口而超时；进程仍运行，未把该读取结果当作完整关闭/重新展开回归通过。
- 系统睡眠唤醒、多显示器、所有动效与运行时减少动态效果切换尚未做完整系统级回归。

尚待后续：风扇与温度协议验证、特权服务及恢复策略、第三方菜单栏整理能力验证、正式图标资源与分发签名公证。ProcessInfo 热状态不是摄氏温度，VM 内存估值不是系统内存压力。

CTO 角色记忆提交失败：operation `904fb774-5a66-591d-9184-8db5cb866506`，document `role:0db967c4a2ee1f20e4b2b4d7`；后端配置的 gpt-6-luna 返回 model_not_found。当前决定已保留在本地 ADR；后续重试应复用原 operation ID，避免重复写入。

## R4 设计还原复核

最新 `docs/design/ermi-r4/index.html` 为参考，不改参考稿来迁就原生实现。主浮层 370×693pt；合并监控白卡 350×335、连续控制卡 350×197；恢复温度主区、左右细分隔、双风扇、三段模式、策略/目标转速与底部入口。三详情页按 800pt 内容宽度对照。

固定样本截图由显式 `--design-reference` 生成，普通启动不会进入该模式；诊断进程行没有真实 PID，无法发送退出信号。截图包括主浮层、固定 RPM、确认框、系统概览、风扇预设、图标整理和完整标题栏。UI 角色最终静态复核认为主要结构已贴合；原生/浏览器字形抗锯齿、基线和图标笔触仍有细微差异，没有声称逐像素完全相同。

`output/native/r4-comparison-metrics.json` 保存同尺寸像素差，仅作静态辅助，不当作“还原百分比”。交互对照页为 `docs/design/ermi-r4/native-comparison.html`，支持并排及叠加查看。构建与10项核心测试通过，Release真实采样再次通过。

UI 角色记忆提交失败：operation `a0625035-c10e-5f4e-b9ec-b2b8e2a4008a`，document `role:51a8aeb33c0c2b20b897495d`；同样由于后端 gpt-6-luna model_not_found。待恢复后复用原 ID，结论已留在本文件及还原实现中。

## 温度与风扇监测接入

本机M1 Max只读接入完成：CPU核心均值（10个映射）、GPU核心均值（4个映射）、F0Ac/F1Ac实测RPM；FNum读到2，类型经真实探针验证。菜单栏和浮层由同一快照驱动，不修改风扇。当前测试16项通过，读取失败不沿用旧值；零RPM与未知分别处理。详见 `../research/apple-smc-readonly.md`。本文件之前“温度与转速待验证”的描述为早期阶段记录，现已被此结果更新；调速仍未接入。

本轮传感器结论的 CTO 角色记忆 retain 命令在会话中断前未返回 operation ID；结果未知，未重复提交。待核实结论为：M1 Max 只读实测、按 key 类型解码、零 RPM 与缺失分别处理、温度均值保留参与 key、风扇编号不推断左右、失败不沿用旧实时值；具体依据保留在 apple-smc-readonly.md 与测试中。
