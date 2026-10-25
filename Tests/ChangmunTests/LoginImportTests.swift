import Foundation
import Testing
@testable import Changmun

/// The login keychain's place in a test: nothing here touches the real one.
final class MemoryKeychain: LoginBackend, @unchecked Sendable {
    var items: [(server: String, account: String, secret: Data, modified: Date)] = []

    func records(server: String?) -> [Logins.Record] {
        items.filter { server == nil || $0.server == server }.map { Logins.Record(server: $0.server, account: $0.account, modified: $0.modified) }
    }

    func secret(server: String, account: String) -> Data? {
        items.first { $0.server == server && $0.account == account }?.secret
    }

    func set(server: String, account: String, secret: Data) -> Bool {
        items.removeAll { $0.server == server && $0.account == account }
        items.append((server, account, secret, Date()))
        return true
    }

    func remove(server: String, account: String) -> Bool {
        let before = items.count
        items.removeAll { $0.server == server && $0.account == account }
        return items.count < before
    }
}

struct LoginImportTests {
    private func with(_ keychain: MemoryKeychain = MemoryKeychain(), _ body: () throws -> Void) rethrows {
        try Logins.$testBackend.withValue(keychain, operation: body)
    }

    @Test func anImportDoesNotWriteOverAPasswordChangmunHas() {
        with {
            #expect(Logins.save(host: "example.com", username: "alice", password: "newer"))
            #expect(Logins.importLogin(host: "example.com", username: "alice", password: "older") == .kept)
            #expect(Logins.importLogin(host: "www.example.com", username: "alice", password: "older") == .kept, "the www twin is the same site")
            #expect(Logins.password(host: "example.com", username: "alice") == "newer")
            #expect(Logins.importLogin(host: "example.com", username: "alice", password: "newer") == .unchanged)
            #expect(Logins.importLogin(host: "example.com", username: "bob", password: "other") == .saved, "another account is new")
            #expect(Logins.importLogin(host: "other.com", username: "alice", password: "x") == .saved)
            #expect(Logins.all().count == 3)
        }
    }

    @Test func aSecondImportChangesNothing() {
        with {
            #expect(Logins.importLogin(host: "example.com", username: "alice", password: "from chrome") == .saved)
            #expect(Logins.save(host: "example.com", username: "alice", password: "changed here"))
            #expect(Logins.importLogin(host: "example.com", username: "alice", password: "from chrome") == .kept)
            #expect(Logins.password(host: "example.com", username: "alice") == "changed here")
        }
    }

    @Test func loginsOfOtherPortsOfAHostStayApart() throws {
        #expect(Logins.key(for: try #require(URL(string: "https://localhost:3000/login"))) == "localhost:3000")
        #expect(Logins.key(for: try #require(URL(string: "https://example.com:443/"))) == "example.com")
        #expect(Logins.key(for: try #require(URL(string: "https://example.com/"))) == "example.com")
        #expect(Logins.key(for: try #require(URL(string: "http://example.com:80/"))) == "example.com")
        #expect(Logins.key(for: try #require(URL(string: "https://[::1]:8443/"))) == "[::1]:8443")
        #expect(Logins.hostname(ofKey: "localhost:3000") == "localhost" && Logins.hostname(ofKey: "[::1]:8443") == "::1" && Logins.hostname(ofKey: "example.com") == "example.com")
        with {
            #expect(Logins.importLogin(host: "localhost:3000", username: "me", password: "three") == .saved)
            #expect(Logins.importLogin(host: "localhost:8080", username: "me", password: "eight") == .saved)
            #expect(Logins.password(host: "localhost:3000", username: "me") == "three")
            #expect(Logins.password(host: "localhost:8080", username: "me") == "eight")
            #expect(Logins.accounts(for: "localhost:3000") == ["me"] && Logins.all().count == 2)
            // A login saved before the port was part of the key (for the host, on any port) still fills, and is not written over.
            #expect(Logins.save(host: "dev.test", username: "old", password: "legacy"))
            #expect(Logins.accounts(for: "dev.test:9000") == ["old"] && Logins.password(host: "dev.test:9000", username: "old") == "legacy")
            #expect(Logins.importLogin(host: "dev.test:9000", username: "old", password: "x") == .saved, "the port's own login is another one")
            #expect(Logins.password(host: "dev.test:9000", username: "old") == "x" && Logins.password(host: "dev.test", username: "old") == "legacy")
        }
    }

