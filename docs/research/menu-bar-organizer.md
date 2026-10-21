# 菜单栏图标整理

2026-10-16，本机 macOS 27.0.1（26A434）。

## 实现

- `MenuBarOrganizer` 是主线程控制器，拥有菜单栏箭头、旧系统分隔符、可见性断言和计时任务；`IconOrganizerView` 提供正式界面，原有设计预览保留。
- macOS 27 使用公开 Accessibility `AXExtrasMenuBar` 读取第三方 App 的入口数量，后台逐 App 读取，超时 150 ms。不监听键盘内容；用户主动点击授权按钮才请求辅助功能权限。展开栏原图标另有可选的屏幕录制授权，与 AX 权限分离。
- `MenuBarVisibilityPlan` 从当前运行 App 构建白名单，只扣除用户选中、本次已识别且仍在运行的 App。Ermi 和系统控件始终保护。尚未读取到或已退出的旧配置不能触发隐藏。
- `ErmiMenuBarBridge` 用 Objective-C 隔离私有 `MenuBarClientCore`，运行时校验类和 selectors，并捕获异常。`MBAssessmentModeConfiguration` 的白名单由系统控件编号 0–63 和允许的 bundle IDs 组成；这些编号及协议来自 Hidden Bar 已有实现，并非 Apple 公共契约。
- 创建断言后才显示“已收起”；异步请求按 generation 废弃旧结果，5 秒超时。展开、停用、刷新、分组更改、新 App 启动、唤醒、屏幕变化和 Ermi 退出释放断言。新 App 启动先恢复全部，避免白名单隐藏未选择的新入口；稳定收纳时其他 App 退出只清理失效入口，保持现有断言。
- macOS 14–26 扩大分隔符，将左侧图标移出菜单栏。收起前检查分隔线在箭头左侧；宽度以所有屏幕最大宽度计算，上限 10000 pt。此分支未在旧系统实机验证。
- `icons.enabled`、`icons.folded`、`icons.hidden`、`icons.order`、`icons.delay` 存于 UserDefaults；启动按保存分组自动准备并恢复隐藏断言，不自动打开横条。延时只在用户展开时启动，菜单栏鼠标停留、拖动或按修饰键时延后。

## 限制

macOS 27 隐藏按 bundle 生效，不能独立管理同一 App 的多个图标；系统控件全部保留。它依赖私有接口，属于独立分发构建的实验功能；后续系统可能改变接口，不能视为 App Store 可发布能力。辅助功能未授权时仅展示授权引导，不伪造 App 列表。独立展开栏位于 `MenuBarTray.swift`，使用逐个 AX 入口及 AXPress/AXShowMenu；图像优先使用原状态项的单色快照，未获取时使用灰度 App 图标。旧系统的加宽法不能解决刘海遮挡。

### 2026-10-20：菜单栏下方单行展开

