// Stress and regression tests for the eight features: what a bot can really send (odd, huge, hostile, half-written),
// and each bug the stress pass found. A fixed-seed generator drives the random cases, so a failure repeats.

import Testing
import UIKit
@testable import HermesHQNative

/// SplitMix64: small, fast, and the same numbers every run.
nonisolated struct StressRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mermaid: reading

@MainActor @Suite(.serialized) struct MermaidStressTests {

    private func flow(_ source: String) -> (nodes: [MermaidDiagram.FlowNode], edges: [MermaidDiagram.FlowEdge], direction: MermaidDiagram.Direction)? {
        guard case .flowchart(let direction, let nodes, let edges, _)? = MermaidParser.parse(source)?.kind else { return nil }
        return (nodes, edges, direction)
    }

    private func pairs(_ edges: [MermaidDiagram.FlowEdge]) -> [String] { edges.map { "\($0.from)>\($0.to)" } }

    /// An emoji is two UTF-16 units: the arrows after one used to be cut at the wrong place.
    @Test func emojiInLabelsKeepsEveryEdge() {
        let parsed = flow("flowchart LR\nA[\"🚀 Launch\"] --> B[\"✅ Done 🎉\"] --> C{\"👨‍👩‍👧 Family?\"} -->|🙂 yes| D")
        #expect(parsed?.nodes.map(\.id) == ["A", "B", "C", "D"])
        #expect(parsed?.nodes.map(\.label) == ["🚀 Launch", "✅ Done 🎉", "👨‍👩‍👧 Family?", "D"])
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C", "C>D"])
        #expect(parsed?.edges.last?.label == "🙂 yes")
        #expect(parsed?.direction == .leftRight)
    }

    @Test func everyArrowFormIsOneEdgeOfTheRightKind() {
        typealias Want = (line: String, style: MermaidDiagram.EdgeStyle, directed: Bool, label: String)
        let cases: [Want] = [
            ("A --> B", .solid, true, ""), ("A ---> B", .solid, true, ""), ("A -----> B", .solid, true, ""),
            ("A-->B", .solid, true, ""), ("A <--> B", .solid, true, ""),
            ("A --- B", .open, false, ""), ("A ----- B", .open, false, ""),
            ("A ==> B", .thick, true, ""), ("A ===> B", .thick, true, ""), ("A === B", .thick, false, ""),
            ("A -.-> B", .dashed, true, ""), ("A -..-> B", .dashed, true, ""), ("A -.- B", .dashed, false, ""),
            ("A -->|yes| B", .solid, true, "yes"), ("A ---|maybe| B", .open, false, "maybe"),
            ("A ==>|must| B", .thick, true, "must"), ("A -.->|later| B", .dashed, true, "later"),
            ("A -- yes --> B", .solid, true, "yes"), ("A -- re-try it --> B", .solid, true, "re-try it"),
            ("A -- \"yes, go --> now\" --> B", .solid, true, "yes, go --> now"),
            ("A -- link --- B", .open, false, "link"),
            ("A == sure ==> B", .thick, true, "sure"), ("A -. maybe .-> B", .dashed, true, "maybe"),
            ("A --o B", .open, false, ""), ("A --x B", .open, false, ""), ("A o--o B", .open, false, ""),
        ]
        for want in cases {
            let parsed = flow("flowchart TD\n" + want.line)
            #expect(parsed?.nodes.map(\.id) == ["A", "B"], "\(want.line)")
            #expect(parsed?.edges.count == 1, "\(want.line)")
            guard let edge = parsed?.edges.first else { continue }
            #expect(edge.from == "A" && edge.to == "B", "\(want.line)")
            #expect(edge.style == want.style, "\(want.line)")
            #expect(edge.directed == want.directed, "\(want.line)")
            #expect(edge.label == want.label, "\(want.line)")
        }
    }

