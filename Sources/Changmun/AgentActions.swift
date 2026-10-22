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

/// How much asking an action calls for, judged by what the page shows of it. It goes by every name the control has (what it
/// says, its accessible name, a picture's alt text, its title), the words in the markup of a control that has none (an icon),
/// where it goes (the path of a link, the address, name and value of a button), and a submit button in a form that asks for card
/// details or posts to a checkout. It errs toward asking: a page can name a button anything. Generic words of agreement ("OK",
/// "확인") are not enough to ask.
///
/// `high` is what can't be taken back or gives something away: money (paying, ordering, transferring, booking), content or data
/// (sending, posting, replying, commenting, sharing, uploading, submitting, subscribing, inviting), access (allowing, granting,
/// authorizing, connecting, linking an account) and losses (deleting, cancelling, revoking, closing): asked about every time.
/// `low` is a cookie banner's consent (accept, agree, allow, where the control or the text around it speaks of cookies) and settings
/// (save, clear, reset, block, enable, disable, install, complete, finish ...): asked about once per site for a chat.
enum IrreversibleAction {
    enum Tier: Int, Comparable {
        case none, low, high
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Facts: Equatable {
        /// The name to show for what is activated.
        var label = ""
        /// Every name it has, and every name that could be (Enter in a field presses the form's default button).
        var names: [String] = []
        /// What the markup of a control with no words says: class, id, data names, the picture it shows.
        var hints: [String] = []
        /// Where it goes, for any control: the path and query of its address (a formaction), a button's name and value; for a
        /// plain link, the path only.
        var dests: [String] = []
        /// It submits a form.
        var submits = false
        /// The form asks for card or bank details.
        var payment = false
        /// Where the form posts to.
        var action = ""
        /// It sends a message: Enter in a message box.
        var sends = false
        /// It is a plain link: a navigation, named by its short text only, and judged by whole segments of its path.
        var link = false
        /// The key pressed is one that acts by itself: Delete or Backspace outside a text field, or a combination with ctrl or meta.
        var keyRisk = false
        /// The control sits in a cookie banner: it, or the text around it, speaks of cookies.
        var cookie = false

        init(label: String = "", names: [String] = [], hints: [String] = [], dests: [String] = [], submits: Bool = false, payment: Bool = false, action: String = "", sends: Bool = false,
             link: Bool = false, keyRisk: Bool = false, cookie: Bool = false) {
            self.label = label
            self.names = names
            self.hints = hints
            self.dests = dests
            self.submits = submits
            self.payment = payment
            self.action = action
            self.sends = sends
            self.link = link
            self.keyRisk = keyRisk
            self.cookie = cookie
        }

        init(_ json: [String: Any]) {
            self.init(label: json["label"] as? String ?? "", names: json["names"] as? [String] ?? [], hints: json["hints"] as? [String] ?? [],
                      dests: json["dests"] as? [String] ?? [], submits: json["submits"] as? Bool ?? false, payment: json["payment"] as? Bool ?? false, action: json["action"] as? String ?? "",
                      sends: json["sends"] as? Bool ?? false, link: json["link"] as? Bool ?? false, keyRisk: json["keyRisk"] as? Bool ?? false, cookie: json["cookie"] as? Bool ?? false)
        }
    }

    static func tier(of facts: Facts) -> Tier {
        if facts.sends || facts.keyRisk || (facts.submits && (facts.payment || postsToCheckout(facts.action))) { return .high }
        if facts.dests.contains(where: { facts.link ? linkGoesToHigh($0) : goesToIrreversible($0) }) { return .high }
        return (facts.names + facts.hints).reduce(Tier.none) { max($0, tier(ofText: $1, cookie: facts.cookie)) }
    }

    /// The name to show the user: the one that put the action in its tier, else the control's own.
    static func name(of facts: Facts, tier wanted: Tier = .high) -> String {
        facts.names.first(where: { tier(ofText: $0, cookie: facts.cookie) >= wanted }) ?? (facts.label.isEmpty ? facts.hints.first(where: { tier(ofText: $0, cookie: facts.cookie) >= wanted }) ?? "" : facts.label)
    }

    /// Words (whole words only, accents and case ignored) of the Latin-script languages.
    private static func fold(all words: [String]) -> Set<String> { Set(words.map(fold)) }

