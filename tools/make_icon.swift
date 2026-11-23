import AppKit

// 生成 1024×1024 的应用图标：渐变圆角方块 + 三条资源占用条 + 状态点。

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let px = 1024

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: px, pixelsHigh: px,
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let size = CGFloat(px)
let inset = size * 0.098
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.225
let body = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

let top = NSColor(srgbRed: 0.33, green: 0.32, blue: 0.94, alpha: 1)
let bottom = NSColor(srgbRed: 0.06, green: 0.62, blue: 0.63, alpha: 1)
NSGradient(starting: top, ending: bottom)!.draw(in: body, angle: -65)

let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: radius, yRadius: radius)
NSColor.white.withAlphaComponent(0.16).setStroke()
highlight.lineWidth = 4
highlight.stroke()

// 三条占用条
let barX = rect.minX + rect.width * 0.20
let barW = rect.width * 0.60
let heights: [CGFloat] = [0.185, 0.135, 0.160]
let fractions: [CGFloat] = [0.92, 0.55, 0.74]
let gap = rect.height * 0.072
let total = heights.reduce(0, +) * rect.height + gap * 2
var y = rect.midY - total / 2 + rect.height * 0.02

for index in 0..<3 {
    let height = heights[index] * rect.height
    let trackRect = NSRect(x: barX, y: y, width: barW, height: height)
    NSColor.black.withAlphaComponent(0.20).setFill()
    NSBezierPath(roundedRect: trackRect, xRadius: height / 2, yRadius: height / 2).fill()

    let fillRect = NSRect(x: barX, y: y, width: barW * fractions[index], height: height)
    NSColor.white.withAlphaComponent(index == 0 ? 0.97 : 0.80).setFill()
    NSBezierPath(roundedRect: fillRect, xRadius: height / 2, yRadius: height / 2).fill()

    y += height + gap
}

// 状态点
let dotSize = rect.width * 0.095
let dotRect = NSRect(x: rect.maxX - rect.width * 0.155 - dotSize,
                     y: rect.maxY - rect.height * 0.155 - dotSize,
                     width: dotSize, height: dotSize)
NSColor(srgbRed: 0.30, green: 0.95, blue: 0.60, alpha: 1).setFill()
NSBezierPath(ovalIn: dotRect).fill()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
