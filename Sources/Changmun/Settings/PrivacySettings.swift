import AppKit
import LocalAuthentication
import SwiftUI
import WebKit

// MARK: Privacy

struct PrivacySettings: View {
    enum Range: String, CaseIterable, Identifiable {
        case hour, today, all
        var id: String { rawValue }
        var name: String {
            switch self {
            case .hour: String(localized: "Past Hour")
            case .today: String(localized: "Today")
            case .all: String(localized: "All Time")
            }
        }
        var since: Date {
            switch self {
            case .hour: Date().addingTimeInterval(-3600)
            case .today: Calendar.current.startOfDay(for: Date())
            case .all: .distantPast
            }
        }
    }

    @ObservedObject var prefs: Preferences
    @ObservedObject private var permissions = SitePermissions.shared
    @ObservedObject private var journal = JournalStatus.shared
    @State private var range = Range.hour
    @State private var clearHistory = true
    @State private var clearSiteData = false
    @State private var confirming = false
    @State private var cleared: String?
    @State private var showPasswords = false
    @State private var passwordCount = 0

    private var clearTarget: String {
        switch (clearHistory, clearSiteData) {
        case (true, true): String(localized: "browsing history and site data")
        case (true, false): String(localized: "browsing history")
        default: String(localized: "site data")
        }
    }

