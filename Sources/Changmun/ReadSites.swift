import SwiftUI

/// A line under the panel's header that tells what the AI has read in this chat and where it may act without asking, with a list to take
/// that back. Hidden while there is nothing to tell.
struct ReadSitesRow: View {
    @State private var read: [String] = []
    @State private var allowed: [String] = []
    @State private var listed = false

    var body: some View {
        VStack(spacing: 0) {
            if !read.isEmpty || !allowed.isEmpty {
                Button { listed.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "eye").font(.system(size: 9.5, weight: .semibold))
                        Text(verbatim: summary).font(.system(size: 10.5, weight: .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $listed, arrowEdge: .bottom) {
                    ReadSitesList(read: read, allowed: allowed)
                }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(Approvals.changes) { refresh() }
    }

    private func refresh() {
        read = Approvals.sitesRead(caller: ChatStore.caller)
        allowed = Approvals.sitesAllowed(caller: ChatStore.caller)
    }

    /// "Read 3 sites · Allowed on 1", with only the part there is something to say of.
    private var summary: String {
        var parts: [String] = []
        if read.count == 1 { parts.append(String(localized: "Read 1 site")) } else if read.count > 1 { parts.append(String(localized: "Read \(read.count) sites")) }
        if !allowed.isEmpty { parts.append(String(localized: "Allowed on \(allowed.count)")) }
        return parts.joined(separator: " · ")
    }
}

private struct ReadSitesList: View {
    let read: [String]
    let allowed: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !allowed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allowed for this chat").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    ForEach(allowed, id: \.self) { site in
                        HStack(spacing: 8) {
                            Text(verbatim: Approvals.display(site)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button { Approvals.revoke(site: site, caller: ChatStore.caller) } label: {
                                Text("Revoke").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
                                    .padding(.horizontal, 8).frame(height: 20).background(Capsule().fill(Theme.pill))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("After revoking, the AI asks again before it acts there.").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
                }
            }
            if !read.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read in this chat").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                    ForEach(read, id: \.self) { site in
                        Text(verbatim: Approvals.display(site)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }
}