    /// `A --- B --> C` was read as one edge from A to C named "- B".
    @Test func chainsOfMixedArrowsAreSeparateEdges() {
        var parsed = flow("flowchart TD\nA --- B --> C")
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])
        #expect(parsed?.edges.map(\.label) == ["", ""])
        #expect(parsed?.edges.map(\.directed) == [false, true])

        parsed = flow("flowchart TD\nA ==> B ==> C ==> D")
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C", "C>D"])
        #expect(parsed?.edges.allSatisfy { $0.style == .thick } == true)

        parsed = flow("flowchart TD\nA --- B --- C")
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])

        parsed = flow("flowchart TD\nA -.-> B -.-> C --> D ==> E")
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C", "C>D", "D>E"])
        #expect(parsed?.edges.map(\.style) == [.dashed, .dashed, .solid, .thick])

        parsed = flow("flowchart TD\nA & B --> C & D")
        #expect(Set(pairs(parsed?.edges ?? [])) == ["A>C", "A>D", "B>C", "B>D"])

        parsed = flow("flowchart TD\nA -- one --> B -- two --> C")
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])
        #expect(parsed?.edges.map(\.label) == ["one", "two"])
    }

    @Test func headersWithSemicolonsAndFrontMatterAreRead() {
        var parsed = flow("graph LR;\n  A-->B;\n  B-->C;")
        #expect(parsed?.direction == .leftRight)
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])

        parsed = flow("graph TD; A-->B; B-->C")
        #expect(parsed?.direction == .topDown)
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])

        parsed = flow("---\ntitle: The plan\nconfig:\n  theme: dark\n---\nflowchart RL\nA --> B")
        #expect(parsed?.direction == .rightLeft)
        #expect(parsed?.nodes.map(\.id) == ["A", "B"])

        parsed = flow("\r\n\r\nflowchart BT\r\nA --> B %% a note\r\n%% whole line\r\nB --> C\r\n")
        #expect(parsed?.direction == .bottomUp)
        #expect(pairs(parsed?.edges ?? []) == ["A>B", "B>C"])
    }

    @Test func shapesAndLabelsReadAsWritten() {
        let parsed = flow("""
        flowchart TD
        A(((Double))) --> B[[Sub]]
        C>Flag] --> D[/Slanted/]
        E{{Hex}} --> F[(Store)]
        G([Pill]) --> H{Choice}
        I["<b>Bold</b> &amp; fa:fa-user Name<br/>second line"] --> J("`**Strong** words`")
        K[She said #quot;hi#quot;]:::loud --> L[A --> B is text]
        style A fill:#f9f
        classDef loud fill:#f00
        click A "https://example.com"
        """)
        let byId = Dictionary(uniqueKeysWithValues: (parsed?.nodes ?? []).map { ($0.id, $0) })
        #expect(byId["A"]?.shape == .circle && byId["A"]?.label == "Double")
        #expect(byId["B"]?.shape == .rect && byId["B"]?.label == "Sub")
        #expect(byId["C"]?.label == "Flag")
        #expect(byId["D"]?.label == "Slanted")
        #expect(byId["E"]?.shape == .hexagon && byId["F"]?.shape == .cylinder)
        #expect(byId["G"]?.shape == .stadium && byId["H"]?.shape == .diamond)
        #expect(byId["I"]?.label == "Bold & Name\nsecond line")
        #expect(byId["J"]?.label == "Strong words")
        #expect(byId["K"]?.label == "She said \"hi\"")
        #expect(byId["L"]?.label == "A --> B is text")
        #expect(parsed?.nodes.count == 12, "style, classDef and click lines add no nodes")
        #expect(parsed?.edges.count == 6)
    }

    @Test func sequenceStateAndPieSurviveWhatBotsWrite() {
        guard case .sequence(let people, let messages)? = MermaidParser.parse("""
        sequenceDiagram
            autonumber
            participant U as 👤 User
            actor B as Bot
            U->>+B: Book it 🙂
            B-->>-U: Done: seat 12A
            B->>B: think
            Note over U,B: a note
            loop every hour
                B-)U: ping
            end
            alt ok
                U-xB: stop
            else
                U<<->>B: both ways
            end
            ->>B: no sender
        """)?.kind else { Issue.record("sequence did not parse"); return }
        #expect(people == ["👤 User", "Bot"])
        #expect(messages.map(\.text) == ["Book it 🙂", "Done: seat 12A", "think", "ping", "stop", "both ways"])
        #expect(messages[1].dashed && !messages[0].dashed)
        #expect(messages[2].from == messages[2].to)

        guard case .state(let nodes, let edges)? = MermaidParser.parse("""
        stateDiagram-v2
            direction LR
            [*] --> Idle
            Idle --> Working: start
            Working --> Idle: done
            Working --> [*]
            state "Waiting for you" as Wait
            Working --> Wait
            note right of Idle
                A long note --> with an arrow
            end note
            note left of Wait: short
            Idle: Nothing to do
        """)?.kind else { Issue.record("state did not parse"); return }
        #expect(Set(nodes.map(\.id)) == ["__start__", "Idle", "Working", "__end__", "Wait"])
        #expect(edges.count == 5)
        #expect(nodes.first { $0.id == "Wait" }?.label == "Waiting for you")

        guard case .pie(let title, let showData, let slices)? = MermaidParser.parse("""
        pie showData title Where the time went
            "Typing" : 42.5
            "Waiting" : 7
            "Nothing" : 0
            "Too big" : 999999999999999999
            "Science" : 1e400
            "Negative" : -3
            "No number" : lots
        """)?.kind else { Issue.record("pie did not parse"); return }
        #expect(title == "Where the time went" && showData)
        #expect(slices.map(\.label) == ["Typing", "Waiting"])
        #expect(MermaidParser.parse("pie\n\"A\" : 0\n\"B\" : 1e999") == nil, "a pie with no real slice is not a pie")
    }

    /// Bigger than this stays a code block: it would be unreadable, and its picture would cost real memory.
    @Test func overTheLimitsFallsBackToACodeBlock() {
        func chain(_ count: Int) -> String {
            "flowchart TD\n" + (0..<(count - 1)).map { "N\($0) --> N\($0 + 1)" }.joined(separator: "\n")
        }
        #expect(MermaidParser.parse(chain(MermaidParser.maxNodes)) != nil)
        #expect(MermaidParser.parse(chain(MermaidParser.maxNodes + 1)) == nil)
        #expect(MermaidParser.parse("flowchart TD\nA[" + String(repeating: "x", count: MermaidParser.maxLineLength) + "] --> B") == nil)
        #expect(MermaidParser.parse("flowchart TD\n" + String(repeating: "A --> B\n", count: MermaidParser.maxLines + 5)) == nil)
        #expect(MermaidParser.parse("flowchart TD\n" + String(repeating: "A --> B %% " + String(repeating: "y", count: 80) + "\n", count: 700)) == nil)
        let fan = "flowchart TD\n" + (0..<21).map { a in (0..<20).map { "A\(a) --> B\($0)" }.joined(separator: "\n") }.joined(separator: "\n")
        #expect(MermaidParser.parse(fan) == nil, "420 edges is over the edge limit")
        #expect(MermaidParser.parse("sequenceDiagram\n" + (0..<17).map { "participant P\($0)" }.joined(separator: "\n")) == nil)
        #expect(MermaidParser.parse("pie\n" + (0..<25).map { "\"S\($0)\" : 1" }.joined(separator: "\n")) == nil)

        // In a chat: the over-limit diagram is a code block, the small one a diagram.
        let style = ChatStyleCache.shared.style(for: .large)
        let big = MarkdownRenderer.render("```mermaid\n\(chain(MermaidParser.maxNodes + 1))\n```", style: style, streaming: false)
        #expect(big.blocks.contains { if case .code = $0 { true } else { false } })
        #expect(!big.blocks.contains { if case .mermaid = $0 { true } else { false } })
        for junk in ["", "   \n\n", "flowchart", "flowchart TD", "graph", "sequenceDiagram", "pie", "%% only a comment", "---\n---", "not mermaid at all", "gantt"] {
            #expect(MermaidParser.parse(junk) == nil, "\(junk.debugDescription)")
            let shown = MarkdownRenderer.render("```mermaid\n\(junk)\n```", style: style, streaming: false)
            #expect(!shown.blocks.contains { if case .mermaid = $0 { true } else { false } })
        }
    }

    /// Lines built to make a regular expression crawl. Each must be read (or refused) at once.
    @Test func hostileLinesAreReadQuickly() {
        let dashes = String(repeating: "-", count: 1_100)
        let lines = [
            "A " + dashes + " B",
            "A -- " + String(repeating: "a - ", count: 280),
            "A " + String(repeating: "-- ", count: 380),
            "A " + String(repeating: "-. ", count: 380),
            "A " + String(repeating: "== x ", count: 220),
            "A " + String(repeating: "-.", count: 550) + "-> B",
            "A[" + String(repeating: "[", count: 500) + String(repeating: "]", count: 500) + "] --> B",
            String(repeating: "\"", count: 1_101) + " --> B",
            String(repeating: "A & ", count: 290) + "B --> C",
            String(repeating: "|", count: 1_000) + "-->|" + String(repeating: "x", count: 100),
        ]
        let clock = ContinuousClock()
        for line in lines {
            let took = clock.measure { _ = MermaidParser.parse("flowchart TD\n" + line) }
            #expect(took < .milliseconds(750), "\(line.prefix(24))… took \(took)")
        }
        let took = clock.measure {
            _ = MermaidParser.parse("sequenceDiagram\n" + String(repeating: "A" + String(repeating: "-", count: 900) + ">>B: hi\n", count: 60))
            _ = MermaidParser.parse("stateDiagram-v2\n" + String(repeating: "A " + String(repeating: "- ", count: 500) + "\n", count: 100))
        }
        #expect(took < .seconds(2))
    }

    /// 3,000 diagrams of random pieces: none may crash, hang, or parse into something over the limits.
    @Test func randomSoupNeverCrashes() {
        var rng = StressRNG(seed: 0xD1A6_0001)
        let pieces = ["A", "B", "C1", "node_x", "🙂", "é", "-->", "---", "==>", "-.->", "--", "-", "=", ".", ">", "<", "|", "||",
                      "[", "]", "(", ")", "{", "}", "((", "))", "[[", "]]", "\"", "'", "`", ";", "&", ":", ":::", "%%", " ", "  ",
                      "subgraph", "end", "style", "o", "x", "\t", "text with words", "<br/>", "&amp;", "#quot;", "\\", "/"]
        let heads = ["flowchart TD", "graph LR;", "flowchart", "sequenceDiagram", "stateDiagram-v2", "pie title T", "pie", "classDiagram", "gantt"]
        let clock = ContinuousClock()
        let took = clock.measure {
            for _ in 0..<3_000 {
                var source = heads.randomElement(using: &rng)! + "\n"
                for _ in 0..<Int.random(in: 1...12, using: &rng) {
                    for _ in 0..<Int.random(in: 1...14, using: &rng) { source += pieces.randomElement(using: &rng)! }
                    source += "\n"
                }
                guard let diagram = MermaidParser.parse(source) else { continue }
                switch diagram.kind {
                case .flowchart(_, let nodes, let edges, _), .state(let nodes, let edges):
                    #expect(!nodes.isEmpty && nodes.count <= MermaidParser.maxNodes && edges.count <= MermaidParser.maxEdges)
                    let ids = Set(nodes.map(\.id))
                    #expect(edges.allSatisfy { ids.contains($0.from) && ids.contains($0.to) }, "\(source.debugDescription)")
                case .sequence(let people, let messages):
                    #expect(messages.allSatisfy { people.contains($0.from) && people.contains($0.to) }, "\(source.debugDescription)")
                case .pie(_, _, let slices):
                    #expect(slices.allSatisfy { $0.value > 0 && $0.value.isFinite })
                case .generic(_, let lines):
                    #expect(!lines.isEmpty)
                }
                // Every one that parses must also measure without trouble.
                let size = MermaidRenderer.naturalSize(for: diagram)
                #expect(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0, "\(source.debugDescription)")
            }
        }
        #expect(took < .seconds(30))
    }

    // MARK: Drawing

    /// A loop back to an earlier step used to push that step below the loop's own end.
    @Test func loopsKeepTheOrderTheyWereWrittenIn() {
        func ranks(_ edges: [(String, String)], nodes: [String] = []) -> [String: Int] {
            MermaidRenderer.flowRanks(nodes: nodes, edges: edges.map { (from: $0.0, to: $0.1) })
        }
        #expect(ranks([("A", "B"), ("B", "C"), ("C", "A")]) == ["A": 0, "B": 1, "C": 2])
        #expect(ranks([("Start", "Check"), ("Check", "Work"), ("Work", "Check"), ("Check", "Done")])
            == ["Start": 0, "Check": 1, "Work": 2, "Done": 2])
        #expect(ranks([("A", "A")]) == ["A": 0])
        #expect(ranks([("A", "B"), ("A", "B"), ("B", "A")]) == ["A": 0, "B": 1])
        #expect(ranks([], nodes: ["X", "Y"]) == ["X": 0, "Y": 0])
        // The longest way decides: D sits under C, not beside B.
        #expect(ranks([("A", "B"), ("B", "C"), ("C", "D"), ("A", "D")]) == ["A": 0, "B": 1, "C": 2, "D": 3])

        // A long chain, and a graph with every edge there can be: linear time, every node ranked, none below zero.
        let chain = (0..<5_000).map { ("n\($0)", "n\($0 + 1)") }
        let clock = ContinuousClock()
        var result: [String: Int] = [:]
        var took = clock.measure { result = ranks(chain) }
        #expect(result["n5000"] == 5_000 && took < .seconds(2))
        var every: [(String, String)] = []
        for a in 0..<120 { for b in 0..<120 where a != b { every.append(("k\(a)", "k\(b)")) } }
        took = clock.measure { result = ranks(every) }
        #expect(result.count == 120 && result.values.allSatisfy { $0 >= 0 && $0 < 120 } && took < .seconds(3))
        #expect(Set(result.values).count == 120, "a complete graph is one node per rank")
    }

    @Test func everyKindDrawsInEveryLookAtEverySize() {
        let sources = [
            "flowchart TD\nA[Start] --> B{Ok?} -->|yes| C((Done))\nB -->|no| A\nC --> C\nsubgraph One [The first]\nA\nB\nend",
            "flowchart LR\nA --> B --> C --> D --> E --> A\nE -.-> B\nD ==> A",
            "flowchart RL\nA[" + String(repeating: "A very long label that should wrap ", count: 12) + "] --> B",
            "flowchart BT\nSolo",
            "sequenceDiagram\nA->>B: " + String(repeating: "long words ", count: 40) + "\nB-->>A: ok\nA->>A: self",
            "stateDiagram-v2\n[*] --> A\nA --> B: go\nB --> A: back\nB --> [*]",
            "pie showData title Parts\n\"One\" : 1\n\"Two\" : 999999999999999\n\"Three\" : 0.000000001",
            "gantt\ntitle Plan\nsection One\nTask :a1, 2026-01-01, 30d",
        ]
        for source in sources {
            guard let diagram = MermaidParser.parse(source) else { Issue.record("did not parse: \(source.prefix(40))"); continue }
            let natural = MermaidRenderer.naturalSize(for: diagram)
            #expect(natural.width > 0 && natural.height > 0 && natural.width < 20_000 && natural.height < 20_000)
            for dark in [false, true] {
                let traits = UITraitCollection { $0.userInterfaceStyle = dark ? .dark : .light }
                for width in [120.0, 280, 390, 1_024, 2_400] {
                    let size = MermaidRenderer.inlineSize(for: diagram, maxWidth: width)
                    #expect(size.height >= 120 && size.height <= 360 && size.width >= 180)
                    let image = MermaidRenderer.renderImage(diagram: diagram, size: size, traits: traits)
                    #expect(image.size.width > 0 && image.cgImage != nil)
                }
                for size in [CGSize.zero, CGSize(width: 1, height: 1), CGSize(width: 50_000, height: 50_000), natural] {
                    let image = MermaidRenderer.renderImage(diagram: diagram, size: size, traits: traits, scale: 3)
                    let pixels = CGFloat((image.cgImage?.width ?? 0) * (image.cgImage?.height ?? 0))
                    #expect(pixels > 0 && pixels <= MermaidRenderer.maxPixels * 1.05)
                }
                let png = MermaidRenderer.pngData(for: diagram, traits: traits)
                #expect(png?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            }
        }
    }

    /// The biggest diagrams the reader lets through: the picture stays inside its pixel budget and is made in time.
    @Test func theBiggestDiagramsStayInsideTheBudget() {
        let traits = UITraitCollection { $0.userInterfaceStyle = .dark }
        let chain = "flowchart LR\n" + (0..<(MermaidParser.maxNodes - 1)).map { "N\($0)[Step number \($0)] --> N\($0 + 1)" }.joined(separator: "\n")
        var wide = "flowchart TD\nRoot"
        for i in 0..<150 { wide += "\nRoot --> Leaf\(i)[\"Leaf \(i) with some words\"]" }
        var tangled = "flowchart TD"
        for a in 0..<20 { for b in 0..<20 where a != b { tangled += "\nT\(a) -->|e\(a)\(b)| T\(b)" } }
        var talk = "sequenceDiagram"
        for i in 0..<MermaidParser.maxMessages { talk += "\nP\(i % 16)->>P\((i * 7 + 3) % 16): Message number \(i) with a fair few words in it" }
        let pie = "pie\n" + (0..<MermaidParser.maxSlices).map { "\"" + String(repeating: "Slice \($0) ", count: 20) + "\" : \($0 + 1)" }.joined(separator: "\n")
        let clock = ContinuousClock()
        for source in [chain, wide, tangled, talk, pie] {
            guard let diagram = MermaidParser.parse(source) else { Issue.record("did not parse: \(source.prefix(30))"); continue }
            var png: Data?
            let took = clock.measure { png = MermaidRenderer.pngData(for: diagram, traits: traits) }
            #expect(took < .seconds(8), "\(source.prefix(30)) took \(took)")
            guard let png, let image = UIImage(data: png)?.cgImage else { Issue.record("no picture: \(source.prefix(30))"); continue }
            #expect(CGFloat(image.width * image.height) <= MermaidRenderer.maxPixels * 1.05, "\(image.width)x\(image.height)")
            let inline = MermaidRenderer.inlineSize(for: diagram, maxWidth: 390)
            #expect(MermaidRenderer.renderImage(diagram: diagram, size: inline, traits: traits).cgImage != nil)
        }
        #expect(MermaidRenderer.budgetedScale(3, for: CGSize(width: 12_000, height: 12_000)) < 0.34)
        #expect(MermaidRenderer.budgetedScale(3, for: CGSize(width: 400, height: 300)) == 3)
        #expect(MermaidRenderer.budgetedScale(3, for: CGSize(width: 1e9, height: 1e9)) == 0.25)
    }

    /// A diagram built by hand with numbers the reader would never let through: drawing must still not crash.
    @Test func impossibleNumbersDoNotCrashTheDrawing() {
        let traits = UITraitCollection { $0.userInterfaceStyle = .light }
        let kinds: [MermaidDiagram.Kind] = [
            .pie(title: "", showData: true, slices: [.init(label: "inf", value: .infinity), .init(label: "one", value: 1)]),
            .pie(title: "T", showData: true, slices: [.init(label: "nan", value: .nan)]),
            .pie(title: "T", showData: false, slices: [.init(label: "max", value: .greatestFiniteMagnitude), .init(label: "max2", value: .greatestFiniteMagnitude)]),
            .pie(title: "T", showData: true, slices: [.init(label: "neg", value: -5), .init(label: "zero", value: 0)]),
            .pie(title: "T", showData: true, slices: []),
            .flowchart(direction: .topDown, nodes: [], edges: [], subgraphs: []),
            .flowchart(direction: .leftRight, nodes: [.init(id: "A", label: "", shape: .diamond, subgraph: "nowhere")],
                       edges: [.init(from: "ghost", to: "A", label: "x", style: .solid, directed: true),
                               .init(from: "A", to: "other ghost", label: "", style: .dashed, directed: false)], subgraphs: []),
            .sequence(participants: [], messages: [.init(from: "A", to: "B", text: "nobody declared", dashed: false, openArrow: false)]),
            .sequence(participants: ["A"], messages: []),
            .state(nodes: [], edges: []),
            .generic(title: "", lines: []),
            .generic(title: "T", lines: (0..<500).map { "line \($0) " + String(repeating: "w", count: 300) }),
        ]
        for (index, kind) in kinds.enumerated() {
            let diagram = MermaidDiagram(source: "hand-built \(index)", kind: kind)
            let natural = MermaidRenderer.naturalSize(for: diagram)
            #expect(natural.width.isFinite && natural.height.isFinite, "kind \(index)")
            #expect(MermaidRenderer.renderImage(diagram: diagram, size: MermaidRenderer.inlineSize(for: diagram, maxWidth: 390), traits: traits).cgImage != nil)
            #expect(MermaidRenderer.pngData(for: diagram, traits: traits) != nil, "kind \(index)")
        }
    }
}

