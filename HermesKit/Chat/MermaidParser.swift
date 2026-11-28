// [mermaid] Pure parser for Mermaid fenced code blocks (flowchart/graph, sequenceDiagram, stateDiagram, pie, and
// structured fallback for other Mermaid types). Zero UIKit dependencies so layout and unit tests run off-main.

import Foundation

nonisolated struct MermaidDiagram: Hashable, Sendable {
    enum Direction: String, Hashable, Sendable {
        case topDown = "TD"
        case bottomUp = "BT"
        case leftRight = "LR"
        case rightLeft = "RL"
    }

    enum NodeShape: Hashable, Sendable {
        case rect
        case rounded
        case stadium
        case diamond
        case circle
        case cylinder
        case hexagon
    }

    enum EdgeStyle: Hashable, Sendable {
        case solid
        case dashed
        case thick
        case open
    }

    struct FlowNode: Hashable, Sendable {
        var id: String
        var label: String
        var shape: NodeShape
        var subgraph: String?
    }

    struct FlowEdge: Hashable, Sendable {
        var from: String
        var to: String
        var label: String
        var style: EdgeStyle
        var directed: Bool
    }

    struct FlowSubgraph: Hashable, Sendable {
        var id: String
        var title: String
    }

    struct SequenceMessage: Hashable, Sendable {
        var from: String
        var to: String
        var text: String
        var dashed: Bool
        var openArrow: Bool
    }

    struct PieSlice: Hashable, Sendable {
        var label: String
        var value: Double
    }

    enum Kind: Hashable, Sendable {
        case flowchart(direction: Direction, nodes: [FlowNode], edges: [FlowEdge], subgraphs: [FlowSubgraph])
        case sequence(participants: [String], messages: [SequenceMessage])
        case state(nodes: [FlowNode], edges: [FlowEdge])
        case pie(title: String, showData: Bool, slices: [PieSlice])
        case generic(title: String, lines: [String])
    }

    var source: String
    var kind: Kind

    var kindLabel: String {
        switch kind {
        case .flowchart: "Flowchart"
        case .sequence: "Sequence Diagram"
        case .state: "State Diagram"
        case .pie: "Pie Chart"
        case .generic(let title, _): title.isEmpty ? "Mermaid Diagram" : title
        }
    }
}

