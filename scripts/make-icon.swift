// Renders Resources/AppIcon.icns and docs/images/icon.png. Run: swift scripts/make-icon.swift
import AppKit

let ink = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.945, alpha: 1)
let tile = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)

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

    // An arched window, and the light it lets in falling to the lower right.
    let w = 330 * s, h = 450 * s
    let frame = NSRect(x: 290 * s, y: 330 * s, width: w, height: h)
    let light = NSBezierPath()
    light.move(to: NSPoint(x: frame.minX, y: frame.minY))
    light.line(to: NSPoint(x: frame.maxX, y: frame.minY))
    light.line(to: NSPoint(x: frame.maxX + 200 * s, y: 190 * s))
    light.line(to: NSPoint(x: frame.minX + 200 * s, y: 190 * s))
    light.close()
    NSGradient(starting: ink.withAlphaComponent(0.30), ending: ink.withAlphaComponent(0.02))!.draw(in: light, angle: -50)
    let arch = NSBezierPath()
    arch.move(to: NSPoint(x: frame.minX, y: frame.minY))
    arch.line(to: NSPoint(x: frame.minX, y: frame.maxY - w / 2))
    arch.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.maxY - w / 2), radius: w / 2, startAngle: 180, endAngle: 0, clockwise: true)
    arch.line(to: NSPoint(x: frame.maxX, y: frame.minY))
    arch.close()
    ink.setFill()
    arch.fill()
    tile.setFill()
    NSBezierPath(rect: NSRect(x: frame.midX - 13 * s, y: frame.minY, width: 26 * s, height: h - 36 * s)).fill()
    NSBezierPath(rect: NSRect(x: frame.minX, y: frame.minY + 180 * s, width: w, height: 26 * s)).fill()

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
