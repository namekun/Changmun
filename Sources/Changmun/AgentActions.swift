import AppKit
import WebKit

/// The keys the AI may press. Letters, digits and symbols are not among them, so a key press can't be used to type
/// something into a page: that is type_text's job, and it comes with its own approvals.
enum AgentKey {
    static let names = ["Enter", "Escape", "Tab", "Backspace", "Delete", "Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"]
    static let modifierNames = ["shift", "alt", "ctrl", "meta"]
    private static let aliases = ["control": "ctrl", "option": "alt", "cmd": "meta", "command": "meta"]

    /// The key's proper name for a name in any letter case; nil for anything not on the list.
    static func name(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return names.first { $0.lowercased() == text.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Which modifiers are held, from a list of their names; nil when the list holds anything else.
    static func modifiers(_ value: Any?) -> [String: Bool]? {
        guard let words = value == nil ? [] : value as? [Any] else { return nil }
        var held = Dictionary(uniqueKeysWithValues: modifierNames.map { ($0, false) })
        for word in words {
            guard let text = (word as? String)?.lowercased() else { return nil }
            let name = aliases[text] ?? text
            guard held[name] != nil else { return nil }
            held[name] = true
        }
        return held
    }
}

/// Whether a click or key press looks like it pays, orders, sends, posts, deletes, transfers or confirms something.
/// It goes by what the page shows: every name the control has (what it says, its accessible name, a picture's alt text,
/// its title), the words in the markup of a control that has none (an icon), where it goes (the address of a link, the
/// address, name and value of a button), and a submit button in a form that asks for card details or posts to a checkout
/// or the like. It errs toward asking: a page can name a button anything, so a harmless-looking name proves nothing, and a
/// name that merely contains a keyword (a "Post office" link) is asked about too. Generic words of agreement ("OK",
/// "확인") are not enough to ask.
enum IrreversibleAction {
    struct Facts: Equatable {
        /// The name to show for what is activated.
        var label = ""
        /// Every name it has, and every name that could be (Enter in a field presses the form's default button).
        var names: [String] = []
        /// What the markup of a control with no words says: class, id, data names, the picture it shows.
        var hints: [String] = []
        /// Where it goes, for any control: the path and query of its address (link or formaction), a button's name and value.
        var dests: [String] = []
        /// It submits a form.
        var submits = false
        /// The form asks for card or bank details.
        var payment = false
        /// Where the form posts to.
        var action = ""
        /// It sends a message: Enter in a message box.
        var sends = false

        init(label: String = "", names: [String] = [], hints: [String] = [], dests: [String] = [], submits: Bool = false, payment: Bool = false, action: String = "", sends: Bool = false) {
            self.label = label
            self.names = names
            self.hints = hints
            self.dests = dests
            self.submits = submits
            self.payment = payment
            self.action = action
            self.sends = sends
        }

        init(_ json: [String: Any]) {
            self.init(label: json["label"] as? String ?? "", names: json["names"] as? [String] ?? [], hints: json["hints"] as? [String] ?? [],
                      dests: json["dests"] as? [String] ?? [], submits: json["submits"] as? Bool ?? false, payment: json["payment"] as? Bool ?? false, action: json["action"] as? String ?? "",
                      sends: json["sends"] as? Bool ?? false)
        }
    }

    static func looksIrreversible(_ facts: Facts) -> Bool {
        facts.sends || (facts.names + facts.hints).contains(where: matches) || facts.dests.contains(where: goesToIrreversible)
            || (facts.submits && (facts.payment || postsToCheckout(facts.action)))
    }

    /// The name to show the user: the one that looked risky, else the control's own.
    static func name(of facts: Facts) -> String {
        facts.names.first(where: matches) ?? (facts.label.isEmpty ? facts.hints.first(where: matches) ?? "" : facts.label)
    }

    /// Words (whole words only, accents and case ignored) of the Latin-script languages.
    private static let words: Set<String> = Set([
        // English
        "buy", "buys", "buying", "purchase", "purchases", "purchasing", "pay", "pays", "paying", "order", "orders", "ordering", "checkout",
        "send", "sends", "sending", "post", "posting", "publish", "publishing", "delete", "deleting", "remove", "removing",
        "transfer", "transferring", "confirm", "confirming", "donate", "donating", "reply",
        "submit", "submitting", "save", "saving", "share", "sharing", "comment", "tweet", "merge", "merging", "approve", "approving",
        "authorize", "authorise", "authorizing", "withdraw", "withdrawing", "book", "reserve", "reserving", "subscribe", "subscribing", "unsubscribe",
        "trash", "bin", "recycle", "discard", "erase", "revoke", "deactivate", "terminate",
        "allow", "allowing", "accept", "accepting", "agree", "agreeing", "grant", "granting", "connect", "connecting", "sell", "selling", "bid", "bidding",
        "invest", "investing", "trade", "trading", "invite", "inviting", "upload", "uploading", "install", "installing", "enable", "enabling",
        "disable", "disabling", "disconnect", "disconnecting", "unlink", "reset", "resetting", "clear", "clearing", "wipe", "wiping", "empty", "emptying",
        "ban", "banning", "block", "blocking", "complete", "completing", "finish", "finishing",
        // Spanish
        "comprar", "compra", "pagar", "pago", "pedir", "pedido", "enviar", "envia", "publicar", "eliminar", "borrar", "transferir", "transferencia",
        "confirmar", "donar", "responder",
        "guardar", "compartir", "comentar", "aprobar", "autorizar", "retirar", "reservar", "suscribirse", "suscribir", "papelera", "descartar", "revocar",
        "permitir", "acepto", "conceder", "otorgar", "conectar", "vender", "pujar", "invertir", "invitar", "subir", "instalar", "activar", "desactivar",
        "desconectar", "desvincular", "restablecer", "vaciar", "bloquear", "completar", "finalizar",
        // German
        "kaufen", "kauf", "bezahlen", "zahlen", "zahlungspflichtig", "bestellen", "bestellung", "senden", "absenden", "abschicken", "versenden",
        "posten", "veröffentlichen", "löschen", "entfernen", "überweisen", "bestätigen", "spenden", "antworten",
        "speichern", "teilen", "kommentieren", "genehmigen", "autorisieren", "abheben", "buchen", "reservieren", "abonnieren", "abbestellen", "einreichen",
        "papierkorb", "verwerfen", "widerrufen",
        "erlauben", "zulassen", "akzeptieren", "zustimmen", "gewähren", "verbinden", "verkaufen", "bieten", "investieren", "handeln", "einladen", "hochladen",
        "installieren", "aktivieren", "deaktivieren", "trennen", "zurücksetzen", "leeren", "sperren", "blockieren", "abschließen", "beenden", "fertigstellen",
        // French
        "acheter", "achat", "payer", "régler", "commander", "commande", "valider", "envoyer", "publier", "supprimer", "retirer", "virer", "virement",
        "transférer", "confirmer", "répondre",
        "enregistrer", "sauvegarder", "partager", "commenter", "approuver", "autoriser", "réserver", "abonner", "soumettre", "corbeille", "poubelle",
        "résilier", "désabonner",
        "accepter", "accorder", "vendre", "enchérir", "investir", "inviter", "téléverser", "installer", "activer", "désactiver", "dissocier",
        "réinitialiser", "vider", "effacer", "bannir", "bloquer", "terminer", "finaliser", "compléter",
    ].map(fold))

    private static let phrases = ["check out", "place order", "passer la commande", "finalizar compra", "realizar pedido", "zur kasse"].map(fold)

    /// Cancelling is ordinary (a dialog's Cancel button), except for a subscription, an order, a booking or the like.
    private static let cancelWords: Set<String> = Set(["cancel", "cancels", "cancelling", "canceling", "cancellation", "cancelar", "annuler", "stornieren", "kündigen"].map(fold))
    private static let cancelContext: Set<String> = Set([
        "subscription", "subscriptions", "order", "orders", "membership", "plan", "booking", "reservation", "account", "trip", "flight", "appointment", "contract",
        "suscripción", "pedido", "membresía", "reserva", "cuenta", "abonnement", "commande", "réservation", "compte", "abo", "bestellung", "mitgliedschaft", "konto",
        "buchung", "vertrag",
    ].map(fold))

    /// Korean, Japanese and Chinese have no spaces between words, so these are looked for anywhere in the text.
    private static let characters = [
        "구매", "결제", "주문", "보내", "전송", "게시", "삭제", "송금", "발송", "이체", "제거", "발행", "후원", "답글",
        "탈퇴", "해지", "제출", "신청", "구독", "휴지통",
        "저장", "공유", "등록", "댓글", "승인", "출금", "허용", "동의", "수락", "연결", "판매", "입찰", "투자", "초대", "업로드", "설치", "활성화", "비활성화",
        "초기화", "차단", "완료",
        "購入", "支払", "決済", "注文", "送信", "投稿", "削除", "送金", "公開", "振込", "寄付", "返信",
        "退会", "申し込み", "申込", "予約", "解約", "ゴミ箱",
        "保存", "共有", "登録", "コメント", "承認", "出金", "許可", "同意", "承諾", "接続", "売却", "入札", "投資", "招待", "アップロード", "インストール",
        "有効化", "無効化", "切断", "リセット", "クリア", "ブロック", "完了",
        "购买", "購買", "支付", "付款", "下单", "下單", "发送", "發送", "发布", "發佈", "發布", "删除", "刪除", "转账", "轉帳", "结算", "結算", "订购", "訂購", "提交订单", "提交訂單",
        "捐款", "回复", "回覆", "确认订单", "確認訂單",
        "提交", "注销", "註銷", "预订", "預訂", "预约", "預約", "订阅", "訂閱", "取消订阅", "取消订单", "取消訂單", "垃圾桶", "垃圾箱", "回收站", "废纸篓",
        "保存", "分享", "评论", "評論", "批准", "提现", "提現", "允许", "允許", "同意", "接受", "授权", "授權", "连接", "連接", "出售", "竞拍", "競拍", "投资", "投資",
        "邀请", "邀請", "上传", "上傳", "安装", "安裝", "启用", "啟用", "禁用", "断开", "斷開", "重置", "清空", "封禁", "屏蔽", "完成",
    ]

    /// Ordinary words that contain one of those: pages and lists a link goes to (a board, a history of orders), not what they
    /// would do. They are taken out before looking for the words above.
    private static let ordinaryCompounds = [
        "게시판", "게시글", "게시물", "구매후기", "구매 후기", "구매내역", "구매 내역", "주문내역", "주문 내역", "주문조회", "주문 조회", "주문목록", "주문 목록",
        "결제내역", "결제 내역", "결제수단", "결제 수단", "등록일", "신청내역", "신청 내역",
        "投稿一覧", "投稿者", "投稿日", "公開日", "公開中", "注文履歴", "注文一覧", "注文番号", "購入履歴", "支払い方法", "支払方法", "決済方法", "送信者", "予約一覧", "申込一覧", "保存済み",
        "发布会", "發佈會", "发布时间", "發布時間", "发布日期", "发布者", "最新发布", "新闻发布", "新聞發布", "订单查询", "訂單查詢", "订单列表", "訂單列表", "购买记录", "購買記錄",
        "购买须知", "购买指南", "支付方式", "付款方式", "已完成", "保存的",
    ]

    /// Without the characters that can split a word without showing (zero-width spaces and joiners, soft hyphens,
    /// direction marks), and with look-alike forms (full-width letters, ligatures) made plain.
    private static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.properties.generalCategory != .format }))
    }

    private static func fold(_ text: String) -> String {
        clean(text).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func matches(_ text: String) -> Bool {
        var cleaned = clean(text)
        for compound in ordinaryCompounds { cleaned = cleaned.replacingOccurrences(of: compound, with: " ") }
        if characters.contains(where: cleaned.contains) { return true }
        let tokens = fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: words.contains) { return true }
        if tokens.contains(where: cancelWords.contains) && tokens.contains(where: cancelContext.contains) { return true }
        let spaced = " " + tokens.joined(separator: " ") + " "
        return phrases.contains { spaced.contains(" \($0) ") }
    }

    /// Where a link, a button or a form goes that pays or gives something up, in the words of an address.
    private static let destinationWords: Set<String> = [
        "checkout", "payment", "payments", "pay", "purchase", "buy", "delete", "remove", "destroy", "erase", "purge", "trash", "transfer", "withdraw",
        "send", "cancel", "unsubscribe", "confirm", "revoke", "deactivate", "terminate",
    ]

    /// A form posts to places that read like these as the last step of something, whatever its button says.
    private static let checkoutWords: Set<String> = destinationWords.union([
        "order", "orders", "billing", "charge", "publish", "comment", "comments", "reply", "message", "messages", "subscribe", "donate", "transfers",
    ])

    /// The words of an address, a name or a value: split at everything that is not a letter and where a capital follows a small
    /// letter ("deleteAccount").
    private static func pieces(_ text: String) -> [String] {
        var out: [String] = [], word = "", afterSmall = false
        for character in text.prefix(300) {
            guard character.isLetter else {
                if !word.isEmpty { out.append(word) }
                word = ""
                afterSmall = false
                continue
            }
            if character.isUppercase && afterSmall {
                out.append(word)
                word = ""
            }
            word.append(character)
            afterSmall = character.isLowercase
        }
        if !word.isEmpty { out.append(word) }
        return out.map(fold)
    }

    /// A form that posts to /checkout or /pay, or to /delete or /send, is the last step of a purchase or a loss whatever its button says.
    static func postsToCheckout(_ action: String) -> Bool {
        guard let path = URL(string: action)?.path else { return false }
        return pieces(path).contains(where: checkoutWords.contains)
    }

    /// Whether the address, name or value a control goes by says it pays, deletes, sends or cancels.
    static func goesToIrreversible(_ destination: String) -> Bool {
        pieces(destination).contains(where: destinationWords.contains)
    }
}

