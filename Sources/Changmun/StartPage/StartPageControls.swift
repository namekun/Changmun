import AppKit
import SwiftUI

/// The controls the Customize popover and the Settings page share, all working on a `StartPageCustomizeModel`.

// MARK: Style

/// The three styles as small pictures of the page as it is now (the popover), each remembering its own sections.
struct StartStyleTiles: View {
    @ObservedObject var model: StartPageCustomizeModel
    let tint: SpaceTint

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(StartStyle.allCases, id: \.self) { style in
                let selected = model.settings.style == style
                Button { model.setStyle(style) } label: {
                    VStack(spacing: 6) {
                        StartPageMiniature(settings: preview(style), tint: tint)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
                            .padding(3)
                            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                        Text(verbatim: style.title).font(.system(size: 11, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.primary : Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityValue(selected ? String(localized: "Selected") : "")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

extension StartStyleTiles {
    /// The page as the settings have it, in the style of the tile.
    fileprivate func preview(_ style: StartStyle) -> StartPageSettings {
        var settings = model.settings
        settings.style = style
        return settings
    }
}

/// The three styles as radio rows with a line of what each is, beside a preview (Settings).
struct StartStyleRadios: View {
    @ObservedObject var model: StartPageCustomizeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(StartStyle.allCases, id: \.self) { style in
                let selected = model.settings.style == style
                Button { model.setStyle(style) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 15)).foregroundStyle(selected ? Color.accentColor : Theme.secondary)
                            .frame(width: 18).decorative()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: style.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primary)
                            Text(verbatim: style.detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(style.title)
                .accessibilityValue(style.detail)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: Sections

/// The sections of the style in use: a switch each, an option (a gear that opens it in the popover, a menu in Settings), and a handle to drag them
/// into another order. The handle is a button for VoiceOver, with "Move Up" and "Move Down" among its actions, and ⌥↑ and ⌥↓ move it.
struct StartComponentsList: View {
    @ObservedObject var model: StartPageCustomizeModel
    /// Settings: the option is a menu in the row. The popover: a gear opens it under the row.
    var inline = false
    /// What the page has to show now, to say which sections that are on have nothing yet (nil: not said).
    var contents: StartPageContents?
    @State private var dragStart: Int?
    @State private var lift: CGFloat = 0
    @FocusState private var focusedHandle: StartSection?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.items.enumerated()), id: \.element.section) { index, item in
                if index > 0 { Divider().padding(.leading, 40).opacity(model.dragging == nil ? 1 : 0) }
                row(item, index: index)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink(0.05)))
        .animation(Motion.quick, value: model.items.map(\.section))
        .animation(Motion.quick, value: model.expanded)
    }

    private func row(_ item: StartItem, index: Int) -> some View {
        let section = item.section
        let dragging = model.dragging == section
        let expanded = model.expanded == section && !inline && item.enabled && section.optionChoices != nil
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                handle(section, index: index)
                Image(systemName: section.symbol).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 18).decorative()
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: section.title).font(.system(size: 13)).foregroundStyle(item.enabled ? Theme.primary : Theme.secondary)
                    if item.enabled, let contents, StartPageRules.isEmpty(section, contents: contents) {
                        Text("Nothing here yet").font(.system(size: 10.5)).foregroundStyle(Theme.dim)
                    }
                }
                Spacer(minLength: 4)
                if item.enabled, let choices = section.optionChoices {
                    if inline {
                        Picker(choices.title, selection: Binding(get: { model.option(section) }, set: { model.setOption(section, $0) })) {
                            ForEach(Array(choices.choices.enumerated()), id: \.offset) { Text(verbatim: $0.element).tag($0.offset) }
                        }
                        .labelsHidden().fixedSize()
                        .accessibilityLabel(String(localized: "\(section.title) options"))
                    } else {
                        Button { model.toggleOptions(section) } label: {
                            Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(expanded ? Color.accentColor : Theme.secondary)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(expanded ? Color.accentColor.opacity(0.14) : .clear))
                        }
                        .buttonStyle(.plain)
                        .help("Options")
                        .accessibilityLabel(String(localized: "\(section.title) options"))
                        .accessibilityValue(Accessibility.expansion(expanded))
                        .accessibilityAddTraits(.isButton)
                    }
                }
                Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in model.toggle(section) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityLabel(String(localized: "Show \(section.title)"))
                    .accessibilityValue(Accessibility.onOffValue(item.enabled))
            }
            .padding(.horizontal, 10)
            .frame(height: StartPageCustomizeModel.rowHeight)
            if expanded, let choices = section.optionChoices {
                options(section, choices)
            }
        }
        .background { if dragging { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).padding(2) } }
        // The lifted row: bigger, with a shadow, following the pointer; with Reduce Motion it just follows.
        .background(dragging ? AnyShapeStyle(Theme.card) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .scaleEffect(dragging && !Motion.reduced ? 1.03 : 1)
        .shadow(color: dragging ? Theme.cardShadow : .clear, radius: dragging ? 8 : 0, y: 3)
        .offset(y: dragging ? lift : 0)
        .zIndex(dragging ? 1 : 0)
    }

    private func options(_ section: StartSection, _ choices: (title: String, choices: [String])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: choices.title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                StartSegmented(options: choices.choices, selection: model.option(section)) { model.setOption(section, $0) }
                    .frame(maxWidth: 220)
            }
        }
        .padding(.leading, 56).padding(.trailing, 12).padding(.bottom, 10)
        .transition(.opacity)
    }

    private func handle(_ section: StartSection, index: Int) -> some View {
        StartGrip(color: focusedHandle == section ? Color.accentColor : Theme.faint)
            .frame(width: 22, height: StartPageCustomizeModel.rowHeight)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { drag in
                        if model.dragging != section {
                            model.beginDrag(section)
                            dragStart = model.position(of: section) - 1
                        }
                        let start = dragStart ?? index
                        let target = StartPageCustomizeModel.dragIndex(start: start, translation: drag.translation.height, count: model.items.count)
                        withAnimation(Motion.quick) { model.drag(section, over: target) }
                        // Where the row sits now follows the pointer, whatever the list did under it.
                        lift = drag.translation.height - CGFloat((model.position(of: section) - 1) - start) * StartPageCustomizeModel.rowHeight
                    }
                    .onEnded { _ in
                        withAnimation(Motion.standard) { lift = 0 }
                        model.endDrag(section)
                        dragStart = nil
                    }
            )
            .focusable()
            .focused($focusedHandle, equals: section)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard let step = StartPageCustomizeModel.step(up: press.key == .upArrow, option: press.modifiers.contains(.option)) else { return .ignored }
                withAnimation(Motion.quick) { model.move(section, by: step) }
                return .handled
            }
            .accessibilityElement()
            .accessibilityLabel(model.reorderLabel(section))
            .accessibilityValue(model.reorderValue(section))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(String(localized: "Drag, or press Option with the up or down arrow, to move it"))
            .accessibilityAction(named: Text("Move Up")) { withAnimation(Motion.quick) { model.move(section, by: -1) } }
            .accessibilityAction(named: Text("Move Down")) { withAnimation(Motion.quick) { model.move(section, by: 1) } }
    }
}