    private static let highWords: Set<String> = fold(all: [
        // English
        "buy", "buys", "buying", "purchase", "purchasing", "pay", "pays", "paying", "order", "ordering", "checkout",
        "send", "sends", "sending", "post", "posting", "publish", "publishing", "delete", "deleting", "transfer", "transferring",
        "confirm", "confirming", "donate", "donating", "tweet", "retweet", "repost", "merge", "merging", "approve", "approving",
        "withdraw", "withdrawing", "deposit", "depositing", "wire", "unsubscribe",
        "trash", "bin", "recycle", "erase", "erasing", "wipe", "wiping", "revoke", "deactivate", "terminate",
        "sell", "selling", "bid", "bidding", "invest", "investing", "trade", "trading",
        "reply", "comment", "submit", "submitting", "share", "sharing", "upload", "uploading", "subscribe", "subscribing", "invite", "inviting",
        "authorize", "authorise", "authorizing", "grant", "granting", "connect", "connecting", "book", "reserve", "reserving",
        // Spanish
        "comprar", "compra", "pagar", "pago", "pedir", "pedido", "enviar", "envia", "publicar", "eliminar", "borrar", "transferir", "transferencia",
        "confirmar", "donar", "aprobar", "retirar", "depositar", "papelera", "revocar", "vender", "pujar", "invertir",
        "responder", "comentar", "compartir", "subir", "suscribirse", "suscribir", "invitar", "autorizar", "conceder", "otorgar", "conectar", "reservar",
        // German
        "kaufen", "kauf", "bezahlen", "zahlen", "zahlungspflichtig", "bestellen", "bestellung", "senden", "absenden", "abschicken", "versenden",
        "posten", "veröffentlichen", "löschen", "überweisen", "bestätigen", "spenden", "genehmigen", "abheben", "einzahlen",
        "abbestellen", "papierkorb", "widerrufen", "verkaufen", "bieten", "investieren", "handeln",
        "antworten", "kommentieren", "teilen", "hochladen", "abonnieren", "einladen", "autorisieren", "gewähren", "verbinden", "einreichen", "buchen", "reservieren",
        // French
        "acheter", "achat", "payer", "régler", "commander", "commande", "valider", "envoyer", "publier", "supprimer", "virer", "virement",
        "transférer", "confirmer", "approuver", "désabonner", "corbeille", "poubelle", "résilier", "vendre", "enchérir", "investir",
        "répondre", "commenter", "partager", "téléverser", "abonner", "inviter", "autoriser", "accorder", "soumettre", "réserver",
    ])

    /// Consent: asked about once per site in a cookie banner, every time anywhere else (an authorization screen says "Allow" too).
    private static let consentWords: Set<String> = fold(all: [
        "allow", "allowing", "accept", "accepting", "agree", "agreeing",
        "permitir", "acepto", "erlauben", "zulassen", "akzeptieren", "zustimmen", "accepter",
    ])

    private static let lowWords: Set<String> = fold(all: [
        // English
        "save", "saving", "remove", "removing", "disconnect", "disconnecting", "unlink", "install", "installing",
        "enable", "enabling", "disable", "disabling", "reset", "resetting", "clear", "clearing", "empty", "emptying", "discard", "ban", "banning",
        "block", "blocking", "complete", "completing", "finish", "finishing",
        // Spanish
        "guardar", "descartar", "instalar", "activar", "desactivar", "desconectar", "desvincular", "restablecer", "vaciar", "bloquear", "completar", "finalizar",
        // German
        "speichern", "entfernen", "verwerfen", "installieren", "aktivieren", "deaktivieren", "trennen", "zurücksetzen", "leeren", "sperren", "blockieren",
        "abschließen", "beenden", "fertigstellen",
        // French
        "retirer", "enregistrer", "sauvegarder", "installer", "activer", "désactiver", "dissocier", "réinitialiser", "vider", "effacer", "bannir", "bloquer",
        "terminer", "finaliser", "compléter",
    ])

    private static let highPhrases = ["check out", "place order", "passer la commande", "finalizar compra", "realizar pedido", "zur kasse", "remove permanently", "permanently remove",
                                      "delete forever", "empty trash", "empty the trash", "empty bin", "empty the bin", "close account", "close my account", "wire transfer",
                                      "make payment", "make a payment", "authorize payment", "authorise payment", "allow access", "give access", "link account", "link your account",
                                      "link my account", "allow all access"].map(fold)

