import AppKit
import CoreGraphics
// Lists every window of the test runner or the test copy that touches a screen, for as long as a run takes: none may.
//   swiftc -O scripts/watch-windows.swift -o /tmp/watch-windows && /tmp/watch-windows & ; run the tests ; touch /tmp/watch-windows.stop
let screens = NSScreen.screens.map(\.frame)
let cgH = screens.first?.height ?? 0
var hits: [String: Int] = [:]
var samples = 0
var detail: [String: String] = [:]
while !FileManager.default.fileExists(atPath: "/tmp/watch-windows.stop") {
    usleep(50_000); samples += 1
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        guard owner.contains("swiftpm") || owner.contains("xctest") || owner.contains("Testing") || owner.contains("PackageTests") || owner.contains("Headless") else { continue }
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0, width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
        let r = CGRect(x: x, y: y, width: width, height: height)
        let visible = r.intersects(CGRect(x: 0, y: 0, width: screens[0].width, height: cgH))
        hits["\(visible ? "ON SCREEN" : "off") \(owner) \(Int(x)) \(Int(y)) \(Int(width))x\(Int(height))", default: 0] += 1
        if visible && width > 0 { detail["alpha \(w[kCGWindowAlpha as String] ?? "?") layer \(w[kCGWindowLayer as String] ?? "?") sharing \(w[kCGWindowSharingState as String] ?? "?") name '\(w[kCGWindowName as String] ?? "")' id \(w[kCGWindowNumber as String] ?? 0) \(Int(width))x\(Int(height))"] = Date().formatted(date: .omitted, time: .standard) }
    }
}
print("samples", samples); for (k,v) in detail { print("DETAIL", v, k) }; for (k,v) in hits.sorted(by: { $0.key < $1.key }) { print(v, k) }