// MARK: - Travel

@MainActor @Suite(.serialized) struct TravelStressTests {

    private func flight(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["airline": "Example Air", "origin": "sfo", "destination": "jfk", "depart_time": "08:15",
                                      "price": 348, "url": "https://example.com/flights/ea412"]
        for (key, value) in extra { o[key] = value }
        return o
    }

    private func hotel(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["name": "The Example Grand", "address": "12 Example St", "url": "https://example.com/hotels/grand", "price": 219]
        for (key, value) in extra { o[key] = value }
        return o
    }

    /// The ids the add-on computes for the same options (`travel.py`): if these drift, Book lands on no card.
    @Test func idsMatchTheAddOns() {
        #expect(TravelCards.flight(flight())?.id == "f-166f1510")
        #expect(TravelCards.hotel(hotel())?.id == "h-296741ec")
        #expect(TravelCards.flightId(airline: "Aérolíneas Ñandú ✈️", origin: "GRU", destination: "EZE", depart: "", url: "https://example.com/v?a=1&b=2") == "f-4b1c3781")
        // Spaces around a field, and the airport's case, don't change the id.
        #expect(TravelCards.flight(flight(["airline": "  Example Air ", "origin": " SFO", "destination": "Jfk "]))?.id == "f-166f1510")
        // The add-on's own vectors (hermes-hq-push test_travel.py).
        let theirs = TravelCards.flight(["airline": "Example Air", "origin": "sfo", "destination": " jfk ", "depart_time": "Fri Mar 6, 8:05 AM",
                                         "price": 300, "url": "https://example.com/flights/ex123?fare=main"])
        #expect(theirs?.id == "f-34c7f1d1")
        let stay = "https://example.com/hotels/example?in=2027-03-06&out=2027-03-09"
        #expect(TravelCards.hotel(["name": "Hotel Example", "address": "1 Example Way", "url": .string(stay)])?.id == "h-83efb011")
        #expect(TravelCards.hotel(["name": "Hotel Example", "url": .string(stay)])?.id == "h-18de903b")
        // A link `URL` would rewrite: the id is still over the text the bot wrote, as the add-on hashes it.
        let odd = "https://example.com/f?to=São Paulo"
        if let rewritten = TravelCards.flight(flight(["url": .string(odd)])) {
            #expect(rewritten.id == TravelCards.flightId(airline: "Example Air", origin: "SFO", destination: "JFK", depart: "08:15", url: odd))
        }
    }

    /// `Int(1e300)` stops the app. A count a bot got wildly wrong is dropped, never trusted.
    @Test func wildNumbersAreDroppedNotTrusted() {
        for wild: JSONValue in [.number(1e300), .number(-1e300), .number(.infinity), .number(.nan), .number(-4), .number(10), "lots", .null, .bool(true), [1, 2]] {
            #expect(TravelCards.flight(flight(["stops": wild]))?.stops == 0, "\(wild)")
            #expect(TravelCards.hotel(hotel(["stars": wild]))?.stars == nil, "\(wild)")
            #expect(TravelCards.hotel(hotel(["reviews": wild, "rating": wild])) != nil, "\(wild)")
            let place = TravelCards.hotel(hotel(["latitude": wild, "longitude": wild]))
            if case .number(let n) = wild, abs(n) <= 90 {
                #expect(place?.hasCoordinates == true, "\(wild) is a real place")
            } else {
                #expect(place?.hasCoordinates == false, "\(wild)")
            }
        }
        // A number where words are meant reads as its digits; one line where a list is meant is a list of one.
        let loose = TravelCards.flight(flight(["flight_number": 412, "why": "Nonstop", "duration": 5.5, "cabin": .number(1e300)]))
        #expect(loose?.flightNumber == "412" && loose?.why == ["Nonstop"] && loose?.duration == "5.5" && loose?.cabin == "")
        #expect(TravelCards.hotels(["hotels": [.object(hotel())], "guests": 2])?.guests == "2")
        #expect(TravelCards.flight(flight(["stops": 2.4]))?.stops == 2)
        #expect(TravelCards.flight(flight(["stops": "1"]))?.stops == 1)
        #expect(TravelCards.hotel(hotel(["stars": 4]))?.stars == 4)
        #expect(TravelCards.hotel(hotel(["stars": 0]))?.stars == nil)
        #expect(TravelCards.hotel(hotel(["stars": 7]))?.stars == nil)
        #expect(TravelCards.hotel(hotel(["rating": 9.2]))?.rating == 4.6, "a mark out of ten is halved")
        #expect(TravelCards.hotel(hotel(["rating": 1e300]))?.rating == nil)
        #expect(TravelCards.hotel(hotel(["rating": -3]))?.rating == 0)
        #expect(TravelCards.hotel(hotel(["reviews": 1_204]))?.reviews == 1_204)
        #expect(TravelCards.hotel(hotel(["reviews": -1]))?.reviews == nil)
        #expect(TravelCards.hotel(hotel(["reviews": 5e9]))?.reviews == nil)
        #expect(TravelCards.hotel(hotel(["latitude": 40.72, "longitude": -74]))?.hasCoordinates == true)
        #expect(TravelCards.hotel(hotel(["latitude": 40.72]))?.hasCoordinates == false, "half a place is no place")
    }

