import AppKit
import Carbon.HIToolbox

/// ⌃⌘← and ⌃⌘→ move the floating video 5 seconds, from any app, but only while one floats: the keys are taken from
/// the system then and given back when the video leaves picture in picture. Clicks are timed meanwhile too.
@MainActor
enum PictureInPictureKeys {
    static let step = 5.0
    private static var watching = false
    private static var hotKeys: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    private static var clickMonitors: [Any] = []

    /// When the mouse was last clicked, anywhere, while a video floated. "Back to tab" is a click on the floating
    /// window; a page leaving picture in picture by itself comes with none, and mustn't pull the browser forward.
    static var lastClick = Date.distantPast
    static var clickedJustNow: Bool { Date().timeIntervalSince(lastClick) < 2 }

    /// Called whenever a tab's picture in picture changes.
    static func update() {
        let floating = Browser.all.contains { browser in browser.openTabs.contains(where: \.isInPictureInPicture) }
        if floating && !watching && !Headless.isOn { register() } else if !floating && watching { unregister() }
    }

    /// The tab whose video floats, else the shown tab of the front window.
    static var target: Tab? {
        Browser.all.lazy.compactMap { browser in browser.openTabs.first(where: \.isInPictureInPicture) }.first ?? Browser.current?.active
    }

    private static func register() {
        watching = true
        let click = { (event: NSEvent) in MainActor.assumeIsolated { PictureInPictureKeys.lastClick = Date() } }
        clickMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp], handler: click),
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { click($0); return $0 },
        ].compactMap { $0 }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { PictureInPictureKeys.target?.seekVideo(by: id.id == 1 ? -PictureInPictureKeys.step : PictureInPictureKeys.step) }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        for (number, key) in [(UInt32(1), kVK_LeftArrow), (2, kVK_RightArrow)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x434D_5049), id: number) // "CMPI"
            if RegisterEventHotKey(UInt32(key), UInt32(cmdKey | controlKey), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                hotKeys.append(ref)
            }
        }
    }

    private static func unregister() {
        watching = false
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }
}
