import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Changmun

@MainActor @Suite(.serialized)
struct StartPageImageTests {
    /// A folder of its own for the picture, and one for the pictures to choose from.
    private final class Place {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("start-image-\(UUID().uuidString)", isDirectory: true)
        var folder: URL { root.appendingPathComponent("StartPage", isDirectory: true) }
        var source: URL { root.appendingPathComponent("from", isDirectory: true) }
        init() { try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: root) }
        var copies: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() }
    }

    private func store(_ place: Place, undo: Duration = .seconds(10)) -> StartPageStore {
        StartPageStore(defaults: UserDefaults(suiteName: "start-image-\(UUID().uuidString)")!, folder: place.folder, undoWindow: undo)
    }

    private static let marker = "SECRET-CAMERA-9000"

    /// A picture of flat colour bands (or noise) with the metadata a phone would put in: orientation, GPS, make and model, a comment.
    private func picture(width: Int, height: Int, type: UTType = .jpeg, orientation: Int = 1, noise: Bool = false, color: (UInt8, UInt8, UInt8) = (200, 60, 40),
                         alpha: Bool = false) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
        let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var seed: UInt64 = 42
        for i in 0..<(width * height) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let n = UInt8(truncatingIfNeeded: seed >> 56)
            pixels[i * 4] = noise ? n : color.0
            pixels[i * 4 + 1] = noise ? n &* 3 : color.1
            pixels[i * 4 + 2] = noise ? n &* 7 : color.2
            pixels[i * 4 + 3] = alpha ? (i % width < width / 2 ? 0 : 255) : 255
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLongitude: 127.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: Self.marker, kCGImagePropertyTIFFModel: Self.marker, kCGImagePropertyTIFFSoftware: Self.marker],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: Self.marker, kCGImagePropertyExifLensModel: Self.marker],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: Self.marker],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    private func save(_ data: Data, as name: String, in place: Place) -> URL {
        let url = place.source.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private func properties(of url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    @Test func theProductionFolderIsInsideTheAppsDataFolder() {
        #expect(StartPageFiles.folder() == Library.folder.appendingPathComponent("StartPage", isDirectory: true))
    }

    // MARK: The copy

    @Test func aPhotoIsShrunkToTheLimitAndKeepsItsLookAndShape() async throws {
        let place = Place()
        let s = store(place)
        let url = save(picture(width: 6000, height: 4000, color: (200, 60, 40)), as: "photo.jpg", in: place)
        #expect(await s.chooseImage(from: url))
        let name = try #require(s.settings.background.imageFile)
        let result = properties(of: try #require(s.imageURL(name)))
        #expect(result[kCGImagePropertyPixelWidth] as? Int == 3840 && result[kCGImagePropertyPixelHeight] as? Int == 2560)
        #expect(s.settings.background.kind == .image)
        #expect(name.hasPrefix("background-") && name.hasSuffix(".jpg") && !name.contains("photo"), "named by us, never by the original")
        #expect(place.copies == [name])
    }

    @Test func aSmallPictureIsNotScaledUp() async throws {
        let place = Place()
        let s = store(place)
        #expect(await s.chooseImage(from: save(picture(width: 800, height: 500), as: "small.jpg", in: place)))
        let result = properties(of: try #require(s.imageURL(s.settings.background.imageFile)))
        #expect(result[kCGImagePropertyPixelWidth] as? Int == 800 && result[kCGImagePropertyPixelHeight] as? Int == 500)
    }

    @Test func everyKindOfMetadataIsLeftOut() async throws {
        let place = Place()
        let s = store(place)
        let original = save(picture(width: 640, height: 480), as: "gps.jpg", in: place)
        let before = properties(of: original)
        #expect(before[kCGImagePropertyGPSDictionary] != nil && before[kCGImagePropertyIPTCDictionary] != nil, "the test picture carries what a phone's does")
        #expect(await s.chooseImage(from: original))
        let copy = try #require(s.imageURL(s.settings.background.imageFile))
        let after = properties(of: copy)
        #expect(after[kCGImagePropertyGPSDictionary] == nil && after[kCGImagePropertyIPTCDictionary] == nil && after[kCGImagePropertyMakerAppleDictionary] == nil)
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFSoftware, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFOrientation] { #expect(tiff[key] == nil) }
        for key in [kCGImagePropertyExifUserComment, kCGImagePropertyExifLensModel, kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifMakerNote] { #expect(exif[key] == nil) }
        #expect((after[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let bytes = try Data(contentsOf: copy)
        #expect(bytes.range(of: Data(Self.marker.utf8)) == nil, "not a trace of it anywhere in the file")
        #expect(bytes.range(of: Data("Exif".utf8)) == nil || (exif[kCGImagePropertyExifUserComment] == nil))
    }

    @Test func thePhotosOrientationIsAppliedToThePixels() async throws {
        let place = Place()
        let s = store(place)
        // Stored 400 wide and 200 high, marked as turned a quarter: it shows 200 wide and 400 high.
        #expect(await s.chooseImage(from: save(picture(width: 400, height: 200, orientation: 6), as: "turned.jpg", in: place)))
        let result = properties(of: try #require(s.imageURL(s.settings.background.imageFile)))
        #expect(result[kCGImagePropertyPixelWidth] as? Int == 200 && result[kCGImagePropertyPixelHeight] as? Int == 400)
    }

    @Test func anAnimatedPictureGivesItsFirstFrame() async throws {
        let place = Place()
        let s = store(place)
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, 2, nil)!
        for color in [(255, 0, 0), (0, 0, 255)] as [(Int, Int, Int)] {
            let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255, blue: CGFloat(color.2) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        }
        CGImageDestinationFinalize(destination)
        #expect(await s.chooseImage(from: save(out as Data, as: "moving.gif", in: place)))
        let file = try #require(s.imageURL(s.settings.background.imageFile))
        let copy = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        #expect(CGImageSourceGetCount(copy) == 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(copy, 0, nil))
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = context.data!.bindMemory(to: UInt8.self, capacity: 4)
        #expect(pixel[0] > 200 && pixel[2] < 60, "red, the first frame")
    }

    @Test func aPictureWithClearPartsIsPutOnWhiteNotBlack() async throws {
        let place = Place()
        let s = store(place)
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100, type: .png, alpha: true), as: "clear.png", in: place)))
        let file = try #require(s.imageURL(s.settings.background.imageFile))
        let copy = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(copy, 0, nil))
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixel = context.data!.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        #expect(pixel[(50 * image.width + 5) * 4] > 240, "the clear half is white")
    }

    // MARK: What is refused

    @Test func whatIsNotAUsablePictureIsRefusedAndChangesNothing() async throws {
        let place = Place()
        let s = store(place)
        let good = save(picture(width: 100, height: 100), as: "good.jpg", in: place)
        #expect(await s.chooseImage(from: good))
        let kept = s.settings
        let keptCopies = place.copies
        let text = save(Data("not a picture, just words".utf8), as: "words.jpg", in: place)
        let empty = save(Data(), as: "empty.png", in: place)
        // A header and then nothing that decodes.
        let junk = save(Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x41, count: 64), as: "junk.jpg", in: place)
        let folderPath = place.source.appendingPathComponent("folder.png")
        try FileManager.default.createDirectory(at: folderPath, withIntermediateDirectories: true)
        let missing = place.source.appendingPathComponent("missing.jpg")
        for url in [text, empty, junk, folderPath, missing] { #expect(await s.chooseImage(from: url) == false, "\(url.lastPathComponent)") }
        #expect(s.settings == kept && place.copies == keptCopies, "nothing changed, nothing left behind")
    }

    @Test func aPipeIsRefusedWithoutWaitingForIt() async throws {
        let place = Place()
        let s = store(place)
        let pipe = place.source.appendingPathComponent("pipe.jpg")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(await s.chooseImage(from: pipe) == false)
    }

    @Test func tooLargeInputsAreRefusedByBytesAndByPixels() throws {
        let place = Place()
        let data = picture(width: 100, height: 100)
        let url = save(data, as: "limits.jpg", in: place)
        #expect(throws: StartPageImage.Failure.tooLarge) { try StartPageImage.importPicture(from: url, into: place.folder, maxFileBytes: data.count - 1) }
        #expect(throws: StartPageImage.Failure.tooLarge) { try StartPageImage.importPicture(from: url, into: place.folder, maxPixels: 99 * 100) }
        #expect(throws: Never.self) { try StartPageImage.importPicture(from: url, into: place.folder, maxFileBytes: data.count, maxPixels: 100 * 100) }
        #expect(StartPageImage.maxFileBytes == 100 * 1024 * 1024 && StartPageImage.maxPixels == 100_000_000 && StartPageImage.maxLongEdge == 3840)
    }

    @Test func aLinkToAPictureIsReadThroughButNotAFolder() async throws {
        let place = Place()
        let s = store(place)
        let real = save(picture(width: 120, height: 80), as: "real.jpg", in: place)
        let link = place.source.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(await s.chooseImage(from: link))
        let folderLink = place.source.appendingPathComponent("folderlink.jpg")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: place.source)
        #expect(await s.chooseImage(from: folderLink) == false)
    }

    // MARK: The files

    @Test func theFolderAndTheCopyAreOnlyTheOwners() async throws {
        let place = Place()
        let s = store(place)
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "p.jpg", in: place)))
        func mode(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? -1) & 0o777 }
        #expect(mode(place.folder) == 0o700)
        #expect(mode(try #require(s.imageURL(s.settings.background.imageFile))) == 0o600)
        #expect(try place.folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // A folder that was there already, open to others, is closed.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: place.folder.path)
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "q.jpg", in: place)))
        #expect(mode(place.folder) == 0o700)
    }

    @Test func choosingAgainReplacesTheCopyAndDeletesTheOneBefore() async throws {
        let place = Place()
        let s = store(place)
        s.setBackground(StartBackground(kind: .spaceGlow, blur: 0.3, dim: 0.7))
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "a.jpg", in: place)))
        let first = try #require(s.settings.background.imageFile)
        #expect(await s.chooseImage(from: save(picture(width: 120, height: 100), as: "b.jpg", in: place)))
        let second = try #require(s.settings.background.imageFile)
        #expect(first != second && place.copies == [second], "one copy at a time")
        #expect(s.settings.background.blur == 0.3 && s.settings.background.dim == 0.7 && s.settings.background.kind == .image, "blur and dim stay")
    }

    @Test func aResetKeepsTheCopyForTheUndoWindowAndThenDeletesIt() async throws {
        let place = Place()
        let s = store(place, undo: .milliseconds(300))
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "a.jpg", in: place)))
        let name = try #require(s.settings.background.imageFile)
        let before = s.reset()
        #expect(s.settings.background.imageFile == nil && place.copies == [name], "still there for Undo")
        s.restore(before)
        try await Task.sleep(for: .milliseconds(600))
        #expect(s.settings.background.imageFile == name && place.copies == [name], "an Undo keeps it for good")
        _ = s.reset()
        try await Task.sleep(for: .milliseconds(600))
        #expect(place.copies.isEmpty, "gone once the window is over")
    }

    @Test func anUndoAfterTheWindowGoesWithoutAPictureThatIsGone() async throws {
        let place = Place()
        let s = store(place, undo: .milliseconds(50))
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "a.jpg", in: place)))
        let before = s.reset()
        try await Task.sleep(for: .milliseconds(400))
        s.restore(before)
        #expect(s.settings.background.imageFile == nil && s.settings.background.kind != .image)
    }

    @Test func stoppingUsingThePictureAlsoLetsItGoAfterTheWindow() async throws {
        let place = Place()
        let s = store(place, undo: .milliseconds(50))
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "a.jpg", in: place)))
        s.setBackground(StartBackground(kind: .color))
        try await Task.sleep(for: .milliseconds(400))
        #expect(place.copies.isEmpty)
    }

    @Test func aLaunchRemovesWhatNothingNamesAndKeepsWhatIsInUse() async throws {
        let place = Place()
        let s = store(place)
        #expect(await s.chooseImage(from: save(picture(width: 100, height: 100), as: "a.jpg", in: place)))
        let inUse = try #require(s.settings.background.imageFile)
        for stray in ["background-old.jpg", ".background-x.jpg.1234.tmp"] { try Data("x".utf8).write(to: place.folder.appendingPathComponent(stray)) }
        try Data("mine".utf8).write(to: place.folder.appendingPathComponent("notes.txt"))
        await s.removeOrphanedImages()
        #expect(place.copies == ["notes.txt", inUse].sorted(), "only the page's own files are touched")
        #expect(StartPageImage.removeOrphans(in: place.folder, keeping: []) == 1)
        #expect(place.copies == ["notes.txt"])
    }

    // MARK: Time

    @Test func aTwelveMegapixelPhotoIsDecodedOffTheMainThread() async throws {
        let place = Place()
        let s = store(place)
        let url = save(picture(width: 4000, height: 3000, noise: true), as: "12mp.jpg", in: place)
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0) / 1_000_000
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(5)) }
        }
        let start = ContinuousClock.now
        let ok = await s.chooseImage(from: url)
        let took = ContinuousClock.now - start
        ticker.cancel()
        print("start page image: 12 MP photo (\(size) MB file) imported in \(took), main thread ticked \(ticks) times meanwhile")
        #expect(ok)
        // Had the main thread been held for the whole import, the 5 ms ticker would have stood still.
        let milliseconds = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
        #expect(Double(ticks) > milliseconds / 5 * 0.3, "the main thread kept running (\(ticks) ticks in \(milliseconds) ms)")
    }
}
