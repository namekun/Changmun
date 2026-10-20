import AppKit
import Foundation
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
                ("wait_for", ["text": ""]), ("wait_for", ["gone": true]), ("wait_for", ["text": "a", "timeout": 0]), ("wait_for", ["text": "a", "timeout": "soon"]), ("wait_for", ["text": "a", "gone": "yes"]),
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
        private func risky(_ names: String..., hints: [String] = [], submits: Bool = false, payment: Bool = false, action: String = "", sends: Bool = false) -> Bool {
            IrreversibleAction.looksIrreversible(.init(label: names.first ?? "", names: names, hints: hints, submits: submits, payment: payment, action: action, sends: sends))
        }

        @Test func buttonsThatPayOrderSendPostDeleteTransferOrConfirmAreCaughtInSevenLanguages() {
            let asked = [
                "Buy now", "Pay $19.99", "Place order", "Place Order", "Proceed to checkout", "Check out", "Send", "Send message", "Post", "Publish", "Delete account", "Remove", "Transfer funds",
                "Confirm", "CONFIRM PAYMENT", "Donate", "Reply",
                "구매하기", "결제하기", "주문 완료", "보내기", "전송", "게시", "삭제", "송금",
                "購入する", "お支払い", "注文を確定する", "送信", "投稿", "削除", "送金",
                "立即购买", "去支付", "提交订单", "发送", "发布", "删除", "转账", "确认订单", "下單", "結算",
                "Comprar ahora", "Pagar", "Realizar pedido", "Finalizar compra", "Enviar", "Publicar", "Eliminar", "Transferir", "Confirmar",
                "Jetzt kaufen", "Zahlungspflichtig bestellen", "Bestellung abschicken", "Senden", "Veröffentlichen", "Löschen", "Überweisen", "Bestätigen", "Zur Kasse",
                "Acheter", "Payer maintenant", "Passer la commande", "Envoyer", "Publier", "Supprimer", "Virement", "Confirmer", "Valider",
            ]
            for name in asked { #expect(risky(name), "\(name)") }
        }

        @Test func theWordsAddedAfterReviewAreCaught() {
            let asked = [
                "Submit", "Save", "Save changes", "Share", "Comment", "Tweet", "Merge pull request", "Approve", "Authorize", "Withdraw", "Book", "Reserve", "Subscribe", "Unsubscribe",
                "Move to Trash", "Discard", "Erase", "Revoke access", "Deactivate", "Terminate", "Empty the bin", "Cancel subscription", "Cancel my order", "Cancel membership", "Cancel booking",
                "탈퇴", "해지하기", "제출", "신청하기", "구독", "휴지통으로 이동",
                "退会する", "申し込み", "予約する", "解約", "ゴミ箱",
                "提交", "注销账户", "预订", "取消订阅", "垃圾桶",
                "Guardar", "Compartir", "Reservar", "Suscribirse", "Speichern", "Teilen", "Buchen", "Abonnieren", "Enregistrer", "Partager", "Réserver", "Soumettre",
            ]
            for name in asked { #expect(risky(name), "\(name)") }
        }

        @Test func ordinaryControlsAreNotAskedAbout() {
            let quiet = [
                "Search", "Next", "Learn more", "Read more", "Close", "Sign in", "Log in", "Add to cart", "Cancel", "Open menu", "Menu", "Back", "Show details", "Posts", "Sender", "Ordinary",
                "OK", "Okay", "Done", "Got it", "Comments", "Books", "Booking.com", "Saved", "Cancel and go back",
                "검색", "다음", "로그인", "더 보기", "장바구니 담기", "닫기", "확인", "취소",
                "検索", "次へ", "ログイン", "詳細を見る", "カートに入れる", "確認", "確定", "キャンセル",
                "搜索", "下一页", "登录", "了解更多", "加入购物车", "确认", "確定", "取消",
                "Buscar", "Siguiente", "Iniciar sesión", "Añadir al carrito", "Cancelar", "Aceptar",
                "Suchen", "Weiter", "Anmelden", "In den Warenkorb", "Abbrechen",
                "Rechercher", "Suivant", "Se connecter", "Ajouter au panier", "Annuler",
                "", "   ",
            ]
            for name in quiet { #expect(!risky(name), "\(name)") }
        }

        @Test func accentsWidthAndCaseDontHideAKeyword() {
            #expect(risky("ÜBERWEISEN") && risky("uberweisen") && risky("Veuillez ENVOYER") && risky("ＢＵＹ"))
            #expect(risky("Pay") && risky("pay") && risky("  PAY  ") && risky("Buy-now") && risky("Delete…"))
        }

        @Test func invisibleCharactersDontSplitAKeyword() {
            #expect(risky("Bu\u{200B}y now") && risky("De\u{200C}le\u{200D}te") && risky("Pa\u{00AD}y") && risky("Se\u{2060}nd") && risky("\u{FEFF}Buy") && risky("Del\u{202E}ete"))
            #expect(risky("삭\u{200B}제") && risky("購\u{200B}入"))
            #expect(!risky("Sear\u{200B}ch"))
        }

        @Test func aControlIsJudgedByEveryNameItHas() {
            // The visible words are harmless, the accessible name (or the picture's alt text, or the title) is not.
            #expect(risky("Close", "Delete everything"))
            #expect(risky("", "Delete") && risky("Menu", "Pay now") && risky("Go", "Send message"))
            #expect(!risky("Close", "Dismiss the notice"))
        }

        @Test func aControlWithNoWordsIsToldByItsMarkup() {
            #expect(risky("", hints: ["fa fa trash o"]) && risky("", hints: ["btn delete"]) && risky("", hints: ["checkout"]) && risky("", hints: ["action send"]))
            #expect(!risky("", hints: ["btn primary", "icon chevron"]) && !risky("", hints: []))
        }

        @Test func aMessageBoxSendsWhateverTheFormSays() {
            #expect(risky("Message", sends: true))
            #expect(!risky("Message", sends: false))
        }

        @Test func aSubmitButtonOfAPaymentFormIsAskedAboutWhateverItSays() {
            #expect(risky("Continue", submits: true, payment: true))
            #expect(risky("Next", submits: true, action: "https://shop.example/checkout/confirm"))
            #expect(risky("Go", submits: true, action: "/orders/pay"))
            #expect(!risky("Continue", submits: false, payment: true), "a button that doesn't submit")
            #expect(!risky("Search", submits: true, action: "https://shop.example/search"))
            #expect(!risky("Search", submits: true, action: "https://shop.example/borders"))
            #expect(!risky("Continue", submits: true))
        }

        @Test func aNameAmongSeveralMakesItRisky() {
            #expect(risky("Message", "Send"), "Enter in a field beside a Send button")
            #expect(!risky("Search", "Filters", "Sort"))
            #expect(IrreversibleAction.name(of: .init(label: "Message", names: ["Message", "Send"])) == "Send")
            #expect(IrreversibleAction.name(of: .init(label: "Go", names: ["Go"])) == "Go")
            #expect(IrreversibleAction.name(of: .init(label: "", hints: ["btn delete"])) == "btn delete")
            #expect(IrreversibleAction.name(of: .init(label: "Icon", hints: ["btn delete"])) == "Icon")
        }

        @Test func factsComeFromThePagesAnswer() {
            let facts = IrreversibleAction.Facts(["label": "Place order", "names": ["Place order"], "hints": ["x"], "submits": true, "payment": true, "action": "https://x/pay", "sends": true])
            #expect(facts == .init(label: "Place order", names: ["Place order"], hints: ["x"], submits: true, payment: true, action: "https://x/pay", sends: true))
            #expect(IrreversibleAction.Facts([:]) == .init())
            #expect(!IrreversibleAction.looksIrreversible(.init()))
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

        @Test func onlyTheChatPanelCanAllowASiteForTheChat() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            for caller in ["mcp-77", "cli", "unverified-panel"] {
                Approvals.forgetReads(caller: caller)
                defer { Approvals.forgetReads(caller: caller) }
                await asking({ _ in .site }) { stand in
                    Approvals.noteRead(tabs[0], readHost: nil, caller: caller)
                    #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: caller))
                    #expect(stand.asked.last?.choices == [.deny, .once], "\(caller)")
                    #expect(await Approvals.allowInteraction(.act("Clicking “Go”"), on: tabs[1], caller: caller))
                    #expect(stand.asked.count == 2, "\(caller) is asked each time")
                }
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
                    #expect(await Approvals.allowIrreversible("Buy now", on: tabs[1], caller: panel))
                    #expect(stand.asked.count == typed + round, "asked in round \(round)")
                }
                let last = stand.asked.last
                #expect(last?.choices == [.deny, .once], "no way to allow it for the chat")
                #expect(last?.message.contains("Buy now") == true && last?.message.contains("shop.example") == true)
            }
            await asking({ _ in .deny }) { stand in
                #expect(!(await Approvals.allowIrreversible("Pay", on: tabs[1], caller: panel)))
                #expect(!(await Approvals.allowIrreversible("Pay", on: tabs[1], caller: panel)))
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
                #expect(!(await Approvals.allowIrreversible("Buy", on: tabs[1], caller: "test-off")), "what can't be undone is asked about whatever the setting says")
            }
            #expect(stand.asked.count == 1 && stand.asked[0].message.contains("Buy"))
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
                #expect(await Approvals.allowInteraction(.type("one\ntwo\n\n\n\n\n\n\n\n\u{202E}three"), on: tabs[1], caller: panel))
                let detail = stand.asked[0].detail
                #expect(detail.contains("one⏎two⏎⏎") && detail.contains("▯three") && !detail.contains("\u{202E}"))
                #expect(detail.components(separatedBy: "\n").count == 5, "only the question's own lines: \(detail)")
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

        @Test func sitesAreToldByTheirRegistrableNameAndPort() {
            func site(_ address: String) -> String? { Approvals.site(of: URL(string: address)) }
            #expect(site("https://www.example.com/a") == "example.com" && site("https://checkout.shop.example.com:443/") == "example.com")
            #expect(site("https://shop.example.co.uk/") == "example.co.uk" && site("http://Example.COM:80/") == "example.com")
            #expect(site("http://localhost:18401/") == "localhost:18401" && site("http://localhost:18402/") == "localhost:18402" && site("http://localhost/") == "localhost")
            #expect(site("http://127.0.0.1:18401/") == "127.0.0.1:18401" && site("http://[::1]:18401/") == "[::1]:18401" && site("http://[::1]/") == "::1")
            #expect(site("https://a.github.io/") == "a.github.io" && site("https://b.github.io/") != site("https://a.github.io/"), "people sharing a host are not one site")
            #expect(site("file:///Users/me/secret.html") == "file:" && site("data:text/html,hi") == "data:" && site("blob:https://a.com/u") == "blob:")
            #expect(site("about:blank") == nil && site("") == nil && Approvals.site(of: nil) == nil)
            #expect(Approvals.site(ofOrigin: "https://x.example:8443") == "x.example:8443" && Approvals.site(ofOrigin: "null") == "" && Approvals.site(ofOrigin: "") == "")
            #expect(Approvals.hasSite("example.com") && Approvals.hasSite("::1") && !Approvals.hasSite("") && !Approvals.hasSite("file:"))
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

        @Test func pagesOfOneSiteDoNotCountAsOtherSitesForEachOther() async {
            let (browser, tabs) = open(["https://www.shop.example/", "https://checkout.shop.example/pay", "https://other.example/"])
            defer { browser.windowClosed() }
            let panel = ChatStore.caller
            Approvals.forgetReads(caller: panel)
            defer { Approvals.forgetReads(caller: panel) }
            await asking({ _ in .once }) { stand in
                Approvals.noteRead(tabs[0], readHost: nil, caller: panel)
                Approvals.noteRead(tabs[0], readHost: Approvals.site(of: URL(string: "https://cdn.shop.example/")), caller: panel)
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: panel))
                #expect(stand.asked.isEmpty, "a hop between hosts of one site asks nothing")
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[2], caller: panel))
                #expect(stand.asked.count == 1 && stand.asked[0].detail.contains("shop.example"))
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

        @Test func listingTabsTellsOnlyTitlesAndAddressesAndAsksNothingLater() async {
            let (browser, tabs) = open(["https://a.example/", "https://b.example/"])
            defer { browser.windowClosed() }
            let caller = "mcp-list"
            Approvals.forgetReads(caller: caller)
            defer { Approvals.forgetReads(caller: caller) }
            await asking({ _ in .once }) { stand in
                let listed = await ToolCatalog.call("list_tabs", [:], caller: caller)
                #expect(!listed.isError && (listed.content.first?["text"] as? String)?.contains("a.example") == true)
                #expect(await Approvals.allowInteraction(.type("x"), on: tabs[1], caller: caller))
                #expect(stand.asked.isEmpty, "a list of titles is not a read of the tabs")
            }
        }

        @Test func aQuestionWaitsUntilTheUserAnswersOrTheCallerIsStopped() async {
            let (browser, tabs) = open(["https://shop.example/"])
            defer { browser.windowClosed() }
            await asking({ _ in .once }) { stand in
                stand.holds = true
                // The stop of another caller leaves it alone.
                async let answer = Approvals.allowIrreversible("Buy", on: tabs[0], caller: "mcp-hold")
                #expect(await waitUntil { stand.asked.count == 1 })
                AgentActivity.shared.cancel(caller: "mcp-someone-else")
                Approvals.release(.once)
                #expect(await answer, "released with yes by the user")
                async let stopped = Approvals.allowIrreversible("Buy", on: tabs[0], caller: "mcp-hold")
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

        @Test func atMostThreeTabsAreKeptDrawingTheMostRecentlyUsed() {
            let (b, tabs) = browser(tabs: (0..<5).map { "https://held\($0).example/" })
            defer { b.windowClosed() }
            AgentActivity.shared.runStarted()
            defer { AgentActivity.shared.runEnded() }
            for tab in tabs { AgentActivity.shared.use(tab, caller: ChatStore.caller) }
            #expect(AgentActivity.shared.held == tabs.suffix(3).reversed().map(\.id), "the three used last, the latest first")
            #expect(tabs.allSatisfy { AgentActivity.shared.holds($0) }, "all of them are still kept awake")
            AgentActivity.shared.use(tabs[0], caller: ChatStore.caller)
            #expect(AgentActivity.shared.held.first == tabs[0].id && AgentActivity.shared.held.count == AgentActivity.maxHeld)
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
        private func page(_ html: String, host: String = "lab.test") async throws -> (Tab, NSWindow, Browser) {
            let b = Browser()
            b.focused()
            let tab = b.openTab(url: nil)
            let view = tab.wake()
            let window = OffscreenWindow(view)
            view.loadHTMLString(html, baseURL: URL(string: "https://\(host)/"))
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

        /// The question the guard asks before something that can't be undone, apart from the others about using a tab.
        private func guarded(_ stand: Approvals.Stand) -> [Approvals.Prompt] { stand.asked.filter { $0.message.contains("press") } }

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
            try await asking({ prompt in prompt.message.contains("press") ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let select = try #require(id(ofKind: "select", in: read))
                // "Account" names one option, whose text is "Delete account": asked about by that, and refused.
                let refused = await call(tab, "select_option", ["element_id": select, "option": "Account"])
                #expect(refused.failed && refused.text.contains("declined"))
                #expect(guarded(stand).count == 1 && guarded(stand)[0].message.contains("Delete account"))
                #expect(await evaluate(tab, "return document.getElementById('acct').value") == "Profile", "nothing was chosen")
                // An option that is only an option is chosen without the guard.
                #expect(!(await call(tab, "select_option", ["element_id": select, "option": "Profile"])).failed)
                #expect(guarded(stand).count == 1)

                // A list that must be opened first: the opening is a click, judged by the list's own name, and so is the option.
                let combo = try #require(id(of: "Actions", in: read))
                let wipe = await call(tab, "select_option", ["element_id": combo, "option": "Erase"])
                #expect(wipe.failed && wipe.text.contains("declined"))
                #expect(guarded(stand).count == 2 && guarded(stand)[1].message.contains("Erase it"))
                #expect(await evaluate(tab, "return document.title") != "wiped")
                let keep = await call(tab, "select_option", ["element_id": combo, "option": "Keep"])
                #expect(!keep.failed)
                #expect(await waitUntil { tab.title == "kept" })

                let menu = try #require(id(of: "Delete menu", in: read))
                let opening = await call(tab, "select_option", ["element_id": menu, "option": "Fine"])
                #expect(opening.failed && guarded(stand).count == 3 && guarded(stand)[2].message.contains("Delete menu"))
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
                if prompt.message.contains("press") { tab.webView?.evaluateJavaScript("document.getElementById('opt').textContent='Keep it'") }
                return .once
            }) { stand in
                let read = await call(tab, "read_page").text
                let combo = try #require(id(of: "Actions", in: read))
                let result = await call(tab, "select_option", ["element_id": combo, "option": "Erase"])
                #expect(guarded(stand).count == 1 && guarded(stand)[0].message.contains("Erase it"))
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
                #expect(guarded(stand).count == 1 && guarded(stand)[0].message.contains("Buy now"))
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
                #expect(asked == [true, true, true, true, true, false, false, true, true], "\(asked)")
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
                #expect(refused.failed && guarded(stand).count == 1 && guarded(stand)[0].message.contains("Place order"))
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
                #expect(guarded(stand).last?.message.contains("Continue") == true)
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
                if prompt.message.contains("press") { tab.webView?.evaluateJavaScript("document.getElementById('buy').setAttribute('aria-label', 'Something else'); document.getElementById('buy').textContent = 'Something else'") }
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

        @Test func aPasswordFieldIsOffLimitsToEveryTool() async throws {
            let (tab, window, browser) = try await page(Self.form)
            defer { window.close(); browser.windowClosed() }
            try await asking({ prompt in prompt.message.contains("press") ? .deny : .once }) { _ in
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
                func uses() -> Int { stand.asked.filter { $0.message.contains("lab.test") && !$0.message.contains("press") }.count }
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
                #expect(!(await call(tab, "click_at", ["x": 5, "y": 5], caller: panel)).failed)
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
                    if prompt.message.contains("press") { AgentActivity.shared.cancel(caller: caller) }
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
                #expect(guarded(stand).first?.message.contains("Place my order") == true)
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
            try await asking({ prompt in prompt.message.contains("press") ? .deny : .once }) { stand in
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
            try await asking({ prompt in prompt.message.contains("press") ? .deny : .once }) { stand in
                let read = await call(tab, "read_page").text
                let size = try #require(id(of: "Size", in: read)), colour = try #require(id(of: "Colour", in: read))
                let refused = await call(tab, "select_option", ["element_id": size, "option": "Large"])
                #expect(refused.failed && guarded(stand).count == 1 && tab.title != "submitted")
                #expect(!(await call(tab, "select_option", ["element_id": colour, "option": "Blue"])).failed && guarded(stand).count == 1, "a list that only changes is only a list")
            }
        }

        @Test func twoOptionsWithTheSameWordsAreNotTakenForEachOther() async throws {
            let html = """
                <body><div role=listbox aria-label="Choices"><div id=a role=option data-value=a onclick="document.title='chose a'">Delete it</div><div id=b role=option data-value=b onclick="document.title='chose b'">Delete it</div></div></body>
                """
            let (tab, window, browser) = try await page(html)
            defer { window.close(); browser.windowClosed() }
            // The page puts the other option first while the user thinks: same words, not the option that was judged.
            try await asking({ prompt in
                if prompt.message.contains("press") { tab.webView?.evaluateJavaScript("document.getElementById('a').before(document.getElementById('b'))") }
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
                #expect(refused.failed && guarded(stand).count == 1 && guarded(stand)[0].message.contains("Delete account"), "\(refused.text)")
                #expect(tab.title != "deleted")
                let fine = await call(tab, "click_at", ["x": 150, "y": 170])
                #expect(!fine.failed && fine.text.contains("Details") && guarded(stand).count == 1, "\(fine.text)")
                #expect(await waitUntil { tab.title == "details" })
            }
        }

        @Test func secretsAreToldByTheirNamesInAnyWritingOfThem() async throws {
            let names = ["otpCode", "userPin", "cvv2", "ssn4", "currentPwd", "pincode", "OTPCode", "card_number", "newPassword"]
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
