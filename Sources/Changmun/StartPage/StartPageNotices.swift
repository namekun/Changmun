import AppKit
import SwiftUI

/// What the start page's parts do besides opening a page: they go through the app's own actions.
@MainActor
enum StartPageActions {
    /// Sends what was typed to the AI as the panel's box would: the panel opens and the message goes, or says what is missing.
    static func ask(_ text: String, browser: Browser, chat: ChatStore) {
        guard !browser.isPrivate else { return }
        browser.showChat = true
        chat.refreshAvailability()
        if chat.availability == .ready {
            chat.submit(text)
        } else {
            chat.say(String(localized: "The AI panel needs Claude Code, so your question wasn't sent."))
        }
    }

    static func openSettings(_ page: SettingsPage) {
        UserDefaults.standard.set(page.rawValue, forKey: "settingsPage")
        (NSApp.delegate as? AppDelegate)?.showSettings(nil)
    }

    static func showHistory() { (NSApp.delegate as? AppDelegate)?.showHistory(nil) }

    static var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// As Settings › General does it.
    static func makeDefaultBrowser(done: @escaping () -> Void) {
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { _ in DispatchQueue.main.async { done() } }
        }
    }
}

/// A fresh profile: nothing of the user's to show yet, so the first steps (import, default browser, the AI) and where favorites will appear.
struct StartFirstRunView: View {
    @ObservedObject var browser: Browser
    let aiReady: Bool
    let search: AnyView
    @State private var isDefault = StartPageActions.isDefaultBrowser

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 58, height: 58).decorative()
            Text("Welcome to Changmun").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.primary).padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text("Start light. Do these three things and this page fills up with what you use.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.top, 6)
            search.frame(maxWidth: 620).padding(.top, 28)
            HStack(alignment: .top, spacing: 16) {
                step(symbol: "square.and.arrow.down", title: String(localized: "Import bookmarks and history"),
                     text: String(localized: "Bring them from the browser you use now, like Safari, Chrome or Arc. From Chromium-based browsers, passwords and logins can come along."),
                     button: String(localized: "Import…"), prominent: true) { browser.showOnboarding = true }
                if !isDefault {
                    step(symbol: "globe", title: String(localized: "Make Changmun your default browser"),
                         text: String(localized: "Links from mail and messages open in Changmun. You can change this any time in Settings."),
                         button: String(localized: "Make Default Browser"), prominent: false) { StartPageActions.makeDefaultBrowser { isDefault = StartPageActions.isDefaultBrowser } }
                }
                if !aiReady {
                    step(symbol: "sparkle", title: String(localized: "Connect the AI"),
                         text: String(localized: "With Claude Code on this Mac, the AI panel can read, click and type on pages. Without it, the browser works as it is."),
                         button: String(localized: "Open AI Settings"), prominent: false) { StartPageActions.openSettings(.ai) }
                }
            }
            .padding(.top, 28)
            VStack(alignment: .leading, spacing: 12) {
                Text("Favorites").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).accessibilityAddTraits(.isHeader)
                HStack(spacing: 20) {
                    HStack(spacing: 20) { ForEach(0..<5, id: \.self) { _ in StartEmptyFavorite(size: 56) } }
                    Text("Drag the sites you visit most to the favorites in the sidebar and they appear here as tiles.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.dim).frame(maxWidth: 280, alignment: .leading)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.top, 32)
            Text("As you use it, this place fills with closed tabs, your reading list and the sites you visit most.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.dim).padding(.top, 36)
        }
        .padding(.horizontal, 24)
        .onAppear { isDefault = StartPageActions.isDefaultBrowser }
    }

    private func step(symbol: String, title: String, text: String, button: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.opacity(0.14)))
                .decorative()
            Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).padding(.top, 14)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Spacer(minLength: 14)
            Button(action: action) {
                Text(verbatim: button).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(prominent ? Color.white : Theme.primary)
                    .padding(.horizontal, 11).frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(prominent ? Color.accentColor : Theme.pressed))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 285, height: 200, alignment: .topLeading)
        .startPlate(radius: 12)
    }
}

/// A private window: no history, closed tabs, reading list or AI on the page, and plainly what stays and what doesn't.
struct StartPrivateView: View {
    let search: AnyView

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "eye.slash").font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.primary)
                .frame(width: 62, height: 52)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.field))
                .decorative()
            Text("Private Window").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.primary).padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text("What you browse in this window isn't kept in history or the session. When you close it, cookies and site data go with it.")
                .font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 6)
            search.frame(maxWidth: 620).padding(.top, 28)
            HStack(alignment: .top, spacing: 28) {
                note("eye.slash", String(localized: "Nothing is kept"),
                     String(localized: "History, the session, cookies and site data are erased when you close the window. Search suggestions aren't sent either."))
                note("sparkle", String(localized: "The AI rests"),
                     String(localized: "A private window can't be shown to the AI, so the AI panel and its suggestions don't appear here."))
                note("shield", String(localized: "It isn't anonymous"),
                     String(localized: "The sites you visit, and your company, school or internet provider, still see it. Ad and tracker blocking stays on."))
            }
            .frame(maxWidth: 880)
            .padding(.top, 32)
        }
        .padding(.horizontal, 24)
    }

    private func note(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
                .decorative()
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary).accessibilityAddTraits(.isHeader)
                Text(verbatim: text).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
