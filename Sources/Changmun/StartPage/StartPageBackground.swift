import AppKit
import ImageIO
import SwiftUI

/// The start page's background and what keeps the text on it readable. The maths is in plain functions (`StartScrim`, `StartSwatch`).

// MARK: Scrim

/// How bright a picture is and how busy: measured once when it is loaded, from a picture of about 32 × 32 cells.
struct StartImageStats: Equatable, Sendable {
    /// The mean relative luminance (0 black … 1 white).
    var luminance: Double
    /// How much neighbouring cells differ in luminance, on average (0 flat … 1 black and white in a checker).
    var contrast: Double

    /// A picture as busy as this is hard to put text on.
    var isBusy: Bool { contrast >= 0.12 }
}

enum StartScrim {
    static let minimum = 0.10
    static let maximum = 0.72
    /// With Reduce Transparency on the picture is not to show through much: the scrim is never thinner than this.
    static let minimumOpaque = 0.30
    /// The shortest side a picture should have not to look soft on a big screen.
    static let sharpEdge = 1600

    /// WCAG's relative luminance of a colour given as sRGB components (0…1).
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// The luminance of every cell of an RGBA picture (8 bits a component, rows `width` pixels long), then their mean and how much neighbours differ.
    static func measure(rgba: [UInt8], width: Int, height: Int) -> StartImageStats {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return StartImageStats(luminance: 0.5, contrast: 0) }
        var cells = [Double](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            cells[index] = relativeLuminance(red: Double(rgba[index * 4]) / 255, green: Double(rgba[index * 4 + 1]) / 255, blue: Double(rgba[index * 4 + 2]) / 255)
        }
        let mean = cells.reduce(0, +) / Double(cells.count)
        var total = 0.0, pairs = 0
        for y in 0..<height {
            for x in 0..<width {
                if x + 1 < width { total += abs(cells[y * width + x] - cells[y * width + x + 1]); pairs += 1 }
                if y + 1 < height { total += abs(cells[y * width + x] - cells[(y + 1) * width + x]); pairs += 1 }
            }
        }
        return StartImageStats(luminance: mean, contrast: pairs > 0 ? total / Double(pairs) : 0)
    }

    struct Result: Equatable {
        /// How strong the scrim is at its centre, where the text is: 0.10 … 0.72.
        var opacity: Double
        /// Whether that is enough for the text to have the contrast aimed at (4.5 : 1, 7 : 1 with Increase Contrast).
        var reachesTarget: Bool
    }

    /// The scrim a picture needs: the floor colour (white in light mode, near black in dark mode) laid over it until the picture's worst places
    /// (the mean pushed by the busyness towards the text) are far enough from the colour of the secondary text. `dim` is the user's own paling or
    /// dimming, 0…1 of its largest, which counts already.
    static func scrim(stats: StartImageStats, dark: Bool, dim: Double = 0, highContrast: Bool = false, reduceTransparency: Bool = false) -> Result {
        let ratio = highContrast ? 7.0 : 4.5
        let spread = min(0.5, 2.5 * stats.contrast)
        let floor = dark ? 0.005 : 1.0
        let text = dark ? (highContrast ? 0.75 : 0.33) : (highContrast ? 0.045 : 0.13)
        var worst = dark ? min(1, stats.luminance + spread) : max(0, stats.luminance - spread)
        let manual = min(max(dim, 0), 1) * Self.manualDimMaximum
        worst = (1 - manual) * worst + manual * floor
        let needed: Double
        if dark {
            // The picture's bright places must be as dark as this for the light text to read.
            let target = (text + 0.05) / ratio - 0.05
            needed = worst <= target ? 0 : (worst - target) / (worst - floor)
        } else {
            let target = ratio * (text + 0.05) - 0.05
            needed = worst >= target ? 0 : (target - worst) / (floor - worst)
        }
        let lowest = reduceTransparency ? minimumOpaque : minimum
        return Result(opacity: min(max(needed, lowest), maximum), reachesTarget: needed <= maximum + 0.0001)
    }

    /// How strong the user's own dimming (the slider's end) is.
    static let manualDimMaximum = 0.6
}

// MARK: Colours

enum StartSwatch {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color { Color(red: red, green: green, blue: blue) }

