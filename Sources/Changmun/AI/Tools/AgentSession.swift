import AppKit
import WebKit

/// Holds one read_page of a tab at a time: the element numbers and frame ranges a read hands out are the tab's single
/// current set, and a second read would take them from under the first.
final class ReadGate {
    private var busy = false

    /// nil when the task was cancelled while waiting for its turn.
    @MainActor func run<T>(_ body: () async -> T) async -> T? {
        while busy {
            if Task.isCancelled { return nil }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        busy = true
        defer { busy = false }
        return await body()
    }
}

/// The frames of one tab that told the app where they are. A frame is only taken for the one a read greeted by its
/// name if it answers with the number that greeting carried, which only the page script of the app and the app know:
/// the page around the frame (or another frame) can greet it too, but can't hand the app a frame under that name.
struct FrameRegistry<Frame> {
    struct Offer {
        var slot: String
        var nonce: String
        var frame: Frame
        var at: Date
    }

    static var maxOffers: Int { 64 }
    static var offerLife: TimeInterval { 60 }

    /// What frames said to the app, newest last.
    private(set) var offers: [Offer] = []
    /// The frames of the latest read (or aim), each with the number the page script gave the greeting.
    private(set) var expected: [String: String] = [:]

    /// A frame says where it is. It is kept for a moment, since it can answer before the read that greets it is over. The first
    /// offer of a name with a number is the one kept: the same words again change nothing. When there is no room, what the
    /// reads are waiting for (a name with the number it was greeted with) stays and the oldest of the rest goes, so a flood of
    /// offers nobody asked for can't push out the frames that answered; with nothing else to remove, the new offer is left out.
    mutating func offer(slot: String, nonce: String, frame: Frame, now: Date = Date()) {
        offers.removeAll { now.timeIntervalSince($0.at) > Self.offerLife }
        guard !offers.contains(where: { $0.slot == slot && $0.nonce == nonce }) else { return }
        if offers.count >= Self.maxOffers {
            guard let oldest = offers.firstIndex(where: { expected[$0.slot] != $0.nonce }) else { return }
            offers.remove(at: oldest)
        }
        offers.append(Offer(slot: slot, nonce: nonce, frame: frame, at: now))
    }

    /// The read greeted this frame with this number.
    mutating func expect(slot: String, nonce: String) {
        if expected.count >= Self.maxOffers, expected[slot] == nil { return }
        expected[slot] = nonce
    }

    /// The frame that answered the greeting of its name; nil when none has (yet), or one answered with another number.
    func frame(for slot: String) -> Frame? {
        guard let nonce = expected[slot] else { return nil }
        return offers.last { $0.slot == slot && $0.nonce == nonce }?.frame
    }

    /// The frames that answered, by their names.
    var known: [(slot: String, frame: Frame)] { expected.keys.compactMap { slot in frame(for: slot).map { (slot, $0) } } }

    /// The frame is gone, or can't be asked anymore: it is not asked about again.
    mutating func drop(slot: String) {
        expected[slot] = nil
        offers.removeAll { $0.slot == slot }
    }

    /// A read begins: only the frames it names are kept.
    mutating func beginRead() {
        expected = [:]
    }

    mutating func endRead() {
        offers.removeAll { offer in expected[offer.slot] != offer.nonce }
    }

    /// The page navigated: a frame the app knew may be another document now.
    mutating func reset() {
        offers = []
        expected = [:]
    }

    /// A frame of the page navigated, and which one can't be told (a frame handle has no identity to compare): every handle is
    /// let go, so none is used for what may be another document now, but the names and numbers the latest read greeted the frames
    /// with stay, so the frames that didn't navigate answer again when greeted and a read under way still knows its frames.
    mutating func frameNavigated() {
        offers = []
    }
}

/// What the app knows about the frames of one tab, for the AI's tools.
struct AgentState {
    var frames = FrameRegistry<WKFrameInfo>()
    /// The element numbers the last read_page gave to the content of each frame of another site.
    var ranges: [(range: ClosedRange<Int>, slot: String)] = []
    let gate = ReadGate()

