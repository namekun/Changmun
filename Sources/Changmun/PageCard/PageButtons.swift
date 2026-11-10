import AppKit
import SwiftUI
import WebKit

/// On a page that looks like an article: shows it as clean text over the page, and takes it away again.
struct ReaderButton: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if tab.isReadable || tab.isReading {
            // Hard Reload takes one of the two, so Reader Mode has the other.
            let key = prefs.shortcuts == .chrome ? "⌥⌘R" : "⇧⌘R"
            Button { tab.toggleReader() } label: {
                Image(systemName: "doc.plaintext").font(.symbolInline)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.isReading ? Theme.primary : Theme.secondary)
            .help(tab.isReading ? String(localized: "Exit Reader Mode (\(key))") : String(localized: "Reader Mode (\(key))"))
            .accessibilityLabel(String(localized: "Reader Mode"))
            .accessibilityValue(Accessibility.onOffValue(tab.isReading))
        }
    }
}

/// On a page in another language: translates it (on this Mac, or with Claude if Settings says so), and brings the original back.
struct TranslateButton: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if tab.foreignLanguage != nil || tab.translation != .original {
            Button { tab.toggleTranslation() } label: {
                Group {
                    if tab.translation == .translating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "translate").font(.symbolInline)
                    }
                }
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.translation == .translated ? Theme.primary : Theme.secondary)
            .help(tab.translatesWithClaude ? String(localized: "Translating with Claude: the page’s text is being sent to Anthropic. Click to stop (⌥⌘T).")
                  : tab.translation == .translated ? String(localized: "Show Original (⌥⌘T)") : String(localized: "Translate (⌥⌘T)"))
            .contextMenu {
                if !tab.isPrivate, tab.url?.scheme?.hasPrefix("http") == true, let host = tab.url?.host()?.lowercased(), !host.isEmpty {
                    Toggle("Keep translating this site", isOn: Binding(get: { prefs.keepsTranslating(host) }, set: { tab.setKeepsTranslating($0, host: host) }))
                        .help("Translates this site’s pages as they open, and the text they add later. With Claude, the text of each page is sent to Anthropic automatically, without asking again.")
                }
            }
            .accessibilityLabel(String(localized: "Translate"))
            .accessibilityValue(tab.translation == .translating ? String(localized: "Translating") : Accessibility.onOffValue(tab.translation == .translated))
        }
    }
}

/// Shows while the tab plays sound (a video, most likely): floats it in picture in picture.
struct PictureInPictureButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isPlayingAudio {
            Button { tab.pictureInPicture(.toggle) } label: {
                Image(systemName: "pip.enter").font(.symbolInline)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Picture in Picture (⌃⌘P)")
            .accessibilityLabel(String(localized: "Picture in Picture"))
        }
    }
}

/// What the page is using the camera and the microphone for right now, said in words in the address (see `CaptureButton`).
struct MediaCapture: Equatable {
    var camera = false
    var microphone = false

    init() {}

    /// A page that is muted (WebKit holds the device but nothing flows) is not capturing.
    init(camera: WKMediaCaptureState, microphone: WKMediaCaptureState) {
        self.camera = camera == .active
        self.microphone = microphone == .active
    }

    var label: String? {
        switch (camera, microphone) {
        case (true, true): String(localized: "Camera and microphone on")
        case (true, false): String(localized: "Camera on")
        case (false, true): String(localized: "Microphone on")
        case (false, false): nil
        }
    }

    var stopHelp: String? {
        switch (camera, microphone) {
        case (true, true): String(localized: "Stop the camera and microphone")
        case (true, false): String(localized: "Stop the camera")
        case (false, true): String(localized: "Stop the microphone")
        case (false, false): nil
        }
    }

    var symbol: String { camera ? "video.fill" : "mic.fill" }
}

/// Shows while the page is capturing from the camera or microphone: says which in words, and a click stops it.
struct CaptureButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if let label = tab.capture.label, let help = tab.capture.stopHelp {
            Button {
                if tab.capture.camera { tab.webView?.setCameraCaptureState(.none) }
                if tab.capture.microphone { tab.webView?.setMicrophoneCaptureState(.none) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: tab.capture.symbol).font(.symbolInline)
                    Text(label).font(.secondaryStrong).lineLimit(1).fixedSize()
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .foregroundStyle(Theme.waitingText)
                .background(Capsule().fill(Theme.pill))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityHint(help)
        }
    }
}

struct AdBlockShield: View {
    @ObservedObject var tab: Tab
    /// The pointer is over the address: drawn in full ink.
    var emphasized = false
    @ObservedObject private var prefs = Preferences.shared

    /// Said in words, as the shield turns orange when it is off.
    static func help(off: Bool) -> String {
        off ? String(localized: "Ad blocking is off on this site. Click to turn it on.") : String(localized: "Turn off ad blocking for this site (if it breaks)")
    }

    static func value(off: Bool) -> String {
        off ? String(localized: "Ad blocking is off on this site") : Accessibility.onOffValue(true)
    }

    var body: some View {
        if prefs.blockTrackers, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true {
            let off = AdBlocker.shared.isAllowed(host)
            Button { AdBlocker.shared.toggleSite(host) } label: {
                Image(systemName: off ? "shield.slash" : "shield.fill")
                    .font(.symbolInline)
                    .foregroundStyle(off ? Theme.waitingText : emphasized ? Theme.primary : Theme.secondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.help(off: off))
            .accessibilityLabel(String(localized: "Ad blocking for this site"))
            .accessibilityValue(Self.value(off: off))
        }
    }
}

struct BookmarkStar: View {
    @ObservedObject var tab: Tab
    /// The pointer is over the address: drawn in full ink.
    var emphasized = false
    @ObservedObject private var library = LibraryWatcher.shared

    var body: some View {
        let url = tab.url?.absoluteString ?? ""
        let folder = tab.favoritesFolder
        let marked = !url.isEmpty && library.isFavorite(url, in: folder)
        Button {
            guard !url.isEmpty else { return }
            let title = tab.bookmarkTitle
            if !Library.shared.toggleBookmark(url: url, title: title, in: folder) && marked {
                tab.browser?.offerUndo(String(localized: "Removed from Favorites")) {
                    Library.shared.addBookmark(url: url, title: title, folder: folder)
                }
            }
        } label: {
            Image(systemName: marked ? "star.fill" : "star")
                .font(.symbolInline)
                .foregroundStyle(marked || emphasized ? Theme.primary : Theme.secondary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(marked ? String(localized: "Remove from Favorites (⌘D)") : String(localized: "Add to Favorites (⌘D)"))
        .accessibilityLabel(marked ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))
    }
}
