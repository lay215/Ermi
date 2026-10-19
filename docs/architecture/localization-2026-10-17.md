# 多语言

用户确认支持简体中文、繁体中文、English 与跟随系统。系统设置首个分组为语言，选择立即更新并保存；未知或不支持的系统语言回退 English，zh-Hant/TW/HK/MO 使用繁体。

Translations.json 为统一词条表，478 项。UI 展示边界调用 L，模型判断值、Picker tag、用户自定义方案名和第三方 App 名称保持原值。动态历史消息使用全串模板匹配，替换参数不会二次处理其中的占位符字符；只对明确的错误包装翻译内层原因，未知系统错误保留原文。不对任意用户字符串做简繁自动转换。

AppLocalization 使用 Observation 驱动页面刷新，不通过重建页面重置筛选、编辑状态或硬件连接。用户语言保存到 ermi.language。诊断 --preview-language 仅影响诊断进程，不修改用户配置。SwiftUI locale 随所选语言变化；macOS 管理员验证、系统设置等系统界面仍由系统语言决定。

验证：104 项 Swift Testing + 1 项 XCTest 通过，新增系统语言及持久化、动态参数与用户名称保留、全目录唯一词条和占位符校验。Release 构建及签名通过。已渲染检查英文紧凑面板、英文设置页及繁体风扇页；四个 Tab 和主控件完整可见，设置内容沿用滚动容器。

交付：output/native/Ermi-0.1.0-arm64-local-multilingual.dmg。未替换当前运行版本，未重新安装 Helper 或改变温控设置。
