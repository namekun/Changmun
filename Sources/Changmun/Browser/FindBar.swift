import AppKit
import SwiftUI

// MARK: Find in page

struct FindBar: View {
    let browser: Browser
    @ObservedObject var overlay: PageOverlay
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("Find on Page", text: $overlay.findText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 180)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    browser.find(backwards: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(.escape) {
                    browser.hideFindBar()
                    return .handled
                }
            if let matches = overlay.findMatches, !overlay.findText.isEmpty {
                Text(matches == 0 ? String(localized: "None") : matches == 1 ? String(localized: "\(matches) match") : String(localized: "\(matches) matches"))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(matches == 0 ? Theme.waitingText : Theme.secondary)
            }
            BarButton(symbol: "chevron.up", help: String(localized: "Previous (⌘⇧G)")) { browser.find(backwards: true) }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "chevron.down", help: String(localized: "Next (⌘G)")) { browser.find() }.disabled(overlay.findText.isEmpty)
            BarButton(symbol: "xmark", help: String(localized: "Close (esc)")) { browser.hideFindBar() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 36)
        .floatingPanel(radius: Metrics.cardRadius)
        .padding(10)
        .onAppear { focused = true }
        .onChange(of: overlay.findFocusRequest) { focused = true }
        .onChange(of: overlay.findText) { browser.find() }
    }
}