    @Test func pricesAreRealMoneyOrTheOptionGoes() {
        #expect(TravelCards.flight(flight(["price": "1,299.50"]))?.price == 1_299.5)
        #expect(TravelCards.flight(flight(["price": " 348 "]))?.price == 348)
        for bad: JSONValue in [0, -348, "free", "", .null, .number(.infinity), .number(.nan), 10_000_000, 1e300, "$348", [348]] {
            #expect(TravelCards.flight(flight(["price": bad])) == nil, "\(bad)")
        }
        // A hotel can be shown without a price, but never with a wrong one.
        #expect(TravelCards.hotel(hotel(["price": -1]))?.pricePerNight == nil)
        #expect(TravelCards.hotel(hotel(["price": 219, "total_price": "1,095"]))?.totalPrice == 1_095)
        // "Was" only when it was more.
        #expect(TravelCards.flight(flight(["was": 412]))?.was == 412)
        #expect(TravelCards.flight(flight(["was": 348]))?.was == nil)
        #expect(TravelCards.flight(flight(["was": 12]))?.was == nil)
        #expect(TravelCards.flight(flight(["was": 1e300]))?.was == nil)
        #expect(TravelCards.flight(flight(["currency": "eur"]))?.currency == "EUR")
        #expect(TravelCards.flight(flight(["currency": "euros"]))?.currency == "USD")
        #expect(TravelCards.flight(flight(["currency": "€€€"]))?.currency == "USD")
    }

    /// Only an https link to a real host opens. Nothing else gets a Book button.
    @Test func onlySafeLinksMakeACard() {
        for bad in ["http://example.com/f", "javascript:alert(1)", "file:///etc/passwd", "https://localhost/f", "https:///nohost",
                    "example.com/f", "", "   ", "data:text/html,hi", "hermes://install?x=1", "https://" + String(repeating: "a", count: 2_100) + ".com"] {
            #expect(TravelCards.flight(flight(["url": .string(bad)])) == nil, "\(bad.prefix(40))")
            #expect(TravelCards.hotel(hotel(["url": .string(bad)])) == nil, "\(bad.prefix(40))")
        }
        let pictures = TravelCards.hotel(hotel(["image": "http://example.com/a.jpg",
                                                "images": ["javascript:alert(1)", "https://example.com/b.jpg", "https://example.com/b.jpg", 7, "https://example.com/c.jpg"]]))?.images
        #expect(pictures?.map(\.absoluteString) == ["https://example.com/b.jpg", "https://example.com/c.jpg"])
    }

    @Test func floodsAreCappedAndLongWordsCut() {
        let long = String(repeating: "Very long words ", count: 40)
        let words = JSONValue.string(long)
        var manyFlights: [JSONValue] = []
        for i in 0..<500 {
            var f = flight()
            f["url"] = .string("https://example.com/f/\(i)")
            f["airline"] = words
            f["why"] = .array(Array(repeating: words, count: 50))
            let leg: JSONValue = .object(["origin": .string("sfo"), "destination": .string("den"), "layover": words])
            f["segments"] = .array(Array(repeating: leg, count: 40))
            manyFlights.append(.object(f))
        }
        let many = JSONValue.array(manyFlights)
        let parsed = TravelCards.flights(["flights": many, "note": words, "follow_ups": .array(Array(repeating: words, count: 30))])
        #expect(parsed?.flights.count == TravelCards.maxFlights)
        #expect(Set(parsed?.flights.map(\.id) ?? []).count == TravelCards.maxFlights)
        let flightsCapped = parsed?.flights.allSatisfy { $0.airline.count <= 60 && $0.why.count <= TravelCards.maxWhy && $0.segments.count <= TravelCards.maxSegments }
        #expect(flightsCapped == true)
        #expect((parsed?.note.count ?? 999) <= 200 && (parsed?.followUps.count ?? 99) <= TravelCards.maxFollowUps)

        var manyHotels: [JSONValue] = []
        for i in 0..<300 {
            var h = hotel()
            h["url"] = .string("https://example.com/h/\(i)")
            h["name"] = words
            h["images"] = .array((0..<200).map { JSONValue.string("https://example.com/i/\(i)/\($0).jpg") })
            h["amenities"] = .array(Array(repeating: words, count: 80))
            manyHotels.append(.object(h))
        }
        let hotels = TravelCards.hotels(["hotels": .array(manyHotels)])
        #expect(hotels?.hotels.count == TravelCards.maxHotels)
        let hotelsCapped = hotels?.hotels.allSatisfy { $0.images.count <= TravelCards.maxImages && $0.amenities.count <= TravelCards.maxAmenities && $0.name.count <= 140 }
        #expect(hotelsCapped == true)

        // Nothing usable: no card at all, and the raw tool call shows as before.
        #expect(TravelCards.flights(["flights": []]) == nil)
        #expect(TravelCards.flights(["flights": "none"]) == nil)
        #expect(TravelCards.flights([:]) == nil)
        #expect(TravelCards.hotels(["hotels": .array([.number(1), .string("two"), .object([:]), .null])]) == nil)

        // A tool call too big to be a card, one still being written, and one that failed.
        func call(_ text: String?, state: ToolCall.State = .done, name: String = TravelCards.flightsTool) -> ToolCall {
            ToolCall(id: "t", name: name, title: "Flights", argsText: text, summary: nil, state: state, durationSeconds: nil)
        }
        let good = ChatJSON.stringify(.object(["flights": .array([.object(flight())])]))
        #expect(TravelCards.flights(call(good))?.flights.count == 1)
        #expect(TravelCards.flights(call(good, name: TravelCards.hotelsTool)) == nil)
        #expect(TravelCards.flights(call(nil)) == nil)
        #expect(TravelCards.flights(call(String(good.dropLast(9)))) == nil, "half-written arguments are not a card")
        #expect(TravelCards.flights(call("[1,2,3]")) == nil)
        // Kept whole for the card only up to a size; past it the call shows as an ordinary tool step.
        #expect(TravelCards.wholeArgsText(name: TravelCards.flightsTool, args: ["flights": .array([.object(flight())])]) == good)
        #expect(TravelCards.wholeArgsText(name: TravelCards.flightsTool, args: ["flights": .array([.object(flight())]),
                                                                                "pad": .string(String(repeating: "p", count: TravelCards.maxArgsBytes))]) == nil)
        #expect(TravelCards.wholeArgsText(name: "web_search", args: ["flights": .array([.object(flight())])]) == nil)
        #expect(TravelCards.wholeArgsText(name: TravelCards.hotelsTool, args: [:]) == nil)
    }

    /// Book and Watch Price go back as a marked message. Only an exact mark at the very start counts.
    @Test func onlyAnExactMarkIsAnAnswer() {
        let option = TravelCards.flight(flight())!
        let room = TravelCards.hotel(hotel())!
        for ask in [TravelCards.Ask.book, .watchPrice] {
            let sent = TravelCards.message(ask, flight: option)
            #expect(TravelCards.answer(in: sent)?.id == option.id && TravelCards.answer(in: sent)?.ask == ask)
            #expect(TravelCards.answer(in: "  \n" + sent)?.id == option.id)
            let room = TravelCards.message(ask, hotel: room)
            #expect(TravelCards.answer(in: room)?.id == "h-296741ec" && TravelCards.answer(in: room)?.ask == ask)
            #expect(TravelCards.bubbleWords(sent)?.isEmpty == false)
            // The chat bubble says which flight or hotel, for a booking and for a watch alike.
            let words = [TravelCards.bubbleWords(sent) ?? "", TravelCards.bubbleWords(room) ?? ""]
            let lead = ask == .book ? "Book: " : "Watch price: "
            #expect(words[0].hasPrefix(lead) && words[0].contains(option.airline), "\(words[0])")
            #expect(words[1].hasPrefix(lead) && words[1].contains(TravelCards.hotel(hotel())!.name), "\(words[1])")
        }
        for fake in ["[Hermes HQ travel f-166F1510: book]", "[Hermes HQ travel f-166f151: book]", "[Hermes HQ travel x-166f1510: book]",
                     "[Hermes HQ travel f-166f1510: buy]", "[Hermes HQ travel f-166f1510:book]", "I said [Hermes HQ travel f-166f1510: book]",
                     "[Hermes HQ travel f-166f1510: book", "[Hermes HQ draft d-166f1510: send]", "", "book f-166f1510"] {
            #expect(TravelCards.answer(in: fake) == nil, "\(fake)")
        }
        // A long chat: every answer is found, a queued one counts, another card's doesn't.
        let call = ToolCall(id: "t", name: TravelCards.flightsTool, title: "Flights",
                            argsText: ChatJSON.stringify(.object(["flights": .array([.object(flight())])])), summary: nil, state: .done, durationSeconds: nil)
        var chat = [ChatMessage(id: "a", role: .assistant, parts: [.tool(call)], timestamp: Date())]
        for i in 0..<2_000 { chat.append(ChatMessage(id: "u\(i)", role: i % 2 == 0 ? .user : .assistant, parts: [.text("words \(i)")], timestamp: Date())) }
        chat.append(ChatMessage(id: "w", role: .user, parts: [.text(TravelCards.message(.watchPrice, flight: option))], timestamp: Date()))
        chat.append(ChatMessage(id: "fake", role: .assistant, parts: [.text(TravelCards.message(.book, flight: option))], timestamp: Date()))
        let clock = ContinuousClock()
        var answers = TravelCards.Answers(asked: [:])
        let took = clock.measure { answers = TravelCards.answers(chat, queued: [TravelCards.message(.book, hotel: room)]) }
        #expect(answers.asked[option.id] == [.watchPrice], "a bot repeating the mark is not you booking")
        #expect(answers.asked[room.id] == [.book])
        #expect(took < .seconds(1))
    }

    @Test func cardsLayOutAtEverySizeWidthAndState() {
        let long = String(repeating: "A very long name ", count: 12)
        let words = JSONValue.string(long)
        var flightList: [JSONValue] = []
        var hotelList: [JSONValue] = []
        for i in 0..<12 {
            var f = flight()
            f["url"] = .string("https://example.com/f/\(i)")
            f["airline"] = i % 2 == 0 ? words : .string("Example Air")
            f["stops"] = .number(Double(i % 4))
            f["was"] = .number(9_000)
            f["price"] = .number(Double(i * 997 + 1))
            f["badge"] = words
            f["cabin"] = words
            f["duration"] = .string("25h 55m")
            f["why"] = .array([words, words])
            f["caution"] = .array([words])
            f["carry_on"] = words
            let first: JSONValue = .object(["origin": .string("sfo"), "destination": .string("den"), "layover": words])
            let second: JSONValue = .object(["origin": .string("den"), "destination": .string("jfk")])
            f["segments"] = .array([first, second])
            flightList.append(.object(f))

            var h = hotel()
            h["url"] = .string("https://example.com/h/\(i)")
            h["name"] = i % 2 == 0 ? words : .string("Inn")
            h["stars"] = .number(Double(i % 6))
            h["rating"] = .number(4.6)
            h["reviews"] = .number(120_433)
            h["neighborhood"] = words
            h["badge"] = words
            h["cancellation"] = words
            h["amenities"] = .array(Array(repeating: words, count: 10))
            h["why"] = .array([words])
            h["images"] = .array([.string("https://example.com/a.jpg"), .string("https://example.com/b.jpg")])
            hotelList.append(.object(h))
        }
        let flights = TravelCards.flights(["note": words, "flights": .array(flightList)])!
        let hotels = TravelCards.hotels(["location": words, "hotels": .array(hotelList)])!
        let sizes: [UIContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge]
        for category in sizes {
            for width in [240.0, 320, 390, 430, 768, 1_366] {
                for expanded in [false, true] {
                    for asked in [[:], [flights.flights[0].id: Set([TravelCards.Ask.book])], [flights.flights[3].id: Set([TravelCards.Ask.watchPrice, .book])]] {
                        let row = FlightsCardRow(flights: flights, rowId: "rf", messageId: "m1", asked: asked, expanded: expanded)
                        let height = FlightsCardLayout.make(row, gap: 8, width: width, category: category).height
                        #expect(height.isFinite && height > 100 && height < 60_000, "flights \(category.rawValue) \(width)")
                    }
                    let row = HotelsCardRow(hotels: hotels, rowId: "rh", messageId: "m2", asked: [hotels.hotels[1].id: [.book]], expanded: expanded)
                    let height = HotelsCardLayout.make(row, gap: 8, width: width, category: category).height
                    #expect(height.isFinite && height > 100 && height < 60_000, "hotels \(category.rawValue) \(width)")
                }
            }
        }
        // The same card measured twice is the same height (the list jumps if it isn't).
        let row = FlightsCardRow(flights: flights, rowId: "rf", messageId: "m1", asked: [:], expanded: true)
        #expect(FlightsCardLayout.make(row, gap: 8, width: 390, category: .large).height == FlightsCardLayout.make(row, gap: 8, width: 390, category: .large).height)
    }

    /// At every text size the price is on the card, whole, and each line has the room its font needs: the cards grow
    /// with the text. (They were sized for the default size, and at accessibility sizes a flight lost its price.)
    @Test func theCardsGrowWithTheTextSize() throws {
        let note = "Morning departures from SFO to JFK. Relaxed the nonstop filter to include one lower fare."
        let flights = try #require(TravelCards.flights(["step": "Fares checked", "note": .string(note), "relaxed_filters": .array([.string("Nonstop only")]),
                                                        "follow_ups": .array([.string("Show business class"), .string("Return Sunday evening")]),
                                                        "flights": .array((0..<6).map { .object(flight(["url": .string("https://example.com/f/\($0)")])) })]))
        let hotels = try #require(TravelCards.hotels(["location": "Manhattan, NY", "check_in": "Dec 12", "check_out": "Dec 15", "guests": "2 guests",
                                                      "note": .string(note), "follow_ups": .array([.string("Under $250/night")]),
                                                      "hotels": .array((0..<3).map { .object(hotel(["url": .string("https://example.com/h/\($0)")])) })]))
        func labels(_ view: UIView) -> [UILabel] { view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? labels($0) } }
        func controls(_ view: UIView, _ lead: String) -> [UIControl] {
            view.subviews.flatMap { sub -> [UIControl] in
                if let c = sub as? UIControl, c.accessibilityIdentifier?.hasPrefix(lead) == true { return [c] }
                return controls(sub, lead)
            }
        }
        let sizes: [UIContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge, .accessibilityMedium, .accessibilityExtraExtraExtraLarge]
        var last: (flights: CGFloat, hotels: CGFloat) = (0, 0)
        for category in sizes {
            for width in [320.0, 402, 440, 820] as [CGFloat] {
                let type = TravelCardType(category: category)
                let note = "\(category.rawValue) \(width)"
                // Flights.
                let fRow = FlightsCardRow(flights: flights, rowId: "rf", messageId: "m1", asked: [:], expanded: false)
                guard case .prompt(let fl) = FlightsCardLayout.make(fRow, gap: 8, width: width, category: category).content,
                      case .flights(let fg)? = fl.travel else { Issue.record("flights layout"); return }
                #expect(fg.height == ceil(FlightsCardLayout.pieces(fRow, width: fg.width, category: category).height), "\(note)")
                let fView = FlightsCardView(frame: CGRect(x: 0, y: 0, width: width, height: fg.gapAbove + fg.height + 8))
                fView.configure(fRow, fg)
                fView.layoutIfNeeded()
                let rows = controls(fView, "travel.flight.")
                #expect(rows.count == 4, "\(note)")
                for row in rows {
                    #expect(abs(row.bounds.height - FlightsCardLayout.rowHeight(type)) < 0.6, "row \(row.bounds.height) \(note)")
                    let texts = labels(row)
                    let price = try #require(texts.first { $0.text == "$348.00" }, "the price is on the row \(note)")
                    let box = price.convert(price.bounds, to: row)
                    #expect(box.width >= price.intrinsicContentSize.width - 0.6, "the price is whole \(box.width) \(note)")
                    #expect(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(box), "the price is inside its row \(box) \(note)")
                    for label in texts where !(label.text ?? "").isEmpty {
                        let frame = label.convert(label.bounds, to: row)
                        #expect(frame.height >= ceil(label.font.lineHeight) - 1, "a line is not squeezed: \(label.text ?? "") \(frame.height) \(note)")
                        #expect(row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label.text ?? "") \(frame) \(note)")
                    }
                }
                // Hotels.
                let hRow = HotelsCardRow(hotels: hotels, rowId: "rh", messageId: "m2", asked: [:], expanded: false)
                guard case .prompt(let hl) = HotelsCardLayout.make(hRow, gap: 8, width: width, category: category).content,
                      case .hotels(let hg)? = hl.travel else { Issue.record("hotels layout"); return }
                let hView = HotelsCardView(frame: CGRect(x: 0, y: 0, width: width, height: hg.gapAbove + hg.height + 8))
                hView.configure(hRow, hg)
                hView.layoutIfNeeded()
                let tiles = controls(hView, "travel.hotel.")
                #expect(tiles.count == 3, "\(note)")
                for tile in tiles {
                    #expect(abs(tile.bounds.height - HotelsCardLayout.tileHeight(type)) < 0.6, "tile \(tile.bounds.height) \(note)")
                    for label in labels(tile) where !(label.text ?? "").isEmpty {
                        let frame = label.convert(label.bounds, to: tile)
                        let lines = CGFloat(max(1, label.numberOfLines))
                        #expect(frame.height >= ceil(label.font.lineHeight) - 1 && frame.height <= ceil(label.font.lineHeight) * lines + 1, "\(label.text ?? "") \(frame.height) \(note)")
                        #expect(tile.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label.text ?? "") \(frame) \(note)")
                    }
                }
                if width == 402 {
                    #expect(fg.height >= last.flights && hg.height >= last.hotels, "bigger text, taller cards \(note)")
                    last = (fg.height, hg.height)
                }
            }
        }
    }
}

