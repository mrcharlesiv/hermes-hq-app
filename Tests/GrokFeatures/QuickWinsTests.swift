// Comprehensive unit & stress tests for all five Quick Wins:
// 1. Email Draft Cc / Bcc
// 2. Clickable Order Card Line Items
// 3. Open HTML Page Live-Update Pill
// 4. Mermaid Diagram Parsing, Rendering, PNG Export & Markdown Integration
// 5. Accidental Phone Hang-Up Guard

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct QuickWinsTests {

    // MARK: 1. Email Draft Cc / Bcc

    @Test func draftParsesStringAndArrayCcBccAndPreservesId() {
        let argsString: [String: JSONValue] = [
            "app": .string("Email — from owner@example.com"),
            "to": .string("alex@example.com"),
            "cc": .string("finance@example.com, ops@example.com"),
            "bcc": .string("archive@example.com"),
            "subject": .string("Q4 update"),
            "body": .string("Hello team, attached is the Q4 summary."),
        ]
        let call1 = ToolCall(id: "c1", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(argsString)),
                             summary: nil, state: .done, durationSeconds: nil)
        let d1 = DraftCards.draft(call1)
        #expect(d1 != nil)
        #expect(d1?.cc == "finance@example.com, ops@example.com")
        #expect(d1?.bcc == "archive@example.com")
        // ID stays compatible with drafts.py (depends on app, to, subject, body).
        #expect(d1?.id == DraftCards.id(app: "Email — from owner@example.com", to: "alex@example.com",
                                        subject: "Q4 update", body: "Hello team, attached is the Q4 summary."))

        let fields = DraftCards.fields(d1!)
        #expect(fields.map(\.label) == ["To", "Cc", "Bcc", "From", "Subject"])
        #expect(fields[1].value == "finance@example.com, ops@example.com")
        #expect(fields[2].value == "archive@example.com")

        let sendMsg = DraftCards.sendMessage(d1!, body: d1!.body)
        #expect(sendMsg.contains("Cc: finance@example.com, ops@example.com"))
        #expect(sendMsg.contains("Bcc: archive@example.com"))
        #expect(sendMsg.contains("Subject: Q4 update"))

        // Array form for cc / bcc with blank entries stripped.
        var argsArray = argsString
        argsArray["cc"] = .array([.string("a@example.com"), .string("  "), .string("b@example.com")])
        argsArray["bcc"] = .array([.string("audit@example.com")])
        let call2 = ToolCall(id: "c2", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(argsArray)),
                             summary: nil, state: .done, durationSeconds: nil)
        let d2 = DraftCards.draft(call2)
        #expect(d2?.cc == "a@example.com, b@example.com")
        #expect(d2?.bcc == "audit@example.com")
    }

    @Test func draftWithoutCcBccOmitsHeaderLines() {
        let args: [String: JSONValue] = [
            "app": .string("Email"),
            "to": .string("alex@example.com"),
            "subject": .string("Ping"),
            "body": .string("Quick check-in."),
        ]
        let call = ToolCall(id: "c3", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(args)),
                            summary: nil, state: .done, durationSeconds: nil)
        let draft = DraftCards.draft(call)!
        #expect(DraftCards.fields(draft).map(\.label) == ["To", "Subject"])
        let msg = DraftCards.sendMessage(draft, body: draft.body)
        #expect(!msg.contains("Cc:"))
        #expect(!msg.contains("Bcc:"))
    }

    // MARK: 2. Clickable Order Card Line Items

    @Test func orderItemsResolveFromCatalogAndDirectURLWithOptionsIntact() {
        let prodArgs: [String: JSONValue] = [
            "products": .array([
                .object([
                    "title": .string("Trail Runner 2"),
                    "store": .string("Example Outfitters"),
                    "url": .string("https://example.com/p/trail-runner-2"),
                    "price": .number(129.99),
                    "options": .array([.object(["name": .string("Color"), "value": .string("Black")])]),
                    "why": .array([.string("Great grip on wet trails")]),
                ])
            ])
        ]
        let prodCall = ToolCall(id: "p1", name: ShoppingCards.productsTool, title: "Products",
                                argsText: ChatJSON.stringify(.object(prodArgs)), summary: nil, state: .done, durationSeconds: nil)
        let prodMsg = ChatMessage(id: "m1", role: .assistant, parts: [.tool(prodCall)], timestamp: Date())

        let orderArgs: [String: JSONValue] = [
            "store": .string("Example Outfitters"),
            "site": .string("https://example.com/checkout"),
            "total": .number(179.98),
            "items": .array([
                .object([
                    "title": .string("Trail Runner 2"),
                    "detail": .string("Color: Navy, Size: 10"),
                    "qty": .number(1),
                    "price": .number(129.99),
                ]),
                .object([
                    "title": .string("Merino Socks"),
                    "detail": .string("Large"),
                    "qty": .number(2),
                    "price": .number(24.99),
                    "url": .string("https://example.com/p/merino-socks"),
                ]),
            ]),
        ]
        let orderCall = ToolCall(id: "o1", name: ShoppingCards.orderTool, title: "Order",
                                 argsText: ChatJSON.stringify(.object(orderArgs)), summary: nil, state: .done, durationSeconds: nil)
        let order = ShoppingCards.order(orderCall)!
        let history = ShoppingCards.catalogProducts(in: [prodMsg])
        #expect(ShoppingCards.openableItemIndices(in: order, matching: history) == [0, 1])

        // Item 0 matches prior catalog product AND updates selected options to Navy / 10 while keeping `why`.
        let resolved0 = ShoppingCards.product(for: order.items[0], in: order, matching: history)!
        #expect(resolved0.url.absoluteString == "https://example.com/p/trail-runner-2")
        #expect(resolved0.why == ["Great grip on wet trails"])
        #expect(resolved0.options.contains(ShoppingCards.Option(name: "Color", value: "Navy")))
        #expect(resolved0.options.contains(ShoppingCards.Option(name: "Size", value: "10")))

        // Item 1 resolves from its direct item URL with option parsed from detail.
        let resolved1 = ShoppingCards.product(for: order.items[1], in: order, matching: history)!
        #expect(resolved1.url.absoluteString == "https://example.com/p/merino-socks")
        #expect(resolved1.options.first?.value == "Large")

        // Layout produces hit controls and tapping fires onOpenItem.
        let row = OrderCardRow(order: order, rowId: "r1", messageId: "m2", state: .waiting, openableItems: [0, 1])
        let layout = OrderCardLayout.make(row, gap: 8, width: 390, category: .large)
        guard case .prompt(let pl) = layout.content, case .order(let geo)? = pl.shopping else {
            Issue.record("Expected order layout")
            return
        }
        #expect(geo.items.count == 2)
        let view = OrderCardButtons()
        var opened: [Int] = []
        view.onOpenItem = { opened.append($0) }
        view.configure(geo)
        let itemButtons = view.ordered.compactMap { $0 as? UIControl }.filter { $0.accessibilityIdentifier?.hasPrefix("order.item.") == true }
        #expect(itemButtons.count == 2)
        itemButtons[1].sendActions(for: .touchUpInside)
        #expect(opened == [1])
    }

    // MARK: 3. HTML Page Live-Update Pill

    @Test func htmlPageSheetLiveUpdatePillShowsAndApplies() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hq-page-pill-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = dir.appending(path: "page.html")
        let v2 = dir.appending(path: "page-v2.html")
        try "<html><body><h1>Version 1</h1></body></html>".write(to: v1, atomically: true, encoding: .utf8)
        try "<html><body><h1>Version 2</h1></body></html>".write(to: v2, atomically: true, encoding: .utf8)

        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }

        let sheet = HTMLPageSheet.present(v1, from: host)
        sheet.loadViewIfNeeded()
        #expect(!sheet.isUpdatePillVisible)

        sheet.noteExternalUpdateAvailable(url: v2)
        #expect(sheet.isUpdatePillVisible)
        #expect(sheet.pendingUpdateURL == v2)

        sheet.applyPendingUpdate()
        #expect(!sheet.isUpdatePillVisible)
        #expect(sheet.pendingUpdateURL == nil)
    }

    // MARK: 4. Mermaid Diagram Parsing, Rendering, PNG Export & Stress

    @Test func mermaidParsesFlowchartSequenceStatePieAndGeneric() {
        let flow = MermaidParser.parse("""
        flowchart LR
            subgraph Pipeline[Build Pipeline]
                A[Code] --> B{Tests Pass?}
                B -->|Yes| C([Ship])
                B -.->|No| D((Fix))
                D --> A
            end
        """)
        #expect(flow != nil)
        if case .flowchart(let dir, let nodes, let edges, let sgs) = flow?.kind {
            #expect(dir == .leftRight)
            #expect(nodes.count == 4)
            #expect(edges.count == 4)
            #expect(sgs.count == 1 && sgs[0].title == "Build Pipeline")
        } else {
            Issue.record("Expected flowchart")
        }

        let seq = MermaidParser.parse("""
        sequenceDiagram
            participant U as User
            participant B as Bot
            U->>B: Find flights
            B-->>U: Flight cards
            B->>B: Cache fares
        """)
        if case .sequence(let participants, let messages) = seq?.kind {
            #expect(participants == ["User", "Bot"])
            #expect(messages.count == 3)
            #expect(messages[1].dashed == true)
        } else {
            Issue.record("Expected sequence diagram")
        }

        let state = MermaidParser.parse("""
        stateDiagram-v2
            [*] --> Idle
            Idle --> Running : start
            Running --> [*]
        """)
        if case .state(let nodes, let edges) = state?.kind {
            #expect(nodes.count == 4)
            #expect(edges.count == 3)
        } else {
            Issue.record("Expected state diagram")
        }

        let pie = MermaidParser.parse("""
        pie showData
            title Budget Split
            "Flights" : 45
            "Hotels" : 35
            "Food" : 20
        """)
        if case .pie(let title, let showData, let slices) = pie?.kind {
            #expect(title == "Budget Split")
            #expect(showData == true)
            #expect(slices.count == 3)
        } else {
            Issue.record("Expected pie chart")
        }

        let cls = MermaidParser.parse("classDiagram\nAnimal <|-- Duck\nDuck : +swim()")
        if case .generic(let title, let lines) = cls?.kind {
            #expect(title == "Class Diagram")
            #expect(lines.count == 2)
        } else {
            Issue.record("Expected generic fallback")
        }
    }

    @Test func mermaidRendersValidPNGAndStressHandlesCyclesAndLargeGraphs() {
        // Stress test: 50-node cyclic graph with fan-out and quotes containing arrows.
        var lines = ["flowchart TD"]
        for i in 0..<50 {
            lines.append("N\(i)[\"Step \(i) --> next\"] --> N\((i + 1) % 50)")
        }
        let diagram = MermaidParser.parse(lines.joined(separator: "\n"))
        #expect(diagram != nil)

        for dark in [false, true] {
            let traits = UITraitCollection { $0.userInterfaceStyle = dark ? .dark : .light }
            let png = MermaidRenderer.pngData(for: diagram!, traits: traits, scale: 2)
            #expect(png != nil)
            // Verify PNG magic header: 89 50 4E 47
            #expect(png!.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            let img = UIImage(data: png!)
            #expect((img?.size.width ?? 0) > 100)
            #expect((img?.size.height ?? 0) > 100)
        }

        // Markdown integration: settled mermaid renders as `.mermaid`; streaming falls back to `.code`.
        let md = "Here is the flow:\n\n```mermaid\nflowchart TD\nA[Start] --> B[End]\n```"
        let style = ChatStyleCache.shared.style(for: .large)
        let settled = MarkdownRenderer.render(md, style: style, streaming: false)
        #expect(settled.blocks.contains { if case .mermaid = $0 { return true } else { return false } })
        let streaming = MarkdownRenderer.render(md, style: style, streaming: true)
        #expect(!streaming.blocks.contains { if case .mermaid = $0 { return true } else { return false } })
        #expect(streaming.blocks.contains { if case .code = $0 { return true } else { return false } })
    }

    // MARK: 5. Accidental Hang-Up Guard

    @Test func phoneHangUpGuardPreventsAccidentalSingleTap() {
        var guardState = PhoneHangUpGuard()
        #expect(!guardState.armed)
        let firstDisarmed = guardState.confirm(at: 100)
        #expect(!firstDisarmed, "cannot confirm while disarmed")

        guardState.arm(at: 100)
        #expect(guardState.armed)
        guardState.cancel()
        #expect(!guardState.armed)
        let afterCancel = guardState.confirm(at: 105)
        #expect(!afterCancel)

        guardState.arm(at: 200)
        let confirmed = guardState.confirm(at: 201)
        #expect(confirmed, "second step confirms")
        #expect(!guardState.armed, "auto-disarms after confirming")
        let doubleConfirm = guardState.confirm()
        #expect(!doubleConfirm, "cannot double-fire")
    }
}
