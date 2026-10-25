import AppKit
import SwiftUI

/// On a page that looks like an article: shows it as clean text over the page, and takes it away again.
struct ReaderButton: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if tab.isReadable || tab.isReading {
            // Hard Reload takes one of the two, so Reader Mode has the other.
            let key = prefs.shortcuts == .chrome ? "⌥⌘R" : "⇧⌘R"
            Button { tab.toggleReader() } label: {
                Image(systemName: "doc.plaintext").font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.isReading ? Theme.primary : Theme.dim)
            .help(tab.isReading ? String(localized: "Exit Reader Mode (\(key))") : String(localized: "Reader Mode (\(key))"))
        }
    }
}

/// On a page in another language: translates it on this Mac, and brings the original back.
struct TranslateButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.foreignLanguage != nil || tab.translation != .original {
            Button { tab.toggleTranslation() } label: {
                Group {
                    if tab.translation == .translating {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "translate").font(.system(size: 10.5, weight: .semibold))
                    }
                }
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(tab.translation == .translated ? Theme.primary : Theme.dim)
            .help(tab.translation == .translated ? String(localized: "Show Original (⌥⌘T)") : String(localized: "Translate (⌥⌘T)"))
        }
    }
}

/// Ad blocking for the current site: filled while blocking, slashed when turned off here.
/// Shows while the tab plays sound (a video, most likely): floats it in picture in picture.
struct PictureInPictureButton: View {
    @ObservedObject var tab: Tab

    var body: some View {
        if tab.isPlayingAudio {
            Button { tab.pictureInPicture(.toggle) } label: {
                Image(systemName: "pip.enter").font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Picture in Picture (⌃⌘P)")
        }
    }
}

struct AdBlockShield: View {
    @ObservedObject var tab: Tab
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if prefs.blockTrackers, let host = tab.url?.host(), tab.url?.scheme?.hasPrefix("http") == true {
            let off = AdBlocker.shared.isAllowed(host)
            Button { AdBlocker.shared.toggleSite(host) } label: {
                Image(systemName: off ? "shield.slash" : "shield.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(off ? Theme.waitingText : Theme.dim)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(off ? String(localized: "Turn on ad blocking for this site") : String(localized: "Turn off ad blocking for this site (if it breaks)"))
        }
    }
}

struct BookmarkStar: View {
    @ObservedObject var tab: Tab
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
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(marked ? Theme.primary : Theme.dim)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(marked ? String(localized: "Remove from Favorites (⌘D)") : String(localized: "Add to Favorites (⌘D)"))
    }
}
