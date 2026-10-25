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

    /// A larger page is cut off at this height and width: a picture taller than this can't be drawn or opened.
    nonisolated static let maxHeight: CGFloat = 16000
    nonisolated static let maxWidth: CGFloat = 4000
    /// The most pixels a captured picture has, which sets how sharp a big page is drawn.
    nonisolated static let maxPixels: CGFloat = 15_000_000

    /// Asks where to save, then writes the page there.
    static func save(_ tab: Tab, as format: Format) async {
        guard tab.webView != nil, let browser = tab.browser, let window = browser.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = filename(title: tab.displayTitle, host: tab.url?.host()) + "." + (format.type.preferredFilenameExtension ?? "")
        panel.directoryURL = Downloads.folder
        let chosen: URL? = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0 == .OK ? panel.url : nil) }
        }
        guard let url = chosen else { return }
        guard let page = await data(of: tab, as: format) else {
            return browser.flashStatus(String(localized: "Couldn't save the page"))
        }
        do {
            try page.data.write(to: url, options: .atomic)
            let name = url.lastPathComponent
            browser.flashStatus(page.cut ? String(localized: "Saved \(name). The page was too large to fit, so only its top left part is included.") : String(localized: "Saved \(name)"))
        } catch {
            browser.flashStatus(String(localized: "Couldn't save the page"))
        }
    }

    /// The page as a PDF or a picture; `cut` says a page beyond the size limits lost its far edges. A tab showing a PDF
    /// document gives that file itself.
    static func data(of tab: Tab, as format: Format) async -> (data: Data, cut: Bool)? {
        guard let webView = tab.webView else { return nil }
        if tab.showsPDF, format == .pdf, let original = await originalPDF(of: webView) { return (original, false) }
        let size = await contentSize(of: webView)
        let configuration = WKPDFConfiguration()
        if let size { configuration.rect = CGRect(x: 0, y: 0, width: min(size.width, maxWidth), height: min(size.height, maxHeight)) }
        let pdf: Data? = await ToolCatalog.withTimeout(seconds: 30, fallback: nil) { finish in
            webView.createPDF(configuration: configuration) { finish(try? $0.get()) }
        }
        guard let pdf else { return nil }
        let cut = size.map { $0.width > maxWidth || $0.height > maxHeight } ?? false
        if format == .pdf { return (pdf, cut) }
        // Drawing a big page takes seconds and hundreds of megabytes of work, which the window must not wait for.
        guard let png = await Task.detached(priority: .userInitiated, operation: { png(fromPDF: pdf) }).value else { return nil }
        return (png, cut)
    }

    private static func contentSize(of webView: WKWebView) async -> CGSize? {
        let script = "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
        let values: [Double]? = await ToolCatalog.withTimeout(seconds: 5, fallback: nil) { finish in
            webView.evaluateJavaScript(script) { value, _ in finish(value as? [Double]) }
        }
        guard let values, values.count == 2, values[0] > 0, values[1] > 0 else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    /// The bytes of the PDF the tab is showing, fetched again with the page's own cookies.
    private static func originalPDF(of webView: WKWebView) async -> Data? {
        let script = """
        const response = await fetch(location.href);
        if (!response.ok) return null;
        const bytes = new Uint8Array(await response.arrayBuffer());
        let text = '';
        for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        return btoa(text);
        """
        let encoded: String? = await ToolCatalog.withTimeout(seconds: 60, fallback: nil) { finish in
            webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { finish(try? $0.get() as? String) }
        }
        guard let encoded, let data = Data(base64Encoded: encoded), data.starts(with: Data("%PDF".utf8)) else { return nil }
        return data
    }

    /// The PDF's one tall page, drawn on white at up to twice its size.
    nonisolated static func png(fromPDF data: Data) -> Data? {
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

    /// A file name may be 255 bytes long, with its extension. Korean and emoji take 3 to 25 bytes a character, so the name is cut by bytes.
    nonisolated static let maxNameBytes = 196

    /// The page's title as a file name, or its site's name when it has none.
    static func filename(title: String, host: String?) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines)).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let name = truncated(String(cleaned.prefix(100)), toBytes: maxNameBytes).trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return name.isEmpty ? truncated(host ?? String(localized: "Page"), toBytes: maxNameBytes) : name
    }

    /// The longest start of the text that fits in this many UTF-8 bytes, cut between characters (an emoji is never cut in two).
    nonisolated static func truncated(_ text: String, toBytes limit: Int) -> String {
        var result = "", used = 0
        for character in text {
            let size = character.utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }
}
