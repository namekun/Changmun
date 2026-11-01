// Says whether any window of a process is on a screen: every window the window server lists for the process ID that is ordered in (the window
// server's on-screen list, whatever its size) is compared with the frame of every display. A window that is not ordered in (the system keeps
// a few of those, such as a 500 by 500 one at a display's corner) can't be seen, and is only counted. Exits 1 if one overlaps a display,
// naming it, 0 if none does, 2 if it can't tell.
//
//   swift scripts/check-offscreen.swift <pid>
import AppKit

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: check-offscreen.swift <pid>\n".utf8))
    exit(2)
}
_ = NSApplication.shared
let screens = NSScreen.screens
guard let primary = screens.first, let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("can't list the displays or the windows\n".utf8))
    exit(2)
}
// The window server's rectangles start at the top left of the primary display; AppKit's at the bottom left.
let displays = screens.map { CGRect(x: $0.frame.minX, y: primary.frame.height - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
var count = 0
var onScreen = 0
var hidden = 0
for window in list where (window[kCGWindowOwnerPID as String] as? Int32) == pid {
    guard let dictionary = window[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
    count += 1
    guard window[kCGWindowIsOnscreen as String] as? Bool == true else { hidden += 1; continue }
    if displays.contains(where: { $0.intersects(bounds) }) {
        onScreen += 1
        print("ON A SCREEN: window \(window[kCGWindowNumber as String] ?? "?") \"\(window[kCGWindowName as String] ?? "")\" at \(bounds), layer \(window[kCGWindowLayer as String] ?? "?")")
    }
}
print("\(count) windows of process \(pid) (\(hidden) not ordered in), \(onScreen) on a screen (displays: \(displays.map { "\($0)" }.joined(separator: ", ")))")
exit(onScreen == 0 ? 0 : 1)
