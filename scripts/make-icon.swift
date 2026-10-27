// Draws the app icon (a little CRT showing color bars) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift

import AppKit

let size: CGFloat = 1024
let fileManager = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a])!
    }
    func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    }

    // Body: the macOS icon grid's 824pt rounded square.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.16, 0.16, 0.18))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0.27, 0.27, 0.30), color(0.10, 0.10, 0.12)], [0, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Tube: a bulging rounded rectangle.
    let screen = CGRect(x: 178, y: 214, width: 668, height: 596)
    let screenPath = CGMutablePath()
    let bulge: CGFloat = 22
    let r: CGFloat = 96
    screenPath.move(to: CGPoint(x: screen.minX + r, y: screen.maxY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.maxX - r, y: screen.maxY),
                            control: CGPoint(x: screen.midX, y: screen.maxY + bulge))
    screenPath.addQuadCurve(to: CGPoint(x: screen.maxX, y: screen.maxY - r),
                            control: CGPoint(x: screen.maxX, y: screen.maxY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.maxX, y: screen.minY + r),
                            control: CGPoint(x: screen.maxX + bulge, y: screen.midY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.maxX - r, y: screen.minY),
                            control: CGPoint(x: screen.maxX, y: screen.minY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.minX + r, y: screen.minY),
                            control: CGPoint(x: screen.midX, y: screen.minY - bulge))
    screenPath.addQuadCurve(to: CGPoint(x: screen.minX, y: screen.minY + r),
                            control: CGPoint(x: screen.minX, y: screen.minY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.minX, y: screen.maxY - r),
                            control: CGPoint(x: screen.minX - bulge, y: screen.midY))
    screenPath.addQuadCurve(to: CGPoint(x: screen.minX + r, y: screen.maxY),
                            control: CGPoint(x: screen.minX, y: screen.maxY))
    screenPath.closeSubpath()

    // Glow spilling onto the bezel.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60, color: color(0.45, 0.75, 1.0, 0.55))
    ctx.addPath(screenPath)
    ctx.setFillColor(color(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(screenPath)
    ctx.clip()
    let bars: [(CGFloat, CGFloat, CGFloat)] = [
        (0.92, 0.92, 0.92), (0.95, 0.85, 0.15), (0.15, 0.85, 0.90), (0.20, 0.85, 0.25),
        (0.88, 0.20, 0.85), (0.92, 0.18, 0.15), (0.15, 0.25, 0.92),
    ]
    let barWidth = (screen.width + 2 * bulge) / CGFloat(bars.count)
    for (i, bar) in bars.enumerated() {
        ctx.setFillColor(color(bar.0, bar.1, bar.2))
        ctx.fill(CGRect(x: screen.minX - bulge + CGFloat(i) * barWidth, y: screen.minY - bulge,
                        width: barWidth + 1, height: screen.height + 2 * bulge))
    }
    // Scanlines.
    ctx.setFillColor(color(0, 0, 0, 0.32))
    var y = screen.minY - bulge
    while y < screen.maxY + bulge {
        ctx.fill(CGRect(x: screen.minX - bulge, y: y, width: screen.width + 2 * bulge, height: 6))
        y += 14
    }
    // Vignette.
    ctx.drawRadialGradient(
        gradient([color(0, 0, 0, 0), color(0, 0, 0, 0.65)], [0.45, 1]),
        startCenter: CGPoint(x: screen.midX, y: screen.midY), startRadius: 0,
        endCenter: CGPoint(x: screen.midX, y: screen.midY), endRadius: screen.width * 0.62,
        options: [.drawsAfterEndLocation])
    // Glass highlight.
    ctx.drawLinearGradient(
        gradient([color(1, 1, 1, 0.28), color(1, 1, 1, 0)], [0, 1]),
        start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.midX, y: screen.midY),
        options: [])
    ctx.restoreGState()

    // Thin bezel edge.
    ctx.addPath(screenPath)
    ctx.setStrokeColor(color(0, 0, 0, 0.8))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Power light.
    ctx.setShadow(offset: .zero, blur: 14, color: color(1, 0.3, 0.2, 0.9))
    ctx.setFillColor(color(1, 0.35, 0.25))
    ctx.fillEllipse(in: CGRect(x: 790, y: 146, width: 22, height: 22))
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    drawIcon(in: ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(output.path)")
