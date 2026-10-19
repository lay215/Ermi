# 本机风扇开发模式

2026-10-16。用户授权实现无需 Developer ID 证书的本机模式，保留管理员授权。

## 使用

构建 `scripts/build-app.sh` 后打开 `output/native/Ermi.app`，在「风扇预设」点击「安装 / 更新本机授权」，终端输入 `INSTALL` 与管理员密码。完成后返回 App 点击「连接本机服务」。安装不应用预设；连接成功后才使用已有预设入口。若 App 是旧进程，先退出并打开新构建。

每次重新构建会改变代码指纹，必须重新安装授权并重启 App。卸载入口需要输入 `UNINSTALL`，保留用户预设。原服务如有未恢复的接管记录，更新和卸载拒绝移除恢复程序，应先恢复系统自动。

## 信任与文件

- 普通 App 与 root helper 通过 XPC 双向限制 identifier 和精确 cdhash，helper 额外检查安装用户 UID。
- 启用本机模式必须显式安装；没有开发证书不会自动变为无身份校验的连接。
- 用户确认前读取当前构建指纹。sudo 执行系统 shell，复制 helper 到 root 私有暂存区、清除 ACL，由系统 codesign 校验记录的指纹后才执行。安装器再复制完整 App 到 root 暂存区复核，拒绝授权过程中变化的构建。
- 服务目录：`/Library/PrivilegedHelperTools/app.ermi.fan-helper.local`，包含 `ErmiFanHelper` 与 `authorization.json`。
- 服务配置：`/Library/LaunchDaemons/app.ermi.fan-helper.local.plist`。本机服务 label 为 `app.ermi.fan-helper.local`。
- 安装锁位于 PrivilegedHelperTools 的 `.app.ermi.fan-helper.local.lock`。授权文件与目录检查 root 归属、权限、符号链接；文件读取还检查大小和链接数。
- 服务更新前停止旧服务，检查恢复日志，安装失败尝试恢复原版本。残缺授权 JSON 或孤立 plist 可通过卸载入口清理；异常归属和未恢复日志仍拒绝删除。
- 正式服务与本机服务互斥，保留 TeamID + SMAppService 正式路径。设备白名单、租约、看门狗、恢复日志及拒绝抢占其他控制程序的规则共用原实现。

## 验证

`swift test`：49 项测试通过，包含 4 项本机授权测试：规则与注入拒绝、真实代码签名及篡改拒绝、文件权限/符号链接/大小检查、其他构建拒绝授权。正式 release 构建及安装脚本语法检查通过。

只读探针：`output/native/Ermi.app/Contents/MacOS/Ermi --fan-service-status`。未安装时正确报告 local-mode=true、installed=false、authorized-build=false。`ErmiFanHelper --local-plan <App路径>` 成功读取当前 App/helper 指纹。

尚未执行管理员安装、XPC 真机握手及实际风扇写入；这些需要用户在终端完成管理员授权后验证。自动测试不能证明硬件调速已经成功。
