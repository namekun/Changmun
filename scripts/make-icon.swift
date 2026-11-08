// Renders Resources/AppIcon.icns and docs/images/icon.png. Run: swift scripts/make-icon.swift
import AppKit

let ink = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.945, alpha: 1)
let tile = NSColor(srgbRed: 30.0 / 255, green: 30.0 / 255, blue: 33.0 / 255, alpha: 1)

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centered in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    tile.setFill()
    NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).fill()
    // A faint edge, so that the tile holds its shape on a dark Dock.
    NSColor(white: 1, alpha: 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 3 * s, dy: 3 * s), xRadius: 182 * s, yRadius: 182 * s)
    edge.lineWidth = 6 * s
    edge.stroke()

    // The window as a sign: an arch, one upright and one crossbar, all of the same stroke, in two colours and nothing else.
    let stroke = 56 * s, w = 392 * s, h = 520 * s
    let f = NSRect(x: body.midX - w / 2, y: body.midY - h / 2, width: w, height: h)
    let arch = NSBezierPath()
    arch.move(to: NSPoint(x: f.minX, y: f.minY))
    arch.line(to: NSPoint(x: f.minX, y: f.maxY - w / 2))
    arch.appendArc(withCenter: NSPoint(x: f.midX, y: f.maxY - w / 2), radius: w / 2, startAngle: 180, endAngle: 0, clockwise: true)
    arch.line(to: NSPoint(x: f.maxX, y: f.minY))
    arch.close()
    arch.lineWidth = stroke
    arch.lineJoinStyle = .round
    ink.setStroke()
    arch.stroke()
    let bars = NSBezierPath()
    bars.move(to: NSPoint(x: f.midX, y: f.minY))
    bars.line(to: NSPoint(x: f.midX, y: f.maxY - w / 2 + 6 * s))
    bars.move(to: NSPoint(x: f.minX, y: f.minY + h * 0.42))
    bars.line(to: NSPoint(x: f.maxX, y: f.minY + h * 0.42))
    bars.lineWidth = stroke
    bars.lineCapStyle = .butt
    bars.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChangmunIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try render(size: 256).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/images/icon.png"))
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
