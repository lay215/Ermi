#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# 默认复用本机固定身份，缺失时明确失败，不能静默退回临时签名使已有授权失效。
# 显式 ERMI_SIGNING_IDENTITY 仍支持正式证书或测试用的临时签名。
if [[ -n "${ERMI_SIGNING_IDENTITY:-}" ]]; then
    SIGNING_IDENTITY="$ERMI_SIGNING_IDENTITY"
else
    identity_file="$HOME/Library/Application Support/Ermi/signing/identity.sha1"
    if [[ ! -f "$identity_file" ]]; then
        print -u2 '请先运行 python3 scripts/setup-local-signing.py 创建本机签名身份。'
        exit 1
    fi
    SIGNING_IDENTITY="$(<"$identity_file")"
    if [[ ! "$SIGNING_IDENTITY" =~ '^[0-9A-F]{40}$' ]]; then
        print -u2 '本机签名指纹配置无效，已停止构建。'
        exit 1
    fi
fi
# 同一安装包包含 Intel 与 Apple Silicon；helper 必须和 App 一起提供两种架构。
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP="${PWD}/output/native/Ermi.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
# 系统应用图标与菜单栏共用白鼬概念稿；生成完整尺寸，供 Finder 等系统入口使用。
ICONSET="${PWD}/.build/Ermi.iconset"
swift scripts/build-app-icon.swift Sources/Ermi/Resources/LogoStudy.png "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Ermi.icns"
cp "$BIN_PATH/ErmiFanHelper" "$APP/Contents/MacOS/ErmiFanHelper"
cp "$BIN_PATH/Ermi" "$APP/Contents/MacOS/Ermi"
cp -R "$BIN_PATH/Ermi_Ermi.bundle" "$APP/Contents/Resources/"
/usr/bin/lipo "$APP/Contents/MacOS/Ermi" -verify_arch arm64 x86_64
/usr/bin/lipo "$APP/Contents/MacOS/ErmiFanHelper" -verify_arch arm64 x86_64
cp scripts/local-fan-control.command "$APP/Contents/Resources/InstallLocalFanControl.command"
cp scripts/local-fan-control.command "$APP/Contents/Resources/UninstallLocalFanControl.command"
chmod 755 "$APP/Contents/Resources/InstallLocalFanControl.command" "$APP/Contents/Resources/UninstallLocalFanControl.command"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Ermi</string>
<key>CFBundleIdentifier</key><string>app.ermi.local</string>
<key>CFBundleName</key><string>Ermi</string>
<key>CFBundleIconFile</key><string>Ermi.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
cat > "$APP/Contents/Library/LaunchDaemons/app.ermi.fan-helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.ermi.fan-helper</string>
<key>BundleProgram</key><string>Contents/MacOS/ErmiFanHelper</string>
<key>MachServices</key><dict><key>app.ermi.fan-helper</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
codesign --force --options runtime --identifier app.ermi.fan-helper --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/ErmiFanHelper"
codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
print "$APP"
