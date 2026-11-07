import SwiftUI

/// Settings › Start Page: where new tabs open.
struct StartPageSettingsView: View {
    @StateObject private var model = StartPageSettingsModel()

    var body: some View {
        Form {
            Section("New Tabs Open") {
                StartNewTabControls(model: model)
                Caption(text: "A private window always shows its own start page, whatever is set here.")
            }
        }
        .formStyle(.grouped)
    }
}