    /// "Save 20%" and "Save up to $5" are promotions, not a save.
    private static let promotional: Set<String> = fold(all: ["save", "saving", "savings"])

    /// Cancelling is ordinary (a dialog's Cancel button), except for a subscription, an order, a booking or the like.
    private static let cancelWords: Set<String> = Set(["cancel", "cancels", "cancelling", "canceling", "cancellation", "cancelar", "annuler", "stornieren", "kündigen"].map(fold))
    private static let cancelContext: Set<String> = Set([
        "subscription", "subscriptions", "order", "orders", "membership", "plan", "booking", "reservation", "account", "trip", "flight", "appointment", "contract",
        "suscripción", "pedido", "membresía", "reserva", "cuenta", "abonnement", "commande", "réservation", "compte", "abo", "bestellung", "mitgliedschaft", "konto",
        "buchung", "vertrag",
    ].map(fold))

    /// Korean, Japanese and Chinese have no spaces between words, so these are looked for anywhere in the text.
    private static let highCharacters = [
        "구매", "결제", "주문", "보내", "전송", "게시", "삭제", "송금", "발송", "이체", "발행", "후원", "탈퇴", "해지", "휴지통", "출금", "입금", "판매", "입찰", "투자", "승인",
        "답글", "예약", "제출", "신청", "구독", "공유", "등록", "댓글", "연결", "초대", "업로드",
        "購入", "支払", "決済", "注文", "送信", "投稿", "削除", "送金", "公開", "振込", "寄付", "退会", "解約", "ゴミ箱", "出金", "入金", "売却", "入札", "投資", "承認",
        "返信", "予約", "申し込み", "申込", "共有", "登録", "コメント", "接続", "招待", "アップロード",
        "购买", "購買", "支付", "付款", "下单", "下單", "发送", "發送", "发布", "發佈", "發布", "删除", "刪除", "转账", "轉帳", "结算", "結算", "订购", "訂購", "提交订单", "提交訂單",
        "捐款", "确认订单", "確認訂單", "注销", "註銷", "取消订阅", "取消订单", "取消訂單", "垃圾桶", "垃圾箱", "回收站", "废纸篓",
        "批准", "提现", "提現", "出售", "竞拍", "競拍", "投资", "投資", "汇款", "匯款", "存款",
        "回复", "回覆", "预订", "預訂", "预约", "預約", "提交", "订阅", "訂閱", "分享", "评论", "評論", "授权", "授權", "连接", "連接", "邀请", "邀請", "上传", "上傳",
    ]

    private static let consentCharacters = ["허용", "동의", "수락", "許可", "同意", "承諾", "允许", "允許", "接受"]

    private static let lowCharacters = [
        "제거", "저장", "설치", "활성화", "비활성화", "초기화", "차단", "완료",
        "保存", "インストール", "有効化", "無効化", "切断", "リセット", "クリア", "ブロック", "完了",
        "安装", "安裝", "启用", "啟用", "禁用", "断开", "斷開", "重置", "清空", "封禁", "屏蔽", "完成",
    ]

    /// What a cookie banner says, or a control in one: cookies in the languages of the app.
    static func mentionsCookies(_ text: String) -> Bool {
        let folded = fold(text)
        return ["cookie", "쿠키", "クッキー", "galleta", "kekse", "témoin", "temoin"].map(fold).contains { folded.contains($0) }
    }

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

    static func tier(ofText text: String, cookie: Bool = false) -> Tier {
        var cleaned = clean(text)
        for compound in ordinaryCompounds { cleaned = cleaned.replacingOccurrences(of: compound, with: " ") }
        if highCharacters.contains(where: cleaned.contains) { return .high }
        let tokens = fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: highWords.contains) { return .high }
        if tokens.contains(where: cancelWords.contains) && tokens.contains(where: cancelContext.contains) { return .high }
        let spaced = " " + tokens.joined(separator: " ") + " "
        if highPhrases.contains(where: { spaced.contains(" \($0) ") }) { return .high }
        // Consent is a cookie banner's when the control or the words around it speak of cookies; anywhere else it grants something.
        if tokens.contains(where: consentWords.contains) || consentCharacters.contains(where: cleaned.contains) {
            return cookie || mentionsCookies(text) ? .low : .high
        }
        if lowCharacters.contains(where: cleaned.contains) { return .low }
        for (index, token) in tokens.enumerated() where lowWords.contains(token) {
            if promotional.contains(token), isAmount(tokens.dropFirst(index + 1)) { continue }
            return .low
        }
        return .none
    }