// MARK: - Image markup

@MainActor @Suite(.serialized) struct ImageMarkupStressTests {

    private func picture(_ width: CGFloat, _ height: CGFloat, scale: CGFloat = 1, color: UIColor = .white) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// The colour of one pixel, `x` and `y` as shares of the picture.
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        guard let cg = image.cgImage else { return (-1, -1, -1) }
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = x * CGFloat(cg.width), py = y * CGFloat(cg.height)
        context.draw(cg, in: CGRect(x: -px, y: -(CGFloat(cg.height) - py - 1), width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    /// The pin's badge was at most 48 pixels wide on the sent picture: a dot on a full-size photo. It now covers
    /// the share of the picture it covered on screen.
    @Test func pinBadgesAreAsBigOnTheSentPictureAsOnScreen() {
        let photo = picture(3_000, 3_000)
        var doc = ImageMarkupDocument()
        doc.addPin(at: ImageMarkupPoint(x: 0.5, y: 0.5), color: .blue, note: "here")

        // Shown 300 points wide, the badge is 24 points: 8% of the picture, so 240 pixels of 3,000.
        let sent = ImageMarkupRenderer.composite(image: photo, document: doc, displayMinSide: 300)
        #expect(sent.size == photo.size)
        let inBadge = pixel(sent, x: 0.5 + 0.025, y: 0.5 - 0.015)    // 75 px right of the middle: inside the badge
        #expect(inBadge.b > 200 && inBadge.r < 120, "blue badge there, got \(inBadge)")
        let outside = pixel(sent, x: 0.5 + 0.06, y: 0.5)             // 180 px: past its edge
        #expect(outside.r > 240 && outside.g > 240 && outside.b > 240, "white paper there, got \(outside)")

        // Without the on-screen size the badge is sized for a picture shown at full size: 48 px, so the same spot is paper.
        let small = ImageMarkupRenderer.composite(image: photo, document: doc)
        let there = pixel(small, x: 0.5 + 0.025, y: 0.5 - 0.015)
        #expect(there.r > 240 && there.g > 240, "got \(there)")

        #expect(ImageMarkupRenderer.badgeDiameter(forMinSide: 10) == 24)
        #expect(ImageMarkupRenderer.badgeDiameter(forMinSide: 100_000) == 48)
        // Nonsense screen sizes fall back, never divide by zero.
        for shown in [0.0, -5, 0.5, .nan, .infinity] {
            #expect(ImageMarkupRenderer.composite(image: picture(200, 100), document: doc, displayMinSide: shown).cgImage != nil)
        }
    }

    /// A 48-megapixel photo is brought down to 4,096 on its long side before it is drawn on (its bitmap alone would
    /// be about 200 MB). Smaller pictures keep every pixel.
    @Test func hugePicturesAreBroughtDownSmallOnesKept() {
        var doc = ImageMarkupDocument()
        doc.addStroke(ImageMarkupStroke(tool: .arrow, color: .red, widthRatio: 0.01, points: [ImageMarkupPoint(x: 0.1, y: 0.1), ImageMarkupPoint(x: 0.9, y: 0.9)]))
        for (width, height, scale) in [(6_000.0, 3_000.0, 1.0), (3_000, 6_000, 1), (2_500, 1_000, 3)] {
            let out = ImageMarkupRenderer.composite(image: picture(width, height, scale: scale), document: doc)
            let long = max(out.cgImage?.width ?? 0, out.cgImage?.height ?? 0)
            #expect(long <= Int(ImageMarkupRenderer.maxExportSide) + 1 && long >= Int(ImageMarkupRenderer.maxExportSide) - 2, "\(width)x\(height)@\(scale) → \(long)")
            #expect(abs(out.size.width - width) < 2 && abs(out.size.height - height) < 2, "the size in points stays, so the marks land where they were drawn")
        }
        let kept = ImageMarkupRenderer.composite(image: picture(1_200, 800, scale: 2), document: doc)
        #expect(kept.cgImage?.width == 2_400 && kept.cgImage?.height == 1_600)

        // Nothing drawn: the picture itself comes back, untouched. An empty picture too.
        let plain = picture(64, 64)
        #expect(ImageMarkupRenderer.composite(image: plain, document: ImageMarkupDocument()) === plain)
        let none = UIImage()
        #expect(ImageMarkupRenderer.composite(image: none, document: doc) === none)
        // One pixel, and a sliver.
        #expect(ImageMarkupRenderer.composite(image: picture(1, 1), document: doc).cgImage != nil)
        #expect(ImageMarkupRenderer.composite(image: picture(4_000, 2), document: doc).cgImage != nil)
    }

    /// Strokes no finger could draw: no points, one point, thousands, widths of zero and worse.
    @Test func oddStrokesDrawWithoutTrouble() {
        var doc = ImageMarkupDocument()
        doc.addStroke(ImageMarkupStroke(tool: .pen, color: .red, widthRatio: 0.01, points: []))
        #expect(doc.isEmpty && !doc.canUndo, "a stroke with no points is not a stroke")
        var rng = StressRNG(seed: 0xD1A6_0002)
        for tool in ImageMarkupTool.allCases where tool != .pin {
            for width in [0.0, -1, 0.000001, 5, .nan, .infinity] {
                doc.addStroke(ImageMarkupStroke(tool: tool, color: .green, widthRatio: width, points: [ImageMarkupPoint(x: 0.5, y: 0.5)]))
                doc.addStroke(ImageMarkupStroke(tool: tool, color: .black, widthRatio: width,
                                                points: [ImageMarkupPoint(x: 0.2, y: 0.2), ImageMarkupPoint(x: 0.2, y: 0.2)]))
            }
            doc.addStroke(ImageMarkupStroke(tool: tool, color: .yellow, widthRatio: 0.01,
                                            points: (0..<6_000).map { _ in ImageMarkupPoint(x: .random(in: -1...2, using: &rng), y: .random(in: -1...2, using: &rng)) }))
        }
        for i in 0..<150 { doc.addPin(at: ImageMarkupPoint(x: .nan, y: Double(i)), color: .white, note: String(repeating: "n", count: i * 40)) }
        #expect(ImageMarkupRenderer.lineWidth(ratio: .infinity, minSide: 400) == 2)
        #expect(ImageMarkupRenderer.lineWidth(ratio: .nan, minSide: 400) == 2)
        #expect(ImageMarkupRenderer.lineWidth(ratio: 5, minSide: 400) == 80)
        #expect(ImageMarkupRenderer.lineWidth(ratio: -1, minSide: 400) == 2)
        #expect(ImageMarkupRenderer.lineWidth(ratio: 0.01, minSide: 3_000) == 30)
        let point = ImageMarkupPoint(x: .nan, y: -.infinity)
        #expect(point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y))
        #expect(ImageMarkupPoint(CGPoint(x: 50, y: 50), in: .zero).x == 1, "a canvas with no size can't divide by zero")
        let clock = ContinuousClock()
        for size in [CGSize(width: 800, height: 600), CGSize(width: 3, height: 900), CGSize(width: 1, height: 1)] {
            var out: UIImage?
            let took = clock.measure { out = ImageMarkupRenderer.composite(image: picture(size.width, size.height), document: doc, displayMinSide: 320) }
            #expect(out?.cgImage != nil)
            #expect(took < .seconds(10), "\(size) took \(took)")
        }
    }

    /// One long scribble back and forth across the whole photo, as a bored finger draws it: 4,000 points, every
    /// sweep crossing the others. Drawn as a single path this took CoreGraphics many seconds (it works out every
    /// crossing first), on every move of the finger. In pieces it is quick, and the see-through highlighter still
    /// comes out one even tone where it crosses itself.
    @Test func aLongScribbleDrawsQuicklyAndEvenly() {
        var scribble: [ImageMarkupPoint] = []
        for i in 0..<ImageMarkupCanvasView.maxStrokePoints {
            let sweep = Double(i / 20), along = Double(i % 20) / 19
            let x = Int(sweep) % 2 == 0 ? along : 1 - along
            scribble.append(ImageMarkupPoint(x: 0.05 + 0.9 * x, y: 0.05 + 0.9 * abs(sin(sweep * 1.7 + along))))
        }
        let clock = ContinuousClock()
        for tool in [ImageMarkupTool.pen, .highlighter] {
            var doc = ImageMarkupDocument()
            doc.addStroke(ImageMarkupStroke(tool: tool, color: .red, widthRatio: tool == .highlighter ? 0.036 : 0.01, points: scribble))
            var out: UIImage?
            let took = clock.measure { out = ImageMarkupRenderer.composite(image: picture(1_200, 900), document: doc, displayMinSide: 390) }
            #expect(out?.cgImage != nil)
            #expect(took < .seconds(3), "\(tool) took \(took)")
        }

        // A highlighter crossing itself: the crossing is the same tone as the rest of the line, not darker.
        var cross = ImageMarkupDocument()
        var points: [ImageMarkupPoint] = (0...100).map { ImageMarkupPoint(x: 0.1 + 0.8 * Double($0) / 100, y: 0.5) }
        points += (0...100).map { ImageMarkupPoint(x: 0.9 - 0.4 * Double($0) / 100, y: 0.5 - 0.4 * Double($0) / 100) }
        points += (0...100).map { ImageMarkupPoint(x: 0.5, y: 0.1 + 0.8 * Double($0) / 100) }
        cross.addStroke(ImageMarkupStroke(tool: .highlighter, color: .blue, widthRatio: 0.036, points: points))
        let out = ImageMarkupRenderer.composite(image: picture(1_000, 1_000), document: cross)
        let crossing = pixel(out, x: 0.5, y: 0.5), line = pixel(out, x: 0.2, y: 0.5), paper = pixel(out, x: 0.2, y: 0.2)
        #expect(paper.r > 250 && paper.g > 250 && paper.b > 250)
        #expect(line.r < 240, "the line is there, got \(line)")
        #expect(abs(crossing.r - line.r) <= 3 && abs(crossing.g - line.g) <= 3 && abs(crossing.b - line.b) <= 3, "crossing \(crossing) vs line \(line)")
        // Piece ends (every 64th point) leave no gap and no darker dot in a see-through line.
        for share in [0.3, 0.6, 0.608, 0.612, 0.7, 0.8] {
            let here = pixel(out, x: share, y: 0.5)
            #expect(abs(here.r - line.r) <= 3 && abs(here.b - line.b) <= 3, "at \(share): \(here) vs \(line)")
        }
    }

    /// 20,000 random edits, undos and redos against the rules: pins are always numbered 1…N, undo never goes
    /// back more than the history holds, and redo after undo is the state it left.
    @Test func undoAndRedoHoldUpUnderRandomEditing() {
        var rng = StressRNG(seed: 0xD1A6_0003)
        var doc = ImageMarkupDocument()
        for step in 0..<20_000 {
            switch Int.random(in: 0..<10, using: &rng) {
            case 0, 1, 2:
                doc.addStroke(ImageMarkupStroke(tool: [.pen, .highlighter, .arrow, .box].randomElement(using: &rng)!, color: .red, widthRatio: 0.01,
                                                points: [ImageMarkupPoint(x: .random(in: 0...1, using: &rng), y: 0.5)]))
            case 3, 4:
                if doc.pins.count < 60 { doc.addPin(at: ImageMarkupPoint(x: 0.5, y: .random(in: 0...1, using: &rng)), color: .blue, note: "n\(step)") }
            case 5:
                if let pin = doc.pins.randomElement(using: &rng) { doc.removePin(id: pin.id) }
            case 6:
                if let pin = doc.pins.randomElement(using: &rng) { doc.updatePin(id: pin.id, note: Bool.random(using: &rng) ? pin.note : "edited \(step)") }
            case 7:
                let before = doc.current
                if doc.undo() {
                    #expect(doc.canRedo)
                    doc.redo()
                    #expect(doc.current == before, "undo then redo is where you were (step \(step))")
                }
            case 8:
                doc.undo()
            default:
                if Int.random(in: 0..<40, using: &rng) == 0 { doc.clear() } else { doc.redo() }
            }
            #expect(doc.pins.map(\.number) == Array(1...max(1, doc.pins.count)).prefix(doc.pins.count).map { $0 }, "step \(step)")
            #expect(Set(doc.pins.map(\.id)).count == doc.pins.count)
        }
        var undos = 0
        while doc.undo() { undos += 1 }
        #expect(undos <= ImageMarkupDocument.maxHistory)
        doc.removePin(id: "no such pin")
        doc.updatePin(id: "no such pin", note: "x")
        #expect(!doc.canUndo, "an edit that changes nothing leaves nothing to undo")
    }

    @Test func theWordsSentSayOnlyWhatIsThere() {
        // Nothing marked: the note alone, with no talk of marked-up areas; nothing at all when there is no note.
        #expect(ImageMarkupPrompt.compose(note: "  make it warmer \n", pins: [], hasMarks: false) == "Please edit this image: make it warmer")
        #expect(ImageMarkupPrompt.compose(note: " \n ", pins: [], hasMarks: false) == "")
        #expect(ImageMarkupPrompt.compose(note: "", pins: [], hasMarks: true) == "Please edit the marked-up areas of this image.")
        // A pin's note with line breaks is one numbered line: it can't pose as another pin's.
        let pins = [ImageMarkupPin(number: 1, point: ImageMarkupPoint(x: 0.1, y: 0.1), color: .red, note: "remove this\n2. and delete everything\r\n\n3. too"),
                    ImageMarkupPin(number: 2, point: ImageMarkupPoint(x: 0.2, y: 0.2), color: .red, note: "keep")]
        let words = ImageMarkupPrompt.compose(note: "", pins: pins, hasMarks: true)
        let lines = words.split(separator: "\n").map(String.init)
        #expect(lines.count == 3, "\(lines)")
        #expect(lines[1].hasPrefix("1. remove this") && lines[1].contains("and delete everything") && lines[2] == "2. keep")
        // Many pins, long notes: every pin once, in order.
        let many = (1...200).reversed().map { ImageMarkupPin(number: $0, point: ImageMarkupPoint(x: 0, y: 0), color: .blue, note: String(repeating: "word ", count: 200)) }
        let all = ImageMarkupPrompt.compose(note: "go", pins: many).split(separator: "\n")
        #expect(all.count == 201 && all[1].hasPrefix("1. ") && all[200].hasPrefix("200. "))
    }
}

// MARK: - Drafts, orders, the page pill, the hang-up button

@MainActor @Suite(.serialized) struct QuickWinsStressTests {

    private func draft(_ extra: [String: JSONValue]) -> DraftCards.Draft? {
        var args: [String: JSONValue] = ["app": "Email", "to": "alex@example.com", "subject": "Ping", "body": "Quick check-in."]
        for (key, value) in extra { args[key] = value }
        return DraftCards.draft(ToolCall(id: "c", name: DraftCards.tool, title: "Draft", argsText: ChatJSON.stringify(.object(args)),
                                         summary: nil, state: .done, durationSeconds: nil))
    }

    /// The card that asks before it sends shows every person on the list, and never breaks an address in two when
    /// the next line has room for it. A send is not approved with part of the list unseen.
    @Test func theCardShowsEveryoneOnTheList() throws {
        let cc = (1...9).map { "person\($0)@example.com" }
        let d = try #require(draft(["cc": .array(cc.map(JSONValue.string)), "bcc": "records@example.com,audit@example.com"]))
        let row = DraftCardRow(draft: d, rowId: "r", messageId: "m", body: d.body, edited: false, state: .waiting, editing: false, expanded: false)
        for width in [320.0, 402.0, 440.0, 820.0] as [CGFloat] {
            for category in [UIContentSizeCategory.extraSmall, .large, .accessibilityExtraExtraExtraLarge] {
                guard case .prompt(let layout) = PromptLayout.draft(row, gap: 6, width: width, category: category).content else { Issue.record("layout"); return }
                let frame = try #require(layout.cardFrame)
                let shown = layout.texts.map { $0.text.text.string }
                let list = try #require(shown.first { $0.contains("person1@example.com") }, "\(width) \(category.rawValue)")
                for name in cc { #expect(list.contains(name), "\(name) \(width) \(category.rawValue)") }
                #expect(shown.contains("records@example.com, audit@example.com"), "a list written without spaces can break between names")
                #expect(layout.texts.allSatisfy { frame.insetBy(dx: -1, dy: -1).contains($0.frame) })
                // No line of the list starts or ends inside an address when the address fits a line.
                let placed = try #require(layout.texts.first { $0.text.text.string == list })
                let longest = (cc.last! as NSString).size(withAttributes: placed.text.text.attributes(at: 0, effectiveRange: nil)).width
                guard longest < placed.frame.width - 4 else { continue }
                let manager = placed.text.manager
                var broken: [String] = []
                manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: placed.text.container)) { _, _, _, glyphs, _ in
                    let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                    let line = (list as NSString).substring(with: chars).trimmingCharacters(in: .whitespaces)
                    let whole = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    for piece in whole where !cc.contains(piece) { broken.append(piece) }
                }
                let note = "\(broken) \(width) \(category.rawValue)"
                #expect(broken.isEmpty, "\(note)")
            }
        }
        // A very long list says how many it left out; the message that goes to the bot still names everyone.
        let crowd = (1...60).map { "p\($0)@example.com" }
        let big = try #require(draft(["cc": .array(crowd.map(JSONValue.string))]))
        let words = DraftCards.shownPeople(big.cc)
        #expect(words.hasSuffix("p12@example.com, and 48 more") && !words.contains("p13@"))
        #expect(DraftCards.shownPeople((1...13).map { "p\($0)@example.com" }.joined(separator: ", ")).hasSuffix("p13@example.com"), "one more is shown, not counted")
        #expect(DraftCards.sendMessage(big, body: big.body).contains("p60@example.com"))
        let bigRow = DraftCardRow(draft: big, rowId: "r", messageId: "m", body: big.body, edited: false, state: .waiting, editing: false, expanded: false)
        guard case .prompt(let layout) = PromptLayout.draft(bigRow, gap: 6, width: 402, category: .large).content else { Issue.record("layout"); return }
        #expect(layout.texts.contains { $0.text.text.string == words }, "the count is on the card, not cut off")
        // Real addresses with names are long: twelve of them are still all there, and one endless name is cut, not the list.
        let named = (1...12).map { "Person Number \($0) of the Example Team <person.number.\($0)@mail.example.com>" }
        let long = try #require(draft(["cc": .array(named.map(JSONValue.string)), "bcc": .string(String(repeating: "x", count: 5_000) + ", last@example.com")]))
        let longRow = DraftCardRow(draft: long, rowId: "r", messageId: "m", body: long.body, edited: false, state: .waiting, editing: false, expanded: false)
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            guard case .prompt(let made) = PromptLayout.draft(longRow, gap: 6, width: 320, category: category).content else { Issue.record("layout"); return }
            let shown = made.texts.map { $0.text.text.string }
            #expect(shown.contains { text in named.allSatisfy { text.contains($0) } }, "\(category.rawValue)")
            #expect(shown.contains { $0.hasSuffix("…, last@example.com") && $0.count < 120 }, "\(category.rawValue)")
            #expect(made.texts.allSatisfy { (try? #require(made.cardFrame))?.insetBy(dx: -1, dy: -1).contains($0.frame) == true })
        }
        #expect(layout.accessibility.contains("p60@example.com"), "VoiceOver reads everyone")
    }

