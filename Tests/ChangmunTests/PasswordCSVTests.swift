import Foundation
import Testing
@testable import Changmun

/// Passwords from a CSV file. The Keychain here is the in-memory one of the login import tests, never the real one.
struct PasswordCSVTests {
    private func with(_ keychain: MemoryKeychain = MemoryKeychain(), _ body: () throws -> Void) rethrows {
        try Logins.$testBackend.withValue(keychain, operation: body)
    }

    private func logins(_ text: String) throws -> [PasswordCSV.Login] { try PasswordCSV.logins(in: Data(text.utf8)) }

    // MARK: The parser

    @Test func quotedFieldsHoldCommasQuotesAndLineBreaks() {
        let text = "a,b,c\r\n\"x,y\",\"say \"\"hi\"\"\",\"line 1\r\nline 2\"\r\n1,,3"
        #expect(PasswordCSV.records(in: Data(text.utf8)) == [["a", "b", "c"], ["x,y", "say \"hi\"", "line 1\r\nline 2"], ["1", "", "3"]])
    }

    @Test func everyLineEndingEndsARecordAndBlankLinesAreNone() {
        #expect(PasswordCSV.records(in: Data("a,b\nc,d\r\ne,f\rg,h\n\n\r\n".utf8)) == [["a", "b"], ["c", "d"], ["e", "f"], ["g", "h"]])
        #expect(PasswordCSV.records(in: Data("a,b\n".utf8)) == [["a", "b"]], "a closing line break starts no record")
        #expect(PasswordCSV.records(in: Data("a,\n,\"\"".utf8)) == [["a", ""], ["", ""]], "empty fields stay")
        #expect(PasswordCSV.records(in: Data()) == [])
    }

    @Test func aByteOrderMarkIsNotPartOfTheFirstField() {
        #expect(PasswordCSV.records(in: Data([0xEF, 0xBB, 0xBF] + Array("url,password\n".utf8))) == [["url", "password"]])
        let utf16 = "url,password\nhttps://a.com,pä\n".data(using: .utf16)!
        #expect(PasswordCSV.records(in: utf16) == [["url", "password"], ["https://a.com", "pä"]], "Excel saves UTF-16 with a mark")
    }

    @Test func nonLatinTextSurvivesAndAMissingClosingQuoteTakesTheRest() {
        #expect(PasswordCSV.records(in: Data("이름,비밀번호\n\"홍길동\",\"비 밀,번호\"".utf8)) == [["이름", "비밀번호"], ["홍길동", "비 밀,번호"]])
        #expect(PasswordCSV.records(in: Data("a,\"b\nc".utf8)) == [["a", "b\nc"]])
    }

    // MARK: The formats

    @Test func theApplePasswordsHeader() throws {
        let rows = try logins("Title,URL,Username,Password,Notes,OTPAuth\nExample (alice),https://example.com/login,alice,s3cret,\"a note, with comma\",\n")
        #expect(rows == [.init(address: "https://example.com/login", username: "alice", password: "s3cret")])
    }

    @Test func theChromeAndEdgeHeader() throws {
        let rows = try logins("name,url,username,password,note\nexample.com,https://example.com/,bob,pw1,\n")
        #expect(rows == [.init(address: "https://example.com/", username: "bob", password: "pw1")])
    }

    @Test func theFirefoxHeader() throws {
        let rows = try logins("url,username,password,httpRealm,formActionOrigin,guid,timeCreated,timeLastUsed,timePasswordChanged\n"
                              + "https://example.com,carol,pw2,,https://example.com,{guid},1,2,3\n")
        #expect(rows == [.init(address: "https://example.com", username: "carol", password: "pw2")])
    }

    @Test func theBitwardenHeader() throws {
        let rows = try logins("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n"
                              + ",,login,Example,,,0,https://example.com,dave,pw3,\n")
        #expect(rows == [.init(address: "https://example.com", username: "dave", password: "pw3")])
    }

    @Test func theOnePasswordHeader() throws {
        let rows = try logins("Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nExample,https://example.com,erin,pw4,,false,false,,\n")
        #expect(rows == [.init(address: "https://example.com", username: "erin", password: "pw4")])
    }