/// The six dots of a drag handle.
struct StartGrip: View {
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 3) { ForEach(0..<3, id: \.self) { _ in Circle().fill(color).frame(width: 2.6, height: 2.6) } }
            }
        }
    }
}

/// A row of choices of which one is on, as the popover's option rows and "New tabs open" show them.
struct StartSegmented: View {
    let options: [String]
    let selection: Int
    let choose: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, name in
                let on = index == selection
                Button { choose(index) } label: {
                    Text(verbatim: name).font(.system(size: 11.5, weight: on ? .semibold : .regular)).foregroundStyle(on ? Theme.primary : Theme.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background { if on { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.selectedFill).shadow(color: Theme.selectedShadow, radius: 1.5, y: 0.5) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink(0.07)))
    }
}

// MARK: Background

struct StartBackgroundControls: View {
    @ObservedObject var model: StartPageCustomizeModel
    let tint: SpaceTint
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var loaded: StartLoadedImage?
    @State private var custom = Color.blue

    private var background: StartBackground { model.settings.background }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                tile(.spaceGlow, String(localized: "Space Color")) { StartBackgroundView(background: StartBackground(kind: .spaceGlow), tint: tint) }
                tile(.plain, String(localized: "Plain")) { Theme.card }
                tile(.color, String(localized: "Colors")) { colorTile }
                tile(.image, String(localized: "Image…")) { imageTile }
                tile(.none, String(localized: "None")) { noneTile }
            }
            if background.kind == .color { swatches }
            if model.imageState == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Preparing the image…").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if model.imageState == .failed {
                notice("exclamationmark.circle.fill", String(localized: "Couldn’t use that image"), .red)
            }
            if background.kind == .image, background.imageFile != nil { imageControls }
        }
        .task(id: background.imageFile) { loaded = await StartImageLoader.load(file: background.imageFile, maxPixel: 420) }
    }

    private func tile<Content: View>(_ kind: StartBackgroundKind, _ name: String, @ViewBuilder _ content: () -> Content) -> some View {
        let selected = background.kind == kind
        return Button { select(kind) } label: {
            VStack(spacing: 5) {
                content()
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
                    .padding(2.5)
                    .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                Text(verbatim: name).font(.system(size: 10.5, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Theme.primary : Theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(selected ? String(localized: "Selected") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func select(_ kind: StartBackgroundKind) {
        if model.selectBackground(kind) { pickImage() }
    }

    private var colorTile: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) { Color(red: 0.62, green: 0.76, blue: 0.95); Color(red: 0.97, green: 0.68, blue: 0.62) }
            HStack(spacing: 0) { Color(red: 0.70, green: 0.88, blue: 0.76); Color(red: 0.80, green: 0.75, blue: 0.95) }
        }
    }

    @ViewBuilder private var imageTile: some View {
        if let loaded, background.imageFile != nil {
            Image(decorative: loaded.image, scale: 1).resizable().scaledToFill()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var noneTile: some View {
        ZStack {
            Theme.card
            Path { path in path.move(to: CGPoint(x: 0, y: 40)); path.addLine(to: CGPoint(x: 60, y: 0)) }.stroke(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: Swatches

    private var swatches: some View {
        HStack(spacing: 8) {
            ForEach(StartBackground.swatches, id: \.self) { id in
                let selected = background.colorID == id
                let light = StartSwatch.tone(id, dark: false)!, dark = StartSwatch.tone(id, dark: true)!
                Button { model.setColor(id) } label: {
                    Circle().fill(LinearGradient(stops: [.init(color: light.color, location: 0.5), .init(color: dark.color, location: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 22, height: 22)
                        .overlay { Circle().strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
                        .padding(2.5)
                        .overlay { Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.name(of: id))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            ColorPicker(String(localized: "Custom Color"), selection: $custom, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: custom) { _, new in
                    if let color = NSColor(new).usingColorSpace(.sRGB) {
                        model.setCustomColor(hex: StartSwatch.hex(of: StartSwatch.RGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)))
                    }
                }
        }
    }

    /// What a swatch is called, for VoiceOver: a colour alone says nothing.
    static func name(of id: String) -> String {
        switch id {
        case "slate": String(localized: "Slate")
        case "blue": String(localized: "Blue")
        case "coral": String(localized: "Coral")
        case "green": String(localized: "Green")
        case "purple": String(localized: "Purple")
        case "amber": String(localized: "Amber")
        case "teal": String(localized: "Teal")
        case "pink": String(localized: "Pink")
        default: id
        }
    }

    // MARK: The picture

    private var imageControls: some View {
        let url = StartPageFiles.imageURL(background.imageFile)
        let dark = scheme == .dark
        let scrim = loaded.map { StartScrim.scrim(stats: $0.stats, dark: dark, dim: background.dim, highContrast: contrast == .increased, reduceTransparency: reduceTransparency) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if let loaded { Image(decorative: loaded.image, scale: 1).resizable().scaledToFill() } else { Theme.ink(0.08) }
                }
                .frame(width: 105, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.cardEdge, lineWidth: 0.5) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background Image").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.primary)
                    HStack(spacing: 4) {
                        if let loaded { Text(verbatim: "\(Int(loaded.pixelSize.width))×\(Int(loaded.pixelSize.height)) ·").font(.system(size: 11)).foregroundStyle(Theme.dim) }
                        Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(Theme.dim).decorative()
                        Text("Only on this Mac").font(.system(size: 11)).foregroundStyle(Theme.dim)
                    }
                    HStack(spacing: 10) {
                        Button { pickImage() } label: { Text("Choose Another…").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.primary).padding(.horizontal, 9).frame(height: 22).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pressed)) }
                            .buttonStyle(.plain)
                        Button { model.removeImage() } label: { Text("Remove").font(.system(size: 11.5)).foregroundStyle(Color.accentColor) }
                            .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
            }
            .opacity(url == nil ? 0.5 : 1)
            slider(String(localized: "Blur"), value: background.blur, display: Int((background.blur * 40).rounded()), range: 0...40) { model.setBlur($0 / 40) }
            slider(dark ? String(localized: "Darken") : String(localized: "Lighten"), value: background.dim, display: Int((background.dim * 60).rounded()), range: 0...60) { model.setDim($0 / 60) }
            if let scrim {
                notice("info.circle", String(localized: "To keep text readable, an automatic scrim of \(Int((scrim.opacity * 100).rounded()))% is laid over it. The image is only stored on this Mac."), Theme.secondary)
                if !scrim.reachesTarget {
                    notice("exclamationmark.triangle.fill", String(localized: "This picture is hard to put text on in this mode. It reads better in the other one."), Theme.waitingText)
                }
            }
            if let loaded, loaded.isSmall {
                notice("exclamationmark.triangle.fill", String(localized: "The image is small, so it may look soft on a big screen."), Theme.waitingText)
            }
            if let loaded, loaded.stats.isBusy {
                notice("exclamationmark.triangle.fill", String(localized: "The pattern is busy. Raising the blur makes text easier to read."), Theme.waitingText)
            }
        }
    }

    private func slider(_ title: String, value: Double, display: Int, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { Double(display) }, set: { set($0) }), in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(String(localized: "\(display), from \(Int(range.lowerBound)) to \(Int(range.upperBound))"))
            Text(verbatim: "\(display)").font(.system(size: 11)).foregroundStyle(Theme.dim).frame(width: 22, alignment: .trailing)
        }
    }

    private func notice(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).padding(.top, 1).decorative()
            Text(verbatim: text).font(.system(size: 11.5)).foregroundStyle(color == Theme.secondary ? Theme.secondary : color).fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.1)))
        .accessibilityElement(children: .combine)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a picture for the start page")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.chooseImage(url) }
    }
}

// MARK: New tabs

struct StartNewTabControls: View {
    @ObservedObject var model: StartPageCustomizeModel
    /// Settings explains more than the popover has room for.
    var detailed = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StartSegmented(options: NewTabOpens.allCases.map(\.title), selection: NewTabOpens.allCases.firstIndex(of: model.settings.newTab) ?? 0) {
                model.setNewTab(NewTabOpens.allCases[$0])
            }
            if let detail = model.settings.newTab.detail {
                Text(verbatim: detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                addressField
            }
        }
        .onChange(of: model.settings.address) { _, new in if new != model.address.trimmingCharacters(in: .whitespacesAndNewlines) { model.restoreAddressFromStore() } }
    }

    private var addressField: some View {
        let state = model.addressState
        let border: Color = switch state {
        case .invalid: .red
        case .insecure: Theme.waitingText
        default: .clear
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if case .ok(let url) = state { StartIcon(url: url.absoluteString, size: 18, plate: false) } else {
                    Image(systemName: "globe").font(.system(size: 13)).foregroundStyle(Theme.secondary).decorative()
                }
                TextField("https://example.com", text: $model.address)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($addressFocused)
                    .onSubmit { model.commitAddress() }
                    .onChange(of: model.address) { model.addressEdited() }
                    .onChange(of: addressFocused) { _, focused in if !focused { model.commitAddress() } }
                    .accessibilityLabel(String(localized: "Address for new tabs"))
                if case .ok = state { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).decorative() }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(addressFocused && state == nil ? Color.accentColor : border, lineWidth: 1.5) }
            switch state {
            case .none where model.address.isEmpty, .empty:
                line("info.circle", String(localized: "Leave it empty to open the start page."), Theme.secondary)
            case .invalid:
                line("exclamationmark.circle.fill", String(localized: "That isn’t a valid address. For example: https://example.com"), .red)
            case .insecure:
                VStack(alignment: .leading, spacing: 3) {
                    line("exclamationmark.triangle.fill", String(localized: "This connection isn’t encrypted. We recommend https://"), Theme.waitingText)
                    Button { model.useHTTPS() } label: { Text("Use https://").font(.system(size: 11.5)).foregroundStyle(Color.accentColor) }
                        .buttonStyle(.plain).padding(.leading, 20)
                }
            case .ok:
                line("checkmark", String(localized: "This address works."), Color(red: 0.12, green: 0.55, blue: 0.3))
            default:
                EmptyView()
            }
            line("globe", String(localized: "This site is loaded every time you open a new tab."), Theme.secondary)
            if detailed {
                Text("The site learns that you connected, and your IP address. A window with no tab always shows the start page, so no site is loaded when a window opens.")
                    .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
            }
        }
    }

    private func line(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).frame(width: 13).padding(.top, 1).decorative()
            Text(verbatim: text).font(.system(size: 11.5)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
