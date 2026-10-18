import Carbon.HIToolbox

/// ⌃⌘← and ⌃⌘→ move the floating video 5 seconds, from any app, but only while one floats: the keys are taken from
/// the system then and given back when the video leaves picture in picture.
@MainActor
enum PictureInPictureKeys {
    static let step = 5.0
    private static var hotKeys: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?

    /// Called whenever a tab's picture in picture changes.
    static func update() {
        let floating = Browser.all.contains { browser in browser.openTabs.contains(where: \.isInPictureInPicture) }
        if floating && hotKeys.isEmpty && !Headless.isOn { register() } else if !floating && !hotKeys.isEmpty { unregister() }
    }

    /// The tab whose video floats, else the shown tab of the front window.
    static var target: Tab? {
        Browser.all.lazy.compactMap { browser in browser.openTabs.first(where: \.isInPictureInPicture) }.first ?? Browser.current?.active
    }

    private static func register() {
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
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
    }
}