    @Test func aSignInInTwoStepsUpdatesTheOneAccountSaved() {
        #expect(LoginOffer.username(captured: "alice", saved: ["alice", "bob"]) == "alice")
        #expect(LoginOffer.username(captured: "", saved: ["alice"]) == "alice")
        #expect(LoginOffer.username(captured: "", saved: []) == "")
        #expect(LoginOffer.username(captured: "", saved: ["alice", "bob"]) == nil, "which one is not known: nothing is offered")
        #expect(LoginOffer.username(captured: "", saved: ["", "bob"]) == "", "a login saved with no name is that one")
        with {
            #expect(Logins.save(host: "example.com", username: "alice", password: "old"))
            let name = LoginOffer.username(captured: "", saved: Logins.accounts(for: "example.com"))
            #expect(name == "alice")
            #expect(Logins.save(host: "example.com", username: name ?? "", password: "new"))
            #expect(Logins.all().map(\.username) == ["alice"], "no second item with an empty account")
            #expect(Logins.password(host: "example.com", username: "alice") == "new")
        }
    }

    @Test func updatingAPasswordOnAPortPageMovesTheLegacyHostOnlyItemToThePortsKey() {
        with {
            #expect(Logins.save(host: "dev.test", username: "me", password: "legacy"))
            #expect(Logins.save(host: "dev.test:9000", username: "me", password: "fresh"))
            #expect(Logins.all().map { $0.host + "/" + $0.username } == ["dev.test:9000/me"], "one item, under the port's key; no parallel one")
            #expect(Logins.password(host: "dev.test:9000", username: "me") == "fresh")
            #expect(Logins.password(host: "dev.test:8080", username: "me") == nil, "the old password no longer fills another port")
            #expect(Logins.save(host: "dev.test:9000", username: "me", password: "again"))
            #expect(Logins.all().count == 1 && Logins.password(exactly: "dev.test:9000", username: "me") == "again")
            // Another account on the legacy key is left alone.
            #expect(Logins.save(host: "dev.test", username: "other", password: "o"))
            #expect(Logins.save(host: "dev.test:9000", username: "me", password: "x"))
            #expect(Logins.all().map { $0.host + "/" + $0.username } == ["dev.test/other", "dev.test:9000/me"])
        }
    }

    @Test func copyingFromTheSettingsReadsTheExactItemOnly() {
        with {
            #expect(Logins.importLogin(host: "dev.test", username: "me", password: "legacy") == .saved)
            #expect(Logins.importLogin(host: "dev.test:9000", username: "me", password: "nine") == .saved)
            #expect(Logins.password(exactly: "dev.test", username: "me") == "legacy")
            #expect(Logins.password(exactly: "dev.test:8080", username: "me") == nil, "not the bare host's, which the lookup for a page would use")
            #expect(Logins.password(exactly: "dev.test:9000", username: "me") == "nine")
            #expect(Logins.password(exactly: "www.dev.test", username: "me") == nil, "not the twin's")
        }
    }

    @Test func aTwoStepSignInIsTheOneAccountSavedUnderExactlyTheKey() {
        with {
            #expect(Logins.save(host: "www.example.com", username: "twin", password: "t"))
            #expect(Logins.save(host: "dev.test", username: "legacy", password: "l"))
            let onExample = LoginOffer.make(host: "example.com", captured: "", password: "p")
            #expect(onExample?.username == "", "the www twin's account is not this site's one account: \(String(describing: onExample))")
            let onPort = LoginOffer.make(host: "dev.test:9000", captured: "", password: "p")
            #expect(onPort?.username == "")
            #expect(Logins.save(host: "example.com", username: "alice", password: "a"))
            let one = LoginOffer.make(host: "example.com", captured: "", password: "new")
            #expect(one?.username == "alice" && one?.updatesExisting == true)
            #expect(Logins.save(host: "example.com", username: "bob", password: "b"))
            #expect(LoginOffer.make(host: "example.com", captured: "", password: "new") == nil, "two accounts: which one is not known")
            let typed = LoginOffer.make(host: "dev.test:9000", captured: "legacy", password: "n")
            #expect(typed?.updatesExisting == true, "a typed name that is saved for the bare host still updates it")
        }
    }

    @Test func importedCookiesDoNotReplaceTheOnesThereAlready() throws {
        func cookie(_ domain: String, _ name: String, _ path: String, _ value: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .name: name, .path: path, .value: value, .originURL: URL(string: "https://example.com/")!]))
        }
        let mine = [try cookie(".example.com", "session", "/", "mine")]
        let theirs = [try cookie(".example.com", "session", "/", "theirs"), try cookie(".example.com", "session", "/app", "theirs"),
                      try cookie(".example.com", "other", "/", "theirs"), try cookie(".EXAMPLE.com", "session", "/", "theirs"), try cookie("other.com", "session", "/", "theirs")]
        let fresh = ImportRunner.newCookies(theirs, existing: mine)
        #expect(fresh.map { "\($0.domain)\($0.name)\($0.path)" } == [".example.comsession/app", ".example.comother/", "other.comsession/"])
    }

    @Test func theReportCountsThePasswordsItKept() {
        var report = ImportReport(source: "Chrome")
        report.passwords = 2
        report.keptPasswords = 3
        #expect(report.summary.contains("3") && report.summary.contains("2"))
        report.passwords = 0
        report.keptPasswords = 0
        #expect(report.summary == ImportReport(source: "x").summary)
    }
}
