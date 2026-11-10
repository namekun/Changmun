import Foundation
import Testing
@testable import Changmun

/// Bookmarks as a file: what other browsers write is read, what Changmun writes comes back, and a hostile file does nothing.
struct BookmarkFileTests {
    private func library() throws -> (Library, URL) {
        let folder = try persistenceScratchFolder()
        return (Library(path: folder.appendingPathComponent("library.sqlite").path), folder)
    }

    private func pairs(_ parsed: BookmarkFile.Parsed) -> [String] { parsed.bookmarks.map { "\($0.folder) | \($0.title) | \($0.url)" } }

    private static let chrome = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <!-- This is an automatically generated file. -->
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" LAST_MODIFIED="2" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://swift.org/" ADD_DATE="3" ICON="data:image/png;base64,AAAA">Swift</A>
            <DT><H3 ADD_DATE="1">Work</H3>
            <DL><p>
                <DT><A HREF="https://example.com/a?x=1&amp;y=2">A &amp; B</A>
            </DL><p>
        </DL><p>
        <DT><H3 ADD_DATE="1">Other bookmarks</H3>
        <DL><p>
            <DT><A HREF="https://other.example/">Other</A>
        </DL><p>
    </DL><p>
    """

    @Test func chromesFileIsReadWithItsFoldersNested() {
        let parsed = BookmarkFile.parse(Self.chrome)
        #expect(pairs(parsed) == [
            "Imported Bookmarks Bar | Swift | https://swift.org/",
            "Imported Bookmarks Bar / Work | A & B | https://example.com/a?x=1&y=2",
            "Imported Other Bookmarks | Other | https://other.example/",
        ])
        #expect(parsed.readingList.isEmpty)
    }

    @Test func firefoxAndSafariFilesNameTheirUsualFolders() {
        let firefox = """
        <DL><p>
        <DT><H3 ADD_DATE="1" LAST_MODIFIED="2">Bookmarks Menu</H3>
        <DL><p>
            <DT><A HREF="https://menu.example/" ADD_DATE="1">Menu</A>
        </DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks Toolbar</H3>
        <DL><p>
            <DT><A HREF="https://bar.example/">Bar</A>
        </DL><p>
        <DT><H3 ADD_DATE="1" UNFILED_BOOKMARKS_FOLDER="true">Alle Lesezeichen</H3>
        <DL><p>
            <DT><A HREF="https://unfiled.example/">Unfiled</A>
        </DL><p>
        </DL>
        """
        #expect(pairs(BookmarkFile.parse(firefox)) == [
            "Imported Bookmarks Menu | Menu | https://menu.example/",
            "Imported Bookmarks Bar | Bar | https://bar.example/",
            "Imported Other Bookmarks | Unfiled | https://unfiled.example/",
        ])
        let safari = """
        <DL><p>
            <DT><H3 FOLDED ADD_DATE="1">Favorites</H3>
            <DL><p><DT><A HREF="https://fav.example/">Fav</A></DL><p>
            <DT><H3 FOLDED ADD_DATE="1">Reading List</H3>
            <DL><p><DT><A HREF="https://read.example/story/" ADD_DATE="1700000000">Story</A></DL><p>
        </DL><p>
        """
        let parsed = BookmarkFile.parse(safari)
        #expect(pairs(parsed) == ["Imported Favorites | Fav | https://fav.example/"])
        #expect(parsed.readingList.map(\.url) == ["https://read.example/story"])
        #expect(parsed.readingList.map(\.read) == [false])
        #expect(parsed.readingList.map(\.added) == [Date(timeIntervalSince1970: 1_700_000_000)])
    }

    @Test func aLinkOutsideAnyFolderGoesToOtherBookmarks() {
        #expect(pairs(BookmarkFile.parse("<DL><DT><A HREF=\"https://loose.example/\">Loose</A></DL>")) == ["Imported Other Bookmarks | Loose | https://loose.example/"])
    }

    @Test func soupWithUnclosedTagsUpperCaseAndBareAttributesIsRead() {
        let soup = """
        <dl><dt><h3>Mixed Case</h3><dl><dt><a href=https://unquoted.example/page>Unquoted<dt><A HREF='https://single.example/'>Single</a>
        <dd>a note that is not a bookmark<DT><A
          HREF="https://multi.example/"
          ADD_DATE="1">Multi
        Line</A>
        <DT><A HREF="https://cut.example/"
        <DT><A HREF="https://after.example/">After
        """
        let parsed = BookmarkFile.parse(soup)
        #expect(pairs(parsed) == [
            "Imported Mixed Case | Unquoted | https://unquoted.example/page",
            "Imported Mixed Case | Single | https://single.example/",
            "Imported Mixed Case | Multi Line | https://multi.example/",
            "Imported Mixed Case |  | https://cut.example/",
            "Imported Mixed Case | After | https://after.example/",
        ])
    }

    @Test func aSlashInAFolderNameDoesNotMakeAnotherFolder() {
        let parsed = BookmarkFile.parse("<DL><DT><H3>Top</H3><DL><DT><H3>Dev / Ops</H3><DL><DT><A HREF=\"https://a.example/\">A</A></DL></DL></DL>")
        #expect(parsed.bookmarks.map(\.folder) == ["Imported Top / Dev ∕ Ops"])
    }

    @Test func aHostileFileGivesOnlyTheWebPagesAndRunsNothing() {
        let hostile = """
        <DL><p><DT><H3>Evil</H3><DL>
        <DT><A HREF="javascript:alert(1)">js</A>
        <DT><A HREF="JaVaScRiPt:alert(2)">js2</A>
        <DT><A HREF="jav&#x61;script:alert(3)">js3</A>
        <DT><A HREF="java&#10;script:alert(4)">js4</A>
        <DT><A HREF="data:text/html,<script>alert(1)</script>">data</A>
        <DT><A HREF="file:///etc/passwd">file</A>
        <DT><A HREF="chrome://settings">chrome</A>
        <DT><A HREF="ftp://ftp.example/file">ftp</A>
        <DT><A HREF="https://">nohost</A>
        <DT><A HREF="https://has space.example/">space</A>
        <DT><A HREF="https://tab&#9;.example/">tab</A>
        <DT><A HREF="https://\(String(repeating: "a", count: 3000)).example/">long</A>
        <DT><A HREF="HTTP://OK.example/Path" onclick="alert(1)" onerror=alert(2)>&lt;b&gt;OK&lt;/b&gt;&amp;lt;<script>alert(1)</script></A>
        <SCRIPT>document.write('<A HREF="https://inscript.example/">x</A>')</SCRIPT>
        <!-- <A HREF="https://comment.example/">c</A> -->
        <STYLE>a{}<A HREF="https://style.example/"></STYLE>
        <IMG SRC="https://tracker.example/pixel.gif"><LINK HREF="https://link.example/">
        </DL></DL>
        """
        let parsed = BookmarkFile.parse(hostile)
        #expect(pairs(parsed) == ["Imported Evil | <b>OK</b>&lt; | HTTP://OK.example/Path"])
        #expect(parsed.readingList.isEmpty)
    }

    @Test func importableAddressesAreWebPagesOnly() {
        for good in ["https://a.example/", "http://a.example:8080/x?y=1#z", " https://a.example/ "] { #expect(BookmarkFile.importableURL(good) != nil, "\(good)") }
        for bad in ["", "a.example", "javascript:alert(1)", "data:text/plain,x", "about:blank", "file:///x", "mailto:a@b.example", "https://", "https:///x", "//a.example/"] {
            #expect(BookmarkFile.importableURL(bad) == nil, "\(bad)")
        }
        #expect(BookmarkFile.importableURL(" https://a.example/ ") == "https://a.example/")
    }

    @Test func aDeeplyNestedOrHugeFileIsReadWithoutTrouble() {
        let deep = String(repeating: "<DL><DT><H3>x</H3>", count: 50_000) + "<DT><A HREF=\"https://deep.example/\">Deep</A>" + String(repeating: "</DL>", count: 50_000)
        let parsed = BookmarkFile.parse(deep)
        #expect(parsed.bookmarks.count == 1)
        #expect(parsed.bookmarks[0].folder.components(separatedBy: " / ").count <= BookmarkFile.maxDepth + 1)
        let wide = String(repeating: "<DT><A HREF=\"https://a.example/x\">t</A>\n", count: 5_000)
        #expect(BookmarkFile.parse("<DL>" + wide).bookmarks.count == 5_000)
        #expect(BookmarkFile.parse(String(repeating: "<", count: 100_000)).bookmarks.isEmpty)
        #expect(BookmarkFile.parse("<A HREF=\"https://x.example/\"" + String(repeating: " a=b", count: 10_000)).bookmarks.count == 1)
        #expect(BookmarkFile.parse("").bookmarks.isEmpty)
        #expect(BookmarkFile.parse("not a bookmark file at all").bookmarks.isEmpty)
    }

    @Test func characterReferencesAreDecodedAndUnknownOnesLeftAlone() {
        #expect(BookmarkFile.decode("a &amp; b &lt;c&gt; &quot;d&quot; &#39;e&#39; &#x41;&#66; &nbsp;") == "a & b <c> \"d\" 'e' AB  ")
        #expect(BookmarkFile.decode("&unknown; &#xZZ; &#99999999999; AT&T &") == "&unknown; &#xZZ; &#99999999999; AT&T &")
    }

    // MARK: Writing and the round trip

    @Test func theFileIsEscapedAndNestedAsTheFormatSays() {
        let html = BookmarkFile.export(
            favorites: [Library.Entry(url: "https://a.example/?x=1&y=\"2\"", title: "<script>alert('x')</script> & more")],
            sources: [(source: "Imported", folders: [Library.Folder(key: "Imported Bookmarks Bar", label: "Bookmarks Bar",
                                                                    entries: [Library.Entry(url: "https://b.example/", title: "B")],
                                                                    children: [Library.Folder(key: "Imported Bookmarks Bar / Sub", label: "Sub", entries: [Library.Entry(url: "https://c.example/", title: "")])])])],
            readingList: [ReadingItem(url: "https://r.example/", title: "Read me", added: Date(timeIntervalSince1970: 1_700_000_000), read: true)])
        #expect(html.hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        #expect(!html.contains("<script>"), "a title is text, never markup")
        #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; more"))
        #expect(html.contains("HREF=\"https://a.example/?x=1&amp;y=&quot;2&quot;\""))
        #expect(html.contains("<DT><H3>Favorites</H3>"))
        #expect(html.contains("<DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">Bookmarks Bar</H3>"))
        #expect(html.contains("ADD_DATE=\"1700000000\""))
        #expect(!html.lowercased().contains("read=") && !html.contains("LAST_VISIT"), "the read state does not leave")
        #expect(html.components(separatedBy: "<DL><p>").count == html.components(separatedBy: "</DL><p>").count)
    }

    @Test func whatIsExportedComesBackFolderForFolderAndNothingIsAddedTwice() throws {
        let (a, folderA) = try library()
        let (b, folderB) = try library()
        defer { try? FileManager.default.removeItem(at: folderA); try? FileManager.default.removeItem(at: folderB) }
        _ = try a.importBookmarks([
            ("https://x.example/", "X", "Imported Bookmarks Bar"),
            ("https://y.example/", "Y & <Z> \"q\"", "Imported Bookmarks Bar / Work 'A'"),
            ("https://o.example/", "Other", "Imported Other Bookmarks"),
            ("https://c.example/", "Chrome one", "Chrome Bookmarks Bar / Sub"),
            ("https://s.example/", "Safari one", "Safari / Favorites"),
        ])
        #expect(a.toggleBookmark(url: "https://fav.example/", title: "Fav"))
        a.addToReadingList(url: "https://r.example/story", title: "Story")
        a.markReadingItem(url: "https://r.example/story", read: true)

        let html = BookmarkFile.export(favorites: a.favorites(), spaceFavorites: [(name: "Travel", entries: [Library.Entry(url: "https://trip.example/", title: "Trip")])],
                                       sources: Library.groupBySource(a.folders(), names: [:], section: { $0 }), readingList: a.readingList())
        guard case .imported(let bookmarks, let readingList) = try BookmarkFile.importBookmarks(from: Data(html.utf8), into: b) else {
            Issue.record("the file read back as nothing")
            return
        }
        #expect(bookmarks == 7 && readingList == 1)

        let back = Dictionary(uniqueKeysWithValues: b.folders().map { ($0.name, $0.entries.map { "\($0.title) | \($0.url)" }) })
        #expect(back == [
            "Imported Bookmarks Bar": ["X | https://x.example/"],
            "Imported Bookmarks Bar / Work 'A'": ["Y & <Z> \"q\" | https://y.example/"],
            "Imported Other Bookmarks": ["Other | https://o.example/"],
            "Imported Chrome / Bookmarks Bar / Sub": ["Chrome one | https://c.example/"],
            "Imported Safari / Favorites": ["Safari one | https://s.example/"],
            "Imported Favorites": ["Fav | https://fav.example/"],
            "Imported Favorites / Travel": ["Trip | https://trip.example/"],
        ])
        #expect(b.favorites().isEmpty, "an import never touches the favorites")
        #expect(b.readingList().map(\.url) == ["https://r.example/story"])
        #expect(b.readingList().allSatisfy { !$0.read }, "only the link travels, not whether it was read")

        let count = b.counts.bookmarks
        guard case .imported = try BookmarkFile.importBookmarks(from: Data(html.utf8), into: b) else { Issue.record("second read failed"); return }
        #expect(b.counts.bookmarks == count, "reading the same file again adds nothing")
        #expect(b.readingList().count == 1)
    }

    @Test func aFileWithNoBookmarksOrTooBigSaysSo() throws {
        let (library, folder) = try library()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try BookmarkFile.importBookmarks(from: Data("<html><body>hello</body></html>".utf8), into: library) == .nothingFound)
        #expect(try BookmarkFile.importBookmarks(from: Data("<DL><DT><A HREF=\"javascript:alert(1)\">x</A></DL>".utf8), into: library) == .nothingFound)
        #expect(try BookmarkFile.importBookmarks(from: Data(count: BookmarkFile.maxFileSize + 1), into: library) == .tooLarge)
        #expect(library.counts.bookmarks == 0)
    }

    @Test func nothingFromAPrivateWindowCanBeInTheFile() {
        // The library is all the export reads, and a private window never writes to it.
        let html = BookmarkFile.export(favorites: [], sources: [], readingList: [])
        #expect(!html.contains("<A "))
    }
}
