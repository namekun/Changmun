/// Which bundle IDs are the headless apps, and the name of the profile folder each one keeps its files in.
package enum ProfileNames {
    package static let headlessBundleID = "io.github.namekun.Changmun.headless"
    package static let userBundleID = "io.github.namekun.Changmun.agent"

    package static func isHeadless(bundleID id: String?) -> Bool { id == headlessBundleID || id == userBundleID }
    /// The name of a headless app's profile folder in Application Support; nil for any other app.
    package static func profileName(forBundle id: String?) -> String? {
        id == headlessBundleID ? "Changmun Headless" : id == userBundleID ? "Changmun Agent" : nil
    }
}