- 普通箭头点击先收纳，再次点击在按钮下方展开一行图标；再次点击、Esc、外部点击关闭横条。设置页“临时展开”和展开栏按钮使用同一入口，原“展开全部收纳图标”仍恢复系统菜单栏显示。
- 收纳前采集精确 AX 元素与位置：macOS 27 按实际隐藏的 bundle 集合筛选，旧系统按分隔线左侧真实位置筛选。同 App 多入口分别保留，无法读取位置的旧系统入口不猜测归组。
- 打开横条和点击项目都保留隐藏断言、旧系统分隔线宽度与 `collapsed` 状态；直接对缓存的原 AX 元素执行一次支持的动作。成功后关闭横条；失败显示错误，不自动重试、不展开全部作为回退。关闭横条也不改变收纳。
- 面板为无标题 `NSPanel`，高 48pt，宽度随数量调整并夹紧屏幕，超宽时横向滚动。计时收起保护菜单栏和展开栏内悬停。
- 展开栏原图标在收纳前读取并只缓存于内存，不是实时状态。原图标读取需要可选的屏幕录制权限，未授权或窗口不可捕捉时使用灰度 App 图标，仍可执行 AX 点击。第三方 AX 支持、刘海、多屏和旧系统实际点击仍需分别验证。
- 分组选择沿用 Ermi 的 `detailCard`、配色、字体及按钮，呈现“保留 / 收起”两条 50pt 图标区。跨区拖动或选中后点击移动按钮都调用同一分组校验；同 App 多入口用数量徽标说明，Ermi 和系统入口锁定。搜索、空组、停用、撤权和扫描中的状态仍保留明确反馈。
- 选择界面参考 Ice 的 [MenuBarLayoutSettingsPane.swift](https://github.com/jordanbaird/Ice/blob/main/Ice/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift)；本项目仅调整归属，菜单栏实际排列仍由 macOS 保存。
- 行为参考 [IceBar.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/UI/IceBar/IceBar.swift) 的单行面板。Ice 的 [MenuBarItemManager.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift) 会先移出单个图标再合成坐标点击；Ermi 使用精确 AX 动作，不依赖坐标，不为点击解除整组隐藏。

验证入口：`swift test`，以及 `Ermi --capture-preview <path> --preview-icon-tray [--tray-state empty|permission|overflow]`。添加 `--check-icon-tray-window` 可检查真实 NSPanel 的打开、Escape、再次打开及关闭；分组页预览使用 `--design-reference --detail-page icons --preview-icon-list --include-chrome [--selected-icon com.apple.Safari]`。预览仅注入内存数据，不改变真实分组或权限。

本次在当前提交加本任务文件的隔离副本中验证，避免混入工作区并行进行的风扇改动：162 项测试通过，单行条四种布局及分组页中英文截图检查通过；签名构建和窗口生命周期探针通过。原生隐藏断言创建/释放通过，但构建的 AX 授权探针为 `false`，因此不将样本点击测试表述为真实第三方菜单验证。

### 2026-10-20：点击保持收纳修复

用户反馈点击展开栏图标会让整组菜单栏重新展开。根因是 `beforeActivate` 调用了 `expand(preservingTray: true)`；已删除该调用、位置等待和操作后的重新收纳任务。点击现在只校验状态并调用原 AX 动作，隐藏断言全程保留。

新增 Organizer 与 Tray 的集成回归，不替换生产点击回调：经真实 `collapse()` 流程建立替身断言，在动作执行瞬间及完成后检查未释放，覆盖成功、失败、关闭竞争，以及停用/退出仍恰好释放一次。隔离副本 166 项测试通过，通用签名构建验证通过。自有隐藏状态项的 AppKit 动作探针通过；macOS 27 原生隐藏下真实第三方菜单的跨进程 AX 弹出仍未实机验证。英文页面截图检查通过，沿用现有样式。

### 2026-10-20：展开栏图标统一菜单栏风格

- 原状态项图像由 `MenuBarIconCapture` 在收纳前通过 ScreenCaptureKit 单窗口接口采集，使用 PID、状态项窗口层和 AX 四边界唯一匹配；不捕获整个桌面。总预算 1.5 秒，超时返回已完成部分，取消或迟到结果不会回填。
- 只接受透明背景且有可辨认轮廓的图像，裁去透明留白并保留 Retina 比例，以 Ermi 单色前景显示。较宽数字图标按比例增加按钮宽度，过长文字回退；横条按真实按钮宽度布局。
- 缺少录屏授权、系统不提供对应窗口或图像不能安全模板化时，使用真正转换后的灰度 App 位图。图片不持久化，也不是动态状态的实时镜像。
- 录屏授权独立于 AX 授权，只由展开栏的图片按钮或“间距与行为 → 菜单栏原图标”主动请求。拒绝或撤销只影响图像，不影响原 AX 点击；授权返回不自动展开或重扫，下次主动收纳才更新图像。
- 预览增加 `--tray-icons status|fallback|mixed|wide`，`status` 与 `wide` 使用示例模板而非真实第三方截图。原第三方状态图像能否被当前系统捕获仍需已授权实例实测；拒绝授权时的灰度显示不依赖截图。
- 验证：隔离副本 181 项测试通过，包含图像唯一匹配、透明轮廓、Retina 比例、超时/取消、权限分离和灰度位图的颜色及 alpha；浅色、石墨灰主题、无录屏授权和宽数字样本预览已检查。真实第三方状态图像未作为本次已验证结果。

### 2026-10-20：展开栏改为 macOS 原生外观

用户要求图标展开栏采用苹果风格。macOS 26+ 使用 SwiftUI `glassEffect(.regular)`，macOS 14–25 回退为 `NSVisualEffectView` 的 `.popover` 材质；保留透明 NSPanel 的系统阴影。展开栏使用系统语义前景色、连续圆角、悬停和按下高亮、工具按钮前的分隔线，随系统深浅色变化。主界面的 Ermi 配色不参与展开栏材质。

点击仍执行原 AX 动作，收纳断言、权限和单行滚动逻辑不变。诊断可加 `--preview-appearance light|dark` 覆盖当前截图进程的外观；`--show-icon-tray-preview` 显示真实样本面板 30 秒后自动关闭，不扫描或隐藏第三方图标。离屏 `cacheDisplay` 无法完整导出 WindowServer 合成的玻璃及其前景效果，不能把该 PNG 当作实际材质截图。

本次隔离副本的 181 项测试通过，通用签名构建通过，真实面板的打开、Escape、再打开与关闭探针通过。实屏截图工具两次读取应用均超时，故没有将玻璃材质的视觉效果标记为实屏已验收。旧系统材质路径只完成编译和静态检查，未在 macOS 14–25 真机验证。

### 2026-10-20：紧凑展开栏与隐藏分组

展开栏高度由 48pt 调整为 36pt，18pt 图标使用 28pt 点击区，上下各留 4pt；原生玻璃圆角同步收紧。菜单栏开关改为字面中点 `·`，保留 24pt 点击宽度及描述当前操作的辅助标签。

macOS 27 按 App 分组增加「隐藏」：`icons.folded` 延续旧收起配置，`icons.hidden` 独立保存隐藏组，两者互斥；配置冲突时隐藏优先。收纳计划以两组并集筛选当前可读、正在运行且不受保护的 App，展开栏只取合格的收起组，因此隐藏项的所有入口均不会混入展开栏。仅有隐藏组时仍允许收纳，展开栏可为空。

沿用既有的显式应用流程：编辑分组或刷新会恢复全部显示，点击「立即收起」应用；普通展开栏开关和原 AX 点击不释放断言。启动不自动收纳，App 集合变化、停用或退出仍恢复全部。旧系统继续按分隔线位置分组，不使用按 App 的隐藏组配置。

验证：隔离副本 189 项测试通过，覆盖三组六方向移动、旧配置与冲突优先级、两组并集隐藏、隐藏 App 多入口全部排除、仅隐藏组收纳及编辑/刷新/停用后的恢复。通用签名构建验证通过；36pt 面板的打开、Escape、再次打开与关闭检查通过；600×430 的中英文设置页预览中，三组和选中后的移动按钮均完整可见。真实第三方隐藏/AX 操作及 WindowServer 玻璃合成仍沿用前述未实机验收的限制。

### 2026-10-20：箭头与单击打开

用户确认用 `chevron.down` / `chevron.up` 替换中点，状态项宽度增至 30pt，保留系统菜单栏全高点击区。准备阶段立即高亮并显示不截获鼠标事件的原生加载指示，打开后箭头朝上。

普通单击现在直接打开或关闭下方横条。首次使用及 App 集合变化后的清单由入口自动读取，无需先打开设置页；扫描、快照和隐藏断言等待期间的连续点击合并为同一个打开意图。清单刷新与显式恢复分离，避免内部刷新取消自身；外部刷新、恢复全部、停用、退出、屏幕及桌面变化仍取消未完成请求，迟到断言立即释放。设置页保留显式取消入口，弹栏关闭与原图标 AX 点击仍保持收纳。

验证：隔离副本 196 项测试通过，覆盖首次单击、三个准备阶段的重复点击、取消后迟到结果、旧刷新取消、新 App 清单及空清单重试。原生状态项通过实际 target/action 触发，按钮四角、中心和加载指示位置均保持命中；状态项宿主在测试进程可为零高度，因此这些检查证明布局与事件路由，不作为实屏材质或真实鼠标点击的验收。中英文行为说明预览无裁切；第三方原图标及 AX 操作仍保留前述实机验证限制。

### 2026-10-20：设置、展开栏与顶部菜单栏排序

macOS 27 的分组页与展开栏支持按 App 拖动排序，设置页提供左右移动按钮。`icons.order` 保存 bundleID，离线 App 的位置保留，新 App 追加到已保存顺序后；没有配置时保持原有显示顺序。同 App 的多个入口一起移动并保留内部相对次序，缓存的 AX 身份和原图标动作不因排序重建。搜索后的拖放按目标身份定位，不能用筛选列表下标修改完整分组。

普通同组排序只保存偏好，不展开真实菜单栏；跨组移动沿用恢复全部后显式收纳的流程。「同步菜单栏顺序」才暂时释放隐藏断言，调用 `MenuBarOrdering` 对完整显示且身份明确的入口合成 ⌘ 拖动。每次移动及最终结果均重新读取 AX 位置核对，失败会明确提示并保留本地顺序。正常完成、失败及 Esc 取消会尝试恢复此前收纳/展开栏状态；显式恢复全部、停用、刷新、退出或屏幕变化会取消任务，迟到结果不能覆盖新状态。

排序只接受当前同一菜单栏内可见、未被刘海遮挡且能精确命中的入口；不宣称同步其他显示器的复制菜单栏。权限、App 身份或显示器布局变化会中止。短时 AppKit 监听只检查鼠标、修饰键与 Esc，不记录键盘内容；用户输入会停止后续拖动，已按下时补发释放。部分已完成的位置不自动回滚；仅在收到释放事件且用户未接手指针时恢复指针位置。无需额外屏幕录制权限。

原生系统事件路径尚未通过真实第三方状态项实机验收；自动化覆盖排序规划、持久化、原动作身份、状态恢复及取消竞争，使用替身操作，不代表 macOS 已接受真实拖动。旧系统继续使用原有 ⌘ 拖动与分隔线方案。设置页排序样本预览在原参数后添加 `--preview-icon-order`。

验证：隔离副本 206 项测试通过，其中新增 10 个测试、19 个展开场景；中英文 600×430 排序页面预览已检查。arm64/x86_64 主程序与 helper 构建及严格签名校验通过，交付到 `output/icon-tray/Ermi.app`；14 个任务源文件哈希与工作区一致。隔离构建未纳入并行风扇改动，真实拖放手势与第三方顶部排序仍待实机验收。

### 2026-10-21：同 App 入口独立排序

此节取代上文“同 App 的多个入口一起移动”的排序约定。设置页拖放、左右按钮与展开栏改用精确 AX 元素身份，只移动选中的入口；同步顶部菜单栏也按完整入口顺序规划并读回核对。三条扫描路径共享身份映射，标题、坐标和扫描下标都不作为入口身份；同 bundle 多进程只合并 App 外壳，入口仍分别排序。刷新时沿用现存入口的显示编号。

原 `icons.order` App 顺序继续作为旧配置的初始排列。逐入口顺序绑定当前 AX 生命周期，不将随机运行期身份写成跨启动偏好；重新启动或入口重建后重新识别，不猜测对应关系。用户显式同步后，真实顶部位置交给 macOS 保存。系统可见性接口仍按 App 生效，因此多入口跨组拖动明确拒绝，并提供“移动整个 App”按钮；不能把独立排序表述为独立保留/收起/隐藏。

新增回归覆盖精确身份、同 App 单入口拖动、设置与展开栏互通、原动作保持、刷新扫描次序变化、旧入口消失、跨组拒绝，以及系统同步收到逐入口顺序。真实第三方菜单栏拖动仍需在已授权实例验收。

### 2026-10-21：App 退出后保持收纳

根因是 `NSWorkspace.didTerminateApplicationNotification` 与启动、唤醒共用无差别 `appsChanged` 清理路径：任何 App 退出都会清空清单、调用 `expand()`、释放隐藏断言。先用 `terminationKeepsOtherIconsCollapsed` 复现，8 个参数场景全部失败（1.19 秒），直接观察到 `collapsed == false` 和断言被释放；不以“下次点击能重新收起”替代保持收纳的验收。

已将通知类型传入处理函数：稳定收纳时，退出只按当前运行 bundle 集合及通知中的准确 PID 移除缓存入口，保留现有隐藏断言、分隔线宽度、面板状态及其他入口 UUID/AX/图像。不会标记自动刷新，避免设置页轮询又间接展开全部。分组及排序偏好保留；启动、唤醒、准备中的变化、撤权、显式刷新与停用仍沿用原恢复规则。

已退出入口的 AX 迟到结果不再显示错误或关闭面板，其他仍有效入口的动作继续完成。回归覆盖收起/隐藏/保留/无关 App 退出、面板打开/关闭、权限轮询、AX 执行中退出及同 bundle 多进程。验证使用真实控制器流程与系统接口替身，不改变本机第三方 App；真实 macOS 私有断言在第三方 App 退出后的系统行为仍需已授权实例实测。

结果：隔离副本 209 项测试通过（新增 3 项测试、11 个参数展开场景，并补充启动/唤醒通知回归）；通用主程序及 helper 的 arm64/x86_64 架构和严格签名验证通过。签名包更新到 `output/icon-tray/Ermi.app`，14 个编译源文件与工作区哈希一致，未包含并行风扇改动。红灯、专项绿灯与完整回归日志保留在同一输出目录。

### 2026-10-21：默认自动收纳与分组即时应用

用户反馈每次必须点击展开箭头才生效，并确认修改分组应立即应用。根因是启动仅安装状态项，分组编辑只保存配置，新 App 启动及唤醒后只释放旧断言；完整准备流程此前只由点击触发。此节取代上文历史记录中的“启动不自动收纳”和“改分组后显式应用”约定。

- 启动和重新启用按已保存分组自动扫描、保存入口快照并收纳，横条保持关闭；后台不请求权限。没有配置或未启用时不扫描。旧系统继续使用分隔线，并不新增 AX 授权前置条件。
- 分组修改立即释放旧断言并应用新分组，移回保留组后恢复系统菜单栏显示；仅剩保留组时不创建新断言。隐藏项仍不进入横条，纯排序不改变收纳。
- App 启动、唤醒、屏幕布局变化及准备中的桌面变化取消过期计划，依据当前清单重新静默收纳。稳定收纳中的退出仍只清理退出入口。启动通知早于状态项创建时，对已配置且运行的缺失项最多追加三次短暂补读，不无限重试。
- 手动展开全部、显式刷新、停用、退出均取消自动意图，迟到扫描与断言不得恢复收纳。权限返回只恢复仍有效的意图；设置页打开与权限轮询不解除已有收纳。
- 自动准备期间点击箭头将打开意图合并到同一次请求。取消、撤权、失败仍使用原 generation 校验和错误反馈。

回归命令：`swift test --filter savedGroupsCollapseWithoutClickingArrow`。修复前启动与重新启用两个场景均因 `collapsed == false` 失败；日志位于 `output/auto-collapse/red.log`。自动化使用真实控制器与注入的 AX、截图、隐藏接口，不操作本机第三方图标，不代表旧系统或第三方菜单实机验收。

验证结果：完整回归 251 项 Swift Testing 与 1 项 XCTest 通过；arm64/x86_64 通用构建和严格签名校验通过，包位于 `output/native/Ermi.app`。真实诊断进程的启停、偏好与权限变化探针通过，保留所有 App 的原生断言创建/释放通过；该进程 `accessibility=false`，不宣称第三方实际隐藏已验证。600×430 设置页样本预览中的即时生效提示无裁切。日志和截图保存于 `output/auto-collapse/`，已安装 App 未替换。

## 复现验证

### 2026-10-21：OpenVPN 多入口独立改组需求澄清（未实现）

用户确认问题发生在设置页跨组拖动，并选择“只移动拖动的那个，另一个留在原组”。验收例：OpenVPN 有两个入口，将其中一个从保留拖到收起后，仅该入口离开顶部并出现在展开栏，另一个保留；拖到隐藏时仅目标入口不在顶部或展开栏显示。不能用两项一起移动或只改变设置页卡片归属代替此结果。

当前 `moveEntry` 对多入口跨组返回失败，原因是实际隐藏桥接 `initWithAllowedSystemItems:allowedBundleIdentifiers:` 按 App 白名单生效；当前逐入口 AX 身份已可用于排序和点击，但尚未用于独立系统可见性。此处记录的是现有实现边界，并不证明所有系统接口都不支持逐入口隐藏。

独立改组的底层方案尚未确定，未修改分组执行代码。用户随后要求先调查为何只有一个 OpenVPN 安装却显示两个图标；在确认入口含义前，不将两个列表项直接视为两个正常图标，也不决定代理状态项方案。

### 2026-10-21：OpenVPN 两个列表项的只读实测

- 安装：仅找到一个 OpenVPN Connect 主应用，版本 3.8.2（6009），bundleID 为 `org.openvpn.client.app`；运行时只有一个主进程 PID 872，另外的 GPU、Renderer 与后台 helper 均属于同一安装。
- 使用新增 `--menu-entry-report <bundleID> <output.json>` 诊断入口，通过 LaunchServices 启动本项目签名构建，实际 GUI 进程 `authorized=true`。该分支在采样、风扇与收纳启动前退出，不请求权限、不执行 AXPress、不改变 VPN 连接或分组。直接从终端运行的临时探针 `authorized=false`，不能据此推断实际 Ermi 没有权限。
- OpenVPN 的 `AXExtrasMenuBar` 确实返回两个不同 AX 元素，均为 `AXMenuBarItem / AXMenuExtra`，均提供 `AXPress`，同属显示器 1。入口 0 坐标为 `(997, 4.5, 19, 24)`，入口 1 为 `(973.5, 4.5, 2, 24)`。本机有两个显示器，但本轮两个入口不是分属两屏的副本。
- Ermi 扫描保留两个 AX 入口，设置页又用同一 bundle 的应用图标绘制每一项，因此一个正常宽度入口和一个仅 2pt 宽的窄入口被呈现成两个完整 OpenVPN 图标。这是已确认的展示来源；窄入口的实际用途是否为占位尚未确认，不能仅按一次宽度观测删除所有窄图标。
- 本机安装包 `app.asar/app.js` 中只找到一处 `new Tray`，会复用已有 `this.tray`，另有单实例锁；这是辅助证据，不能单靠源码匹配数断言运行时只可能有一个 AX 入口。

证据：`output/openvpn-diagnosis/gui-report.json`、`probe.log`；诊断构建与签名通过。本轮仅调查并补充只读诊断，未更改 OpenVPN、真实菜单栏布局或入口过滤规则。


### 2026-10-21：修复 OpenVPN 主题观察状态项被当作图标

进一步检查本机 OpenVPN Connect 3.8.2（6009）的 `app.asar.unpacked/napi.node`，确认 `-[SettingsManager initPrivate]` 创建 NSStatusItem 后调用 `setVisible:YES` 和 `setLength:0`；`getTheme` 读取该 item.button 的 `effectiveAppearance`，`listenTrayTheme:` 为其注册观察。它是用于主题检测的空状态项；此前“窄入口用途未知”的结论已由该二进制证据补全。反汇编片段保存在 `output/openvpn-diagnosis/theme-observer-disassembly.txt`，未修改 OpenVPN 安装或连接。

Ermi 此前无差别统计 AXChildren，并给每项绘制完整 App 图标，导致这个 AX 实测宽 2pt 的空项也占据一张卡片，继而触发多入口跨组保护。新增共用 `MenuBarEntryFilter`，设置页清单、展开栏扫描及原生排序扫描都过滤 `org.openvpn.client.app` 中宽 0–2pt、尺寸有限且高度大于 0 的入口。该范围对应已核实的 length=0 空项及系统返回值，不作为其他 App 的通用最小宽度。尺寸不可读或异常时保留入口；正常的多个 OpenVPN 图标也全部保留，不按 App 名称、扫描序号或“只留最大项”去重。

该修复使当前 OpenVPN 只剩一个可操作入口，沿用现有单入口分组流程，支持拖入收起、隐藏及移回保留。真实多入口的独立跨组仍未实现，仍由原保护分支明确拒绝，不能把本修复描述为已支持所有 App 的逐入口隐藏。

回归：`swift test --filter 'openVPNThemeObserverDoesNotDuplicateIconOrBlockGroupDrag|entryFilterPreservesRealMultipleIconsAndUnknownSizes'`。修复前精确复现两个卡片及跨组拒绝（`red.log`），修复后验证卡片数、真实入口 AX 身份、三组迁移及可见性白名单（`green.log`）。完整回归 257 项 Swift Testing 与 1 项 XCTest 通过（`tests.log`）。系统隐藏使用替身，不把自动化结果表述为已执行真实 VPN 图标隐藏。

签名通用构建位于 `output/native/Ermi.app`（`build-fix.log`）。通过 LaunchServices 启动该构建的只读诊断，`authorized=true`；同一个 OpenVPN 进程仍返回 19×24 与 2×24 两项，前者 `includedInOrganizer=true`，后者为 false，`managedEntryCount=1`（`gui-report-fixed.json`）。真实过滤已验证，未执行真实 VPN 图标拖动、点击或连接操作；已安装的 `/Applications/Ermi.app` 未替换。

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
