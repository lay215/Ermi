# 主题与系统设置

默认冰川银，新增石墨灰、午夜蓝、雾松绿、暖岩灰、薰衣草灰及自定义背景/强调色。ErmiAppearance 使用 Observation 驱动 SwiftUI 更新，UserDefaults 持久化；无值或未知主题回退冰川银。强调色自动加深保证白字对比，背景字色按相对亮度选择。现有 ErmiTheme 的动态属性供按钮和图表共用，布局与风扇逻辑不变。

图标整理右侧新增系统设置 Tab，集中主题、通用、权限、风扇服务、关于；隐藏页停止设置轮询。面板齿轮、右键菜单和 Cmd+, 均导航到该页，避免重复设置窗口。

验证：101 项 Swift Testing + 1 项 XCTest 通过，含持久化和灰阶/预设对比度测试；release 构建和签名通过。诊断渲染检查默认面板及设置 Tab。未替换用户正在运行的 App，更新包为 output/native/Ermi-0.1.0-arm64-local-themes.dmg。

## 详情页主题同步与设置布局修正

系统设置采用 ScrollView + SettingsSection 卡片，移除原生 grouped Form 的逐行分隔线，保留全部设置绑定及授权操作。导航使用原始主题背景与对比字色；正文、卡片和控件由主题背景分别混合 92%、98%、86% 白色，保持深色/自定义主题下深色正文可读。页面共享 Observation 主题来源，不重建页面，因此切换主题保留滚动位置及编辑状态。主题说明同步更新简中、繁中、英文。

验证：104 项 Swift Testing 和 1 项 XCTest 通过；release 构建与签名通过；诊断渲染检查薰衣草灰设置和午夜蓝英文风扇页。诊断参数 --preview-theme 仅覆盖进程内主题，不保存用户偏好。新版包：output/native/Ermi-0.1.0-arm64-local-theme-sync.dmg，未替换正在运行的 App。

## 标题栏按钮对齐修正

窗口显示后 AppKit 会重排原 standardWindowButton，即使换父视图并监听 frame 仍无法稳定定位（600→720 宽度诊断失败）。现隐藏窗口原按钮，使用 NSWindow.standardWindowButton(_:for:) 创建独立原生按钮，target/action 分别指向窗口 performClose、performMiniaturize、performZoom，由自定义导航栏 layout 居中排列；保留左边距 18pt 和按钮中心间隔 20pt，与 Logo 共用 52pt 导航高度。

新增诊断 --check-window-chrome（需与 --capture-preview、--include-chrome 一起使用）：实际显示窗口后按 720、600 宽度缩放并断言按钮坐标。两次均 aligned=true，截图确认按钮与 Logo 居中。release 构建及签名通过，交付包为 Ermi-0.1.0-arm64-local-titlebar-fix.dmg。

## 全界面主题补齐与弹窗压缩

将 compact 分段底色、滑条轨道/边框、进程退出按钮、图表网格与副线、方案菜单和退出确认弹层的固定蓝灰色改为共享主题 token；详情页与图标托盘统一原生控件 tint。危险操作及温度状态继续保留语义颜色，系统管理的菜单和授权窗口遵循 macOS 外观。

弹窗高度从 461pt 改为 437pt；风扇操作行从 38pt 改为 26pt，内部间距从 8pt 改为 6pt，各模式共用高度以避免切换时跳动。诊断渲染验证雾松绿英文固定转速和薰衣草灰繁中确认弹层；104 Swift Testing + 1 XCTest 通过，release 构建及签名通过。安装包：Ermi-0.1.0-arm64-local-unified-theme.dmg，未替换运行中的 App。
