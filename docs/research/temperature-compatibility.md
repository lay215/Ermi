# 温度传感器兼容依据（2026-10-19）

温度映射按芯片品牌选择，不再按 MacBookPro18,2/18,4 机型限制。风扇控制能力独立探测，温度映射可用于无风扇 Mac。最低 macOS 版本仍由 Package.swift 决定，不代表老系统可运行。

## 固定的一手来源

本次联网读取并固定 Stats commit `573145558badb690728e39f3b2dcdb490e2ea731`：

- [传感器 key 及语义](https://github.com/exelban/stats/blob/573145558badb690728e39f3b2dcdb490e2ea731/Modules/Sensors/values.swift)：仅采用明确标记 CPU/GPU 的温度项；Apple Silicon 使用对应平台的 `average: true` 项。
- [平台成员集合](https://github.com/exelban/stats/blob/573145558badb690728e39f3b2dcdb490e2ea731/Kit/plugins/SystemKit.swift)：M1/M2/M3/M5 含基础版、Pro、Max、Ultra；M4/M6 仅基础版、Pro、Max；另含 A18 Pro。本项目严格按这些品牌匹配，不根据未来品牌推断兼容。
- [模板展开逻辑](https://github.com/exelban/stats/blob/573145558badb690728e39f3b2dcdb490e2ea731/Modules/Sensors/readers.swift)：Intel `TC%c` / `TC%C` 明确展开 `0..<10`。
- [MIT 许可](https://github.com/exelban/stats/blob/573145558badb690728e39f3b2dcdb490e2ea731/LICENSE)。采用协议/映射事实，未引入第三方运行依赖。

上述来源是开源软件维护的逆向映射，不是 Apple 公开硬件契约；上游声明的芯片集合也不等于本项目真机验证矩阵。

## 聚合与缺失语义

- Apple Silicon 维持现有“本轮可用核心传感器的算术均值”。M1 Max 的候选集合、顺序与有效区间 `(0, 150]` 不变，不混入缺失值、0 或旧值。
- M4 基础版 GPU 使用 `Tg0G/Tg0H`；Pro/Max 使用 `Tg1U/Tg1k`，再加上上游明确列出的共享 GPU keys。不同变体不互相回退。
- Intel CPU 优先 `TCAC/TCBC/TC0c…TC9c/TC0C…TC9C` 传感器均值；这些候选沿用上游 average 标记，不宣称与物理核心一一对应或覆盖全部核心。仅全部核心候选缺失时按 `TCAD`（package）、`TC0D`（diode）、`TC0E`（virtual diode）、`TC0F`（filtered diode）顺序选择一个有效读数。优先级是本项目产品规则：优先整包实测，避免将同一芯片多种处理后的读数重复平均；各 key 语义来自上游。回退时 `aggregation` 明确标记 package/diode。
- Intel GPU 取最大有效读数，候选是 `TCGC`（Intel Graphics）、`TG0D`（diode）、`TGDD`（AMD Radeon），避免同一物理 GPU 的多个别名被重复加权，也覆盖集显/独显并存时最热 GPU；记录实际 keys 和 maximum GPU die aggregation；不将散热片或邻近温度冒充核心温度。
- 未知芯片、所有候选缺失或非法读数返回 nil。不因 FNum 缺失而禁用温度；也不因温度缺失而伪造风扇数量。

## 验证与限制

固定映射的每个品牌都有 fixture 验证；另覆盖 M4 GPU 变体隔离、Intel 核心优先/整包回退/拒绝 proximity、未知品牌、缺失和非法读数；保留原 M1 Max 聚合回归。

只有实际可访问的本机可作只读探针验证，未声称完成 Intel、M2–M6、A18 Pro 全部真机测试。部分机型可能只暴露候选集合的子集，均值不是全部物理核心温度。未来芯片及上游未定义的变体仍需要新证据与适配，不以 key 名相似推测。
