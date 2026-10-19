import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small wrapper over the system SQLite, enough for the library and for reading other browsers' databases.
final class SQLite {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            // The failed init is deinitialized too: it must not close the same handle again.
            db = nil
            throw SQLiteError(message: message)
        }
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func run(_ sql: String, _ values: [Any?] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error() }
    }

    /// Rows as arrays of column values: Int64, Double, String, Data or nil.
    func query(_ sql: String, _ values: [Any?] = []) throws -> [[Any?]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[Any?]] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var row: [Any?] = []
            for i in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(statement, i))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, i))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, i)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row.append(count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i), count: count))
                default: row.append(nil)
                }
            }
            rows.append(row)
            code = sqlite3_step(statement)
        }
        // A read that broke off (busy, damaged, out of memory) is an error, not a shorter answer.
        guard code == SQLITE_DONE else { throw error() }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do { try body(); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error }
    }

    private func prepare(_ sql: String, _ values: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error() }
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, i, v, -1, transient)
            case let v as Int: sqlite3_bind_int64(statement, i, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, i, v)
            case let v as Double: sqlite3_bind_double(statement, i, v)
            case let v as Data: _ = v.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32(v.count), transient) }
            default: sqlite3_bind_null(statement, i)
            }
        }
        return statement
    }

    private func error() -> SQLiteError { SQLiteError(message: String(cString: sqlite3_errmsg(db))) }
}

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