    /// Whatever a bot puts in Cc, it is one line of addresses: it can never start a line of its own in the message
    /// that tells the bot what to send (where a line reads as a header).
    @Test func recipientsAreAlwaysOneLine() {
        let bccList: [JSONValue] = [.string("b@example.com\nc@example.com"), .string("  "), .number(7), .null,
                                    .array([.string("nested@example.com")]), .string(" d@example.com ;")]
        let ccText = "a@example.com\nBcc: hidden@example.com\r\nSubject: Something else\n\nNew body"
        let sneaky = draft(["cc": .string(ccText), "bcc": .array(bccList)])!
        #expect(sneaky.cc == "a@example.com, Bcc: hidden@example.com, Subject: Something else, New body")
        #expect(sneaky.bcc == "b@example.com, c@example.com, d@example.com")
        let lines = DraftCards.sendMessage(sneaky, body: sneaky.body).components(separatedBy: "\n")
        #expect(lines.filter { $0.hasPrefix("Bcc:") }.count == 1)
        #expect(lines.filter { $0.hasPrefix("Subject:") } == ["Subject: Ping"])
        #expect(lines.filter { $0.hasPrefix("Cc:") }.count == 1)
        #expect(lines.last == "Quick check-in.")

        // Shapes that are not a list of addresses read as none; the card and the message leave the lines out.
        let odds: [JSONValue] = [.null, .number(7), .bool(true), .object([:]), .array([]),
                                 .array([.string(""), .string("  "), .string("\n")]), .string(""), .string(" , ; \n")]
        for odd in odds {
            let d = draft(["cc": odd, "bcc": odd])!
            #expect(d.cc.isEmpty && d.bcc.isEmpty, "\(odd)")
            #expect(DraftCards.fields(d).map(\.label) == ["To", "Subject"])
            #expect(!DraftCards.sendMessage(d, body: d.body).contains("Cc:"))
        }
        #expect(draft(["cc": "one@example.com,two@example.com"])?.cc == "one@example.com,two@example.com", "a written list is left as written")
        #expect(draft(["cc": ["Ünï Cödé <u@example.com>", "名前 <n@example.com>"]])?.cc == "Ünï Cödé <u@example.com>, 名前 <n@example.com>")

        // The id is the add-on's (app, to, subject, body): Cc and Bcc don't change which draft a Send answers.
        #expect(sneaky.id == draft([:])?.id)
        #expect(DraftCards.answer(in: DraftCards.sendMessage(sneaky, body: "edited"))?.id == sneaky.id)

        // 2,000 addresses: read, shown and sent without trouble.
        let crowd = draft(["cc": .array((0..<2_000).map { .string("person\($0)@example.com") })])!
        #expect(crowd.cc.components(separatedBy: ", ").count == 2_000)
        #expect(DraftCards.sendMessage(crowd, body: crowd.body).components(separatedBy: "\n").filter { $0.hasPrefix("Cc:") }.count == 1)
    }

