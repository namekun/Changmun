// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift [a|b|c] [--preview out.png]
import AppKit

let variant = CommandLine.arguments.dropFirst().first { ["a", "b", "c"].contains($0) } ?? "c"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let violet = color(0x8C59FA), blue = color(0x408CFA)

/// A four-pointed sparkle whose points are `r` from the center; `pinch` sets how far in the sides curve.
func sparkle(center c: NSPoint, radius r: CGFloat, pinch: CGFloat = 0.2) -> NSBezierPath {
    let path = NSBezierPath()
    let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y), NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
    path.move(to: tips[0])
    for i in 0..<4 {
        let next = tips[(i + 1) % 4]
        path.curve(to: next, controlPoint1: NSPoint(x: c.x + (tips[i].x - c.x) * pinch, y: c.y + (tips[i].y - c.y) * pinch),
                   controlPoint2: NSPoint(x: c.x + (next.x - c.x) * pinch, y: c.y + (next.y - c.y) * pinch))
    }
    path.close()
    return path
}

func fill(_ path: NSBezierPath, gradient: NSGradient, angle: CGFloat) {
    gradient.draw(in: path, angle: angle)
}

func render(size: CGFloat, variant: String) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS icon grid: 824pt rounded square centered in 1024, with a soft drop shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24 * s
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0xFFFFFF).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    switch variant {
    case "a":
        // A window with four panes on the violet-to-blue gradient; the sparkle sits in the top-right pane.
        fill(squircle, gradient: NSGradient(starting: violet, ending: blue)!, angle: -45)
        let frame = body.insetBy(dx: 190 * s, dy: 190 * s)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 70 * s, yRadius: 70 * s)
        outline.lineWidth = 46 * s
        color(0xFFFFFF).setStroke()
        outline.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: frame.midX, y: frame.minY)); cross.line(to: NSPoint(x: frame.midX, y: frame.maxY))
        cross.move(to: NSPoint(x: frame.minX, y: frame.midY)); cross.line(to: NSPoint(x: frame.maxX, y: frame.midY))
        cross.lineWidth = 34 * s
        cross.stroke()
        color(0xFFFFFF).setFill()
        sparkle(center: NSPoint(x: frame.midX + frame.width / 4, y: frame.midY + frame.height / 4), radius: 78 * s).fill()

    case "c":
        // Dawn through a window: a dark tile, the panes glowing with the gradient, a white sparkle.
        fill(squircle, gradient: NSGradient(starting: color(0x1E1B2E), ending: color(0x0E0D16))!, angle: -90)
        let frame = body.insetBy(dx: 200 * s, dy: 170 * s)
        let gap = 26 * s
        let paneW = (frame.width - gap) / 2, paneH = (frame.height - gap) / 2
        let glow = NSGradient(colors: [color(0xB79CFF), violet, blue, color(0x7FD3FF)])!
        for row in 0..<2 {
            for col in 0..<2 {
                let pane = NSRect(x: frame.minX + CGFloat(col) * (paneW + gap), y: frame.minY + CGFloat(row) * (paneH + gap), width: paneW, height: paneH)
                let corner: CGFloat = 46 * s
                glow.draw(in: NSBezierPath(roundedRect: pane, xRadius: corner, yRadius: corner), relativeCenterPosition: NSPoint(x: col == 0 ? 0.6 : -0.6, y: row == 0 ? 0.6 : -0.6))
            }
        }
        color(0xFFFFFF).setFill()
        sparkle(center: NSPoint(x: frame.maxX - 40 * s, y: frame.maxY - 40 * s), radius: 96 * s).fill()

    default:
        // The app itself: a soft white tile, a sidebar and a content card, and the AI sparkle in gradient.
        fill(squircle, gradient: NSGradient(starting: color(0xF6F5FB), ending: color(0xE4E6F0))!, angle: -90)
        let window = body.insetBy(dx: 150 * s, dy: 190 * s).offsetBy(dx: 0, dy: -10 * s)
        let windowPath = NSBezierPath(roundedRect: window, xRadius: 56 * s, yRadius: 56 * s)
        NSGraphicsContext.saveGraphicsState()
        let windowShadow = NSShadow()
        windowShadow.shadowColor = color(0x3B2A7A, 0.22)
        windowShadow.shadowBlurRadius = 30 * s
        windowShadow.shadowOffset = NSSize(width: 0, height: -12 * s)
        windowShadow.set()
        color(0xEDEEF4).setFill()
        windowPath.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Traffic lights.
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            color(UInt32(hex)).setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + (34 + CGFloat(i) * 36) * s, y: window.maxY - 54 * s, width: 22 * s, height: 22 * s)).fill()
        }
        // Sidebar rows: the active tab is a white pill.
        let sidebarX = window.minX + 30 * s
        for i in 0..<4 {
            let row = NSRect(x: sidebarX, y: window.maxY - (120 + CGFloat(i) * 62) * s, width: 150 * s, height: 40 * s)
            (i == 1 ? color(0xFFFFFF) : color(0xD9DBE6)).setFill()
            NSBezierPath(roundedRect: i == 1 ? row : row.insetBy(dx: 0, dy: 8 * s).offsetBy(dx: 0, dy: 0), xRadius: 12 * s, yRadius: 12 * s).fill()
        }
        // The content card in gradient, with the sparkle.
        let card = NSRect(x: window.minX + 205 * s, y: window.minY + 26 * s, width: window.width - 231 * s, height: window.height - 52 * s)
        fill(NSBezierPath(roundedRect: card, xRadius: 34 * s, yRadius: 34 * s), gradient: NSGradient(starting: violet, ending: blue)!, angle: -45)
        color(0xFFFFFF).setFill()
        sparkle(center: NSPoint(x: card.midX + 6 * s, y: card.midY + 18 * s), radius: 110 * s).fill()
        sparkle(center: NSPoint(x: card.midX + 118 * s, y: card.midY - 92 * s), radius: 42 * s).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if let i = CommandLine.arguments.firstIndex(of: "--preview"), i + 1 < CommandLine.arguments.count {
    // All three variants on light and dark, for choosing.
    let tile: CGFloat = 360, pad: CGFloat = 40
    let width = Int(3 * tile + 4 * pad), height = Int(2 * tile + 3 * pad)
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    color(0xF2F2F5).setFill(); NSRect(x: 0, y: CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height) / 2).fill()
    color(0x1C1C1E).setFill(); NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) / 2).fill()
    for (col, v) in ["a", "b", "c"].enumerated() {
        let image = NSImage(size: NSSize(width: 1024, height: 1024))
        image.addRepresentation(render(size: 1024, variant: v))
        for row in 0..<2 {
            let rect = NSRect(x: pad + CGFloat(col) * (tile + pad), y: pad + CGFloat(row) * (tile + pad), width: tile, height: tile)
            image.draw(in: rect)
        }
        let label = NSAttributedString(string: v.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold), .foregroundColor: color(0x8E8E93)])
        label.draw(at: NSPoint(x: pad + CGFloat(col) * (tile + pad) + tile / 2 - 9, y: CGFloat(height) - 34))
    }
    NSGraphicsContext.restoreGraphicsState()
    try sheet.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    print(CommandLine.arguments[i + 1])
    exit(0)
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChangmunIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(size: CGFloat(base * scale), variant: variant).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns" : "iconutil failed")
