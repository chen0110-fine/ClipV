import Cocoa

func renderIcon(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    // Standard macOS app icon proportions (~82% canvas squircle with soft drop shadow)
    let inset = s * 0.095
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = cardRect.width * 0.225
    let roundedPath = NSBezierPath(roundedRect: cardRect, xRadius: corner, yRadius: corner)

    // Soft outer drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.045, color: NSColor(white: 0, alpha: 0.28).cgColor)
    NSColor(srgbRed: 0.25, green: 0.34, blue: 0.92, alpha: 1.0).setFill()
    roundedPath.fill()
    cg.restoreGState()

    // Gradient background clipped to squircle
    cg.saveGState()
    roundedPath.addClip()

    let colors = [
        NSColor(srgbRed: 0.36, green: 0.44, blue: 0.98, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.22, green: 0.30, blue: 0.85, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.14, green: 0.19, blue: 0.62, alpha: 1.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.55, 1.0]) {
        cg.drawLinearGradient(
            grad,
            start: CGPoint(x: cardRect.midX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.midX, y: cardRect.minY),
            options: []
        )
    }

    // Subtle top ambient radial highlight
    let glowColors = [
        NSColor(white: 1.0, alpha: 0.28).cgColor,
        NSColor(white: 1.0, alpha: 0.0).cgColor
    ] as CFArray
    if let radial = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 1.0]) {
        cg.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: cardRect.midX, y: cardRect.maxY * 0.92),
            startRadius: 0,
            endCenter: CGPoint(x: cardRect.midX, y: cardRect.maxY * 0.92),
            endRadius: cardRect.width * 0.72,
            options: []
        )
    }

    // Back stacked glass card
    let backCard = CGRect(
        x: cardRect.minX + cardRect.width * 0.23,
        y: cardRect.minY + cardRect.height * 0.26,
        width: cardRect.width * 0.54,
        height: cardRect.height * 0.54
    )
    let backPath = NSBezierPath(roundedRect: backCard, xRadius: cardRect.width * 0.08, yRadius: cardRect.width * 0.08)
    NSColor(white: 1.0, alpha: 0.24).setFill()
    backPath.fill()

    // Front crisp white clipboard card
    let frontCard = CGRect(
        x: cardRect.minX + cardRect.width * 0.20,
        y: cardRect.minY + cardRect.height * 0.16,
        width: cardRect.width * 0.60,
        height: cardRect.height * 0.58
    )
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.015), blur: s * 0.035, color: NSColor(white: 0, alpha: 0.22).cgColor)
    let frontPath = NSBezierPath(roundedRect: frontCard, xRadius: cardRect.width * 0.085, yRadius: cardRect.width * 0.085)
    NSColor(white: 1.0, alpha: 0.96).setFill()
    frontPath.fill()
    cg.restoreGState()

    // Clipboard top clip pill
    let clipW = cardRect.width * 0.26
    let clipH = cardRect.height * 0.085
    let clipRect = CGRect(
        x: cardRect.midX - clipW / 2,
        y: frontCard.maxY - clipH * 0.45,
        width: clipW,
        height: clipH
    )
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: clipH / 2, yRadius: clipH / 2)
    NSColor(srgbRed: 0.27, green: 0.36, blue: 0.90, alpha: 1.0).setFill()
    clipPath.fill()
    NSColor(white: 1.0, alpha: 0.9).setStroke()
    clipPath.lineWidth = max(1.0, s * 0.012)
    clipPath.stroke()

    // Clean minimalist lines + accent "V" mark inside the front card
    let lineH = frontCard.height * 0.068
    let lineX = frontCard.minX + frontCard.width * 0.16

    let line1 = CGRect(x: lineX, y: frontCard.maxY - frontCard.height * 0.32, width: frontCard.width * 0.68, height: lineH)
    NSColor(srgbRed: 0.28, green: 0.36, blue: 0.88, alpha: 0.88).setFill()
    NSBezierPath(roundedRect: line1, xRadius: lineH / 2, yRadius: lineH / 2).fill()

    let line2 = CGRect(x: lineX, y: frontCard.maxY - frontCard.height * 0.50, width: frontCard.width * 0.50, height: lineH)
    NSColor(srgbRed: 0.28, green: 0.36, blue: 0.88, alpha: 0.45).setFill()
    NSBezierPath(roundedRect: line2, xRadius: lineH / 2, yRadius: lineH / 2).fill()

    let line3 = CGRect(x: lineX, y: frontCard.maxY - frontCard.height * 0.68, width: frontCard.width * 0.34, height: lineH)
    NSColor(srgbRed: 0.28, green: 0.36, blue: 0.88, alpha: 0.28).setFill()
    NSBezierPath(roundedRect: line3, xRadius: lineH / 2, yRadius: lineH / 2).fill()

    // Subtle crisp inner glass border on the squircle
    let borderPath = NSBezierPath(roundedRect: cardRect.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: corner, yRadius: corner)
    NSColor(white: 1.0, alpha: 0.25).setStroke()
    borderPath.lineWidth = max(1.0, s * 0.008)
    borderPath.stroke()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    if let data = renderIcon(size: px) {
        try data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("Generated iconset at \(outDir)")
