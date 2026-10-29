import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes the copy of the picture the user chose for the start page's background: an untrusted file turned into one shrunk JPEG with nothing of the
/// original in it (no metadata, no name, no path), written into the app's own folder. Pure file work with no state, so it runs off the main thread.
enum StartPageImage {
    /// Largest file, in bytes, and largest picture, in pixels, that are looked at at all.
    static let maxFileBytes = 100 * 1024 * 1024
    static let maxPixels = 100_000_000
    /// The long edge of the copy, in pixels.
    static let maxLongEdge = 3840
    static let quality = 0.85
    /// Every file the page keeps in its folder starts like this; nothing else in the folder is touched.
    static let filePrefix = "background-"

    enum Failure: Error, Equatable {
        case unreadable, notAnImage, tooLarge, undecodable, notSaved
    }

    /// The file name of the new copy in `folder`, made from the picture at `source`.
    static func importPicture(from source: URL, into folder: URL, maxFileBytes: Int = maxFileBytes, maxPixels: Int = maxPixels,
                              maxLongEdge: Int = maxLongEdge) throws -> String {
        let data = try read(source, limit: maxFileBytes)
        let jpeg = try reencode(data, maxPixels: maxPixels, maxLongEdge: maxLongEdge)
        try prepare(folder)
        let name = filePrefix + UUID().uuidString + ".jpg"
        // A temporary file made private from the start, then renamed: a copy is whole or not there, and never readable by others.
        guard DurableFile.write(jpeg, to: folder.appendingPathComponent(name)) else { throw Failure.notSaved }
        return name
    }

    /// The file's bytes, read through one descriptor that is checked after it is open: what it names then is the thing read, whatever a link
    /// pointed at before (a symbolic link to a picture is fine, a pipe, a device or a folder is not), and no more than `limit` bytes are taken.
    static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw Failure.notAnImage }
        guard info.st_size > 0, info.st_size <= limit else { throw Failure.tooLarge }
        var data = Data(count: Int(info.st_size))
        var done = 0
        let complete = data.withUnsafeMutableBytes { buffer -> Bool in
            while done < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress! + done, buffer.count - done)
                if count <= 0 { return false }
                done += count
            }
            return true
        }
        // A file that shrank while it was read is not the one that was looked at.
        guard complete else { throw Failure.unreadable }
        return data
    }

    /// The first frame of the picture, upright, at most `maxLongEdge` on its long side, as JPEG bytes without any of the original's properties.
    static func reencode(_ data: Data, maxPixels: Int = maxPixels, maxLongEdge: Int = maxLongEdge) throws -> Data {
        let options = [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }), type.conforms(to: .image) else { throw Failure.notAnImage }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.undecodable }
        guard width <= maxPixels / height else { throw Failure.tooLarge }
        // The orientation the photo was taken with is applied to the pixels, since the property saying so is not kept. Smaller pictures are not
        // scaled up: asking for a thumbnail size would do that.
        var thumbnail: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                          kCGImageSourceShouldCacheImmediately: true]
        if max(width, height) > maxLongEdge { thumbnail[kCGImageSourceThumbnailMaxPixelSize] = maxLongEdge }
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.undecodable }
        image = flattened(image)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.notSaved }
        // Only the quality is given: no EXIF, GPS, maker notes, orientation, title or any other property goes with the picture.
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notSaved }
        return output as Data
    }

    /// JPEG has no transparency: a picture with some is put on white, as it would look on paper, rather than going black where it is clear.
    private static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// The folder exists, only its owner can open it, and a backup leaves it out.
    static func prepare(_ folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var folder = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }

    /// Takes away the copies in `folder` that the settings don't name (`keeping`), and the temporary files an interrupted write left (DurableFile names them after the copy).
    @discardableResult
    static func removeOrphans(in folder: URL, keeping: Set<String>) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var removed = 0
        for name in files where (name.hasPrefix(filePrefix) || name.hasPrefix("." + filePrefix)) && !keeping.contains(name) {
            if (try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }
}
