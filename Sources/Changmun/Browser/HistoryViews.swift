import AppKit
import SwiftUI

// MARK: History

struct HistoryView: View {
    @State private var search = ""
    @State private var visits: [Library.Visit] = []

    private var days: [(day: Date, visits: [Library.Visit])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visits) { calendar.startOfDay(for: $0.lastVisit) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search History", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List {
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(.dateTime.year().month().day().weekday(.wide))) {
                        ForEach(day.visits) { visit in
                            HistoryRow(visit: visit)
                                .contextMenu {
                                    Button("Open in New Tab") { open(visit) }
                                    Button("Copy Address") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(visit.url, forType: .string)
                                    }
                                    Divider()
                                    Button("Remove from History") {
                                        Library.shared.deleteHistory(url: visit.url)
                                        reload()
                                    }
                                }
                                .onTapGesture(count: 2) { open(visit) }
                        }
                    }
                }
            }
            .overlay { if visits.isEmpty { Text(search.isEmpty ? String(localized: "No history") : String(localized: "No matching history")).foregroundStyle(.secondary) } }
            HStack {
                Text("Double-click to open in a new tab. To clear history by time range, go to Settings › Privacy.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .frame(minWidth: 520, minHeight: 360)
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onReceive(NotificationCenter.default.publisher(for: Library.didChange)) { _ in reload() }
    }

    private func reload() {
        visits = Library.shared.history(matching: search, limit: 1000)
    }

    private func open(_ visit: Library.Visit) {
        let browser = Browser.recent ?? BrowserWindow.open()
        browser.openBookmark(visit.url, key: nil)
        browser.window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: Archive

struct ArchiveView: View {
    @ObservedObject private var archive = TabArchive.shared
    @State private var search = ""

    var body: some View {
        let entries = archive.matching(search)
        VStack(spacing: 0) {
            TextField("Search Archived Tabs", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            List(entries) { entry in
                ArchiveRow(entry: entry)
                    .contextMenu {
                        Button("Reopen") { open(entry) }
                        Button("Copy Address") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.url, forType: .string)
                        }
                        Divider()
                        Button("Remove from Archive") { archive.remove(entry.id) }
                    }
                    .onTapGesture(count: 2) { open(entry) }
            }
            .overlay {
                if entries.isEmpty { Text(search.isEmpty ? String(localized: "No archived tabs") : String(localized: "No matching tabs")).foregroundStyle(.secondary) }
            }
            HStack {
                Text("Double-click to reopen. Set how long until tabs are archived in Settings › Tabs.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { archive.removeAll() }.disabled(archive.entries.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 460, minHeight: 320)
    }

    private func open(_ entry: TabArchive.Entry) {
        let browser = Browser.recent ?? BrowserWindow.open()
        browser.reopen(entry)
        browser.window?.makeKeyAndOrderFront(nil)
    }
}

struct ArchiveRow: View {
    let entry: TabArchive.Entry

    var body: some View {
        HStack(spacing: 10) {
            SiteIcon(url: entry.url, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title.isEmpty ? entry.url : entry.title).lineLimit(1)
                Text([URL(string: entry.url)?.host(), entry.group].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(entry.archived.formatted(.relative(presentation: .named)))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(entry.url)
    }
}

struct HistoryRow: View {
    let visit: Library.Visit

    var body: some View {
        HStack(spacing: 10) {
            Text(visit.lastVisit.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            SiteIcon(url: visit.url, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? visit.url : visit.title).lineLimit(1)
                Text(URL(string: visit.url)?.host() ?? visit.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .help(visit.url)
    }
}
