# 菜单栏图标间距控制

在图标整理页添加间距 0–30、点击区域内边距 0–20、近似预览、显式保存和恢复默认。拖动不写入系统偏好；没有覆盖值时滑块起始建议为 6，不将建议值称为系统默认。显示已保存值以区分草稿和持久化状态。

参考 https://github.com/beyondthecode-bc/MenuBarSpacing 的公开说明；该仓库不是应用源码。其说明使用 CFPreferences 的 NSStatusItemSpacing 和 NSStatusItemSelectionPadding，并要求注销重新登录或重启。
currentHost 写入依据：https://gist.github.com/brunojppb/b9c2c9a53801f16c7e5010544a850fc4 。使用当前用户、全局域、本机 host；读取优先本机再 anyHost。恢复默认仅删除这两个键的本机和 anyHost 覆盖，保留其他偏好。没有调用管理员工具或自动注销/重启。

验证：96 项 Swift Testing + 1 项 XCTest 通过。新增 3 项在独立 CFPreferences 测试域验证草稿不写入、保存后重新读取、host 优先级、恢复两个域、无关键保留、越界拒绝。测试不修改真实菜单栏偏好。
Release 构建与签名验证通过。现有诊断导出的图标页确认新控件渲染，内容可通过原页面 ScrollView 浏览。命令行诊断的图标权限状态不代表桌面 App 权限。
产物：output/native/Ermi-0.1.0-arm64-local-spacing.dmg，hdiutil 校验通过。未注销当前会话，系统菜单栏实际间距变化仍待重新登录后验收。

## 保存并应用

追加保存后自动刷新：点击“保存并应用”重新扫描现有图标，固定确认清单，确认后写入偏好并串行刷新。仅保存仍可使用。正常退出第三方 App，最多等待 5 秒，不强制结束；按扫描时的 bundleURL 重开，拒绝退出与启动失败分别报告。排除 Apple App、内嵌 Helper、Ermi 自身和扫描未识别到的 App。
系统组件仅重载 ControlCenter 与 SystemUIServer，从本机固定路径的 LaunchAgent plist 读取 Label，再在当前用户 GUI 域执行 launchctl kickstart -k，后台执行且有超时。不自动注销或重启电脑。未获得图标权限时确认页明确说明只能刷新系统组件。
依据 Thaw 的 MenuBarItemSpacingManager：设置持久化不等于进程重新读取，重启宿主可使其重新加载；不再将“注销/重启”描述为唯一方法。实现未复制该项目代码。

验证：99 项 Swift Testing + 1 项 XCTest 通过，新增保存失败不重启、部分失败继续执行、重复提交去重测试。Release 构建与签名通过。未在开发过程中批量退出用户的实际 App；macOS 27 上的具体图标间距效果尚待通过确认入口执行后验证。系统命令成功仅报告刷新，不宣称所有图标已采用新间距。
更新安装包：Ermi-0.1.0-arm64-local-spacing-refresh.dmg。
