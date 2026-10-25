import Foundation

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
        /// The control's own name speaks of cookies.
        var cookie = false
        /// The control sits in the container of a known consent manager and its own name does not speak of cookies: only the page's markup
        /// says it is a cookie banner.
        var banner = false

        init(label: String = "", names: [String] = [], hints: [String] = [], dests: [String] = [], submits: Bool = false, payment: Bool = false, action: String = "", sends: Bool = false,
             link: Bool = false, keyRisk: Bool = false, cookie: Bool = false, banner: Bool = false) {
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
            self.banner = banner
        }

        init(_ json: [String: Any]) {
            self.init(label: json["label"] as? String ?? "", names: json["names"] as? [String] ?? [], hints: json["hints"] as? [String] ?? [],
                      dests: json["dests"] as? [String] ?? [], submits: json["submits"] as? Bool ?? false, payment: json["payment"] as? Bool ?? false, action: json["action"] as? String ?? "",
                      sends: json["sends"] as? Bool ?? false, link: json["link"] as? Bool ?? false, keyRisk: json["keyRisk"] as? Bool ?? false, cookie: json["cookie"] as? Bool ?? false, banner: json["banner"] as? Bool ?? false)
        }
    }

    static func tier(of facts: Facts) -> Tier {
        if facts.sends || facts.keyRisk || (facts.submits && (facts.payment || postsToCheckout(facts.action))) { return .high }
        if facts.dests.contains(where: { facts.link ? linkGoesToHigh($0) : goesToIrreversible($0) }) { return .high }
        return (facts.names + facts.hints).reduce(Tier.none) { max($0, tier(ofText: $1, cookie: facts.cookie, banner: facts.banner)) }
    }

    /// The action is in the low tier only because the page's markup says it sits in a cookie banner (a consent manager's container):
    /// a page can say so of anything, so it is asked about every time, in words that don't vouch for it.
    static func restsOnMarkup(_ facts: Facts) -> Bool {
        var without = facts
        without.banner = false
        return facts.banner && tier(of: facts) < tier(of: without)
    }

    /// The name to show the user: the one that put the action in its tier, else the control's own.
    static func name(of facts: Facts, tier wanted: Tier = .high) -> String {
        facts.names.first(where: { tier(ofText: $0, cookie: facts.cookie, banner: facts.banner) >= wanted }) ?? (facts.label.isEmpty ? facts.hints.first(where: { tier(ofText: $0, cookie: facts.cookie, banner: facts.banner) >= wanted }) ?? "" : facts.label)
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

    static func tier(ofText text: String, cookie: Bool = false, banner: Bool = false) -> Tier {
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
            return cookie || banner || mentionsCookies(text) ? .low : .high
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