/// What the AI is doing now: the line the panel shows, the tabs it is using (which must keep running while the user
/// looks at another), and the stop button's reach into a wait or an approval that is under way.
@MainActor
final class AgentActivity: ObservableObject {
    static let shared = AgentActivity()
    /// A tab used by another caller than the panel (which says when its run ends) counts as in use for this long.
    static let lease: TimeInterval = 90
    /// So many tabs at most are kept drawing behind the page shown; the rest of those in use are only kept awake.
    static let maxHeld = 3

    /// The tabs in use that are kept drawing, the most recently used first, for the views that keep them.
    @Published private(set) var held: [Int] = []
    private var stops: [String: Int] = [:]
    /// Per tab and caller, when the tab was last used.
    private var uses: [Int: [String: Date]] = [:]
    private var panelRun: Date?
    private var expiry: Task<Void, Never>?

    /// Counts a caller's stops: what began before one ends at it.
    func stopCount(for caller: String) -> Int {
        stops[caller] ?? 0
    }

    func use(_ tab: Tab, caller: String) {
        uses[tab.id, default: [:]][caller] = Date()
        refresh()
        scheduleExpiry()
    }

    private func valid(_ caller: String, at date: Date) -> Bool {
        if caller == ChatStore.caller { return panelRun.map { date >= $0 } ?? false }
        return Date().timeIntervalSince(date) < Self.lease
    }

