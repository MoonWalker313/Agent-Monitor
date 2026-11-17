// Draws AgentBar's app icon and .dmg background from code (no image assets to keep in sync).
// Usage: swift scripts/render-art.swift <out-dir>
// Writes: icon_<size>.png (16…1024), dmg-background.png (660x470), dmg-background@2x.png (1320x940)
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/art"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func png(width: Int, height: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    draw(ctx, CGFloat(width))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// A lit cue lamp: glow, glass body, lens highlight.
func drawLamp(_ ctx: CGContext, center: CGPoint, radius r: CGFloat, hex: UInt32, glow: CGFloat,
              light: UInt32 = 0xFFD37A, dark: UInt32 = 0xC9780A) {
    let space = CGColorSpaceCreateDeviceRGB()
    // Glow
    let glowColors = [color(hex, 0.55 * glow).cgColor, color(hex, 0).cgColor] as CFArray
    let glowGradient = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(glowGradient, startCenter: center, startRadius: r * 0.95, endCenter: center, endRadius: r * 1.75, options: [])
    // Body
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
    ctx.clip()
    let body = [color(light).cgColor, color(hex).cgColor, color(dark).cgColor] as CFArray
    let bodyGradient = CGGradient(colorsSpace: space, colors: body, locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(bodyGradient, startCenter: CGPoint(x: center.x - r * 0.25, y: center.y + r * 0.3), startRadius: 0,
                           endCenter: center, endRadius: r * 1.05, options: [.drawsAfterEndLocation])
    ctx.restoreGState()
    // Lens highlight
    let hl = CGRect(x: center.x - r * 0.55, y: center.y + r * 0.18, width: r * 0.7, height: r * 0.45)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.35).cgColor)
    ctx.fillEllipse(in: hl)
    // Rim
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.25).cgColor)
    ctx.setLineWidth(max(1, r * 0.04))
    ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
}

// MARK: App icon: a blackout cue board with one lamp standing by, and two smaller cues below.
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    let inset = s * 0.098                       // macOS icon grid: 824/1024 content
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(color(0x161618).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // Panel gradient
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color(0x2C2C30).cgColor, color(0x141416).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    // Main lamp: standing by
    drawLamp(ctx, center: CGPoint(x: s * 0.5, y: s * 0.575), radius: s * 0.15, hex: 0xFFB020, glow: 0.8)
    // A row of smaller cues: running, done, unlit
    let y = s * 0.28, r = s * 0.032, gap = s * 0.115
    drawLamp(ctx, center: CGPoint(x: s * 0.5 - gap, y: y), radius: r, hex: 0x0A84FF, glow: 0.5, light: 0x7CC0FF, dark: 0x0060CC)
    drawLamp(ctx, center: CGPoint(x: s * 0.5, y: y), radius: r, hex: 0x30D158, glow: 0.5, light: 0x8BEBA5, dark: 0x1C7A37)
    drawLamp(ctx, center: CGPoint(x: s * 0.5 + gap, y: y), radius: r, hex: 0x4A4A4E, glow: 0, light: 0x6A6A70, dark: 0x2E2E32)
    // Inner hairline
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: s * 0.004, dy: s * 0.004), cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.08).cgColor); ctx.setLineWidth(s * 0.004); ctx.strokePath()
    ctx.restoreGState()
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try! png(width: size, height: size) { ctx, s in drawIcon(ctx, s) }
        .write(to: URL(fileURLWithPath: "\(out)/icon_\(size).png"))
}

// MARK: .dmg background (house lights): drag hint between the two icons, approval note below.
func drawBackground(_ ctx: CGContext, _ w: CGFloat) {
    let k = w / 660
    let h = 470 * k
    ctx.setFillColor(color(0xF2F1EE).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    func text(_ string: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, centerX: CGFloat, baselineFromTop: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * k, weight: weight),
                                                    .foregroundColor: color(hex)]
        let str = NSAttributedString(string: string, attributes: attrs)
        let size = str.size()
        str.draw(at: CGPoint(x: centerX * k - size.width / 2, y: h - baselineFromTop * k))
    }

    // Arrow between app (x 170) and Applications (x 490), icons centred at y 170 from top.
    let y = h - 170 * k
    ctx.setStrokeColor(color(0x8E8C86).cgColor)
    ctx.setLineWidth(2 * k)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [6 * k, 7 * k])
    ctx.move(to: CGPoint(x: 252 * k, y: y)); ctx.addLine(to: CGPoint(x: 400 * k, y: y)); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.move(to: CGPoint(x: 392 * k, y: y + 9 * k)); ctx.addLine(to: CGPoint(x: 404 * k, y: y)); ctx.addLine(to: CGPoint(x: 392 * k, y: y - 9 * k))
    ctx.strokePath()

    text("Drag AgentBar to Applications", size: 15, weight: .semibold, hex: 0x1D1D1F, centerX: 330, baselineFromTop: 64)
    text("First time opening it? macOS asks you to approve AgentBar once.", size: 12, weight: .regular, hex: 0x5F5E63, centerX: 330, baselineFromTop: 288)
    text("The READ ME below shows how, step by step.", size: 12, weight: .regular, hex: 0x5F5E63, centerX: 330, baselineFromTop: 306)
}

try! png(width: 660, height: 470) { ctx, w in drawBackground(ctx, w) }.write(to: URL(fileURLWithPath: "\(out)/dmg-background.png"))
try! png(width: 1320, height: 940) { ctx, w in drawBackground(ctx, w) }.write(to: URL(fileURLWithPath: "\(out)/dmg-background@2x.png"))
print("art written to \(out)")
