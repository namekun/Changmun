import SwiftUI

/// The start page drawn small from its settings, for the style tiles of the popover and the preview of the Settings page: the real background and,
/// where the real page has text and pictures, bars and boxes in their places. It is a drawing of the page's arrangement at 1000 points wide, scaled
/// down, and is only built while the popover or the Settings page is open.
struct StartPageMiniature: View {
    let settings: StartPageSettings
    let tint: SpaceTint
    var sample = true

    private static let width: CGFloat = 1000
    private static let height: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Self.width
            ZStack(alignment: .top) {
                StartBackgroundView(background: settings.background, tint: tint)
                page
                    .frame(width: Self.width, height: Self.height, alignment: .top)
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .environment(\.startOnImage, settings.background.kind == .image)
        }
        .aspectRatio(Self.width / Self.height, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }

    private var shown: [StartSection] { settings.current.shown.map(\.section) }

    private func bar(_ width: CGFloat, _ height: CGFloat = 12, _ opacity: Double = 0.16) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous).fill(Theme.ink(opacity)).frame(width: width, height: height)
    }

    private var searchBar: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink(0.11)).frame(width: 620, height: 52)
            .overlay(alignment: .leading) { bar(210, 12, 0.2).padding(.leading, 46) }
    }

    private func tiles(_ count: Int, _ size: CGFloat) -> some View {
        HStack(spacing: 26) {
            ForEach(0..<count, id: \.self) { index in
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.white).frame(width: size, height: size)
                        .overlay { RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1) }
                        .overlay { Circle().fill(Self.colors[index % Self.colors.count]).frame(width: size * 0.42, height: size * 0.42) }
                    bar(size * 0.7, 8, 0.14)
                }
            }
        }
    }

    private static let colors: [Color] = [.black, .red, Color(white: 0.3), .purple, .orange, .blue, .green, .pink]

    private func cards(_ count: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink(0.06)).frame(height: 130)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white).frame(width: 32, height: 32)
                            bar(150, 12, 0.22)
                            bar(100, 10, 0.12)
                        }
                        .padding(14)
                    }
            }
        }
    }

    private func rows(_ count: Int, _ width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink(0.14)).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 5) { bar(width * 0.55, 10, 0.24); bar(width * 0.3, 8, 0.12) }
                    Spacer()
                }
                .frame(width: width, height: 44)
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch settings.style {
        case .dashboard: dashboard
        case .quiet: quiet
        case .aiFirst: aiFirst
        }
    }

    private func heading(_ width: CGFloat = 90) -> some View { bar(width, 12, 0.3) }

    private var dashboard: some View {
        VStack(spacing: 0) {
            searchBar.padding(.top, 70)
            if shown.contains(.aiSuggestions) {
                HStack(spacing: 8) { ForEach(0..<3, id: \.self) { _ in Capsule().fill(Theme.ink(0.08)).frame(width: 130, height: 28) } }.padding(.top, 14)
            }
            let rows = StartPageArrangement.rows(shown, style: .dashboard)
            VStack(alignment: .leading, spacing: 34) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .full(let section): block(section, wide: true)
                    case .pair(let a, let b): HStack(alignment: .top, spacing: 48) { block(a, wide: false); block(b, wide: false) }
                    case .wide(let section): block(section, wide: true)
                    }
                }
            }
            .frame(width: 984, alignment: .leading)
            .padding(.top, 36)
        }
    }

    private func block(_ section: StartSection, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading()
            switch section {
            case .favorites:
                if settings.current.item(.favorites)?.option == 1 {
                    VStack(alignment: .leading, spacing: 18) { tiles(4, 74); tiles(4, 74) }
                } else {
                    tiles(8, 58)
                }
            case .continueViewing: cards(4)
            case .readingList, .frequent: rows(4, wide ? 480 : 468)
            case .aiSuggestions: EmptyView()
            }
        }
    }

    private var quiet: some View {
        VStack(spacing: 28) {
            searchBar
            ForEach(shown.filter { $0 != .aiSuggestions }, id: \.self) { section in
                switch section {
                case .favorites:
                    if settings.current.item(.favorites)?.option == 1 {
                        VStack(spacing: 18) { tiles(4, 74); tiles(4, 74) }
                    } else {
                        tiles(8, 62)
                    }
                case .continueViewing: rows(3, 620)
                case .readingList: rows(3, 620)
                case .frequent: rows(4, 620)
                case .aiSuggestions: EmptyView()
                }
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 60)
    }

    private var aiFirst: some View {
        VStack(spacing: 0) {
            Circle().fill(tint.color).frame(width: 56, height: 56).padding(.top, 50)
            bar(280, 26, 0.5).padding(.top, 18)
            bar(360, 12, 0.18).padding(.top, 14)
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white).frame(width: 680, height: 112)
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 1) }
                .padding(.top, 28)
            if shown.contains(.aiSuggestions) {
                LazyVGrid(columns: [GridItem(.fixed(335), spacing: 10), GridItem(.fixed(335))], spacing: 10) {
                    ForEach(0..<4, id: \.self) { _ in RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink(0.06)).frame(height: 56) }
                }
                .frame(width: 680).padding(.top, 14)
            }
            searchBar.scaleEffect(y: 0.8).padding(.top, 26)
            VStack(spacing: 24) {
                ForEach(shown.filter { $0 != .aiSuggestions }, id: \.self) { section in
                    switch section {
                    case .favorites: tiles(8, 46)
                    case .continueViewing, .readingList: rows(3, 620)
                    case .frequent: rows(4, 620)
                    case .aiSuggestions: EmptyView()
                    }
                }
            }
            .padding(.top, 22)
        }
    }
}