    @Test func columnsGoByNameInAnyCaseAndOrder() throws {
        let rows = try logins("\u{FEFF}PASSWORD, Notes ,UserName,URL\npw,n,frank,https://example.com\n")
        #expect(rows == [.init(address: "https://example.com", username: "frank", password: "pw")])
        #expect(try logins("url,username,password\nhttps://a.com\n") == [.init(address: "https://a.com", username: "", password: "")], "a short row has empty fields")
    }

    @Test func anUnknownHeaderIsAnErrorThatSaysWhatIsWrongWithoutQuotingTheFile() {
        for text in ["", "\n\n", "a,b,c\n1,2,3\n", "url,username\nhttps://a.com,x\n", "Title,Notes\nhunter2,hunter2\n"] {
            #expect(throws: PasswordCSV.ReadError.self) { try logins(text) }
        }
        let message = PasswordCSV.ReadError.notAPasswordFile.localizedDescription
        #expect(message.contains("Passwords app") && !message.contains("hunter2"))
    }

    // MARK: Saving

    @Test func onlyHttpsLoginsWithAPasswordAreSaved() {
        with {
            let result = PasswordCSV.importLogins([
                .init(address: "https://example.com/login", username: "alice", password: "pw"),
                .init(address: "http://plain.example.com", username: "alice", password: "pw"),
                .init(address: "android://hash@com.example.app/", username: "alice", password: "pw"),
                .init(address: "example.com", username: "alice", password: "pw"),
                .init(address: "", username: "alice", password: "pw"),
                .init(address: "https://empty.example.com", username: "alice", password: ""),
                .init(address: "https://localhost:3000/", username: "me", password: "three"),
                .init(address: "HTTPS://Www.Example.org/x", username: "me", password: "up"),
            ])
            #expect(result == PasswordCSV.Counts(imported: 3, unchanged: 0, kept: 0, skipped: 5, failed: 0))
            #expect(Logins.all().map(\.host) == ["localhost:3000", "www.example.org", "example.com"].sorted())
            #expect(Logins.password(host: "example.com", username: "alice") == "pw")
            #expect(Logins.password(host: "localhost:3000", username: "me") == "three")
        }
    }

    @Test func theFirstHttpsAddressOfSeveralInOneFieldIsTheSite() {
        #expect(PasswordCSV.host(for: "http://a.com\nhttps://b.com/x\nhttps://c.com") == "b.com")
        #expect(PasswordCSV.host(for: "http://a.com\nandroid://x@y/") == nil)
    }

    @Test func aRowTwiceIsSavedOnceAndANewerPasswordIsKept() throws {
        try with {
            let result = PasswordCSV.importLogins([
                .init(address: "https://example.com", username: "alice", password: "pw"),
                .init(address: "https://example.com", username: "alice", password: "pw"),
                .init(address: "https://www.example.com", username: "alice", password: "other"),
                .init(address: "https://example.com", username: "bob", password: "pw"),
            ])
            #expect(result == PasswordCSV.Counts(imported: 2, unchanged: 1, kept: 1, skipped: 0, failed: 0))
            #expect(Logins.password(host: "example.com", username: "alice") == "pw")

            #expect(Logins.save(host: "newer.com", username: "me", password: "changed here"))
            let again = PasswordCSV.importLogins(try logins("url,username,password\nhttps://newer.com,me,from the file\nhttps://example.com,alice,pw\n"))
            #expect(again == PasswordCSV.Counts(imported: 0, unchanged: 1, kept: 1, skipped: 0, failed: 0))
            #expect(Logins.password(host: "newer.com", username: "me") == "changed here", "a password Changmun has is the newer")
        }
    }

    @Test func aFileOfThousandsOfRowsIsReadAndSavedFromDisk() throws {
        var text = "Title,URL,Username,Password,Notes,OTPAuth\r\n"
        for i in 0..<3_000 { text += "Site \(i),https://site\(i).example.com/,user,\"pw,\(i)\",\"a\r\nnote\",\r\n" }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("passwords-\(UUID().uuidString).csv")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try with {
            let result = try PasswordCSV.run(file: file)
            #expect(result == PasswordCSV.Counts(imported: 3_000, unchanged: 0, kept: 0, skipped: 0, failed: 0))
            #expect(Logins.password(host: "site2999.example.com", username: "user") == "pw,2999")
        }
    }
}