    /// What the AI last saw of the page, from a read or from the report of what an action changed: the address and title it was
    /// told, and the last element number handed out (new elements are numbered on from it). nil before a read, and after the page
    /// navigated, when its elements are gone.
    struct Seen {
        var url: String
        var title: String
        var lastID: Int
    }

    var seen: Seen?
    /// The page navigated after it was read.
    var navigated = false
    /// Frames that did not answer a look at what changed, and when: they are not asked again for a while, so that one that hangs
    /// can't hold up every report after an action.
    var hung: [String: Date] = [:]
    static let hungFor: TimeInterval = 10

    mutating func beginRead() {
        frames.beginRead()
        ranges = []
        seen = nil
        navigated = false
        hung = [:]
    }

    mutating func endRead() { frames.endRead() }

    /// A frame of the page navigated: see `FrameRegistry.frameNavigated`. The element numbers of the frames' contents stay, and a
    /// number in a frame whose handle is gone is answered as a frame that can't be reached, never taken for the page's own.
    mutating func frameNavigated() { frames.frameNavigated() }

    mutating func reset() {
        frames.reset()
        hung = [:]
        ranges = []
        navigated = navigated || seen != nil
        seen = nil
    }
}

/// A frame of another site can't be reached from the page's own scripts. Each one runs a small script of the app's
/// (in the isolated world, so the page can't see or answer it) that, when the page script of the app greets the frame
/// by name with a number used once, tells the app; the message carries the frame, which WebKit lets the app run
/// scripts in. The number is known to the app's script and to the app only: the page around the frame can greet the
/// frame too, but not with that number.
final class FrameWatcher: NSObject, WKScriptMessageHandler {
    static let name = "changmunFrame"

    static let script = """
    (() => {
      if (window === window.top) return;
      addEventListener('message', e => {
        const d = e.data;
        if (e.source === window.parent && d && typeof d.changmunFrame === 'string' && typeof d.nonce === 'string') window.webkit.messageHandlers.\(name).postMessage(d.changmunFrame + ':' + d.nonce);
      });
    })();
    """

    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        controller.add(FrameWatcher(), contentWorld: .defaultClient, name: name)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, let body = message.body as? String, body.count <= 100 else { return }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        MainActor.assumeIsolated {
            Browser.all.lazy.flatMap(\.tabs).first { $0.webView === message.webView }?.agent.frames.offer(slot: String(parts[0]), nonce: String(parts[1]), frame: message.frameInfo)
        }
    }
}

extension Tab {
    /// The frame a name from the page script stands for, given a moment for the frame to answer the greeting.
    func frame(named slot: String) async -> WKFrameInfo? {
        for _ in 0..<14 {
            if let frame = agent.frames.frame(for: slot) { return frame }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// Several frames, each given its moment at the same time: the ones that answered, by their names.
    func frames(named slots: [String]) async -> [String: WKFrameInfo] {
        await withTaskGroup(of: (String, WKFrameInfo?).self) { group in
            for slot in slots { group.addTask { @MainActor in (slot, await self.frame(named: slot)) } }
            var found: [String: WKFrameInfo] = [:]
            for await (slot, info) in group { if let info { found[slot] = info } }
            return found
        }
    }
}

/// Every password field is known to the AI's scripts as one from the moment its page begins, not only from the first tool call.
enum PasswordWatcher {
    static func install(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: PageScripts.watchPasswords, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
    }
}

struct ToolFailure: Error {
    var result: ToolResult
}

/// One tool call of one caller, and the stop count of the caller when it began: after every wait for the user, a call
/// that was stopped in the meantime goes no further.
struct Session {
    /// A call goes no further after this long: the client that asked gives up on it (120 s), and what it was told then is that
    /// the call failed, so nothing may be done after that, whatever the user answered.
    static var lifetime: TimeInterval = 110

    var caller: String
    var token: Int
    var deadline: Date
    /// The site the tab was approved for when it wasn't the page in front; the pages and frames the call reaches are checked against it.
    var approved: String?

    @MainActor init(caller: String, approved: String? = nil) {
        self.caller = caller
        self.approved = approved
        token = AgentActivity.shared.stopCount(for: caller)
        deadline = Date().addingTimeInterval(Self.lifetime)
    }

    @MainActor var stopped: Bool { AgentActivity.shared.stopCount(for: caller) != token || Date() > deadline }
}