    private func order(store: String = "Example Outfitters", site: String? = "https://example.com/checkout", items: [[String: JSONValue]]) -> ShoppingCards.Order? {
        var args: [String: JSONValue] = ["store": .string(store), "total": 100, "items": .array(items.map(JSONValue.object))]
        if let site { args["site"] = .string(site) }
        return ShoppingCards.order(ToolCall(id: "o", name: ShoppingCards.orderTool, title: "Order", argsText: ChatJSON.stringify(.object(args)),
                                            summary: nil, state: .done, durationSeconds: nil))
    }

    private func shown(_ products: [[String: JSONValue]]) -> [ShoppingCards.Product] {
        let call = ToolCall(id: "p", name: ShoppingCards.productsTool, title: "Products",
                            argsText: ChatJSON.stringify(.object(["products": .array(products.map(JSONValue.object))])), summary: nil, state: .done, durationSeconds: nil)
        return ShoppingCards.catalogProducts(in: [ChatMessage(id: "m", role: .assistant, parts: [.tool(call)], timestamp: Date())])
    }

    /// A line opens its own product. It used to open any product of the same name, from any store, even when the
    /// line carried its own link.
    @Test func anOrderLineOpensItsOwnProductNeverALookalike() {
        let history = shown([
            ["title": "USB-C Cable", "store": "Other Shop", "url": "https://other.example.com/cable", "price": 4, "why": ["Cheap"]],
            ["title": "Trail Runner 2", "store": "Example Outfitters", "url": "https://example.com/p/trail-runner-2", "price": 129.99, "why": ["Great grip"]],
        ])
        #expect(history.count == 2)
        let o = order(items: [
            ["title": "USB-C Cable", "price": 19, "url": "https://example.com/p/cable"],
            ["title": "usb-c cable ", "price": 19],
            ["title": "Trail Runner 2", "price": 119, "url": "https://example.com/p/trail-runner-2?color=navy", "detail": "Navy"],
            ["title": "  TRAIL runner 2", "price": 119],
        ])!
        // Its own link wins over the lookalike in another shop.
        let own = ShoppingCards.product(for: o.items[0], in: o, matching: history)
        #expect(own?.url.absoluteString == "https://example.com/p/cable" && own?.store == "Example Outfitters" && own?.why == [])
        // No link of its own, and the only product of that name is another shop's: the store's site, not their page.
        let none = ShoppingCards.product(for: o.items[1], in: o, matching: history)
        #expect(none?.url.absoluteString == "https://example.com/checkout" && none?.store == "Example Outfitters")
        // The same product from the same store: its reasons, at the line's own link and price.
        let same = ShoppingCards.product(for: o.items[2], in: o, matching: history)
        #expect(same?.url.absoluteString == "https://example.com/p/trail-runner-2?color=navy")
        #expect(same?.why == ["Great grip"] && same?.price == 119)
        #expect(same?.options.first?.value == "Navy")
        let byName = ShoppingCards.product(for: o.items[3], in: o, matching: history)
        #expect(byName?.url.absoluteString == "https://example.com/p/trail-runner-2" && byName?.price == 119)
        #expect(history[1].price == 129.99, "the shown product itself is not changed")

        // No site and no link: nothing to open, so no button.
        let bare = order(store: "Corner Shop", site: nil, items: [["title": "Bread", "price": 3], ["title": "USB-C Cable", "price": 5]])!
        #expect(ShoppingCards.openableItemIndices(in: bare, matching: history).isEmpty)
        // An order that names no store may borrow a shown product by name.
        let nameless = order(store: "", site: nil, items: [["title": "USB-C Cable", "price": 5]])
        if let nameless { #expect(ShoppingCards.openableItemIndices(in: nameless, matching: history) == [0]) }
    }

    @Test func unsafeLinksAndHugeOrdersAreHandled() {
        let o = order(site: nil, items: [
            ["title": "A", "price": 1, "url": "javascript:alert(1)"], ["title": "B", "price": 1, "url": "http://example.com/b"],
            ["title": "C", "price": 1, "url": "file:///etc/hosts"], ["title": "D", "price": 1, "url": "https://example.com/d"],
            ["title": "E", "price": 1, "url": 7], ["title": "F", "price": 1, "url": "https:///no-host"],
        ])!
        #expect(o.items.map { $0.url?.absoluteString } == [nil, nil, nil, "https://example.com/d", nil, nil])
        #expect(ShoppingCards.openableItemIndices(in: o, matching: []) == [3])

        // 400 lines against 400 shown products: quick, and capped where the card caps.
        let history = shown((0..<400).map { ["title": .string("Thing \($0)"), "store": "Example Outfitters", "url": .string("https://example.com/p/\($0)"), "price": 5] })
        let big = order(items: (0..<400).map { ["title": .string("Thing \($0)"), "price": 5, "detail": .string(String(repeating: "Colour: Navy, ", count: 60)),
                                                "options": .array((0..<50).map { ["name": .string("Option \($0)"), "value": "x"] })] })!
        let clock = ContinuousClock()
        var open: Set<Int> = []
        let took = clock.measure { open = ShoppingCards.openableItemIndices(in: big, matching: history) }
        #expect(open.count == big.items.count && took < .seconds(2))
        #expect(big.items.allSatisfy { $0.options.count <= ShoppingCards.maxOptions })
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            for width in [240.0, 390, 1_024] {
                let row = OrderCardRow(order: big, rowId: "r", messageId: "m", state: .waiting, openableItems: open)
                let layout = OrderCardLayout.make(row, gap: 8, width: width, category: category)
                #expect(layout.height.isFinite && layout.height > 100)
            }
        }
    }

