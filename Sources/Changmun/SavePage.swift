import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// "Save as PDF" and "Capture Full Page": the whole page, not just what is on screen. Nothing here touches history,
/// the downloads list or the page's site data, so a private window saves the same way.
@MainActor
enum SavePage {
    enum Format {
        case pdf, image

        var type: UTType { self == .pdf ? .pdf : .png }
    }

    /// A longer page is cut off here: a picture taller than this can't be drawn or opened.
    static let maxHeight: CGFloat = 16000
    /// The most pixels a captured picture has, which sets how sharp a big page is drawn.
    static let maxPixels: CGFloat = 40_000_000

    /// Asks where to save, then writes the page there.
    static func save(_ tab: Tab, as format: Format) async {
        guard let webView = tab.webView, let browser = tab.browser, let window = browser.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = filename(title: tab.displayTitle, host: tab.url?.host()) + "." + (format.type.preferredFilenameExtension ?? "")
        panel.directoryURL = Downloads.folder
        let chosen: URL? = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
        }
        guard let url = chosen else { return }
        guard let data = await data(of: webView, as: format) else {
            return browser.flashStatus(String(localized: "Couldn't save the page"))
        }
        do {
            try data.write(to: url)
            browser.flashStatus(String(localized: "Saved \(url.lastPathComponent)"))
        } catch {
            browser.flashStatus(String(localized: "Couldn't save the page"))
        }
    }

    static func data(of webView: WKWebView, as format: Format) async -> Data? {
        let size = await contentSize(of: webView)
        let configuration = WKPDFConfiguration()
        if let size { configuration.rect = CGRect(x: 0, y: 0, width: size.width, height: min(size.height, maxHeight)) }
        let pdf: Data? = await ToolCatalog.withTimeout(seconds: 30, fallback: nil) { finish in
            webView.createPDF(configuration: configuration) { finish(try? $0.get()) }
        }
        guard let pdf else { return nil }
        return format == .pdf ? pdf : png(fromPDF: pdf)
    }

    private static func contentSize(of webView: WKWebView) async -> CGSize? {
        let script = "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
        guard let values = try? await webView.evaluateJavaScript(script) as? [Double], values.count == 2, values[0] > 0, values[1] > 0 else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    /// The PDF's one tall page, drawn on white at up to twice its size.
    static func png(fromPDF data: Data) -> Data? {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        defer { withExtendedLifetime(document) {} }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, (maxPixels / max(bounds.width * bounds.height, 1)).squareRoot())
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// The page's title as a file name, or its site's name when it has none.
    static func filename(title: String, host: String?) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines)).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = String(cleaned.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return name.isEmpty ? (host ?? String(localized: "Page")) : name
    }
}
