import AppKit

// 打包复用菜单栏 statusLogo 与面板 ErmiLogo 的概念稿取景，避免 App 图标出现整张展示板。
// 这里仅导出现有图形；若调整品牌取景，需同步两处运行时绘制参数。
let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let size = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // 使用与菜单栏相同的左上角坐标系和圆角，保持肖像方向及边界一致。
        let transform = AffineTransform(translationByX: 0, byY: size)
        (transform as NSAffineTransform).concat()
        let flip = NSAffineTransform()
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                     xRadius: size * 0.26, yRadius: size * 0.26).addClip()
        source.draw(in: NSRect(x: -size * 0.3868, y: -size * 0.1393,
                               width: size * 2.9966, height: size * 1.584),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: destination.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
