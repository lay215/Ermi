# 固定本机签名与图形化安装

用户目标：不在终端输入命令、INSTALL 或密码；普通界面构建不再使风扇授权失效。使用本机专用自签名身份，不使用公开测试私钥，不涉及正式发行或自动更新。

## 实现

- `scripts/setup-local-signing.py` 一次性生成 RSA 3072、codeSigning 用途、十年有效期的本机证书，导入默认用户钥匙串。私钥导入为不可导出，仅允许 `/usr/bin/codesign`；临时 PEM/PKCS12 在结束时清理。证书及公开指纹位于 `~/Library/Application Support/Ermi/signing/`，不进入项目。
- `scripts/build-app.sh` 默认使用该固定指纹；缺失时失败，不偷偷回退到 ad-hoc。显式 `ERMI_SIGNING_IDENTITY` 保留原覆盖入口。
- v2 本机授权绑定 `identifier app.ermi.local + certificate leaf SHA1`；客户端原 cdhash 仅作安装审计。Helper 仍固定 cdhash，更新 Helper 需要安装。v1 可读，迁移必须经管理员安装。
- 安装计划要求 App/Helper 同一证书；管理员验证前固定的双 cdhash 与 root 独占暂存副本再次比对，随后生成 v2。保留用户ID、目录所有权、链接拒绝、恢复检查和失败回滚。
- App 入口后台调用安装脚本 `--gui`，固定 AppleScript 通过 argv/quoted form 构造参数，由 `with administrator privileges` 显示系统验证。密码只交给系统，不读取或保存；不打开 Terminal。
- 安装成功自动连接并 inspect，不自动应用旧预设；取消、卸载、睡眠均单独处理。安装期间暂停轮询、防重入，不让旧回包覆盖安装结果。

## 当前验证

- 全量 93 项 Swift Testing + 1 项 XCTest 通过：`/tmp/ermi-gui-stable-tests.log`。
- 定向授权测试、固定证书/v1兼容/错证书拒绝测试通过。
- shell 语法、AppleScript 仅编译、含空格及单双引号 argv 转义检查通过，未通过测试触发系统提权。
- 已创建钥匙串身份 `Ermi Local Development`；没有导入任何网上公开私钥。
- 首次 codesign 探针正在等待用户完成钥匙串验证；CUA 明确禁止操作 SecurityAgent。最终证书签名打包、两次不同构建沿用同一身份验证、GUI管理员安装及真机连接仍待完成，不能把源码测试等同于系统验收。

## 使用边界

首次迁移需系统管理员验证；普通 App 构建可沿用身份，Helper 变更仍走 App 内图形化更新。自签名身份用于本机，不等同 Apple Developer ID、Gatekeeper 公证或其他机器的信任；图标读取隐私权限由系统独立管理，需实测迁移后保留情况。


## 钥匙串验证后的进展

用户已完成 codesign 首次钥匙串允许。签名探针及最终 App 均通过 strict 签名验证，默认 designated requirement 为 identifier + 固定 certificate leaf 指纹。两个不同内容探针的 cdhash 分别为 `38e7a3c51da735e3c8189d055a9449145ed1f8f2`、`c0e89c5967d4e49dd8372bd25f642c8152d07442`，均满足同一客户端证书规则；签名过程中未再次阻塞。最终打包成功：`/tmp/ermi-stable-final-build.log`。仅用于对比的二进制不进入交付物。

`--local-plan` 已验证最终 App/Helper 同证书且返回精确安装哈希。CUA 读取 Ermi 仍超时，已直接调用同一打包安装脚本 `--gui` 发起原生管理员验证；结果在 `/tmp/ermi-gui-install-result.log`，仍待用户完成管理员验证和已安装服务复查。没有修改系统证书信任设置，签名规则直接固定本机叶证书。


## 最终迁移验证

用户完成原生管理员验证后，GUI安装脚本退出0，服务安装成功。已安装 authorization.json 为 version=2、userID=501、固定本机证书指纹；最终App只读探针返回 `authorized-build=true connected=true phase=system capabilities=2 error=none`。

进一步在隔离临时App副本中改变Info.plist并使用同一身份重新签名，cdhash由 `ba094334bfe5d6c7b9c16f5ea8e99d8358057c30` 变为 `eba685c20ed650bba4a4b529fceda92b87ad916e`。未修改已安装授权或重装Helper，副本仍返回授权有效且XPC连接成功，证实跨构建身份授权实际生效。临时副本已清理，正式App未改变，风扇保持系统模式。

图形化提权已通过同一打包脚本真实安装验证；App按钮到自动重连路径由注入测试验证，CUA窗口读取仍不可用，因此不声称完成该按钮的真机点击验收。图标整理TCC权限属于独立系统权限，本轮未修改或重置。
