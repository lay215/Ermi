<h1 align="center">Ermi</h1>
<p align="center">Your Mac’s vitals, cooling, and menu bar — in one native app.</p>
<p align="center">
  <a href="https://github.com/lay215/Ermi/releases"><img src="https://img.shields.io/badge/download-Releases-blue" alt="Download releases"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/architecture-Apple%20Silicon-orange" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"></a>
</p>
<p align="center">English · <a href="README.zh-CN.md">简体中文</a></p>

Ermi is an open-source macOS menu bar app for system monitoring, fan control, and menu bar organization. Built with SwiftUI and AppKit, it keeps useful controls close without taking over your desktop.

## Preview

<p align="center"><img src="docs/images/popover.png" width="340" alt="Menu bar popover"></p>
<p align="center">Menu bar popover</p>

| System overview | Fan control | Menu bar organization |
| --- | --- | --- |
| ![System overview](docs/images/monitor.png) | ![Fan control](docs/images/fan.png) | ![Menu bar organization](docs/images/icons.png) |

Screenshots show the running app; displayed readings are illustrative snapshots, not live data.

## Features

- **System monitoring** — CPU and memory usage, recent trends, memory pressure, disk space, battery, network traffic, uptime, and processes.
- **Temperature and fans** — CPU/GPU temperatures and fan RPM on supported hardware; unavailable readings are shown explicitly.
- **Cooling controls** — system-managed cooling, fixed RPM, two-point temperature control, and built-in or custom presets. Restore the last successfully applied configuration on launch or wake.
- **A tidier menu bar** — keep or collapse icons, expand them temporarily, and access supported entries through a separate tray.
- **Make it yours** — six built-in color themes, custom colors, English, Simplified Chinese, and Traditional Chinese.
- **Native conveniences** — optional launch at login, reduced motion, and keyboard shortcuts for the four detail pages.

## Download & install

**[Get Ermi from GitHub Releases →](https://github.com/lay215/Ermi/releases)**

| Platform | Package | Status |
| --- | --- | --- |
| macOS 14+, Intel & Apple Silicon | [Ermi-0.1.2-universal-preview.dmg](https://github.com/lay215/Ermi/releases/download/v0.1.2/Ermi-0.1.2-universal-preview.dmg) | Preview; primarily validated on M1 Max |

1. Open the release page and read its compatibility notes.
2. Download the `.dmg`, open it, and drag **Ermi.app** into **Applications**.
3. Launch Ermi and click the ermine icon in the menu bar.

This preview uses a local signing identity and is **not notarized by Apple**. macOS may block the first launch. If you trust the download, use the system’s **Privacy & Security → Open Anyway** option when available. Do not disable Gatekeeper globally.

For fan control, choose **Install / Update Authorization** on the fan page and complete the macOS administrator prompt. Installation establishes authorization; it does not apply a fan preset. Menu bar organization requires separate system permissions, as prompted by macOS.

Known issue: M4 Pro CPU temperature can be underreported and affect automatic fan control. This release fixes helper installation, not temperature sampling; use system fan control until the temperature issue is resolved.

Each DMG includes a `.sha256` companion file. In the download directory, verify it with:

```sh
shasum -a 256 -c Ermi-0.1.2-universal-preview.dmg.sha256
```

## Build from source

Requires an Intel or Apple Silicon Mac, macOS 14+, Xcode with Swift 6, Python 3, and OpenSSL for local signing setup. The build script produces a Universal app and helper (arm64 + x86_64).

```sh
git clone https://github.com/lay215/Ermi.git
cd Ermi
python3 scripts/setup-local-signing.py
scripts/build-app.sh
open output/native/Ermi.app
```

The setup script creates or reuses a stable local signing identity in your Keychain. Private keys are not included in the repository or app. To use another signing identity, set `ERMI_SIGNING_IDENTITY` when building.

```sh
swift test
output/native/Ermi.app/Contents/MacOS/Ermi --smoke-test
scripts/package-dmg.sh
```

Build products and local debug captures are ignored by Git. DMGs belong in Releases, not source commits.

## Compatibility & current limits

- Current source supports chip-family temperature mappings and capability-based fan protocols for Intel and Apple Silicon, including single-fan and multi-fan Macs. Fanless devices retain monitoring; unknown protocols remain read-only. See [hardware compatibility](docs/architecture/hardware-compatibility.md) for sources, scope, and validation limits. Hardware validation remains primarily on **M1 Max**; code coverage does not mean every model has been tested.
- Menu bar organization depends on macOS behavior and permissions. The macOS 27 path uses experimental private APIs; the macOS 14–26 separator-based path still needs hardware validation.
- Full third-party menu interaction and real sleep/wake fan recovery still need broader acceptance testing. Passing automated tests does not establish hardware compatibility.
- No automatic updater or Apple-notarized distribution is currently provided.

## Documentation & feedback

- [Release notes](docs/releases/v0.1.2.md)
- [Local signing and fan service authorization](docs/architecture/local-signing-and-gui-install-2026-10-17.md)
- [Fan control validation](docs/architecture/fan-control-validation-2026-10-16.md)
- [Report a bug or request a feature](https://github.com/lay215/Ermi/issues)

When reporting an issue, include your Mac model, macOS version, Ermi version, and steps to reproduce. Contributions are welcome; run the relevant tests and describe any hardware validation performed.

## License

[MIT](LICENSE). Third-party references retain their original notices, including [Hidden Bar’s MIT license](docs/research/hidden-bar-LICENSE).