    /// Whether the words that follow "save" are an amount ("20", "up to 50", "$5").
    private static func isAmount(_ rest: ArraySlice<String>) -> Bool {
        var rest = rest
        if rest.first == "up", rest.dropFirst().first == "to" { rest = rest.dropFirst(2) }
        return rest.first?.first?.isNumber == true
    }

    /// Whether a text puts an action in a tier of at least `wanted`.
    static func matches(_ text: String, tier wanted: Tier = .high, cookie: Bool = false) -> Bool { tier(ofText: text, cookie: cookie) >= wanted }

    /// Where a form, a button or a script goes that pays or gives something up, in the words of an address.
    private static let destinationWords: Set<String> = [
        "checkout", "payment", "payments", "pay", "purchase", "buy", "delete", "remove", "destroy", "erase", "purge", "trash", "transfer", "withdraw",
        "send", "cancel", "unsubscribe", "confirm", "revoke", "deactivate", "terminate",
    ]

    /// A link is a navigation: only a whole segment of its path that is one of these says it goes to the last step of something.
    private static let linkSegments: Set<String> = [
        "checkout", "payment", "pay", "purchase", "buy", "delete", "destroy", "erase", "purge", "transfer", "withdraw", "send", "unsubscribe", "revoke", "deactivate", "terminate",
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

    /// Whether the path of a link has a whole segment that is "checkout", "pay", "delete" and the like (a hyphenated slug is not one).
    static func linkGoesToHigh(_ path: String) -> Bool {
        path.prefix(300).split(separator: "/").contains { linkSegments.contains(fold(String($0))) }
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

    /// The tabs in use, the most recently used first. The view that keeps them leaves out the page in front and the ones shown
    /// elsewhere and holds the first `maxHeld` of the rest, so a page in use that is in front doesn't take a place from another.
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
        let now = newest.filter { ToolCatalog.findTab($0) != nil }
        if now != held { held = now }
    }

    /// A tab in use got another page (it woke up, or went to sleep): the view that holds it behind the page in front takes the new one.
    func pageChanged(_ tab: Tab) {
        // Not within the update of a view that woke the tab.
        if held.contains(tab.id) { DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() } }
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
        // The words the AI gave the step, when it gave any, take the place of the app's.
        if caller == ChatStore.caller, panelRun != nil || text == nil { ChatStore.shared.step = text.map { ToolCatalog.currentTitle ?? $0 } }
    }
}

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

    mutating func beginRead() {
        frames.beginRead()
        ranges = []
        seen = nil
        navigated = false
    }

    mutating func endRead() { frames.endRead() }

    /// A frame of the page navigated: see `FrameRegistry.frameNavigated`. The element numbers of the frames' contents stay, and a
    /// number in a frame whose handle is gone is answered as a frame that can't be reached, never taken for the page's own.
    mutating func frameNavigated() { frames.frameNavigated() }

    mutating func reset() {
        frames.reset()
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
            // Text made only of what the page's own search treats as space (JavaScript's \s: also U+FEFF) is found everywhere.
            if let text = args["text"], (text as? String)?.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0 != "\u{FEFF}" }) != true { return "text must be a non-empty string." }
            if args["gone"] != nil && args["gone"] as? Bool == nil { return "gone must be true or false." }
            if args["gone"] as? Bool == true && args["text"] == nil { return "gone needs the text to wait for to disappear." }
            if args["timeout"] != nil && number(args["timeout"]).map({ $0 > 0 }) != true { return "timeout must be a number of seconds." }
        case "sign_in":
            if args["element_id"] != nil && !hasElement("element_id") { return "element_id must be a number." }
        case "screenshot":
            if args["labels"] != nil && args["labels"] as? Bool == nil { return "labels must be true or false." }
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
        await tab.agent.gate.run { await readPageAlone(tab, webView, maxChars: maxChars, session: session) } ?? (stopped, [])
    }

    @MainActor
    static func readPageAlone(_ tab: Tab, _ webView: WKWebView, maxChars: Int, session: Session) async -> (ToolResult, frameHosts: Set<String>) {
        tab.agent.beginRead()
        defer { tab.agent.endRead() }
        let maxElements = 250
        let deadline = Date().addingTimeInterval(pageReadDeadline)
        guard let page = await readPart(["maxChars": maxChars, "start": 0, "limit": maxElements], frame: nil, in: webView, timeout: readTimeout) else {
            return (.text("Error: the page did not answer in time (a dialog may be open).", error: true), [])
        }
        var lines = page.lines, count = page.count, capped = page.capped, framesText = "", hosts = Set<String>()
        func readFrames(_ frames: [(slot: String, nonce: String, src: String, title: String)], depth: Int) async {
            let refs = Array(frames.prefix(8))
            for ref in refs { tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce) }
            // The frames are given their moment to answer the greeting all at once, not one after the other.
            let infos = depth < 2 && Date() < deadline && !session.stopped ? await tab.frames(named: refs.map(\.slot)) : [:]
            for ref in refs {
                // What is told of a frame that couldn't be read (its address or title, which its page chose) is cut, and its address is
                // a site the model was told of.
                let name = Approvals.shown(ref.src.isEmpty ? ref.title : ref.src, limit: 200)
                guard depth < 2, Date() < deadline, !session.stopped, let info = infos[ref.slot],
                      let part = await readPart(["maxChars": min(maxChars, 4000), "start": count, "limit": max(maxElements - count, 0)], frame: info, in: webView,
                                                timeout: min(frameTimeout, max(deadline.timeIntervalSinceNow, 1))) else {
                    framesText += "\n\n--- Frame: \(name.text)\(name.cut > 0 ? "…" : "") (from another site; its content could not be read) ---"
                    if !ref.src.isEmpty, let site = Approvals.site(of: URL(string: ref.src)), Approvals.hasSite(site) { hosts.insert(site) }
                    continue
                }
                // The site is the one the frame says it is in, from inside: where it was when it greeted may be another by now.
                let host = Self.host(ofOrigin: part.origin)
                // Whatever of a frame goes to the model (its address, a word of its text, an element) is read from its site and
                // recorded as such; a frame that showed nothing at all (a tracking pixel, an empty box) sends nothing and records nothing.
                if part.lines.isEmpty && part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await readFrames(part.frames, depth: depth + 1)
                    continue
                }
                hosts.insert(host.isEmpty ? Approvals.unknownFrame : host)
                lines += part.lines.map { $0 + " (in a frame of \(host.isEmpty ? "another site" : host))" }
                if part.count > count { tab.agent.ranges.append((count + 1...part.count, ref.slot)) }
                count = max(count, part.count)
                capped = capped || part.capped
                let address = Approvals.shown(part.url, limit: 300)
                framesText += "\n\n--- Frame: \(address.text)\(address.cut > 0 ? "…" : "") ---\n" + part.text
                await readFrames(part.frames, depth: depth + 1)
            }
        }
        await readFrames(page.frames, depth: 0)
        tab.agent.seen = AgentState.Seen(url: page.url, title: page.title, lastID: count)
        let cut = capped ? "\n(Only the first \(maxElements) elements are listed. Scroll, or use click_at for the rest.)" : ""
        return (.text("Title: \(page.title)\nURL: \(page.url)\nScroll: \(page.scroll) of \(page.height) (viewport \(page.viewport))"
                      + "\n\n--- Interactive elements ---\n" + (lines.isEmpty ? "(none)" : lines.joined(separator: "\n")) + cut
                      + "\n\n--- Page text ---\n" + page.text + framesText), hosts)
    }

    /// The frame an element number from the last read lives in: nil for the page itself or a frame of its own site.
    @MainActor
    static func frame(ofElement id: Int, in tab: Tab) async -> Result<WKFrameInfo?, ToolFailure> {
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
    /// Every such frame counts, whatever it says about itself or whoever's lists it is on.
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
            guard depth < 3 else { return }
            for ref in shown.refs { tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce) }
            let infos = await tab.frames(named: shown.refs.map(\.slot))
            for ref in shown.refs {
                var host = Approvals.unknownFrame
                if let info = infos[ref.slot] {
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
        /// The fingerprint keeps the digits of the names (an amount or a count that changes is another thing): what asks every time.
        var exact: Bool
        /// The site it is in, by what the document says: "" when it has none (a frame with no site). The page of the tab itself,
        /// when it has none (a file: page), is the site of its scheme.
        var host: String
        var label: String { facts.label.isEmpty ? (args["id"] as? Int).map { "[\($0)]" } ?? "" : facts.label }

        /// The arguments the script that acts looks at: where, what it must still be, and anything the action needs.
        func scriptArgs(_ extra: [String: Any] = [:]) -> [String: Any] {
            args.merging(["expect": ["origin": origin, "fp": fingerprint, "exact": exact]]) { $1 }.merging(extra) { $1 }
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
    /// frames of other sites, without acting on it. `key` is the key about to be pressed on it, if any, with the modifiers held in `mods`; `typing` says the
    /// tool types the text itself, with Enter after it when `key` is Enter; `drop` says a drag ends on it.
    @MainActor
    static func aim(_ wanted: [String: Any], key: String? = nil, mods: [String: Bool]? = nil, typing: Bool = false, drop: Bool = false, tab: Tab, in webView: WKWebView, session: Session) async throws -> Aim {
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
            if let mods { args["mods"] = mods }
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
            // What asks every time is fingerprinted with its digits (an amount, a quantity); the rest without, since a count on a
            // page changes by itself.
            let exact = IrreversibleAction.tier(of: facts) == .high
            let aim = Aim(frame: frame, slot: slot, args: args, facts: facts, secret: json["secret"] as? Bool ?? false,
                          description: json["description"] as? String ?? "", origin: origin, fingerprint: json[exact ? "fpExact" : "fp"] as? String ?? "", exact: exact, host: host)
            // The site is the one the document says it is, from inside it. What it showed of the target counts as read from
            // there; and a site other than the one the tab was approved for (a frame of another site, or the tab having gone to
            // another site since) is another site: using it from a tab the user isn't looking at is asked about for that site.
            let approvedSite = session.approved ?? tabHost
            if frame != nil || aim.host != tabHost || aim.host != approvedSite {
                let inFront = tab.browser.map { tab.id == $0.activeID && $0 === Browser.recent } ?? false
                if !aim.host.isEmpty, aim.host != approvedSite, !inFront {
                    let allowed = await Approvals.allowTab(tab, caller: session.caller, host: aim.host)
                    if session.stopped { throw ToolFailure(result: stopped) }
                    if !allowed { throw ToolFailure(result: declined) }
                }
                let read = aim.host.isEmpty ? Approvals.unknownFrame : aim.host
                Approvals.noteRead(tab, readHost: read, caller: session.caller)
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
        for aim in irreversible {
            // A form that sends what is typed in it to another site is asked about every time, whatever the button says.
            let destination = foreignDestination(of: aim)
            let tier = destination == nil ? IrreversibleAction.tier(of: aim.facts) : .high
            guard tier != .none else { continue }
            let name = IrreversibleAction.name(of: aim.facts, tier: tier)
            let allowed = await Approvals.allowAction(tier, name.isEmpty ? aim.label : name, on: tab, caller: session.caller, site: aim.host, destination: destination)
            if session.stopped { throw ToolFailure(result: stopped) }
            if !allowed { throw ToolFailure(result: declined) }
        }
    }

    /// The site a form is sent to, when the action submits one to a site other than the one it is on.
    static func foreignDestination(of aim: Aim) -> String? {
        guard aim.facts.submits, let url = URL(string: aim.facts.action), ["http", "https"].contains(url.scheme?.lowercased()),
              let destination = Approvals.site(of: url), destination != aim.host else { return nil }
        return destination
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

    // MARK: What an action changed

    /// Most lines of changes told after an action.
    static let maxChangeLines = 40

    /// After an action, once the page has settled: what changed in its interactive elements since the AI last saw them (its read,
    /// or the last report), with the address and title if they changed, so that it needn't read the whole page again. New elements
    /// are numbered on and work with the tools. Everything told is page content, so the sites it came from (the page's, and
    /// those of the frames that answered) are recorded as read, as a read does. Empty when the tab is not one the caller may be
    /// told about; after a navigation, only says so.
    @MainActor
    static func changes(_ tab: Tab, _ webView: WKWebView, session: Session) async -> String {
        guard Approvals.mayShow(tab, caller: session.caller), session.approved == nil || Approvals.site(of: tab.url) == session.approved else { return "" }
        return await tab.agent.gate.run { await changesAlone(tab, webView, session: session) } ?? ""
    }

    @MainActor
    private static func changesAlone(_ tab: Tab, _ webView: WKWebView, session: Session) async -> String {
        guard let seen = tab.agent.seen else {
            return tab.agent.navigated ? "\n\nWhat changed: the page navigated. Read the page (read_page) to see it and number its elements."
                : "\n\nWhat changed: not told, since this page was not read before. Read the page (read_page) to number its elements."
        }
        let page = await run(PageScripts.changes, ["args": ["start": seen.lastID, "budget": maxChangeLines, "settle": 1200]], in: webView, timeout: 8)
        guard case .answered(let json) = look(page) else {
            return "\n\nWhat changed: the page did not answer. Read the page (read_page) to see it."
        }
        if json["navigated"] as? Bool == true {
            return "\n\nWhat changed: the page navigated. Read the page (read_page) to see it and number its elements."
        }
        let url = json["url"] as? String ?? "", title = json["title"] as? String ?? ""
        Approvals.noteRead(tab, readHost: Approvals.site(of: URL(string: url)), caller: session.caller)
        var lines = (json["lines"] as? [String] ?? []), more = int(json["more"]) ?? 0, last = seen.lastID + (int(json["added"]) ?? 0)
        // The frames of other sites that the latest read reached, each numbered on after the page.
        for (slot, frame) in tab.agent.frames.known {
            let answer = await run(PageScripts.changes, ["args": ["start": last, "budget": max(maxChangeLines - lines.count, 0), "settle": 0]], in: webView, frame: frame, timeout: frameTimeout)
            let result = look(answer)
            if result == .gone { tab.agent.frames.drop(slot: slot) }
            guard case .answered(let part) = result, part["navigated"] as? Bool != true else { continue }
            let host = host(ofOrigin: part["origin"] as? String ?? "")
            // A tab the user isn't looking at is approved for one site: what a frame of another says is not told.
            if let approved = session.approved, host != approved { continue }
            Approvals.noteRead(tab, readHost: host.isEmpty ? Approvals.unknownFrame : host, caller: session.caller)
            lines += (part["lines"] as? [String] ?? []).map { $0 + " (in a frame of \(host.isEmpty ? "another site" : host))" }
            more += int(part["more"]) ?? 0
            if let added = int(part["added"]), added > 0 {
                tab.agent.ranges.append((last + 1...last + added, slot))
                last += added
            }
        }
        tab.agent.seen = AgentState.Seen(url: url, title: title, lastID: last)
        var report: [String] = []
        if url != seen.url { report.append("URL: \(Approvals.shown(seen.url, limit: 300).text) → \(Approvals.shown(url, limit: 300).text)") }
        if title != seen.title { report.append("Title: \(Approvals.shown(seen.title, limit: 120).text) → \(Approvals.shown(title, limit: 120).text)") }
        report += lines
        if more > 0 { report.append("(\(more) more changes are not listed. Read the page (read_page) for the rest.)") }
        if lines.isEmpty && more == 0 { report.append("No interactive element changed.") }
        return "\n\nWhat changed (+ new, ~ changed, - gone; new elements are numbered and the numbers of your last read still work, except for those gone):\n" + report.joined(separator: "\n")
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
            return .text("Clicked [\(id)]. \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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
            return .text("Clicked at (\(pixels(x)), \(pixels(y))), which was \(aim.description). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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
            if result.isError { return result }
            return .text("Typed into [\(id)]\(submit ? " and pressed Enter" : ""). \(now(tab, caller: session.caller))" + (await changes(tab, webView, session: session)))
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
            let aim = try await Self.aim(wanted, key: key, mods: modifiers, tab: tab, in: webView, session: session)
            if aim.secret { return .text("Error: Changmun does not let the AI press keys in password fields. Ask the user to.", error: true) }
            let step = String(localized: "Pressing \(key)")
            AgentActivity.shared.step(step, caller: session.caller)
            // Enter or Space on a button or in a form does what a click does, and Enter in a message box sends it.
            try await approve(.act(step), aims: [aim], irreversible: [aim], tab: tab, session: session)
            let result = await act(PageScripts.pressKey, aim.script(["mods": modifiers]), aim: aim, tab: tab, webView: webView)
            if result.isError { return result }
            return .text("Pressed \(key) on \(aim.description): \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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

            func ask(_ stage: String, open: Bool = false, expect: String? = nil, exact: Bool = false) async -> ToolResult {
                var extra: [String: Any] = ["stage": stage, "option": option, "open": open, "expectExact": exact]
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
            guard let chosen = answer(resolved), chosen["label"] is String, let fingerprint = chosen["fp"] as? String, let exactFingerprint = chosen["fpExact"] as? String else {
                return .text("Error: the page did not answer.", error: true)
            }
            // An option that asks every time is fingerprinted with its digits (a quantity, an amount).
            let optionFacts = IrreversibleAction.Facts(chosen)
            let exact = IrreversibleAction.tier(of: optionFacts) == .high
            // A menu item named "Delete" is a button by another name, and so is the option of a list that acts when it changes
            // (a native list that submits its form takes the form's card details and address along). It is judged by every
            // name its markup gives it, and chosen only if it is still that very option.
            try await approve(nil, aims: [aim], irreversible: [aim.judged(as: optionFacts)], tab: tab, session: session)
            let result = await ask("choose", expect: exact ? exactFingerprint : fingerprint, exact: exact)
            if result.isError { return result }
            return .text("Selected in [\(id)]: \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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
            return .text("Moved the pointer over [\(id)]. \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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
            return .text("Dragged \(from.description) to \(to.description): \(said(result)). \(now(tab, caller: session.caller))." + (await changes(tab, webView, session: session)))
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

    /// What a look at one place of the page came to: its answer, a script that could not be run there at all (the frame is gone), or
    /// no answer (the place is busy, or hung, or the answer was not one).
    enum Look: Equatable {
        case answered([String: Any]), gone, hung

        static func == (a: Look, b: Look) -> Bool {
            switch (a, b) {
            case (.gone, .gone), (.hung, .hung): return true
            case (.answered(let x), .answered(let y)): return NSDictionary(dictionary: x).isEqual(to: y)
            default: return false
            }
        }
    }

    static func look(_ result: ToolResult) -> Look {
        let text = result.content.first?["text"] as? String
        if result.isError { return text == didNotAnswer ? .hung : .gone }
        guard let text, let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return .hung }
        return .answered(json)
    }

    /// How long one frame is given to answer a look at the page, when the wait it belongs to ends at `end`.
    static func lookTimeout(until end: Date, now: Date = Date()) -> Double {
        min(frameTimeout, max(end.timeIntervalSince(now), 1))
    }

    /// Greets the frames of other sites that the page shows now (those a read has not named too), so that a look at the page can
    /// include them; says whether every one of them answered. A frame that did not answer (it may still be loading) is not waited
    /// for again until a moment has passed (`unreachable` says when each was tried). The frames of one document are greeted at the same time.
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
            var waiting: [String] = []
            for ref in shown.refs where tab.agent.frames.frame(for: ref.slot) == nil {
                if let tried = unreachable[ref.slot], Date().timeIntervalSince(tried) < 1.5 {
                    all = false
                    continue
                }
                tab.agent.frames.expect(slot: ref.slot, nonce: ref.nonce)
                waiting.append(ref.slot)
            }
            let answered = await tab.frames(named: waiting)
            for slot in waiting {
                if answered[slot] == nil {
                    unreachable[slot] = Date()
                    all = false
                } else {
                    unreachable[slot] = nil
                }
            }
            for ref in shown.refs where depth < 2 {
                if let info = tab.agent.frames.frame(for: ref.slot) { await visit(info, depth: depth + 1) }
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
            guard case .answered(let json) = look(result) else {
                // A frame the page script could not be run in is gone: it is not asked again. One that did not answer in time is
                // slow or hung, which says nothing about its text: the wait goes on without an answer from it.
                if let slot = place.slot, look(result) == .gone {
                    tab.agent.frames.drop(slot: slot)
                } else {
                    unanswered = true
                }
                continue
            }
            // The answer says something about what the frame shows, so it was read from where it is.
            let host = host(ofOrigin: json["origin"] as? String ?? "")
            if place.frame == nil {
                Approvals.noteRead(tab, readHost: host.isEmpty ? nil : host, caller: caller)
            } else {
                Approvals.noteRead(tab, readHost: host.isEmpty ? Approvals.unknownFrame : host, caller: caller)
            }
            if json["found"] as? Bool == true { return true }
        }
        return unanswered ? nil : false
    }
}
