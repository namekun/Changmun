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
        /// Changmun had a different password for the site and account already, and that one is the newer.
        var kept = 0
        /// Not an https site, or no password.
        var skipped = 0
        /// The Keychain refused it.
        var failed = 0
    }

    enum ReadError: LocalizedError {
        case notAPasswordFile, tooLarge

        var errorDescription: String? {
            switch self {
            case .notAPasswordFile:
                String(localized: "That file doesn’t look like a password export. Changmun reads the CSV files that the Passwords app, Chrome, Edge, Firefox, 1Password and Bitwarden export.")
            case .tooLarge:
                String(localized: "That file is too large to be a password export")
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

    /// Saves each row for its site, never over a password Changmun has for the same site and account. Of two rows for one account, the first wins, so the
    /// second counts as kept.
    static func importLogins(_ logins: [Login]) -> Counts {
        var result = Counts()
        for login in logins {
            guard !login.password.isEmpty, let host = host(for: login.address) else { result.skipped += 1; continue }
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
    /// Bitwarden puts the several addresses of one login in one field, a line each; the first https one is the site.
    static func host(for address: String) -> String? {
        for line in address.split(whereSeparator: \.isNewline) {
            guard let url = URL(string: line.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https",
                  let key = Logins.key(for: url) else { continue }
            return key.lowercased()
        }
        return nil
    }

    // MARK: Reading

    /// The rows under the header, for whichever of the formats the header is: the address, user name and password columns go by their name in any case,
    /// in any order (`url` and `login_uri`, `username` and `login_username`, `password` and `login_password`), and the others are left alone.
    static func logins(in data: Data) throws -> [Login] {
        let rows = records(in: data)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
              let address = header.firstIndex(where: { ["url", "login_uri"].contains($0) }),
              let username = header.firstIndex(where: { ["username", "login_username"].contains($0) }),
              let password = header.firstIndex(where: { ["password", "login_password"].contains($0) }) else { throw ReadError.notAPasswordFile }
        return rows.dropFirst().map { row in
            Login(address: row.indices.contains(address) ? row[address] : "", username: row.indices.contains(username) ? row[username] : "",
                  password: row.indices.contains(password) ? row[password] : "")
        }
    }

    /// The records of a CSV file (RFC 4180): fields in quotes can hold commas, line breaks and doubled quotes; a record ends at CRLF, LF or CR;
    /// a byte order mark is dropped; blank lines are no record. Excel's UTF-16 is read too.
    static func records(in data: Data) -> [[String]] {
        var bytes: [UInt8]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            bytes = Array((String(data: data, encoding: .utf16) ?? "").utf8)
        } else {
            bytes = Array(data)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
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
            } else if byte == quote {
                quoted = true
            } else if byte == comma {
                endField()
            } else if byte == lf || byte == cr {
                endRecord()
                if byte == cr, i + 1 < bytes.count, bytes[i + 1] == lf { i += 1 }
            } else {
                field.append(byte)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
