import AppKit
@preconcurrency import ApplicationServices

// 设置清单、展开栏和原生排序共用入口筛选，避免空状态项在另一条扫描路径重新出现。
enum MenuBarEntryFilter {
    static func managedItems(
        _ items: [AXUIElement], bundleID: String,
        size: (AXUIElement) -> CGSize? = readSize
    ) -> [AXUIElement] {
        // OpenVPN Connect 的 SettingsManager 创建 length=0 的 NSStatusItem，专门读取并观察
        // button.effectiveAppearance；3.8.2 的本机二进制已核实，AX 实测仍报告 2pt 宽。
        // 仅排除这个 App 的零内容宽度入口，不将窄尺寸规则推广到其他 App 的真实状态图标。
        guard bundleID == "org.openvpn.client.app" else { return items }
        return items.filter { item in
            // 不可读、无效或布局尚未确定的尺寸不能证明是辅助项，保留入口以免误丢用户图标。
            guard let size = size(item), size.width.isFinite, size.height.isFinite,
                  size.width >= 0, size.height > 0 else { return true }
            return size.width > 2
        }
    }

    private static func readSize(_ item: AXUIElement) -> CGSize? {
        AXUIElementSetMessagingTimeout(item, 0.15)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(raw, to: AXValue.self), .cgSize, &size) else { return nil }
        return size
    }
}