    func holds(_ tab: Tab) -> Bool {
        uses[tab.id]?.contains { valid($0.key, at: $0.value) } ?? false
    }

    func runStarted() {
        panelRun = Date()
    }

    func runEnded() {
        panelRun = nil
        refresh()
    }

    /// Drops what is no longer in use, and works out which tabs are kept drawing.
    private func refresh() {
        for (id, callers) in uses {
            let live = callers.filter { valid($0.key, at: $0.value) }
            uses[id] = live.isEmpty ? nil : live
        }
        let newest = uses.sorted { ($0.value.values.max() ?? .distantPast) > ($1.value.values.max() ?? .distantPast) }.map(\.key)
        let now = Array(newest.filter { ToolCatalog.findTab($0) != nil }.prefix(Self.maxHeld))
        if now != held { held = now }
    }

    /// One timer for all the leases: it wakes when the first one runs out.
    private func scheduleExpiry() {
        expiry?.cancel()
        let soonest = uses.values.flatMap { $0.filter { $0.key != ChatStore.caller }.values }.min()
        guard let soonest else { return }
        let wait = max(0, soonest.addingTimeInterval(Self.lease).timeIntervalSinceNow) + 0.5
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh()
            self?.scheduleExpiry()
        }
    }

    /// The stop button (and a new chat, and the end of the AI's process): what the caller has under way ends, a question
    /// waiting for the user's answer is withdrawn as no, the marks the AI drew come off the pages, and the line goes.
    func cancel(caller: String = ChatStore.caller) {
        stops[caller, default: 0] += 1
        Approvals.cancelPending(caller: caller)
        for (id, callers) in uses where callers[caller] != nil {
            guard let tab = ToolCatalog.findTab(id), let webView = tab.webView else { continue }
            for frame in [nil] + tab.agent.frames.known.map({ Optional($0.frame) }) {
                webView.callAsyncJavaScript(PageScripts.clearMarks, arguments: [:], in: frame, in: .defaultClient) { _ in }
            }
        }
        if caller == ChatStore.caller {
            ChatStore.shared.step = nil
            runEnded()
        }
    }

    /// Tells the panel what a tool call from it is doing, while one of its runs lasts.
    func step(_ text: String?, caller: String) {
        if caller == ChatStore.caller, panelRun != nil || text == nil { ChatStore.shared.step = text }
    }
}

/// Holds one read_page of a tab at a time: the element numbers and frame ranges a read hands out are the tab's single
/// current set, and a second read would take them from under the first.
final class ReadGate {
    private var busy = false

