/// How a site's host is written for the user.
package enum DisplayHost {
    /// The host without a leading "www." (matched as written, case included).
    package nonisolated static func trimmed(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
