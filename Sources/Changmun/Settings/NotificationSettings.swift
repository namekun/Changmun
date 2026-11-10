import SwiftUI

/// Whether the app tells the user, with a system notification, what happens while another app is in front.
struct NotificationSettings: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject private var notifier = Notifier.shared

    var body: some View {
        Section {
            Toggle("Notify when the app is in the background", isOn: $prefs.notifyInBackground)
                .onAppear { notifier.refreshAuthorization() }
            Caption(text: "A notification when a download finishes, or when the AI is waiting for your answer, while another app is in front. The first one asks the Mac for permission.")
            if notifier.authorization == .refused {
                Caption(text: "Notifications for Changmun are turned off in System Settings, so none are shown.")
                Button("Open Notification Settings") {
                    if let pane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=" + Notifier.appBundleID) { Outside.open(pane) }
                }
            }
        }
    }
}