        func mixed(with other: RGB, _ share: Double) -> RGB {
            RGB(red: red * (1 - share) + other.red * share, green: green * (1 - share) + other.green * share, blue: blue * (1 - share) + other.blue * share)
        }
    }

    private static func rgb(_ hex: UInt32) -> RGB {
        RGB(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Each of `StartBackground.swatches`: a pale tone for light mode and a deep one for dark mode.
    private static let tones: [String: (light: UInt32, dark: UInt32)] = [
        "slate": (0xE4E8EE, 0x23272D), "blue": (0xD9E6F8, 0x1B2A40), "coral": (0xFBE1D9, 0x3A2420), "green": (0xDCEFE3, 0x1C3326),
        "purple": (0xE8E0F8, 0x2D2442), "amber": (0xF8ECD0, 0x3A3018), "teal": (0xD6EEEE, 0x17343A), "pink": (0xF8DFE9, 0x3B2230),
    ]

    static func tone(_ id: String, dark: Bool) -> RGB? {
        tones[id].map { rgb(dark ? $0.dark : $0.light) }
    }

    /// "#RRGGBB" (the # is optional), or nil.
    static func parseHex(_ text: String) -> RGB? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return rgb(value)
    }

    static func hex(of color: RGB) -> String {
        func part(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", part(color.red), part(color.green), part(color.blue))
    }

    /// A colour of the user's own, made pale for light mode and deep for dark mode.
    static func tone(hex text: String, dark: Bool) -> RGB? {
        parseHex(text).map { dark ? $0.mixed(with: RGB(red: 0, green: 0, blue: 0), 0.7) : $0.mixed(with: RGB(red: 1, green: 1, blue: 1), 0.8) }
    }

    /// The colour of the page for a background of kind `.color`; the slate for one that can't be read.
    static func page(_ background: StartBackground, dark: Bool) -> RGB {
        if background.colorID == "custom", let custom = background.customHex, let tone = tone(hex: custom, dark: dark) { return tone }
        return tone(background.colorID, dark: dark) ?? tone("slate", dark: dark)!
    }
}

// MARK: Pictures

/// A background picture as it is shown: decoded for the size of the view, with what was measured of it.
struct StartLoadedImage: @unchecked Sendable {
    var image: CGImage
    var stats: StartImageStats
    /// The pixels of the copy on disk, for "the picture is small".
    var pixelSize: CGSize

    var isSmall: Bool { min(pixelSize.width, pixelSize.height) < CGFloat(StartScrim.sharpEdge) }
}

enum StartImageLoader {
    private static let cache = NSCache<NSString, Box>()

    private final class Box {
        let loaded: StartLoadedImage
        init(_ loaded: StartLoadedImage) { self.loaded = loaded }
    }

    /// The copy of the picture shown at about `maxPixel` on its longer side (a cached decode when it was shown so before), or nil if the file is
    /// gone or isn't a picture. Decoded and measured off the main thread.
    static func load(file: String?, maxPixel: Int) async -> StartLoadedImage? {
        guard let url = StartPageFiles.imageURL(file) else { return nil }
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bucket = max(1, (maxPixel + 399) / 400) * 400
        let key = "\(url.lastPathComponent)|\(stamp)|\(bucket)" as NSString
        if let cached = cache.object(forKey: key) { return cached.loaded }
        let loaded = await Task.detached(priority: .userInitiated) { decode(url, maxPixel: min(bucket, 3000)) }.value
        if let loaded { cache.setObject(Box(loaded), forKey: key) }
        return loaded
    }

    private static func decode(_ url: URL, maxPixel: Int) -> StartLoadedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        func thumbnail(_ side: Int) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary)
        }
        guard let image = thumbnail(maxPixel), let small = thumbnail(32) else { return nil }
        let w = small.width, h = small.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(small, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return StartLoadedImage(image: image, stats: StartScrim.measure(rgba: pixels, width: w, height: h), pixelSize: CGSize(width: width, height: height))
    }
}

// MARK: View

/// Whether what is drawn on the page sits on a picture (the cards, the search field and the chips are then glass plates).
private struct StartOnImageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var startOnImage: Bool {
        get { self[StartOnImageKey.self] }
        set { self[StartOnImageKey.self] = newValue }
    }
}

