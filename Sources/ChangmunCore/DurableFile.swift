import Foundation

/// Helpers for the files that hold what the user would miss: reading them, keeping a copy of a damaged one, writing them whole.
package enum DurableFile {
    /// What reading a data file gave: nothing yet, its bytes, or an error (permissions, a disk fault) that says nothing about what it holds.
    package enum FileRead {
        case missing, unreadable
        case data(Data)

        package init(_ file: URL) {
            do {
                self = .data(try Data(contentsOf: file))
            } catch {
                let nsError = error as NSError
                self = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError ? .missing : .unreadable
            }
        }
    }

    /// Copies a file that couldn't be read whole to "<name>-damaged-<time>.<ext>" beside it, so starting over never costs what it held.
    /// The same damage found again at the next launch is not copied again, and only the newest `damagedCopies` copies are kept.
    /// Returns whether a copy of it is there.
    package static func keepDamaged(_ file: URL) -> Bool {
        let manager = FileManager.default
        let folder = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        /// The copies beside it, oldest first: by the time in the name, then by the number after it.
        func copies() -> [(order: [Int], url: URL)] {
            var found: [(order: [Int], url: URL)] = []
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("\(stem)-damaged-") && name.hasSuffix(suffix) {
                let parts = name.dropFirst("\(stem)-damaged-".count).dropLast(suffix.count).split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
                if (1...2).contains(parts.count), !parts.contains(nil) { found.append((parts.compactMap { $0 }, folder.appendingPathComponent(name))) }
            }
            return found.sorted { $0.order.lexicographicallyPrecedes($1.order) }
        }
        let damaged = try? Data(contentsOf: file)
        if let damaged, copies().contains(where: { (try? Data(contentsOf: $0.url)) == damaged }) { return true }
        // Named after the newest copy there is, so a copy never takes the place (and the age) of an older one that was pruned.
        var time = Int(Date().timeIntervalSince1970), attempt = 0
        if let last = copies().last?.order, last[0] >= time {
            time = last[0]
            attempt = (last.count > 1 ? last[1] : 0) + 1
        }
        let copy = folder.appendingPathComponent("\(stem)-damaged-\(time)" + (attempt == 0 ? "" : "-\(attempt)") + suffix)
        guard (try? manager.copyItem(at: file, to: copy)) != nil else { return false }
        for old in copies().dropLast(damagedCopies) { try? manager.removeItem(at: old.url) }
        return true
    }

    package static let damagedCopies = 3

    /// Decodes what it can: a value that doesn't decode becomes nil instead of failing everything around it.
    package struct Lossy<Value: Decodable>: Decodable {
        package let value: Value?
        package init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Opens a new file for writing with mode 0600 from the start, refusing to follow a link or to reuse a name.
    /// Returns its descriptor (the caller closes it), or nil when it couldn't be made.
    package static func createPrivate(at file: URL) -> Int32? {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        return descriptor >= 0 ? descriptor : nil
    }

    /// Writes the file so that it is never readable by anyone else, not even for a moment: a temporary file in the same folder made with
    /// mode 0600 (and refusing to follow a link or to reuse a name), then renamed over the old one.
    package static func write(_ data: Data, to file: URL) -> Bool {
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        guard let descriptor = createPrivate(at: temporary) else { return false }
        var written = 0
        let ok = data.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                if count < 0 { return false }
                written += count
            }
            return true
        }
        let closed = close(descriptor) == 0
        guard ok, closed, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        return true
    }

    /// A write that was cut short (the app quit in the middle of it) leaves its temporary file behind: it holds the data, so it goes.
    package static func removeStaleTemporaries(beside file: URL) {
        let folder = file.deletingLastPathComponent(), prefix = ".\(file.lastPathComponent)."
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            unlink(folder.appendingPathComponent(name).path)
        }
    }
}
