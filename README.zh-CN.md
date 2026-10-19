<h1 align="center">Ermi</h1>
<p align="center">随时了解 Mac 状态，调节散热，整理菜单栏。</p>
<p align="center"><a href="https://github.com/lay215/Ermi/releases">下载 / Releases</a> · macOS 14+ · Apple Silicon · <a href="LICENSE">MIT</a></p>
<p align="center"><a href="README.md">English</a> · 简体中文</p>

Ermi 是一款开源的原生 macOS 菜单栏工具，集系统监控、风扇调节与图标整理于一体，使用 SwiftUI + AppKit 构建。

## 界面预览

<p align="center"><img src="docs/images/monitor.png" width="640" alt="Ermi 系统概览"></p>

| 风扇调节 | 图标整理 |
| --- | --- |
| ![风扇调节](docs/images/fan.png) | ![图标整理](docs/images/icons.png) |

截图来自运行中的应用，画面数值为截图时状态。

## 功能

- **系统监控**：查看 CPU、内存、近期趋势、内存压力、磁盘空间、电池、网络流量、运行时间和进程。
- **温度与转速**：在支持的硬件上读取 CPU/GPU 温度和风扇 RPM；无法读取时明确显示未知。
- **风扇调节**：支持系统管理、固定转速、两点自动温控及内置和自定义方案；启动或唤醒后尝试恢复上次成功应用的配置。
- **图标整理**：支持常驻、收起、临时展开，以及通过独立展开栏访问受支持的菜单栏入口。
- **个性化**：六种内置配色、自定义颜色，支持简体中文、繁体中文和英文。
- **原生体验**：可选登录启动、减少动态效果，以及四页详情快捷键。

## 下载与安装

**[前往 GitHub Releases 下载 →](https://github.com/lay215/Ermi/releases)**

| 平台 | 安装包 | 状态 |
| --- | --- | --- |
| macOS 14+，Apple Silicon | `Ermi-0.1.0-arm64-preview.dmg` | 预览版，主要在 M1 Max 上验证 |
| Intel Mac | — | 暂不提供安装包 |

1. 打开 Releases，阅读该版本的兼容性说明。
2. 下载并打开 `.dmg`，将 **Ermi.app** 拖入 **Applications（应用程序）**。
3. 启动 Ermi，点击菜单栏中的白鼬图标。

预览版采用本机签名，**尚未经过 Apple 公证**。首次打开可能被 macOS 拦截；确认下载来源可信后，可在系统提供该选项时通过“隐私与安全性 → 仍要打开”放行，无需全局关闭 Gatekeeper。

首次使用风扇调节时，选择“安装 / 更新授权”，完成 macOS 管理员验证。安装只建立授权，不会应用风扇方案。图标整理所需权限独立于风扇授权，按系统提示开启。

安装包附带 `.sha256` 校验文件，在下载目录执行：

```sh
shasum -a 256 -c Ermi-0.1.0-arm64-preview.dmg.sha256
```

## 从源码运行

需要 Apple Silicon Mac、macOS 14+、带 Swift 6 的 Xcode，以及用于本机签名配置的 Python 3 和 OpenSSL。

```sh
git clone https://github.com/lay215/Ermi.git
cd Ermi
python3 scripts/setup-local-signing.py
scripts/build-app.sh
open output/native/Ermi.app
```

签名脚本会在钥匙串中创建或复用固定本机身份，私钥不会进入仓库或安装包。需要使用其他签名身份时，可在构建时指定 `ERMI_SIGNING_IDENTITY`。

```sh
swift test
output/native/Ermi.app/Contents/MacOS/Ermi --smoke-test
scripts/package-dmg.sh
```

构建产物、调试截图与录屏由 Git 忽略；安装包通过 Releases 分发。

## 兼容性与当前限制

- 温度读取和风扇控制主要在 **M1 Max** 验证，其他机型仍需验证；无风扇机型无法提供风扇调节。
- 图标整理依赖系统版本及权限。macOS 27 路径使用实验性私有接口，macOS 14–26 的分隔线方案仍需实机验收。
- 第三方菜单完整交互、真实睡眠唤醒后的风扇恢复仍需更广泛验收；自动化测试通过不代表所有硬件兼容。
- 暂无自动更新、Intel 安装包或 Apple 公证发行包。

## 文档与反馈

- [版本说明](docs/releases/v0.1.0.md)
- [本机签名与风扇授权](docs/architecture/local-signing-and-gui-install-2026-10-17.md)
- [风扇控制验证记录](docs/architecture/fan-control-validation-2026-10-16.md)
- [反馈问题或建议](https://github.com/lay215/Ermi/issues)

反馈时请附上 Mac 型号、macOS 版本、Ermi 版本和复现步骤。欢迎贡献代码；提交时请运行相关测试，并说明实际做过的硬件验证。

## 开源许可

采用 [MIT License](LICENSE)。第三方参考内容保留原有声明，包括 [Hidden Bar 的 MIT 许可](docs/research/hidden-bar-LICENSE)。