struct StartBackgroundView: View {
    let background: StartBackground
    let tint: SpaceTint
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var loaded: StartLoadedImage?

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.card
            switch background.kind {
            case .spaceGlow: glow(dark: dark)
            case .plain, .none: EmptyView()
            case .color: StartSwatch.page(background, dark: dark).color
            case .image:
                if let loaded { picture(loaded, dark: dark) } else { glow(dark: dark) }
            }
        }
        .accessibilityHidden(true)
        .background {
            GeometryReader { geo in
                Color.clear.task(id: ImageRequest(file: background.kind == .image ? background.imageFile : nil, side: Int(max(geo.size.width, geo.size.height)))) {
                    await reload(side: Int(max(geo.size.width, geo.size.height)))
                }
            }
        }
    }

    private struct ImageRequest: Equatable {
        var file: String?
        var side: Int
    }

    private func reload(side: Int) async {
        guard background.kind == .image, let file = background.imageFile else { loaded = nil; return }
        let scale = Int((NSScreen.main?.backingScaleFactor ?? 2).rounded(.up))
        let image = await StartImageLoader.load(file: file, maxPixel: max(400, side) * scale)
        guard !Task.isCancelled else { return }
        loaded = image
    }

    /// The space's colour as a soft glow from the top of the page: the same in light and dark, a little stronger in dark.
    private func glow(dark: Bool) -> some View {
        GeometryReader { geo in
            RadialGradient(colors: [tint.color.opacity(dark ? 0.30 : 0.24), tint.color.opacity(0)], center: .top,
                           startRadius: 0, endRadius: max(geo.size.width * 0.5, 1))
                .frame(height: min(geo.size.height, 460))
                .scaleEffect(x: 1.25, y: 1, anchor: .top)
        }
    }

    private func picture(_ loaded: StartLoadedImage, dark: Bool) -> some View {
        let floor = dark ? Color(white: 0.02) : Color.white
        let scrim = StartScrim.scrim(stats: loaded.stats, dark: dark, dim: background.dim, highContrast: contrast == .increased, reduceTransparency: reduceTransparency)
        return GeometryReader { geo in
            ZStack {
                Image(decorative: loaded.image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .blur(radius: background.blur * 40, opaque: true)
                    .clipped()
                floor.opacity(background.dim * StartScrim.manualDimMaximum)
                RadialGradient(colors: [floor.opacity(scrim.opacity), floor.opacity(scrim.opacity * 0.75)], center: .center,
                               startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.7)
            }
        }
        .clipped()
    }
}

/// What a plate is for the things drawn over a picture: glass (a material, with an edge), or opaque when Reduce Transparency is on.
struct StartPlate: ViewModifier {
    var radius: CGFloat
    var fill: Color = Theme.ink(0.045)
    var raised = false
    @Environment(\.startOnImage) private var onImage
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            if onImage {
                if reduceTransparency {
                    shape.fill(Theme.card)
                } else {
                    shape.fill(.regularMaterial)
                }
            } else {
                shape.fill(fill)
            }
        }
        .overlay { shape.strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
        .shadow(color: raised ? Theme.cardShadow : .clear, radius: raised ? 6 : 0, y: raised ? 2 : 0)
    }
}

extension View {
    func startPlate(radius: CGFloat, fill: Color = Theme.ink(0.045), raised: Bool = false) -> some View {
        modifier(StartPlate(radius: radius, fill: fill, raised: raised))
    }
}

/// The rows of a section over a picture sit on one plate, as the cards do.
struct StartGroupPlate: ViewModifier {
    @Environment(\.startOnImage) private var onImage

    @ViewBuilder func body(content: Content) -> some View {
        if onImage { content.padding(6).startPlate(radius: 12) } else { content }
    }
}

/// Text that stands straight on a picture (a heading, a tile's name) gets a soft halo of the page's colour.
struct StartHalo: ViewModifier {
    @Environment(\.startOnImage) private var onImage

    func body(content: Content) -> some View {
        content.shadow(color: onImage ? Theme.card.opacity(0.85) : .clear, radius: onImage ? 3 : 0)
    }
}

extension View {
    func startGroupPlate() -> some View { modifier(StartGroupPlate()) }
    func startHalo() -> some View { modifier(StartHalo()) }
}
