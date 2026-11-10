import SwiftUI

/// A line under the panel's header that tells what the AI has read in this chat and where it may act without asking, with a list to take
/// that back. Hidden while there is nothing to tell.
struct ReadSitesRow: View {
    @State private var read: [String] = []
    @State private var allowed: [String] = []
    @State private var tabs: [String] = []
    @State private var addresses: [String] = []
    @State private var listed = false

    var body: some View {
        VStack(spacing: 0) {
            if !read.isEmpty || allowedCount > 0 {
                Button { listed.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye").font(.symbolInline)
                        Text(verbatim: summary).font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $listed, arrowEdge: .bottom) {
                    ReadSitesList(read: read, allowed: allowed, tabs: tabs, addresses: addresses)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(Approvals.changes) { refresh() }
    }

    private func refresh() {
        read = Approvals.sitesRead(caller: ChatStore.caller)
        allowed = Approvals.sitesAllowed(caller: ChatStore.caller)
        tabs = Approvals.tabsAllowed(caller: ChatStore.caller)
        addresses = Approvals.addressesAllowed(caller: ChatStore.caller)
    }

    private var allowedCount: Int { allowed.count + tabs.count + addresses.count }

    /// "Read 3 sites · Allowed on 1", with only the part there is something to say of.
    private var summary: String {
        var parts: [String] = []
        if read.count == 1 { parts.append(String(localized: "Read 1 site")) } else if read.count > 1 { parts.append(String(localized: "Read \(read.count) sites")) }
        if allowedCount > 0 { parts.append(String(localized: "\(allowedCount) allowed")) }
        return parts.joined(separator: " · ")
    }
}

private struct ReadSitesList: View {
    let read: [String]
    let allowed: [String]
    /// The tabs the AI may use and the addresses it may open without asking, until a new chat.
    let tabs: [String]
    let addresses: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !allowed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowed for this chat").font(.captionStrong).foregroundStyle(Theme.secondary)
                    ForEach(allowed, id: \.self) { site in
                        row(Approvals.display(site)) { Approvals.revoke(site: site, caller: ChatStore.caller) }
                    }
                    Text("After revoking, the AI asks again before it acts there.").font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if !tabs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tabs it may use").font(.captionStrong).foregroundStyle(Theme.secondary)
                    ForEach(tabs, id: \.self) { key in
                        row(Approvals.describeTab(key)) { Approvals.revoke(tab: key, caller: ChatStore.caller) }
                    }
                }
            }
            if !addresses.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Addresses it may open").font(.captionStrong).foregroundStyle(Theme.secondary)
                    ForEach(addresses, id: \.self) { address in
                        row(Approvals.shown(address, limit: 200).text) { Approvals.revoke(address: address, caller: ChatStore.caller) }
                    }
                }
            }
            if !tabs.isEmpty || !addresses.isEmpty {
                Text("After revoking, the AI asks again before it uses that tab or opens that address. A new chat starts with none of these.")
                    .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !read.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read in this chat").font(.captionStrong).foregroundStyle(Theme.secondary)
                    ForEach(read, id: \.self) { site in
                        Text(verbatim: Approvals.display(site)).font(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
    }

    private func row(_ title: String, revoke: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: title).font(.secondary).lineLimit(1).truncationMode(.middle).help(title)
            Spacer(minLength: 8)
            Button(action: revoke) {
                Text("Revoke").font(.captionStrong).foregroundStyle(Theme.primary)
                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Theme.pill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Revoke \(title)"))
        }
    }
}
