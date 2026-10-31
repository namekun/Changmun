// Renders Resources/AppIcon.icns and docs/images/icon.png. Run: swift scripts/make-icon.swift
import AppKit

let ink = NSColor(srgbRed: 0.957, green: 0.957, blue: 0.945, alpha: 1)
let tileTop = NSColor(srgbRed: 44.0 / 255, green: 44.0 / 255, blue: 48.0 / 255, alpha: 1)
let tileBottom = NSColor(srgbRed: 22.0 / 255, green: 22.0 / 255, blue: 25.0 / 255, alpha: 1)
let bars = NSColor(srgbRed: 0.067, green: 0.067, blue: 0.067, alpha: 1)

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centered in 1024.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: tileTop, ending: tileBottom)!.draw(in: tile, angle: -90)
    // A faint edge, so that the tile holds its shape on a dark Dock.
    NSColor(white: 1, alpha: 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 3 * s, dy: 3 * s), xRadius: 182 * s, yRadius: 182 * s)
    edge.lineWidth = 6 * s
    edge.stroke()

    // An arched window, and the light it lets in falling to the lower right, with the shadow of its bars.
    let w = 380 * s, h = 518 * s, bar = 30 * s
    let frame = NSRect(x: 251 * s, y: 305 * s, width: w, height: h)
    let floor = 150 * s, drop = 200 * s
    let depth = frame.minY - floor
    let light = NSBezierPath()
    func pane(_ u0: CGFloat, _ u1: CGFloat, _ t0: CGFloat, _ t1: CGFloat) {
        let at = { (u: CGFloat, t: CGFloat) in NSPoint(x: frame.minX + u * w + t * drop, y: frame.minY - t * depth) }
        light.move(to: at(u0, t0))
        light.line(to: at(u1, t0))
        light.line(to: at(u1, t1))
        light.line(to: at(u0, t1))
        light.close()
    }
    let across = bar / (2 * w), along = bar * 0.8 / (2 * depth), cross: CGFloat = 0.46
    pane(0, 0.5 - across, 0, cross - along)
    pane(0.5 + across, 1, 0, cross - along)
    pane(0, 0.5 - across, cross + along, 1)
    pane(0.5 + across, 1, cross + along, 1)
    NSGradient(starting: ink.withAlphaComponent(0.62), ending: ink.withAlphaComponent(0.14))!.draw(in: light, angle: -62)
    let arch = NSBezierPath()
    arch.move(to: NSPoint(x: frame.minX, y: frame.minY))
    arch.line(to: NSPoint(x: frame.minX, y: frame.maxY - w / 2))
    arch.appendArc(withCenter: NSPoint(x: frame.midX, y: frame.maxY - w / 2), radius: w / 2, startAngle: 180, endAngle: 0, clockwise: true)
    arch.line(to: NSPoint(x: frame.maxX, y: frame.minY))
    arch.close()
    ink.setFill()
    arch.fill()
    bars.setFill()
    NSBezierPath(rect: NSRect(x: frame.midX - bar / 2, y: frame.minY, width: bar, height: h - 41 * s)).fill()
    NSBezierPath(rect: NSRect(x: frame.minX, y: frame.minY + 207 * s, width: w, height: bar)).fill()

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