    var body: some View {
        Form {
            Section("Clear History") {
                Picker("Time Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.name).tag($0) }
                }
                Toggle("Browsing History", isOn: $clearHistory)
                Toggle("Site data such as cookies and cache (signs you out of sites)", isOn: $clearSiteData)
                HStack {
                    if let cleared { Caption(verbatim: cleared) }
                    Spacer()
                    Button("Clear…") { confirming = true }.disabled(!clearHistory && !clearSiteData)
                }
            }
            .confirmationDialog("Clear \(clearTarget)? (\(range.name))",
                                isPresented: $confirming) {
                Button("Clear", role: .destructive, action: clear)
            }
            Section {
                Toggle("Stay signed in after quitting", isOn: $prefs.keepSessionCookies)
                Caption(text: "Keeps the sign-in cookies that sites meant to end when the browser closes, for up to 30 days, in a file on this Mac encrypted with a key from your login Keychain, until you turn it off or clear site data.")
                if prefs.keepSessionCookies && journal.keyDenied {
                    Caption(text: "Couldn’t use the Keychain, so sign-ins won’t survive quitting.", color: .red)
                }
            }
            AdBlockSection(prefs: prefs)
            Section {
                Toggle("Remove tracking from links", isOn: $prefs.removeTrackingFromLinks)
                Caption(text: "Takes known tracking parameters (utm_source, fbclid, gclid and the like) out of the addresses you type, open from a bookmark, open in a new tab or the peek, or have the AI open. Links you click inside a page are left as the site wrote them. A site where it breaks a page has its own switch in the address bar.")
                Toggle("Prefer secure connections", isOn: $prefs.preferSecureConnections)
                Caption(text: "Tries http addresses over https first (the same ones as above), and loads them over http only when the site can’t be reached over https. Links clicked inside a page, redirects and forms are left as the site made them. A certificate that can’t be verified is never answered with http.")
            }
            Section {
                LabeledContent("Saved Passwords") {
                    HStack {
                        Text(passwordCount == 1 ? String(localized: "\(passwordCount) password") : String(localized: "\(passwordCount) passwords")).foregroundStyle(.secondary)
                        Button("Manage…") { showPasswords = true }
                    }
                }
                Toggle("Require Touch ID to fill passwords", isOn: $prefs.requireAuthToFill)
                Caption(text: "Filling a saved password asks for Touch ID or your Mac password, then doesn’t ask again for a minute.")
                ForEach(prefs.neverSaveLoginHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "Never ask to save")
                        Button { prefs.neverSaveLoginHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Pop-ups") {
                Caption(text: "Pop-ups that a site opens without a click are blocked, and you’re told about it over the page. Sites you chose “Always allow for this site” on stay here.")
                ForEach(prefs.popupHosts, id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        Caption(text: "Pop-ups allowed")
                        Button { prefs.popupHosts.removeAll { $0 == host } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Camera & Microphone") {
                if permissions.stored.isEmpty {
                    Caption(text: "Sites ask the first time they request access. If you choose “Remember”, they stay here.")
                }
                ForEach(permissions.stored.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host).lineLimit(1)
                        Spacer()
                        ForEach(SitePermissions.Device.allCases, id: \.self) { device in
                            Picker(device.name, selection: Binding(get: { permissions.decision(host, device) },
                                                                   set: { permissions.set($0, host: host, device: device) })) {
                                ForEach(SitePermissions.Decision.allCases, id: \.self) { Text($0.name).tag($0) }
                            }
                            .fixedSize()
                        }
                        Button { permissions.forget(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { passwordCount = Logins.all().count }
        .sheet(isPresented: $showPasswords, onDismiss: { passwordCount = Logins.all().count }) { PasswordsSheet() }
    }

    private func clear() {
        let since = range.since
        var done: [String] = []
        if clearHistory {
            let removed = Library.shared.clearHistory(since: since)
            done.append(removed == 1 ? String(localized: "\(removed) history item") : String(localized: "\(removed) history items"))
            // Remembered zoom sizes and closed windows name the sites too.
            if range == .all { prefs.siteZoom = [:] }
            Browser.closedWindows = []
            // The start page's "Continue viewing" lists the closed tabs with their titles and addresses.
            for browser in Browser.all { browser.removeClosedTabs(since: since) }
            // The tab archive names the sites too, and so do the icons cached for them.
            TabArchive.shared.remove(since: since)
            Task { await Browser.pruneIcons() }
            // What was taken off the start page names sites too.
            StartHiddenItems.shared.showAll()
        }
        if clearSiteData {
            // The kept cookies go first, so a snapshot of cookies about to be erased can't be written after; what the stores keep is written once they are done.
            CookieJournal.shared.clearing()
            let stores = [WKWebsiteDataStore.default()] + Profiles.stores(SpaceStore.shared.spaces)
            Task {
                for store in stores { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: since) }
                CookieJournal.shared.cleared()
            }
            StartHiddenItems.shared.showAll()
            done.append(String(localized: "Site data"))
        }
        cleared = String(localized: "Cleared: \(done.joined(separator: ", "))")
    }
}

struct PasswordsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logins = Logins.all()
    @State private var search = ""
    @State private var unlocked = false
    @State private var copied: String?
    @State private var deleting: Logins.Saved?

    private var shown: [Logins.Saved] {
        let q = search.lowercased()
        return q.isEmpty ? logins : logins.filter { $0.host.lowercased().contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Saved Passwords").font(.headline)
                Spacer()
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            .padding(14)
            List {
                ForEach(shown) { login in
                    HStack {
                        SiteIcon(url: "https://\(login.host)/", size: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(login.host)
                            Text(login.username.isEmpty ? String(localized: "(No username)") : login.username).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if copied == login.id { Text("Copied").font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button("Copy Password") { Task { await copy(login) } }.buttonStyle(.borderless)
                        Button(role: .destructive) { deleting = login } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .overlay { if logins.isEmpty { Text("No saved passwords").foregroundStyle(.secondary) } }
            HStack {
                Caption(text: "Copying requires Touch ID or your Mac password. Passwords are stored only in this Mac’s keychain.")
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 540, height: 440)
        .confirmationDialog("Delete the password for \(deleting?.host ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let login = deleting { Logins.delete(host: login.host, username: login.username) }
                logins = Logins.all()
                deleting = nil
            }
        }
    }

    private func copy(_ login: Logins.Saved) async {
        if !unlocked {
            let context = LAContext()
            unlocked = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(localized: "Authentication is required to copy the saved password"))) == true
        }
        guard unlocked, let password = Logins.password(exactly: login.host, username: login.username) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        copied = login.id
    }
}

struct AdBlockSection: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var blocker = AdBlocker.shared
    @State private var newList = ""

    var body: some View {
        Section("Ad Blocking") {
            Toggle("Block ads and trackers", isOn: $prefs.blockTrackers)
            if prefs.blockTrackers {
                ForEach(blocker.lists) { list in
                    HStack {
                        Toggle(list.name, isOn: Binding(
                            get: { !prefs.disabledFilterLists.contains(list.id) },
                            set: { on in
                                prefs.disabledFilterLists.removeAll { $0 == list.id }
                                if !on { prefs.disabledFilterLists.append(list.id) }
                                Task { await blocker.update() }
                            }))
                        .lineLimit(1)
                        if list.id.hasPrefix("custom-") {
                            Button { prefs.customFilterLists.removeAll { $0 == list.url }; Task { await blocker.recompile() } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                HStack {
                    TextField("Add filter list URL (e.g. a Korean ad list)", text: $newList).onSubmit(addList)
                    Button("Add", action: addList).disabled(URL(string: newList)?.scheme?.hasPrefix("http") != true)
                }
                HStack {
                    Caption(verbatim: [blocker.status, blocker.lastUpdated.map { String(localized: "Last updated \($0.formatted(date: .abbreviated, time: .shortened))") }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    Spacer()
                    if blocker.working { ProgressView().controlSize(.small) }
                    Button("Update Now") { Task { await blocker.update() } }.disabled(blocker.working)
                }
                if !prefs.adBlockAllowlist.isEmpty {
                    ForEach(prefs.adBlockAllowlist, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Text("Not blocked").foregroundStyle(.secondary)
                            Button { blocker.toggleSite(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }
                Caption(text: "Lists are re-downloaded every 4 days. If a site breaks, you can turn blocking off for just that site with the shield button in the address bar.")
            }
        }
    }

    private func addList() {
        let url = newList.trimmingCharacters(in: .whitespaces)
        guard URL(string: url)?.scheme?.hasPrefix("http") == true, !prefs.customFilterLists.contains(url) else { return }
        prefs.customFilterLists.append(url)
        newList = ""
        Task { await blocker.update() }
    }
}
