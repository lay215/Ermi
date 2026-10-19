#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app="$PWD/output/native/Ermi.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
destination="${1:-$PWD/output/native/Ermi-${version}-universal-local.dmg}"
[[ ! -e "$destination" ]] || { print -u2 "安装包已存在：$destination"; exit 1; }
# 使用已验收的 App，不在打包过程中重编译或改变风扇授权身份。
/usr/bin/codesign --verify --deep --strict "$app"
# 不能把遗留的 arm64 单架构构建包装成全架构安装包。
/usr/bin/lipo "$app/Contents/MacOS/Ermi" -verify_arch arm64 x86_64
/usr/bin/lipo "$app/Contents/MacOS/ErmiFanHelper" -verify_arch arm64 x86_64
stage=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ermi-dmg.XXXXXX")
trap '/bin/rm -r "$stage"' EXIT
/usr/bin/ditto "$app" "$stage/Ermi.app"
/bin/ln -s /Applications "$stage/Applications"
cat > "$stage/安装说明.txt" <<'TXT'
Ermi 本机版

适用：Intel 与 Apple Silicon Mac，macOS 14 或更新版本。
温度和调速依设备实际提供的传感器与控制协议；无风扇机型仅监测，未知协议不执行写入。

安装：退出正在运行的 Ermi，将 Ermi.app 拖入 Applications，然后从“应用程序”打开。
风扇：首次使用时，在“风扇调节”点击“安装 / 更新授权”，在 macOS 弹窗中验证，无需终端输入。
同一签名的普通界面更新可沿用风扇授权；更新 Helper 时仍需在 App 中安装。
图标整理：首次使用需在系统设置允许对应权限，该权限独立于风扇授权。

此包使用本机专用签名，未经过 Apple 公证，不作为已公证的公开发行版。
包内不包含签名私钥。
TXT
/usr/bin/hdiutil create -volname "Ermi" -srcfolder "$stage" -format UDZO -fs HFS+ "$destination"
/usr/bin/hdiutil verify "$destination"
# 校验清单仅记录文件名，下载到其他机器后可直接校验，也不泄露构建机绝对路径。
(cd "${destination:A:h}" && /usr/bin/shasum -a 256 "${destination:t}") > "$destination.sha256"
print "$destination"