nonisolated enum MermaidParser {
    /// Whether a code fence language names Mermaid.
    static func isMermaidLanguage(_ language: String?) -> Bool {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return false }
        return raw == "mermaid" || raw == "mmd"
    }

    /// Parses a Mermaid source string into a structured diagram; returns nil if empty or clearly not a diagram.
    /// The most a diagram may hold and still be drawn; anything bigger stays a code block (it would be unreadable
    /// at any size, and its layout and picture would cost real time and memory).
    static let maxSourceLength = 60_000, maxLines = 600, maxLineLength = 1_200
    static let maxNodes = 160, maxEdges = 400, maxParticipants = 16, maxMessages = 120, maxSlices = 24

    static func parse(_ source: String) -> MermaidDiagram? {
        guard source.utf16.count <= maxSourceLength else { return nil }
        let rawLines = withoutFrontMatter(source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        guard rawLines.count <= maxLines else { return nil }
        let lines = rawLines.compactMap { cleanLine($0) }
        guard let first = lines.first, !lines.contains(where: { $0.utf16.count > maxLineLength }) else { return nil }
        let lower = first.lowercased()

        if lower.hasPrefix("flowchart") || lower.hasPrefix("graph") {
            let diagram = parseFlowchart(lines)
            if case .flowchart(_, let nodes, let edges, _) = diagram, !nodes.isEmpty,
               nodes.count <= maxNodes, edges.count <= maxEdges {
                return MermaidDiagram(source: source, kind: diagram)
            }
            return nil
        }
        if lower.hasPrefix("sequencediagram") {
            let diagram = parseSequence(Array(lines.dropFirst()))
            if case .sequence(let participants, let messages) = diagram, !participants.isEmpty || !messages.isEmpty,
               participants.count <= maxParticipants, messages.count <= maxMessages {
                return MermaidDiagram(source: source, kind: diagram)
            }
            return nil
        }
        if lower.hasPrefix("statediagram") {
            let diagram = parseState(Array(lines.dropFirst()))
            if case .state(let nodes, let edges) = diagram, !nodes.isEmpty, nodes.count <= maxNodes, edges.count <= maxEdges {
                return MermaidDiagram(source: source, kind: diagram)
            }
            return nil
        }
        if lower == "pie" || lower.hasPrefix("pie ") {
            let diagram = parsePie(lines)
            if case .pie(_, _, let slices) = diagram, !slices.isEmpty, slices.count <= maxSlices {
                return MermaidDiagram(source: source, kind: diagram)
            }
            return nil
        }

        // Known Mermaid diagram types rendered via structured block fallback.
        let knownPrefixes: [(String, String)] = [
            ("classdiagram", "Class Diagram"),
            ("erdiagram", "ER Diagram"),
            ("gantt", "Gantt Chart"),
            ("journey", "User Journey"),
            ("gitgraph", "Git Graph"),
            ("mindmap", "Mindmap"),
            ("timeline", "Timeline"),
            ("quadrantchart", "Quadrant Chart"),
            ("xychart", "XY Chart"),
            ("sankey", "Sankey Diagram"),
            ("c4context", "C4 Diagram"),
        ]
        for (prefix, title) in knownPrefixes where lower.hasPrefix(prefix) {
            let body = Array(lines.dropFirst()).prefix(24).map { $0 }
            guard !body.isEmpty else { return nil }
            return MermaidDiagram(source: source, kind: .generic(title: title, lines: body))
        }
        return nil
    }

    /// A YAML front matter block at the top (`---`, `title: …`, `---`) is Mermaid's own, not part of the diagram.
    private static func withoutFrontMatter(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[start].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return lines }
        return Array(lines[(end + 1)...])
    }

    private static func cleanLine(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("%%") { return nil }
        if let comment = line.range(of: "%%") {
            line = String(line[..<comment.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line.isEmpty ? nil : line
    }

    // MARK: Flowchart / Graph

    private static func parseFlowchart(_ lines: [String]) -> MermaidDiagram.Kind {
        // The header is `flowchart LR`, and an older style puts `;` after it and even statements on the same line
        // (`graph TD; A-->B; B-->C`): the direction is the header's second word, the rest are statements.
        let headerStatements = splitStatements(lines[0])
        let headerParts = (headerStatements.first ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let dirToken = headerParts.count > 1 ? headerParts[1].uppercased() : "TD"
        let direction: MermaidDiagram.Direction = switch dirToken {
        case "LR": .leftRight
        case "RL": .rightLeft
        case "BT": .bottomUp
        default: .topDown // TD, TB
        }
        let body = Array(headerStatements.dropFirst()) + Array(lines.dropFirst())

        var nodes: [MermaidDiagram.FlowNode] = []
        var nodeIndex: [String: Int] = [:]
        var edges: [MermaidDiagram.FlowEdge] = []
        var subgraphs: [MermaidDiagram.FlowSubgraph] = []
        var subgraphStack: [String] = []

        func upsertNode(_ parsed: (id: String, label: String, shape: MermaidDiagram.NodeShape)) {
            if let idx = nodeIndex[parsed.id] {
                if parsed.label != parsed.id || parsed.shape != .rect {
                    nodes[idx].label = parsed.label
                    nodes[idx].shape = parsed.shape
                }
                if nodes[idx].subgraph == nil, let sg = subgraphStack.last {
                    nodes[idx].subgraph = sg
                }
            } else {
                nodeIndex[parsed.id] = nodes.count
                nodes.append(MermaidDiagram.FlowNode(id: parsed.id, label: parsed.label, shape: parsed.shape, subgraph: subgraphStack.last))
            }
        }

        for raw in body {
            // Handle semicolon-separated statements on one line.
            for stmt in splitStatements(raw) {
                let s = stmt.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                let low = s.lowercased()
                if low.hasPrefix("style ") || low.hasPrefix("classdef ") || low.hasPrefix("class ") || low.hasPrefix("linkstyle ") || low.hasPrefix("click ") || low.hasPrefix("direction ") {
                    continue
                }
                if low.hasPrefix("subgraph") {
                    let rest = String(s.dropFirst("subgraph".count)).trimmingCharacters(in: .whitespaces)
                    let sgId = rest.isEmpty ? "sg\(subgraphs.count + 1)" : extractSubgraphId(rest)
                    let sgTitle = extractSubgraphTitle(rest, fallback: sgId)
                    subgraphs.append(MermaidDiagram.FlowSubgraph(id: sgId, title: sgTitle))
                    subgraphStack.append(sgId)
                    continue
                }
                if low == "end" {
                    _ = subgraphStack.popLast()
                    continue
                }
                let chain = parseEdgeChain(s, edgeBudget: maxEdges - edges.count)
                if chain.overflowed {
                    return .flowchart(direction: direction, nodes: [], edges: [], subgraphs: [])
                }
                if chain.edges.isEmpty {
                    if let single = parseNodeToken(s) { upsertNode(single) }
                } else {
                    for node in chain.nodes {
                        upsertNode(node)
                        if nodes.count > maxNodes {
                            return .flowchart(direction: direction, nodes: [], edges: [], subgraphs: [])
                        }
                    }
                    edges.append(contentsOf: chain.edges)
                }
                if nodes.count > maxNodes || edges.count > maxEdges {
                    return .flowchart(direction: direction, nodes: [], edges: [], subgraphs: [])
                }
            }
        }
        return .flowchart(direction: direction, nodes: nodes, edges: edges, subgraphs: subgraphs)
    }

    private static func splitStatements(_ line: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var depth = 0
        for ch in line {
            if ch == "\"" { inQuote.toggle() }
            if !inQuote {
                if ch == "[" || ch == "(" || ch == "{" { depth += 1 }
                else if ch == "]" || ch == ")" || ch == "}" { depth = max(0, depth - 1) }
                else if ch == ";" && depth == 0 {
                    out.append(cur)
                    cur = ""
                    continue
                }
            }
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func extractSubgraphId(_ rest: String) -> String {
        if let bracket = rest.firstIndex(of: "[") {
            let prefix = rest[..<bracket].trimmingCharacters(in: .whitespaces)
            if !prefix.isEmpty { return prefix }
        }
        return rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func extractSubgraphTitle(_ rest: String, fallback: String) -> String {
        if let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]"), open < close {
            let inner = rest[rest.index(after: open)..<close].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !inner.isEmpty { return inner }
        }
        let cleaned = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        return cleaned.isEmpty ? fallback : cleaned
    }

    /// Parses chained edges like `A[Start] --> B{Check} -->|Yes| C((Done))` and `&` fan-outs `A & B --> C`.
    private static func parseEdgeChain(_ line: String, edgeBudget: Int) -> (nodes: [(id: String, label: String, shape: MermaidDiagram.NodeShape)], edges: [MermaidDiagram.FlowEdge], overflowed: Bool) {
        // Tokenize by edge operators while ignoring text inside quotes or brackets.
        let ops = findEdgeOperators(in: line)
        guard !ops.isEmpty else { return ([], [], false) }

        var segments: [String] = []
        var cursor = line.startIndex
        for op in ops {
            segments.append(String(line[cursor..<op.range.lowerBound]).trimmingCharacters(in: .whitespaces))
            cursor = op.range.upperBound
        }
        segments.append(String(line[cursor...]).trimmingCharacters(in: .whitespaces))

        var allNodes: [(id: String, label: String, shape: MermaidDiagram.NodeShape)] = []
        var segmentNodes: [[(id: String, label: String, shape: MermaidDiagram.NodeShape)]] = []
        for seg in segments {
            let group = splitAmpersand(seg).compactMap(parseNodeToken)
            segmentNodes.append(group)
            allNodes.append(contentsOf: group)
        }

        var edges: [MermaidDiagram.FlowEdge] = []
        for (i, op) in ops.enumerated() {
            guard i + 1 < segmentNodes.count else { break }
            let leftCount = segmentNodes[i].count
            let rightCount = segmentNodes[i + 1].count
            if leftCount > 0 && rightCount > 0 {
                let remaining = edgeBudget - edges.count
                if remaining <= 0 || leftCount > remaining / rightCount {
                    return ([], [], true)
                }
            }
            for lhs in segmentNodes[i] {
                for rhs in segmentNodes[i + 1] {
                    edges.append(MermaidDiagram.FlowEdge(from: lhs.id, to: rhs.id, label: op.label, style: op.style, directed: op.directed))
                }
            }
        }
        return (allNodes, edges, false)
    }

    private struct RawEdgeOp {
        var range: Range<String.Index>
        var style: MermaidDiagram.EdgeStyle
        var directed: Bool
        var label: String
    }

    /// Edge operators, most specific first. Compiled once: a diagram runs every pattern over every statement.
    /// `label` is the capture group holding the edge's words, when the operator carries them.
    private static let edgePatterns: [(regex: NSRegularExpression, style: MermaidDiagram.EdgeStyle, directed: Bool, label: Int?)] = {
        // An edge's words between two halves of an arrow: anything but `>`, `|` and a second hyphen in a row.
        let words = #"((?:[^\-\n>|]|-(?!-))+?)"#
        let table: [(String, MermaidDiagram.EdgeStyle, Bool, Int?)] = [
            (#"-\.+\s*([^.\-\n>|]+?)\s*\.+->"#, .dashed, true, 1),           // A -. text .-> B
            (#"(?<![=<])==\s*([^=\n>|]+?)\s*={2,}>"#, .thick, true, 1),       // A == text ==> B
            // `--(?!-)`: exactly two hyphens open the words, so `A --- B --> C` is two edges, not one named "- B".
            (#"(?<![-<])--(?!-)\s*"# + words + #"\s*-{2,}>"#, .solid, true, 1),    // A -- text --> B
            (#"(?<![-<])--(?!-)\s*"# + words + #"\s*-{3,}(?!>)"#, .open, false, 1), // A -- text --- B
            (#"<?-\.+->\s*\|([^|\n]*)\|"#, .dashed, true, 1),                 // A -.->|text| B
            (#"<?={2,}>\s*\|([^|\n]*)\|"#, .thick, true, 1),                  // A ==>|text| B
            (#"<?-{2,}>\s*\|([^|\n]*)\|"#, .solid, true, 1),                  // A -->|text| B
            (#"-{3,}\s*\|([^|\n]*)\|"#, .open, false, 1),                     // A ---|text| B
            (#"<?-\.+->"#, .dashed, true, nil),
            (#"-\.+-"#, .dashed, false, nil),
            (#"<?={2,}>"#, .thick, true, nil),
            (#"={3,}"#, .thick, false, nil),
            (#"<?-{2,}>"#, .solid, true, nil),                                // -->, --->, <-->
            (#"(?<=\s)[ox]-{2,}[ox](?=\s|$)"#, .open, false, nil),            // A o--o B, A x--x B
            (#"-{2,}[ox](?=\s|$)"#, .open, false, nil),                       // A --o B, A --x B
            (#"-{3,}"#, .open, false, nil),
        ]
        return table.compactMap { pattern, style, directed, label in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, style, directed, label) }
        }
    }()

    private static func findEdgeOperators(in line: String) -> [RawEdgeOp] {
        // Mask bracketed and quoted spans so an operator inside a label (`A["x --> y"]`) isn't taken for an edge.
        // Each masked character becomes as many `_` as it has UTF-16 units (an emoji has two), so a match's place
        // in the masked text is its place in the line.
        var clean = ""
        clean.reserveCapacity(line.utf16.count)
        var inQuote = false
        var depth = 0
        for ch in line {
            var hide = inQuote || depth > 0
            if ch == "\"" { inQuote.toggle(); hide = true }
            else if !inQuote {
                if ch == "[" || ch == "(" || ch == "{" { depth += 1; hide = true }
                else if ch == "]" || ch == ")" || ch == "}" { hide = hide || depth > 0; depth = max(0, depth - 1) }
            }
            if hide { clean.append(String(repeating: "_", count: ch.utf16.count)) } else { clean.append(ch) }
        }

        var found: [RawEdgeOp] = []
        var occupied: [Range<Int>] = []
        let nsLine = line as NSString
        let whole = NSRange(location: 0, length: (clean as NSString).length)
        guard whole.length == nsLine.length else { return [] }

        for (regex, style, directed, labelGroup) in edgePatterns {
            for m in regex.matches(in: clean, range: whole) {
                let r = m.range.location..<(m.range.location + m.range.length)
                if occupied.contains(where: { $0.overlaps(r) }) { continue }
                guard let swiftRange = Range(m.range, in: line) else { continue }
                var label = ""
                if let g = labelGroup, g < m.numberOfRanges, m.range(at: g).location != NSNotFound {
                    label = cleanLabel(nsLine.substring(with: m.range(at: g)))
                }
                occupied.append(r)
                found.append(RawEdgeOp(range: swiftRange, style: style, directed: directed, label: label))
            }
        }
        return found.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func splitAmpersand(_ segment: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var depth = 0
        for ch in segment {
            if ch == "\"" { inQuote.toggle() }
            if !inQuote {
                if ch == "[" || ch == "(" || ch == "{" { depth += 1 }
                else if ch == "]" || ch == ")" || ch == "}" { depth = max(0, depth - 1) }
                else if ch == "&" && depth == 0 {
                    out.append(cur.trimmingCharacters(in: .whitespaces))
                    cur = ""
                    continue
                }
            }
            cur.append(ch)
        }
        let last = cur.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { out.append(last) }
        return out
    }

    private static func parseNodeToken(_ raw: String) -> (id: String, label: String, shape: MermaidDiagram.NodeShape)? {
        // Strip trailing class syntax `:::className`.
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cls = token.range(of: ":::") {
            token = String(token[..<cls.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !token.isEmpty else { return nil }

        let delimiters: [(open: String, close: String, shape: MermaidDiagram.NodeShape)] = [
            ("(((", ")))", .circle),      // double circle
            ("([", "])", .stadium),
            ("[(", ")]", .cylinder),
            ("[[", "]]", .rect),          // subroutine
            ("((", "))", .circle),
            ("{{", "}}", .hexagon),
            ("[/", "/]", .rect),          // parallelogram and trapezoids: drawn as boxes
            ("[\\", "\\]", .rect),
            ("[/", "\\]", .rect),
            ("[\\", "/]", .rect),
            ("[", "]", .rect),
            ("(", ")", .rounded),
            ("{", "}", .diamond),
        ]

        // Find the first shape opener after the identifier prefix.
        var idEnd = token.startIndex
        while idEnd < token.endIndex {
            let ch = token[idEnd]
            if ch == "[" || ch == "(" || ch == "{" { break }
            idEnd = token.index(after: idEnd)
        }
        var rawId = String(token[..<idEnd]).trimmingCharacters(in: .whitespaces)
        var rest = String(token[idEnd...]).trimmingCharacters(in: .whitespaces)
        // The flag shape, `A>Label]`: no opener of its own.
        if rest.isEmpty, token.hasSuffix("]"), let flag = token.firstIndex(of: ">") {
            rawId = String(token[..<flag]).trimmingCharacters(in: .whitespaces)
            rest = "[" + String(token[token.index(after: flag)...])
        }
        guard !rawId.isEmpty else { return nil }
        if rest.isEmpty {
            return (rawId, rawId, .rect)
        }
        for d in delimiters {
            if rest.hasPrefix(d.open) && rest.hasSuffix(d.close) && rest.count >= d.open.count + d.close.count {
                let inner = rest.dropFirst(d.open.count).dropLast(d.close.count)
                let label = cleanLabel(String(inner))
                return (rawId, label.isEmpty ? rawId : label, d.shape)
            }
        }
        return (rawId, rawId, .rect)
    }

    private static let tagPattern = try? NSRegularExpression(pattern: #"</?[a-zA-Z][^<>]{0,40}>"#)
    private static let iconPattern = try? NSRegularExpression(pattern: #"\bfa[bsrl]?:fa-[a-z0-9-]+\s*"#)

    /// A label's words as they'd read: quotes and Markdown-string ticks off, `<br>` as a line break, other tags and
    /// icon names out, the entities a bot writes most (`&amp;`, `#quot;`) as their characters.
    private static func cleanLabel(_ s: String) -> String {
        var out = unquote(s)
        if out.hasPrefix("`") && out.hasSuffix("`") && out.count >= 2 { out = String(out.dropFirst().dropLast()) }
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("#quot;", "\""),
                               ("&nbsp;", " "), ("#amp;", "&"), ("#35;", "#"), ("&#39;", "'"), ("#lt;", "<"), ("#gt;", ">")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        for pattern in [tagPattern, iconPattern] {
            guard let pattern else { continue }
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "")
        }
        out = out.replacingOccurrences(of: "**", with: "")
        return out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unquote(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if (out.hasPrefix("\"") && out.hasSuffix("\"")) || (out.hasPrefix("'") && out.hasSuffix("'")) {
            if out.count >= 2 { out = String(out.dropFirst().dropLast()) }
        }
        for br in ["<br/>", "<br>", "<br />", "<BR/>", "<BR>", "<br >"] { out = out.replacingOccurrences(of: br, with: "\n") }
        return out
    }

    // MARK: Sequence Diagram

    private static let sequenceArrow = try? NSRegularExpression(
        pattern: #"^(.+?)\s*(<<-->>|<<->>|-->>|->>|-->|->|--x|-x|--\)|-\))\s*([+-]?[^:]+?)(?:\s*:\s*(.*))?$"#)
    /// Lines of a sequence diagram that draw no message: blocks, notes, activations, the title.
    private static let sequenceSkipped = ["note", "activate", "deactivate", "autonumber", "end", "loop", "alt", "else", "opt",
                                          "par", "and", "critical", "option", "break", "rect", "box", "title", "create",
                                          "destroy", "link", "links", "properties", "details"]

    private static func parseSequence(_ lines: [String]) -> MermaidDiagram.Kind {
        var participants: [String] = []
        var aliases: [String: String] = [:]
        var messages: [MermaidDiagram.SequenceMessage] = []

        func addParticipant(_ raw: String, display: String? = nil) -> String {
            let id = raw.trimmingCharacters(in: .whitespaces)
            if let display, !display.isEmpty { aliases[id] = display }
            let shown = aliases[id] ?? id
            if !participants.contains(shown) { participants.append(shown) }
            return shown
        }

        let arrowRegex = sequenceArrow

        for line in lines {
            let low = line.lowercased()
            if low.hasPrefix("participant ") || low.hasPrefix("actor ") {
                let keywordLen = low.hasPrefix("participant ") ? 12 : 6
                let rest = String(line.dropFirst(keywordLen)).trimmingCharacters(in: .whitespaces)
                if let asRange = rest.range(of: " as ", options: .caseInsensitive) {
                    let id = String(rest[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let alias = cleanLabel(String(rest[asRange.upperBound...])).replacingOccurrences(of: "\n", with: " ")
                    _ = addParticipant(id, display: alias)
                } else {
                    _ = addParticipant(cleanLabel(rest).replacingOccurrences(of: "\n", with: " "))
                }
                continue
            }
            if sequenceSkipped.contains(where: { low == $0 || low.hasPrefix($0 + " ") }) { continue }
            guard let regex = arrowRegex else { continue }
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let fromRaw = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let arrow = ns.substring(with: m.range(at: 2))
            var toRaw = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            if toRaw.hasPrefix("+") || toRaw.hasPrefix("-") { toRaw.removeFirst() }
            let text = m.range(at: 4).location != NSNotFound ? cleanLabel(ns.substring(with: m.range(at: 4))).replacingOccurrences(of: "\n", with: " ") : ""
            guard !fromRaw.isEmpty, !toRaw.isEmpty else { continue }
            let from = addParticipant(fromRaw)
            let to = addParticipant(toRaw)
            messages.append(MermaidDiagram.SequenceMessage(
                from: from, to: to, text: text,
                dashed: arrow.hasPrefix("--"),
                openArrow: arrow == "->" || arrow == "-->"
            ))
        }
        return .sequence(participants: participants, messages: messages)
    }

    // MARK: State Diagram

    private static let stateTransition = try? NSRegularExpression(pattern: #"^(.+?)\s*-->\s*([^:]+?)(?:\s*:\s*(.*))?$"#)

    private static func parseState(_ lines: [String]) -> MermaidDiagram.Kind {
        var nodes: [MermaidDiagram.FlowNode] = []
        var nodeIndex: [String: Int] = [:]
        var edges: [MermaidDiagram.FlowEdge] = []

        /// `rename`: false for a state merely named in a transition, which must not take the words a
        /// `state "Waiting for you" as Wait` line or a `Wait: …` line gave it.
        func upsert(_ id: String, label: String? = nil, shape: MermaidDiagram.NodeShape? = nil, rename: Bool = true) {
            let finalShape = shape ?? (id == "[*]" ? .circle : .rounded)
            let finalLabel = label ?? (id == "[*]" ? "●" : id)
            if let idx = nodeIndex[id] {
                if rename, let label, !label.isEmpty { nodes[idx].label = label }
            } else {
                nodeIndex[id] = nodes.count
                nodes.append(MermaidDiagram.FlowNode(id: id, label: finalLabel, shape: finalShape, subgraph: nil))
            }
        }

        let transRegex = stateTransition
        var inNote = false
        for line in lines {
            let low = line.lowercased()
            // A note written over several lines runs to `end note`; one with a colon is a single line.
            if inNote { if low == "end note" { inNote = false }; continue }
            if low.hasPrefix("note ") { inNote = !line.contains(":"); continue }
            if low.hasPrefix("direction ") || low == "{" || low == "}" || low == "--" || low.hasPrefix("classdef ")
                || low.hasPrefix("class ") || low.hasPrefix("hide ") || low.hasPrefix("scale ") || low.hasPrefix("title ") { continue }
            if low.hasPrefix("state ") {
                let rest = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if let asRange = rest.range(of: " as ", options: .caseInsensitive) {
                    let lbl = cleanLabel(String(rest[..<asRange.lowerBound]))
                    let id = String(rest[asRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " {"))
                    upsert(id, label: lbl, shape: .rounded)
                }
                continue
            }
            if let regex = transRegex {
                let ns = line as NSString
                if let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let from = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                    let to = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                    let lbl = m.range(at: 3).location != NSNotFound ? cleanLabel(ns.substring(with: m.range(at: 3))).replacingOccurrences(of: "\n", with: " ") : ""
                    let fromId = from == "[*]" ? "__start__" : from
                    let toId = to == "[*]" ? "__end__" : to
                    upsert(fromId, label: from == "[*]" ? "Start" : from, shape: from == "[*]" ? .circle : .rounded, rename: false)
                    upsert(toId, label: to == "[*]" ? "End" : to, shape: to == "[*]" ? .circle : .rounded, rename: false)
                    edges.append(MermaidDiagram.FlowEdge(from: fromId, to: toId, label: lbl, style: .solid, directed: true))
                    continue
                }
            }
            if let colon = line.firstIndex(of: ":") {
                let id = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let desc = cleanLabel(String(line[line.index(after: colon)...]))
                if !id.isEmpty { upsert(id, label: desc.isEmpty ? id : "\(id)\n\(desc)", shape: .rounded) }
            }
        }
        return .state(nodes: nodes, edges: edges)
    }

    // MARK: Pie Chart

    private static let pieSlice = try? NSRegularExpression(pattern: #"^"([^"]+)"\s*:\s*([0-9]{1,18}(?:\.[0-9]{1,9})?)$"#)
    /// A slice bigger than this isn't a count of anything; it also keeps the total a finite number.
    static let maxPieValue = 1e15

    private static func parsePie(_ lines: [String]) -> MermaidDiagram.Kind {
        let header = lines[0]
        let showData = header.lowercased().contains("showdata")
        var title = ""
        if let titleRange = header.range(of: "title ", options: .caseInsensitive) {
            title = cleanLabel(String(header[titleRange.upperBound...])).replacingOccurrences(of: "\n", with: " ")
        }
        var slices: [MermaidDiagram.PieSlice] = []
        let sliceRegex = pieSlice
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("title ") {
                title = cleanLabel(String(line.dropFirst(6))).replacingOccurrences(of: "\n", with: " ")
                continue
            }
            guard let regex = sliceRegex else { continue }
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let val = Double(ns.substring(with: m.range(at: 2))), val.isFinite, val > 0, val <= maxPieValue else { continue }
            slices.append(MermaidDiagram.PieSlice(label: cleanLabel(ns.substring(with: m.range(at: 1))).replacingOccurrences(of: "\n", with: " "), value: val))
        }
        return .pie(title: title, showData: showData, slices: slices)
    }
}
