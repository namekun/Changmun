import AppKit
import SwiftUI

/// The controls of Settings › Start Page, working on a `StartPageSettingsModel`.

/// A row of choices of which one is on, as "New tabs open" shows them.
struct StartSegmented: View {
    let options: [String]
    let selection: Int
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, name in
                let on = index == selection
                Button { choose(index) } label: {
                    Text(verbatim: name).font(on ? .captionStrong : .caption).foregroundStyle(on ? Theme.primary : Theme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background { if on { RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Theme.selectedFill).e1() } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Theme.ink(0.07)))
    }
}

struct StartNewTabControls: View {
    @ObservedObject var model: StartPageSettingsModel
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StartSegmented(options: NewTabOpens.allCases.map(\.title), selection: NewTabOpens.allCases.firstIndex(of: model.settings.newTab) ?? 0) {
                model.setNewTab(NewTabOpens.allCases[$0])
            }
            if let detail = model.settings.newTab.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                addressField
            }
        }
        .onChange(of: model.settings.address) { _, new in if new != model.address.trimmingCharacters(in: .whitespacesAndNewlines) { model.restoreAddressFromStore() } }
    }

    private var addressField: some View {
        let state = model.addressState
        let border: Color = switch state {
        case .invalid: Theme.danger
        case .insecure: Theme.waitingText
        default: .clear
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if case .ok(let url) = state { StartIcon(url: url.absoluteString, size: 18, plate: false) } else {
                    Image(systemName: "globe").font(.symbolToolbar).foregroundStyle(Theme.secondary).decorative()
                }
                TextField("https://example.com", text: $model.address)
                    .textFieldStyle(.plain).font(.body)
                    .focused($addressFocused)
                    .onSubmit { model.commitAddress() }
                    .onChange(of: model.address) { model.addressEdited() }
                    .onChange(of: addressFocused) { _, focused in if !focused { model.commitAddress() } }
                    .accessibilityLabel(String(localized: "Address for new tabs"))
                if case .ok = state { Image(systemName: "checkmark").font(.symbolInline).foregroundStyle(Theme.success).decorative() }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).fill(Theme.field))
            .overlay { RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous).strokeBorder(addressFocused && state == nil ? Color.accentColor : border, lineWidth: 1.5) }
            switch state {
            case .none where model.address.isEmpty, .empty:
                line("info.circle", String(localized: "Leave it empty to open the start page."), Theme.secondary)
            case .invalid:
                line("exclamationmark.circle", String(localized: "That isn’t a valid address. For example: https://example.com"), Theme.danger)
            case .insecure:
                VStack(alignment: .leading, spacing: 4) {
                    line("exclamationmark.triangle", String(localized: "This connection isn’t encrypted. We recommend https://"), Theme.waitingText)
                    Button { model.useHTTPS() } label: { Text("Use https://").font(.caption).foregroundStyle(Color.accentColor) }
                        .buttonStyle(.plain).padding(.leading, 24)
                }
            case .ok:
                line("checkmark", String(localized: "This address works."), Theme.success)
            default:
                EmptyView()
            }
            line("globe", String(localized: "This site is loaded every time you open a new tab."), Theme.secondary)
            Text("The site learns that you connected, and your IP address. A window with no tab always shows the start page, so no site is loaded when a window opens.")
                .font(.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 24)
        }
    }

    private func line(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.symbolInline).foregroundStyle(color).frame(width: 16).padding(.top, 1).decorative()  // grid-exempt: optical nudge of 1 pt
            Text(verbatim: text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
