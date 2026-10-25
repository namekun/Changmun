import AppKit
import WebKit

extension Browser {
    // MARK: Icons

    /// Hosts whose icon couldn't be found, and when: asked again after an hour, not on every row.
    private static var missingIcons: [String: Date] = [:]
    /// Icons being fetched, so rows showing the same site wait for one request.
    private static var iconLoads: [String: Task<NSImage?, Never>] = [:]

    private static var iconFolder: URL {
        let url = Library.folder.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A site's icon for a page that may not be open, cached on disk by host.
    /// `keep` false (a private window's page) leaves no trace on disk.
    static func icon(for address: String, keep: Bool = true) async -> NSImage? {
        guard let url = URL(string: address), let host = url.host(), let scheme = url.scheme, scheme.hasPrefix("http") else { return nil }
        if let cached = favicons[host] { return cached }
        if let missed = missingIcons[host], missed.timeIntervalSinceNow > -3600 { return nil }
        if let loading = iconLoads[host] { return await loading.value }
        let file = iconFolder.appendingPathComponent(host + ".png")
        if let image = NSImage(contentsOf: file) {
            favicons[host] = image
            return image
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = url.host(percentEncoded: true)
        components.port = url.port
        components.path = "/favicon.ico"
        let session = keep ? URLSession.shared : ephemeral
        let load = Task { () -> NSImage? in
            guard let iconURL = components.url,
                  let (data, response) = try? await session.data(from: iconURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.isValid else { return nil }
            return image
        }
        iconLoads[host] = load
        let image = await load.value
        iconLoads[host] = nil
        guard let image else {
            missingIcons[host] = Date()
            return nil
        }
        missingIcons[host] = nil
        favicons[host] = image
        if keep { storeIcon(image, host: host) }
        return image
    }

    /// Deletes the cached icons of sites that no page, bookmark, tab or archived tab is left from: Clear History, and the history's
    /// year, leave none behind. Which hosts are still in use is `keeping` (lowercase).
    static func pruneIcons(keeping hosts: Set<String>, in folder: URL? = nil) {
        let folder = folder ?? iconFolder
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".png") {
            let host = String(name.dropLast(4))
            guard !hosts.contains(host.lowercased()) else { continue }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        for host in favicons.keys where !hosts.contains(host.lowercased()) { favicons[host] = nil }
    }

    /// The hosts of the open tabs and the archived ones.
    static func hostsInUse(archive: TabArchive? = nil) -> Set<String> {
        let archive = archive ?? .shared
        var hosts = Set(all.flatMap(\.tabs).compactMap { $0.url?.host()?.lowercased() })
        hosts.formUnion(archive.entries.compactMap { URL(string: $0.url)?.host()?.lowercased() })
        return hosts
    }

    /// Prunes the icon cache by what the library, the tabs and the archive still hold. Nothing is pruned when the library can't be read.
    static func pruneIcons(archive: TabArchive? = nil, library: Library? = nil) async {
        let archive = archive ?? .shared, library = library ?? .shared
        guard let known = await library.inBackground({ $0.knownHosts() }) else { return }
        pruneIcons(keeping: known.union(hostsInUse(archive: archive)))
    }

    static func storeIcon(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: iconFolder.appendingPathComponent(host + ".png"))
    }
}