    /// Tapping a line many times fast, and lines that can't open, on the laid-out card.
    @Test func lineButtonsFireOncePerTapAndOnlyForOpenableLines() {
        let o = order(site: nil, items: [["title": "A", "price": 1], ["title": "B", "price": 1, "url": "https://example.com/b"], ["title": "C", "price": 1]])!
        let row = OrderCardRow(order: o, rowId: "r", messageId: "m", state: .waiting, openableItems: ShoppingCards.openableItemIndices(in: o, matching: []))
        guard case .prompt(let prompt) = OrderCardLayout.make(row, gap: 8, width: 390, category: .large).content, case .order(let geo)? = prompt.shopping else {
            Issue.record("expected an order layout"); return
        }
        let view = OrderCardButtons()
        var opened: [Int] = []
        view.onOpenItem = { opened.append($0) }
        for _ in 0..<50 { view.configure(geo) }      // a reused cell is set up again and again
        let buttons = view.ordered.compactMap { $0 as? UIControl }.filter { $0.accessibilityIdentifier?.hasPrefix("order.item.") == true }
        #expect(buttons.count == 1, "only the line with a page gets a button, and reuse doesn't stack them")
        for _ in 0..<25 { buttons.first?.sendActions(for: .touchUpInside) }
        #expect(opened == Array(repeating: 1, count: 25))
    }

    /// Updates arriving faster than anyone can tap: the pill shows the newest, one tap takes it, and an update
    /// for the page already shown raises nothing.
    @Test func thePagePillKeepsOnlyTheNewestUpdate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hq-pill-stress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let versions = try (0..<40).map { i -> URL in
            let url = dir.appending(path: "page-v\(i).html")
            try "<html><body><h1>Version \(i)</h1></body></html>".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        let sheet = HTMLPageSheet.present(versions[0], from: host)
        sheet.loadViewIfNeeded()

        sheet.applyPendingUpdate()                       // nothing waiting: nothing happens
        #expect(!sheet.isUpdatePillVisible && sheet.pendingUpdateURL == nil)
        for url in versions.dropFirst() { sheet.noteExternalUpdateAvailable(url: url) }
        #expect(sheet.isUpdatePillVisible && sheet.pendingUpdateURL == versions.last)
        sheet.applyPendingUpdate()
        sheet.applyPendingUpdate()                       // the double tap
        #expect(!sheet.isUpdatePillVisible && sheet.pendingUpdateURL == nil)
        sheet.noteExternalUpdateAvailable(url: dir.appending(path: "gone.html"))
        sheet.applyPendingUpdate()                       // the file vanished meanwhile: no crash
        #expect(sheet.pendingUpdateURL == nil)
    }

    /// The red button takes two taps. However the taps fall, one arming gives at most one hang-up, and never from a
    /// tap that came right behind the arming tap.
    @Test func theHangUpButtonNeverFiresOnOneTapHoweverFast() {
        var rng = StressRNG(seed: 0xD1A6_0004)
        var button = PhoneHangUpGuard()
        var armedAt: Double?, hangUps = 0, expected = 0, now = 1_000.0
        for _ in 0..<50_000 {
            now += [0.0, 0.01, 0.2, 0.44, 0.45, 0.5, 3][Int.random(in: 0..<7, using: &rng)]
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: button.arm(at: now); if armedAt == nil { armedAt = now }
            case 1: button.cancel(); armedAt = nil           // the four seconds ran out, or the screen closed
            case 2:
                let kept = button.keep(at: now)
                let settled = armedAt.map { now - $0 >= PhoneHangUpGuard.settle } ?? false
                #expect(kept == settled)
                if settled { armedAt = nil }
            default:
                let settled = armedAt.map { now - $0 >= PhoneHangUpGuard.settle } ?? false
                if settled { expected += 1; armedAt = nil }
                if button.confirm(at: now) { hangUps += 1 }
            }
            #expect(button.armed == (armedAt != nil))
        }
        #expect(hangUps == expected && hangUps > 1_000)
        var fresh = PhoneHangUpGuard()
        let first = fresh.confirm(), second = fresh.confirm()
        #expect(!first && !second, "a fresh call screen never hangs up on the first taps")
    }

    /// A double tap, a triple tap, a burst of forty taps in the same spot: none of them ends the call, and the
    /// question is still up afterwards. Only a tap made after the settle time answers it.
    @Test func aBurstOfTapsNeverEndsTheCall() {
        for gap in [0.0, 0.02, 0.08, 0.15, 0.3] {
            for taps in [2, 3, 5, 40] where Double(taps - 1) * gap < PhoneHangUpGuard.settle {
                var button = PhoneHangUpGuard()
                var ended = false, kept = false
                button.arm(at: 50)
                for i in 1..<taps {
                    let at = 50 + Double(i) * gap
                    button.arm(at: at)                       // the old button, if the tap still reached it
                    if button.confirm(at: at) { ended = true }
                    if button.keep(at: at) { kept = true }
                }
                #expect(!ended && !kept && button.armed, "\(taps) taps \(gap) s apart")
            }
        }
        var button = PhoneHangUpGuard()
        button.arm(at: 10)
        button.arm(at: 10.4)                                 // a second arming tap never moves the clock
        let tooSoon = button.confirm(at: 10.44)
        let intime = button.confirm(at: 10.5)
        let again = button.confirm(at: 11)
        #expect(!tooSoon && intime && !again, "one arming, one hang-up, and not before the settle time")
        button.arm(at: 20)
        let backwards = button.confirm(at: 19)
        #expect(!backwards && button.armed, "a clock that went backwards is not a settled tap")
        let kept = button.keep(at: 21)
        let afterKeep = button.confirm(at: 22)
        #expect(kept && !button.armed && !afterKeep)
        #expect(PhoneHangUpGuard.disarmDelay(assisted: false) == PhoneHangUpGuard.disarmDelay)
        #expect(PhoneHangUpGuard.disarmDelay(assisted: true) >= .seconds(15), "VoiceOver needs longer than four seconds")
        #expect(PhoneHangUpGuard.settle >= 0.3 && PhoneHangUpGuard.settle < 1)
        #expect(PhoneHangUpGuard.disarmDelay >= .seconds(3))
    }
}