    @MainActor func run<T>(_ body: () async -> T) async -> T {
        while busy { try? await Task.sleep(for: .milliseconds(50)) }
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

    /// A frame says where it is. It is kept for a moment, since it can answer before the read that greets it is over.
    mutating func offer(slot: String, nonce: String, frame: Frame, now: Date = Date()) {
        offers.removeAll { now.timeIntervalSince($0.at) > Self.offerLife }
        offers.append(Offer(slot: slot, nonce: nonce, frame: frame, at: now))
        if offers.count > Self.maxOffers { offers.removeFirst(offers.count - Self.maxOffers) }
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
}

/// What the app knows about the frames of one tab, for the AI's tools.
struct AgentState {
    var frames = FrameRegistry<WKFrameInfo>()
    /// The element numbers the last read_page gave to the content of each frame of another site.
    var ranges: [(range: ClosedRange<Int>, slot: String)] = []
    let gate = ReadGate()

    mutating func beginRead() {
        frames.beginRead()
        ranges = []
    }

    mutating func endRead() { frames.endRead() }

    mutating func reset() {
        frames.reset()
        ranges = []
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

    @MainActor init(caller: String) {
        self.caller = caller
        token = AgentActivity.shared.stopCount(for: caller)
        deadline = Date().addingTimeInterval(Self.lifetime)
    }

    @MainActor var stopped: Bool { AgentActivity.shared.stopCount(for: caller) != token || Date() > deadline }
}

extension ToolCatalog {
    static let unreachableFrame = ToolResult.text("Error: that part of the page is a frame from another site that Changmun couldn't reach. Use the rest of the page, or tell the user.", error: true)
    static let stopped = ToolResult.text("Stopped: the user stopped it, or it took too long.", error: true)

    static func number(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let v as Int: number = Double(v)
        case let v as Double: number = v
        case let v as String: number = Double(v.trimmingCharacters(in: .whitespaces))
        default: number = nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    /// A coordinate for display, kept to a sane range.
    static func pixels(_ value: Any?) -> Int {
        Int(min(max(number(value) ?? 0, 0), 1_000_000))
    }

    /// What is wrong with the arguments of the tools that act on the page, before any tab is touched.
    static func validate(_ name: String, _ args: [String: Any]) -> String? {
        func hasElement(_ key: String) -> Bool { args[key] != nil && int(args[key]) != nil }
        func hasPoint(_ prefix: String) -> Bool {
            guard let x = number(args[prefix + "x"]), let y = number(args[prefix + "y"]) else { return false }
            return x >= 0 && y >= 0 && x < 1_000_000 && y < 1_000_000
        }
        switch name {
        case "press_key":
            guard AgentKey.name(args["key"]) != nil else { return "key must be one of: " + AgentKey.names.joined(separator: ", ") + "." }
            guard AgentKey.modifiers(args["modifiers"]) != nil else { return "modifiers must be a list of: " + AgentKey.modifierNames.joined(separator: ", ") + "." }
            if args["element_id"] != nil && !hasElement("element_id") { return "element_id must be a number." }
        case "select_option":
            guard hasElement("element_id"), let option = args["option"] as? String, !option.isEmpty else { return "element_id and option are required." }
        case "hover":
            guard hasElement("element_id") else { return "element_id is required." }
        case "click_at":
            guard hasPoint("") else { return "x and y are required: CSS pixels from the top left of the visible page, as in a screenshot." }
        case "wait_for":
            if let text = args["text"], (text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { return "text must be a non-empty string." }
            if args["gone"] != nil && args["gone"] as? Bool == nil { return "gone must be true or false." }
            if args["gone"] as? Bool == true && args["text"] == nil { return "gone needs the text to wait for to disappear." }
            if args["timeout"] != nil && number(args["timeout"]).map({ $0 > 0 }) != true { return "timeout must be a number of seconds." }
        case "drag":
            guard hasElement("from_element_id") != hasPoint("from_"), hasElement("to_element_id") != hasPoint("to_") else {
                return "Give where to drag from and where to drop: from_element_id or from_x and from_y, and to_element_id or to_x and to_y."
            }
        default:
            break
        }
        return nil
    }

    // MARK: Reading, with frames

    private struct Part {
        var title = "", url = "", origin = "", text = ""
        var scroll = 0, height = 0, viewport = 0, count = 0
        var capped = false
        var lines: [String] = []
        var frames: [(slot: String, nonce: String, src: String, title: String)] = []
    }

    private static func readPart(_ arguments: [String: Any], frame: WKFrameInfo?, in webView: WKWebView, timeout: Double) async -> Part? {
        let result = await run(PageScripts.read, arguments, in: webView, frame: frame, timeout: timeout)
        guard !result.isError, let text = result.content.first?["text"] as? String,
              let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return Part(title: json["title"] as? String ?? "", url: json["url"] as? String ?? "", origin: json["origin"] as? String ?? "", text: json["text"] as? String ?? "",
                    scroll: int(json["scroll"]) ?? 0, height: int(json["height"]) ?? 0, viewport: int(json["viewport"]) ?? 0, count: int(json["count"]) ?? 0,
                    capped: json["capped"] as? Bool ?? false, lines: json["lines"] as? [String] ?? [],
                    frames: (json["frames"] as? [[String: Any]] ?? []).map { ($0["slot"] as? String ?? "", $0["nonce"] as? String ?? "", $0["src"] as? String ?? "", $0["title"] as? String ?? "") })
    }

    /// The site an origin names, as the approvals know sites: "" for an origin that has none (a sandboxed frame, a data: page).
    static func host(ofOrigin origin: String) -> String {
        Approvals.site(ofOrigin: origin)
    }

    static let readTimeout = 10.0, frameTimeout = 5.0, pageReadDeadline = 25.0

    /// The page as text: its elements are numbered on through the frames of the same site (read from the page) and then
    /// the frames of other sites (each read by the script run inside it), so every number works with the tools.
    @MainActor
    static func readPage(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session) async -> (ToolResult, frameHosts: Set<String>) {
        await tab.agent.gate.run { await readPageAlone(tab, webView, maxChars: maxChars, session: session) }
    }

    @MainActor
    private static func readPageAlone(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session) async -> (ToolResult, frameHosts: Set<String>) {
        tab.agent.beginRead()
        defer { tab.agent.endRead() }
        let maxElements = 250
        let deadline = Date().addingTimeInterval(pageReadDeadline)
        guard let page = await readPart(["maxChars": maxChars, "start": 0, "limit": maxElements], frame: nil, in: webView, timeout: readTimeout) else {
            return (.text("Error: the page did not answer in time (a dialog may be open).", error: true), [])
        }
        var lines = page.lines, count = page.count, capped = page.capped, framesText = "", hosts = Set<String>()
        func readFrames(_ frames: [(slot: String, nonce: String, src: String, title: String)], depth: Int) async {
            for ref in frames.prefix(8) {
                let name = ref.src.isEmpty ? ref.title : ref.src
                tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce)
                guard depth < 2, Date() < deadline, !session.stopped, let info = await tab.frame(named: ref.slot),
                      let part = await readPart(["maxChars": min(maxChars, 4000), "start": count, "limit": max(maxElements - count, 0)], frame: info, in: webView,
                                                timeout: min(frameTimeout, max(deadline.timeIntervalSinceNow, 1))) else {
                    framesText += "\n\n--- Frame: \(name) (from another site; its content could not be read) ---"
                    continue
                }
                // The site is the one the frame says it is in, from inside: where it was when it greeted may be another by now.
                let host = Self.host(ofOrigin: part.origin)
                // A frame that showed nothing (a tracking pixel, an empty box) gave nothing from its site.
                if !part.lines.isEmpty || part.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 { hosts.insert(host.isEmpty ? Approvals.unknownFrame : host) }
                lines += part.lines.map { $0 + " (in a frame of \(host.isEmpty ? "another site" : host))" }
                if part.count > count { tab.agent.ranges.append((count + 1...part.count, ref.slot)) }
                count = max(count, part.count)
                capped = capped || part.capped
                framesText += "\n\n--- Frame: \(part.url) ---\n" + part.text
                await readFrames(part.frames, depth: depth + 1)
            }
        }
        await readFrames(page.frames, depth: 0)
        let cut = capped ? "\n(Only the first \(maxElements) elements are listed. Scroll, or use click_at for the rest.)" : ""
        return (.text("Title: \(page.title)\nURL: \(page.url)\nScroll: \(page.scroll) of \(page.height) (viewport \(page.viewport))"
                      + "\n\n--- Interactive elements ---\n" + (lines.isEmpty ? "(none)" : lines.joined(separator: "\n")) + cut
                      + "\n\n--- Page text ---\n" + page.text + framesText), hosts)
    }

    /// The frame an element number from the last read lives in: nil for the page itself or a frame of its own site.
    @MainActor
    private static func frame(ofElement id: Int, in tab: Tab) async -> Result<WKFrameInfo?, ToolFailure> {
        guard let slot = tab.agent.ranges.first(where: { $0.range.contains(id) })?.slot else { return .success(nil) }
        guard let frame = await tab.frame(named: slot) else { return .failure(ToolFailure(result: unreachableFrame)) }
        return .success(frame)
    }

    /// The frames a picture shows, from the answer of the script that lists them: nil when it gave none, and `more` when there
    /// are more than the app asks about.
    static func shownFrames(from answer: String?) -> (refs: [(slot: String, nonce: String)], more: Bool)? {
        guard let answer, let list = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [[String: String]] else { return nil }
        let first = list.prefix(maxShownFrames)
        let refs = first.compactMap { ref in ref["slot"].flatMap { slot in ref["nonce"].map { (slot, $0) } } }
        return (refs, list.count > first.count || refs.count < first.count)
    }

    static let maxShownFrames = 8

    /// The sites of the frames a picture of the page shows (also those inside frames of other sites), each asked where it
    /// really is. A frame that can't be reached or has no site, one beyond the first few, and a list that could not be had
    /// all count as an unknown frame, which is a site of its own for the approvals: the picture may show anything there.
    @MainActor
    static func shownFrameHosts(_ tab: Tab, _ webView: WKWebView) async -> Set<String> {
        var hosts = Set<String>()
        func visit(_ frame: WKFrameInfo?, depth: Int) async {
            let result = await run(PageScripts.visibleFrames, [:], in: webView, frame: frame, timeout: 5)
            guard let shown = shownFrames(from: result.isError ? nil : result.content.first?["text"] as? String) else {
                hosts.insert(Approvals.unknownFrame)
                return
            }
            // Frames in frames in frames are not followed any further.
            if shown.more || (depth >= 3 && !shown.refs.isEmpty) { hosts.insert(Approvals.unknownFrame) }
            for ref in shown.refs where depth < 3 {
                tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce)
                var host = Approvals.unknownFrame
                if let info = await tab.frame(named: ref.slot) {
                    let origin = await run(PageScripts.origin, [:], in: webView, frame: info, timeout: 3)
                    if !origin.isError, let origin = origin.content.first?["text"] as? String, !Self.host(ofOrigin: origin).isEmpty { host = Self.host(ofOrigin: origin) }
                    await visit(info, depth: depth + 1)
                }
                hosts.insert(host)
            }
        }
        await visit(nil, depth: 0)
        return hosts
    }

    // MARK: Aiming

    /// Where a tool's target is and what acting on it would do: the frame to run the action in, the target in that
    /// frame's own pixels or numbers, and what the target is.
    struct Aim {
        var frame: WKFrameInfo?
        var slot: String?
        /// What was asked of the page to find it (an element number, a point, the focus, the key to be pressed).
        var args: [String: Any]
        var facts: IrreversibleAction.Facts
        var secret: Bool
        var description: String
        /// The origin of the document it is in, as that document says: "null" for a sandboxed frame or a data: page.
        var origin: String
        /// What the page showed of it, so that the action can tell it is still the same thing.
        var fingerprint: String
        /// The site it is in, by what the document says: "" when it has none (a frame with no site). The page of the tab itself,
        /// when it has none (a file: page), is the site of its scheme.
        var host: String
        var label: String { facts.label.isEmpty ? (args["id"] as? Int).map { "[\($0)]" } ?? "" : facts.label }

        /// The arguments the script that acts looks at: where, what it must still be, and anything the action needs.
        func scriptArgs(_ extra: [String: Any] = [:]) -> [String: Any] {
            args.merging(["expect": ["origin": origin, "fp": fingerprint]]) { $1 }.merging(extra) { $1 }
        }

        func script(_ extra: [String: Any] = [:]) -> [String: Any] { ["args": scriptArgs(extra)] }

        /// The same target, judged by other facts (the option a list would choose, not the list).
        func judged(as facts: IrreversibleAction.Facts) -> Aim {
            var copy = self
            copy.facts = facts
            return copy
        }
    }

    /// Finds the target (an element number, a point, or what has the focus), following a point or the focus into
    /// frames of other sites, without acting on it. `key` is the key about to be pressed on it, if any; `typing` says the
    /// tool types the text itself, with Enter after it when `key` is Enter; `drop` says a drag ends on it.
    @MainActor
    static func aim(_ wanted: [String: Any], key: String? = nil, typing: Bool = false, drop: Bool = false, tab: Tab, in webView: WKWebView, session: Session) async throws -> Aim {
        var target = wanted, frame: WKFrameInfo?, slot: String?
        if let id = target["id"] as? Int {
            switch await Self.frame(ofElement: id, in: tab) {
            case .failure(let failure): throw failure
            case .success(let found):
                frame = found
                slot = tab.agent.ranges.first { $0.range.contains(id) }?.slot
            }
        }
        for _ in 0..<5 {
            var args = target
            if let key { args["key"] = key }
            if typing { args["typing"] = true }
            if drop { args["drop"] = true }
            let result = await run(PageScripts.inspect, ["args": args], in: webView, frame: frame)
            if result.isError { throw ToolFailure(result: result) }
            guard let text = result.content.first?["text"] as? String,
                  let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw ToolFailure(result: .text("Error: the page did not answer.", error: true))
            }
            if let next = json["relay"] as? String {
                tab.agent.frames.expect(slot: next, nonce: json["nonce"] as? String ?? "")
                guard let info = await tab.frame(named: next) else { throw ToolFailure(result: unreachableFrame) }
                frame = info
                slot = next
                if json["active"] as? Bool == true {
                    target = ["active": true]
                } else if let x = number(json["x"]), let y = number(json["y"]) {
                    target = ["x": x, "y": y]
                } else {
                    throw ToolFailure(result: .text("Error: the page did not answer.", error: true))
                }
                continue
            }
            var facts = IrreversibleAction.Facts(json)
            if facts.label.isEmpty, let x = target["x"] as? Double, let y = target["y"] as? Double { facts.label = "\(Int(x)), \(Int(y))" }
            let tabHost = Approvals.site(of: tab.url) ?? ""
            let origin = json["origin"] as? String ?? "null"
            var host = ToolCatalog.host(ofOrigin: origin)
            if host.isEmpty && frame == nil { host = tabHost }
            let aim = Aim(frame: frame, slot: slot, args: args, facts: facts, secret: json["secret"] as? Bool ?? false,
                          description: json["description"] as? String ?? "", origin: origin, fingerprint: json["fp"] as? String ?? "", host: host)
            // The site is the one the document says it is, from inside it. What it showed of the target counts as read from
            // there; and a frame of another site is another site: using it from a tab the user isn't looking at is asked
            // about for that site.
            if frame != nil || aim.host != tabHost {
                let inFront = tab.browser.map { tab.id == $0.activeID && $0 === Browser.recent } ?? false
                if !aim.host.isEmpty, aim.host != tabHost, !inFront {
                    let allowed = await Approvals.allowTab(tab, caller: session.caller, host: aim.host)
                    if session.stopped { throw ToolFailure(result: stopped) }
                    if !allowed { throw ToolFailure(result: declined) }
                }
                Approvals.noteRead(tab, readHost: aim.host.isEmpty ? Approvals.unknownFrame : aim.host, caller: session.caller)
            }
            return aim
        }
        throw ToolFailure(result: .text("Error: frames are nested too deeply there.", error: true))
    }

    /// The questions before the page is touched, in this order, each followed by a check that the call was not stopped
    /// while the user thought about it: the interaction itself (after reading other sites), then, for what looks like it
    /// pays, orders, sends, posts, deletes or confirms, that, every time. Throws what to answer when the answer is no.
    @MainActor
    static func approve(_ interaction: Approvals.Interaction?, aims: [Aim], irreversible: [Aim] = [], tab: Tab, session: Session) async throws {
        if session.stopped { throw ToolFailure(result: stopped) }
        if let interaction {
            let allowed = await Approvals.allowInteraction(interaction, on: tab, caller: session.caller, site: aims[0].host)
            if session.stopped { throw ToolFailure(result: stopped) }
            if !allowed { throw ToolFailure(result: declined) }
        }
        for aim in irreversible where IrreversibleAction.looksIrreversible(aim.facts) {
            let name = IrreversibleAction.name(of: aim.facts)
            let allowed = await Approvals.allowIrreversible(name.isEmpty ? aim.label : name, on: tab, caller: session.caller, site: aim.host)
            if session.stopped { throw ToolFailure(result: stopped) }
            if !allowed { throw ToolFailure(result: declined) }
        }
    }

    private static func said(_ result: ToolResult) -> String {
        let text = result.content.first?["text"] as? String ?? ""
        return text.hasPrefix("ok: ") ? String(text.dropFirst(4)) : text
    }

    /// Runs the script that acts, and gives a navigation it started a moment to begin and end.
    @MainActor
    private static func act(_ script: String, _ arguments: [String: Any], aim: Aim, tab: Tab, webView: WKWebView, waits: Bool = true) async -> ToolResult {
        let before = webView.url
        let result = await run(script, arguments, in: webView, frame: aim.frame)
        if waits, !result.isError { await waitForLoad(tab, expectingChangeFrom: before) }
        return result
    }

    // MARK: Tools

    @MainActor
    static func clickElement(_ id: Int, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            let step = String(localized: "Clicking “\(aim.label)”")
            AgentActivity.shared.step(step, caller: session.caller)
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.click, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Clicked [\(id)]. \(now(tab, caller: session.caller)). Element numbers may have changed; read the page again before using them.")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func clickAt(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let x = number(args["x"]), let y = number(args["y"]) else { return .text("x and y are required.", error: true) }
        do {
            let aim = try await Self.aim(["x": x, "y": y], tab: tab, in: webView, session: session)
            let step = String(localized: "Clicking at \(pixels(x)), \(pixels(y))")
            AgentActivity.shared.step(step, caller: session.caller)
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.clickAt, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Clicked at (\(pixels(x)), \(pixels(y))), which was \(aim.description). \(now(tab, caller: session.caller)). Element numbers may have changed; read the page again before using them.")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func typeText(_ id: Int, text: String, submit: Bool, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], key: submit ? "Enter" : nil, typing: submit, tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI type into password fields. Ask the user to.", error: true) }
            AgentActivity.shared.step(String(localized: "Typing into “\(aim.label)”"), caller: session.caller)
            try await approve(.type(text), aims: [aim], irreversible: submit ? [aim] : [], tab: tab, session: session)
            let result = await act(PageScripts.type, aim.script(["text": text, "submit": submit]), aim: aim, tab: tab, webView: webView)
            if result.isError || !submit { return result }
            return .text("Typed into [\(id)] and pressed Enter. \(now(tab, caller: session.caller))")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func pressKey(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let key = AgentKey.name(args["key"]), let modifiers = AgentKey.modifiers(args["modifiers"]) else { return .text("Invalid key.", error: true) }
        let wanted: [String: Any] = int(args["element_id"]).map { ["id": $0] } ?? ["active": true]
        do {
            let aim = try await Self.aim(wanted, key: key, tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI press keys in password fields. Ask the user to.", error: true) }
            let step = String(localized: "Pressing \(key)")
            AgentActivity.shared.step(step, caller: session.caller)
            // Enter or Space on a button or in a form does what a click does, and Enter in a message box sends it.
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.pressKey, aim.script(["mods": modifiers]), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Pressed \(key) on \(aim.description): \(said(result)). \(now(tab, caller: session.caller)). Element numbers may have changed; read the page again before using them.")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    /// Choosing an option, in steps: the page says which option the words name (a list that is closed is opened first, which
    /// is a click, and asked about as one), that option is judged by what it says, and it is chosen only if still the same.
    @MainActor
    static func selectOption(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        guard let id = int(args["element_id"]), let option = args["option"] as? String else { return .text("element_id and option are required.", error: true) }
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI use password fields. Ask the user to.", error: true) }
            AgentActivity.shared.step(String(localized: "Choosing “\(option)”"), caller: session.caller)
            // The option is the AI's own text, picked from a list the page wrote, and a page can write a list to read it back from.
            try await approve(.choose(option), aims: [aim], tab: tab, session: session)

            func ask(_ stage: String, open: Bool = false, expect: String? = nil) async -> ToolResult {
                var extra: [String: Any] = ["stage": stage, "option": option, "open": open]
                if let expect { extra["expectFp"] = expect }
                return await act(PageScripts.selectOption, aim.script(extra), aim: aim, tab: tab, webView: webView, waits: stage == "choose")
            }
            func answer(_ result: ToolResult) -> [String: Any]? {
                (result.content.first?["text"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
            }
            var resolved = await ask("resolve")
            if resolved.isError { return resolved }
            if answer(resolved)?["needsOpen"] as? Bool == true {
                // Opening the list is a click on it (the use of the page was approved with the choice).
                try await approve(nil, aims: [aim], irreversible: [aim], tab: tab, session: session)
                resolved = await ask("resolve", open: true)
                if resolved.isError { return resolved }
            }
            guard let chosen = answer(resolved), chosen["label"] is String, let fingerprint = chosen["fp"] as? String else {
                return .text("Error: the page did not answer.", error: true)
            }
            // A menu item named "Delete" is a button by another name, and so is the option of a list that acts when it changes
            // (a native list that submits its form takes the form's card details and address along). It is judged by every
            // name its markup gives it, and chosen only if it is still that very option.
            try await approve(nil, aims: [aim], irreversible: [aim.judged(as: .init(chosen))], tab: tab, session: session)
            let result = await ask("choose", expect: fingerprint)
            if result.isError { return result }
            return .text("Selected in [\(id)]: \(said(result)). \(now(tab, caller: session.caller)). Element numbers may have changed; read the page again before using them.")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func hover(_ id: Int, tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        do {
            let aim = try await Self.aim(["id": id], tab: tab, in: webView, session: session)
            let step = String(localized: "Pointing at “\(aim.label)”")
            AgentActivity.shared.step(step, caller: session.caller)
            try await approve(.act(step), aims: [aim], tab: tab, session: session)
            let result = await act(PageScripts.hover, aim.script(), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Moved the pointer over [\(id)]. Read the page again to see what appeared. \(now(tab, caller: session.caller))")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    @MainActor
    static func drag(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        func wanted(_ prefix: String) -> [String: Any]? {
            if let id = int(args[prefix + "element_id"]) { return ["id": id] }
            guard let x = number(args[prefix + "x"]), let y = number(args[prefix + "y"]) else { return nil }
            return ["x": x, "y": y]
        }
        guard let fromTarget = wanted("from_"), let toTarget = wanted("to_") else { return .text("Say where to drag from and where to drop.", error: true) }
        do {
            let from = try await Self.aim(fromTarget, tab: tab, in: webView, session: session)
            let to = try await Self.aim(toTarget, drop: true, tab: tab, in: webView, session: session)
            if from.secret || to.secret { return .text("Error: Changmun does not let the AI use password fields. Ask the user to.", error: true) }
            guard from.slot == to.slot else { return .text("Error: dragging from one frame to another isn't supported.", error: true) }
            let step = String(localized: "Dragging “\(from.label)” to “\(to.label)”")
            AgentActivity.shared.step(step, caller: session.caller)
            // Dropping something on a control named "Delete" or "Send" does what pressing it would, and dragging a control
            // named so drops it into something.
            try await approve(.act(step), aims: [from], irreversible: [from, to], tab: tab, session: session)
            let result = await act(PageScripts.drag, ["args": ["from": from.scriptArgs(), "to": to.scriptArgs()]], aim: from, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Dragged \(from.description) to \(to.description): \(said(result)). \(now(tab, caller: session.caller)). Element numbers may have changed; read the page again before using them.")
        } catch let failure as ToolFailure {
            return failure.result
        } catch {
            return .text("Error: \(error.localizedDescription)", error: true)
        }
    }

    /// Waits until the text is on the page (or is gone), or until the page has loaded when no text is given. The stop
    /// button ends it at once. A look at the page that gets no answer says nothing: the wait goes on.
    @MainActor
    static func waitFor(_ args: [String: Any], tab: Tab, webView: WKWebView, session: Session) async -> ToolResult {
        let timeout = min(max(number(args["timeout"]) ?? 10, 1), 30)
        let text = args["text"] as? String, gone = args["gone"] as? Bool ?? false
        if let text {
            AgentActivity.shared.step(gone ? String(localized: "Waiting for “\(text)” to go away") : String(localized: "Waiting for “\(text)”"), caller: session.caller)
        } else {
            AgentActivity.shared.step(String(localized: "Waiting for the page to load"), caller: session.caller)
        }
        let started = Date()
        // No look at the page ever got an answer: the last one may have been cut short by the end of the wait.
        var unknown = true
        var unreachable: [String: Date] = [:]
        func seconds() -> String { String(format: "%.1f", Date().timeIntervalSince(started)) }
        // A page that has just been told to load hasn't started yet.
        try? await Task.sleep(for: .milliseconds(250))
        var pause = 250
        while true {
            if session.stopped || Task.isCancelled { return stopped }
            if let text {
                let has = await pageHas(text, tab: tab, webView: webView, caller: session.caller, until: started.addingTimeInterval(timeout), unreachable: &unreachable)
                if session.stopped || Task.isCancelled { return stopped }
                if has != nil { unknown = false }
                if waitIsOver(has: has, gone: gone) {
                    return .text(gone ? "“\(text)” is gone (after \(seconds()) s). \(now(tab, caller: session.caller))" : "“\(text)” is on the page (after \(seconds()) s). \(now(tab, caller: session.caller))")
                }
            } else if !tab.isLoading {
                return .text("The page has loaded (after \(seconds()) s). \(now(tab, caller: session.caller))")
            }
            if Date().timeIntervalSince(started) >= timeout {
                let what = text.map { gone ? (unknown ? "the page did not answer, so “\($0)” could not be checked" : "“\($0)” was still on the page")
                    : (unknown ? "“\($0)” did not appear where Changmun could look (a frame from another site could not be reached)" : "“\($0)” did not appear") } ?? "the page was still loading"
                return .text("Timed out after \(Int(timeout)) s: \(what). \(now(tab, caller: session.caller))", error: true)
            }
            try? await Task.sleep(for: .milliseconds(pause))
            pause = min(pause * 3 / 2, 1000)
        }
    }

    /// Waiting for the text to show (or, with `gone`, to go): a look at the page that got no answer says neither.
    static func waitIsOver(has: Bool?, gone: Bool) -> Bool {
        has.map { $0 != gone } ?? false
    }

    /// How long one frame is given to answer a look at the page, when the wait it belongs to ends at `end`.
    static func lookTimeout(until end: Date, now: Date = Date()) -> Double {
        min(frameTimeout, max(end.timeIntervalSince(now), 1))
    }

    /// Greets the frames of other sites that the page shows now (those a read has not named too), so that a look at the page can
    /// include them; says whether every one of them answered. A frame that did not answer (it may still be loading) is not waited
    /// for again until a moment has passed (`unreachable` says when each was tried).
    @MainActor
    private static func greetShownFrames(_ tab: Tab, _ webView: WKWebView, unreachable: inout [String: Date]) async -> Bool {
        var all = true
        func visit(_ frame: WKFrameInfo?, depth: Int) async {
            let result = await run(PageScripts.visibleFrames, [:], in: webView, frame: frame, timeout: 3)
            guard let shown = shownFrames(from: result.isError ? nil : result.content.first?["text"] as? String) else {
                all = false
                return
            }
            if shown.more { all = false }
            for ref in shown.refs {
                if tab.agent.frames.frame(for: ref.slot) == nil {
                    if let tried = unreachable[ref.slot], Date().timeIntervalSince(tried) < 1.5 {
                        all = false
                        continue
                    }
                    tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce)
                    guard await tab.frame(named: ref.slot) != nil else {
                        unreachable[ref.slot] = Date()
                        all = false
                        continue
                    }
                    unreachable[ref.slot] = nil
                }
                if depth < 2, let info = tab.agent.frames.frame(for: ref.slot) { await visit(info, depth: depth + 1) }
            }
        }
        await visit(nil, depth: 0)
        return all
    }

    /// Whether the text is on the page, in a frame of its site, or in a frame of another site (greeted first, so that a frame the
    /// latest read did not name is looked in too); nil when a place that might hold it did not answer or could not be reached.
    /// The looks are over by `end` (one frame that hangs can't hold the wait past it), and a frame that is gone or can't be
    /// asked is not asked again.
    @MainActor
    private static func pageHas(_ text: String, tab: Tab, webView: WKWebView, caller: String, until end: Date, unreachable: inout [String: Date]) async -> Bool? {
        var unanswered = await !greetShownFrames(tab, webView, unreachable: &unreachable)
        let places: [(slot: String?, frame: WKFrameInfo?)] = [(nil, nil)] + tab.agent.frames.known.map { ($0.slot, $0.frame) }
        for place in places {
            if place.frame != nil, end.timeIntervalSinceNow <= 0 {
                unanswered = true
                break
            }
            let timeout = lookTimeout(until: end)
            let result = await run(PageScripts.hasText, ["args": ["text": text]], in: webView, frame: place.frame, timeout: timeout)
            guard !result.isError, let answer = result.content.first?["text"] as? String,
                  let json = (try? JSONSerialization.jsonObject(with: Data(answer.utf8))) as? [String: Any] else {
                // A frame that had its whole time and still said nothing is gone (or hung); one cut short may only be slow.
                if let slot = place.slot, timeout >= frameTimeout {
                    tab.agent.frames.drop(slot: slot)
                } else {
                    unanswered = true
                }
                continue
            }
            // The answer says something about what the frame shows, so it was read from where it is.
            let host = host(ofOrigin: json["origin"] as? String ?? "")
            Approvals.noteRead(tab, readHost: place.frame == nil && host.isEmpty ? nil : (host.isEmpty ? Approvals.unknownFrame : host), caller: caller)
            if json["found"] as? Bool == true { return true }
        }
        return unanswered ? nil : false
    }
}
