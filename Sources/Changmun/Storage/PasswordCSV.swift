import Foundation

/// Passwords from a CSV file: what the Passwords app (Safari's), Chrome, Edge, Firefox, 1Password and Bitwarden export, since Apple lets no other
/// browser read iCloud Keychain. The file holds the passwords in plain text, so it is read once into memory, nothing from it is logged or
/// copied, and an error says what is wrong with the file, never what is in it.
enum PasswordCSV {
    struct Login: Equatable {
        var address: String
        var username: String
        var password: String
    }

    /// What became of each row.
    struct Counts: Equatable {
        var imported = 0
        var unchanged = 0
        /// A row for a site and account that an earlier row of the file had: saved once, from the first.
        var duplicates = 0
        /// Changmun had a different password for the site and account already, and that one is the newer.
        var kept = 0
        /// Not an https site, or no password.
        var skipped = 0
        /// The Keychain refused it.
        var failed = 0
    }

    enum ReadError: LocalizedError {
        case notAPasswordFile, tooLarge, notReadableText

        var errorDescription: String? {
            switch self {
            case .notAPasswordFile:
                String(localized: "That file doesn’t look like a password export. Changmun reads the CSV files that the Passwords app, Chrome, Edge, Firefox, 1Password and Bitwarden export.")
            case .tooLarge:
                String(localized: "That file is too large to be a password export")
            case .notReadableText:
                String(localized: "That file isn’t UTF-8 text, so its passwords can’t be read safely. Export it again as CSV, or save it as CSV UTF-8, and try once more.")
            }
        }
    }

    /// A file that big is not a list of passwords, and is refused before it is read.
    static let maxFileSize = 32_000_000

    /// Reads the file once, and saves its https logins. Meant for a background thread: a few thousand Keychain writes take a while.
    static func run(file url: URL) throws -> Counts {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileSize else { throw ReadError.tooLarge }
        return importLogins(try logins(in: Data(contentsOf: url)))
    }

    /// Saves each row for its site, never over a password Changmun has for the same site and account. Of several rows for one account (the www
    /// twin of a site is the same site), the first is saved and the others count as duplicates, whatever their passwords.
    static func importLogins(_ logins: [Login]) -> Counts {
        var result = Counts()
        var seen = Set<String>()
        for login in logins {
            guard !login.password.isEmpty, let host = host(for: login.address) else { result.skipped += 1; continue }
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            guard seen.insert(site + "\n" + login.username).inserted else { result.duplicates += 1; continue }
            switch Logins.importLogin(host: host, username: login.username, password: login.password) {
            case .saved: result.imported += 1
            case .unchanged: result.unchanged += 1
            case .kept: result.kept += 1
            case .failed: result.failed += 1
            }
        }
        return result
    }

    /// The key a login is saved under, for an https address only: Changmun saves no login of a plain http site, and an address like android:// is no site.
    /// Bitwarden puts the several addresses of one login in one field, separated by commas (and a line break is taken for one too); the first https one
    /// is the site. That one must be a plain address: a row whose site can't be told for sure (a user name or a backslash in front of the host, which
    /// Foundation and WebKit read differently, a host with characters no host name has, a port that no port is) is skipped, not saved under a guess.
    static func host(for address: String) -> String? {
        let candidates = address.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = candidates.first(where: { $0.lowercased().hasPrefix("https://") }) else { return nil }
        let authority = first.dropFirst("https://".count).prefix { !"/?#".contains($0) }
        guard !authority.contains("\\"), let url = URL(string: first), url.user == nil, url.password == nil,
              url.port.map({ (1...65_535).contains($0) }) ?? true, let key = Logins.key(for: url),
              isHostName(Logins.hostname(ofKey: key)) else { return nil }
        return key.lowercased()
    }

    /// What a host is made of once its non-ASCII letters are in punycode: labels of letters, digits, hyphens and underscores between dots, or an IPv6 address.
    private static func isHostName(_ host: String) -> Bool {
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else { return false }
        // No empty label: a trailing dot (the absolute name) is the only one a host may have.
        var labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count > 1, labels.last?.isEmpty == true { labels.removeLast() }
        return labels.allSatisfy { !$0.isEmpty }
    }

    // MARK: Reading

    /// The rows under the header, for whichever of the formats the header is: the address, user name and password columns go by their name in any case,
    /// in any order (`url` and `login_uri`, `username` and `login_username`, `password` and `login_password`), and the others are left alone.
    static func logins(in data: Data) throws -> [Login] {
        let rows = try records(in: data)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let address = header.firstIndex(where: { ["url", "login_uri"].contains($0) }),
              let username = header.firstIndex(where: { ["username", "login_username"].contains($0) }),
              let password = header.firstIndex(where: { ["password", "login_password"].contains($0) }) else { throw ReadError.notAPasswordFile }
        return rows.dropFirst().map { row in
            Login(address: row.indices.contains(address) ? row[address] : "", username: row.indices.contains(username) ? row[username] : "",
                  password: row.indices.contains(password) ? row[password] : "")
        }
    }

    /// The records of a CSV file (RFC 4180): fields in quotes can hold commas, line breaks and doubled quotes; a quote opens one only at the start of a field
    /// (anywhere else it is a letter like any); a record ends at CRLF, LF or CR; a byte order mark is dropped; blank lines are no record. The file must be
    /// UTF-8, or UTF-16 with its mark (what Excel saves): text in any other encoding would be read as other letters, and a password saved so is wrong.
    static func records(in data: Data) throws -> [[String]] {
        var bytes: [UInt8]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf16) else { throw ReadError.notReadableText }
            bytes = Array(text.utf8)
        } else {
            bytes = Array(data)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
            guard String(bytes: bytes, encoding: .utf8) != nil else { throw ReadError.notReadableText }
        }
        // Valid UTF-8 is cut only at the ASCII commas, quotes and line breaks below, so every field is whole text.
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var atStart = true
        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            atStart = true
        }
        func endRecord() {
            endField()
            if record != [""] { records.append(record) }
            record = []
        }
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if quoted {
                if byte != quote { field.append(byte) }
                else if i + 1 < bytes.count, bytes[i + 1] == quote { field.append(quote); i += 1 }
                else { quoted = false }
            } else if byte == quote && atStart {
                quoted = true
                atStart = false
            } else if byte == comma {
                endField()
            } else if byte == lf || byte == cr {
                endRecord()
                if byte == cr, i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
            } else {
                field.append(byte)
                atStart = false
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
