import AppKit
import SwiftUI

enum AddressBarChoice: String, CaseIterable, Identifiable {
    /// On top in developer mode, in the sidebar otherwise.
    case automatic
    case sidebar
    case top

    var id: String { rawValue }
}

enum ShortcutScheme: String, CaseIterable, Identifiable {
    case safari
    case chrome

    var id: String { rawValue }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    @Published var developerMode = UserDefaults.standard.bool(forKey: "developerMode") {
        didSet { UserDefaults.standard.set(developerMode, forKey: "developerMode") }
    }
    @Published var addressBar = AddressBarChoice(rawValue: UserDefaults.standard.string(forKey: "addressBar") ?? "") ?? .automatic {
        didSet { UserDefaults.standard.set(addressBar.rawValue, forKey: "addressBar") }
    }

    @Published var shortcuts = ShortcutScheme(rawValue: UserDefaults.standard.string(forKey: "shortcuts") ?? "") ?? .safari {
        didSet { UserDefaults.standard.set(shortcuts.rawValue, forKey: "shortcuts") }
    }

    var addressBarOnTop: Bool { Self.onTop(addressBar, developerMode: developerMode) }

    nonisolated static func onTop(_ choice: AddressBarChoice, developerMode: Bool) -> Bool {
        choice == .top || (choice == .automatic && developerMode)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section {
                Picker("주소창 위치", selection: $prefs.addressBar) {
                    Text("개발자 모드에 맞춤 (지금: \(Preferences.onTop(.automatic, developerMode: prefs.developerMode) ? "위" : "사이드바"))").tag(AddressBarChoice.automatic)
                    Text("왼쪽 사이드바").tag(AddressBarChoice.sidebar)
                    Text("위").tag(AddressBarChoice.top)
                }
                .pickerStyle(.radioGroup)
                Text("위에 두면 전체 주소가 보이고 그 자리에서 바로 고칠 수 있어요 (⌘L).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("단축키", selection: $prefs.shortcuts) {
                    Text("Safari식").tag(ShortcutScheme.safari)
                    Text("Chrome식").tag(ShortcutScheme.chrome)
                }
                .pickerStyle(.segmented)
                Text(prefs.shortcuts == .safari
                     ? "사이드바 ⌘⇧L · 강력 새로고침 ⌥⌘R · 콘솔 ⌥⌘C · 탭 이동 ⌘⇧[ ⌘⇧]"
                     : "사이드바 ⌘S · 강력 새로고침 ⌘⇧R · 콘솔 ⌥⌘J · 탭 이동 ⌘⇧[ ⌘⇧] ⌥⌘← ⌥⌘→")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("개발자 모드", isOn: $prefs.developerMode)
                Text("켜면 주소창이 기본으로 위에 놓여요. 웹 인스펙터는 언제든 F12(네트워크 탭)나 ⌥⌘I로 열 수 있어요.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
