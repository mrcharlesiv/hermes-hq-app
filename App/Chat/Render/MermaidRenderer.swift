// [mermaid] Native CoreGraphics Mermaid diagram layout, Retina rendering, and PNG export.
// Runs purely offline and thread-safely (so chat height measurement stays fast at 120 Hz, and Copy Image produces
// crisp Retina PNGs on both iPhone/iPad and Mac Catalyst).

import UIKit
import os

nonisolated enum MermaidRenderer {
    struct Palette: Sendable {
        var background: UIColor
        var nodeFill: UIColor
        var nodeStroke: UIColor
        var subgraphFill: UIColor
        var subgraphStroke: UIColor
        var edgeColor: UIColor
        var textColor: UIColor
        var secondaryText: UIColor
        var accent: UIColor
        var labelPillFill: UIColor
        /// The picture is see-through (the card shows behind it): an arrow's words clear the line under them rather
        /// than paint a patch over it, since the card's own colour may be see-through too. Copy Image paints.
        var labelKnockout = true
        var sliceColors: [UIColor]
    }

    static func palette(for traits: UITraitCollection) -> Palette {
        let dark = traits.userInterfaceStyle == .dark
        let bg = ChatPalette.codeFill.resolvedColor(with: traits)
        let card = (dark ? UIColor(white: 0.17, alpha: 1) : UIColor.white).resolvedColor(with: traits)
        let stroke = ChatPalette.separator.resolvedColor(with: traits)
        let accent = ChatPalette.tint.resolvedColor(with: traits)
        let label = ChatPalette.label.resolvedColor(with: traits)
        let label2 = ChatPalette.label2.resolvedColor(with: traits)
        let sgFill = accent.withAlphaComponent(dark ? 0.10 : 0.06)
        let sgStroke = accent.withAlphaComponent(dark ? 0.35 : 0.28)
        let slices: [UIColor] = [
            accent,
            UIColor.systemTeal.resolvedColor(with: traits),
            UIColor.systemOrange.resolvedColor(with: traits),
            UIColor.systemPurple.resolvedColor(with: traits),
            UIColor.systemGreen.resolvedColor(with: traits),
            UIColor.systemPink.resolvedColor(with: traits),
            UIColor.systemIndigo.resolvedColor(with: traits),
        ]
        return Palette(
            background: bg,
            nodeFill: card,
            nodeStroke: stroke,
            subgraphFill: sgFill,
            subgraphStroke: sgStroke,
            edgeColor: label2,
            textColor: label,
            secondaryText: label2,
            accent: accent,
            labelPillFill: bg,
            sliceColors: slices
        )
    }

    /// Natural aspect-preserving size of the rendered diagram inside an inline chat bubble of width `maxWidth`.
    static func inlineSize(for diagram: MermaidDiagram, maxWidth: CGFloat) -> CGSize {
        let natural = naturalSize(for: diagram)
        let targetW = max(180, maxWidth)
        let scale = min(1.0, targetW / max(1, natural.width))
        let h = min(360, max(120, ceil(natural.height * scale)))
        return CGSize(width: targetW, height: h)
    }

    /// Full natural canvas size for the expanded sheet and crisp PNG export.
    static func naturalSize(for diagram: MermaidDiagram) -> CGSize {
        switch diagram.kind {
        case .flowchart(let dir, let nodes, let edges, let subgraphs):
            return flowLayout(direction: dir, nodes: nodes, edges: edges, subgraphs: subgraphs).size
        case .state(let nodes, let edges):
            return flowLayout(direction: .topDown, nodes: nodes, edges: edges, subgraphs: []).size
        case .sequence(let participants, let messages):
            return sequenceLayout(participants: participants, messages: messages).size
        case .pie(let title, _, let slices):
            let legendRows = max(1, slices.count)
            let h = (title.isEmpty ? 28 : 54) + max(200, CGFloat(legendRows) * 26 + 32)
            return CGSize(width: 460, height: h)
        case .generic(_, let lines):
            let h = 52 + CGFloat(max(1, lines.count)) * 22 + 16
            return CGSize(width: 420, height: h)
        }
    }

    private struct CacheKey: Hashable {
        var source: String
        var width: Int
        var height: Int
        var dark: Bool
        var theme: Int
    }

    private static let cacheLock = OSAllocatedUnfairLock(initialState: [CacheKey: UIImage]())

    /// The most pixels one diagram picture may hold (about 64 MB of bitmap): a very wide or long diagram is drawn
    /// at a lower scale rather than failing to allocate.
    static let maxPixels: CGFloat = 16_000_000

    /// `scale`, lowered until a `size` picture fits the pixel budget (never below 0.25).
    static func budgetedScale(_ scale: CGFloat, for size: CGSize) -> CGFloat {
        let area = max(1, size.width) * max(1, size.height)
        return max(0.25, min(scale, (maxPixels / area).squareRoot()))
    }

    static func renderImage(diagram: MermaidDiagram, size: CGSize, traits: UITraitCollection, scale: CGFloat = 2) -> UIImage {
        let w = min(12_000, max(120, Int(ceil(size.width))))
        let h = min(12_000, max(80, Int(ceil(size.height))))
        let key = CacheKey(source: diagram.source, width: w, height: h,
                           dark: traits.userInterfaceStyle == .dark, theme: traits[ThemeGenerationTrait.self])
        if let hit = cacheLock.withLock({ $0[key] }) { return hit }
        let pal = palette(for: traits)
        let format = UIGraphicsImageRendererFormat()
        format.scale = budgetedScale(max(1, scale), for: CGSize(width: w, height: h))
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        let image = renderer.image { ctx in
            draw(diagram: diagram, in: CGRect(x: 0, y: 0, width: w, height: h), palette: pal, cg: ctx.cgContext)
        }
        cacheLock.withLock { map in
            if map.count > 64 { map.removeAll(keepingCapacity: true) }
            map[key] = image
        }
        return image
    }

    /// High-resolution PNG data for Copy Image and Share.
    static func pngData(for diagram: MermaidDiagram, traits: UITraitCollection, scale: CGFloat = 3) -> Data? {
        let natural = naturalSize(for: diagram)
        var pal = palette(for: traits)
        // A solid picture: a see-through card colour is laid on the page colour first, as the chat shows it.
        pal.background = solid(pal.background, over: ChatPalette.page.resolvedColor(with: traits))
        pal.labelPillFill = pal.background
        pal.labelKnockout = false
        let format = UIGraphicsImageRendererFormat()
        format.scale = budgetedScale(max(2, scale), for: natural)
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: natural, format: format)
        let img = renderer.image { ctx in
            pal.background.setFill()
            ctx.fill(CGRect(origin: .zero, size: natural))
            draw(diagram: diagram, in: CGRect(origin: .zero, size: natural), palette: pal, cg: ctx.cgContext)
        }
        return img.pngData()
    }

    /// `color` laid over `base`, with no see-through left (an exported picture has nothing behind it).
    static func solid(_ color: UIColor, over base: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var br: CGFloat = 1, bg: CGFloat = 1, bb: CGFloat = 1, ba: CGFloat = 1
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return color.withAlphaComponent(1) }
        guard a < 1 else { return color }
        if !base.getRed(&br, green: &bg, blue: &bb, alpha: &ba) { br = 1; bg = 1; bb = 1 }
        return UIColor(red: r * a + br * (1 - a), green: g * a + bg * (1 - a), blue: b * a + bb * (1 - a), alpha: 1)
    }

    // MARK: Drawing dispatch

    private static func draw(diagram: MermaidDiagram, in rect: CGRect, palette: Palette, cg: CGContext) {
        let natural = naturalSize(for: diagram)
        let fit = min(rect.width / max(1, natural.width), rect.height / max(1, natural.height))
        let drawnW = natural.width * fit
        let drawnH = natural.height * fit
        let ox = rect.minX + (rect.width - drawnW) / 2
        let oy = rect.minY + (rect.height - drawnH) / 2

        cg.saveGState()
        cg.translateBy(x: ox, y: oy)
        cg.scaleBy(x: fit, y: fit)
        switch diagram.kind {
        case .flowchart(let dir, let nodes, let edges, let subgraphs):
            drawFlowchart(flowLayout(direction: dir, nodes: nodes, edges: edges, subgraphs: subgraphs),
                          edges: edges, palette: palette, cg: cg)
        case .state(let nodes, let edges):
            drawFlowchart(flowLayout(direction: .topDown, nodes: nodes, edges: edges, subgraphs: []),
                          edges: edges, palette: palette, cg: cg)
        case .sequence(let participants, let messages):
            drawSequence(sequenceLayout(participants: participants, messages: messages), palette: palette, cg: cg)
        case .pie(let title, let showData, let slices):
            drawPie(title: title, showData: showData, slices: slices, size: natural, palette: palette, cg: cg)
        case .generic(let title, let lines):
            drawGeneric(title: title, lines: lines, size: natural, palette: palette, cg: cg)
        }
        cg.restoreGState()
    }

    // MARK: Flowchart / State layout & draw

    private struct FlowLayout {
        var size: CGSize
        var direction: MermaidDiagram.Direction
        var nodeFrames: [String: CGRect]
        var nodes: [MermaidDiagram.FlowNode]
        var subgraphBoxes: [(title: String, frame: CGRect)]
    }

    private static func flowLayout(direction: MermaidDiagram.Direction, nodes: [MermaidDiagram.FlowNode],
                                   edges: [MermaidDiagram.FlowEdge], subgraphs: [MermaidDiagram.FlowSubgraph]) -> FlowLayout {
        guard !nodes.isEmpty else {
            return FlowLayout(size: CGSize(width: 240, height: 120), direction: direction, nodeFrames: [:], nodes: [], subgraphBoxes: [])
        }
        var rank = flowRanks(nodes: nodes.map(\.id), edges: edges.map { ($0.from, $0.to) })

        var maxRank = rank.values.max() ?? 0
        if direction == .bottomUp || direction == .rightLeft {
            for (k, v) in rank { rank[k] = maxRank - v }
        }
        maxRank = rank.values.max() ?? 0

        var layers: [[MermaidDiagram.FlowNode]] = Array(repeating: [], count: maxRank + 1)
        for n in nodes {
            let r = min(maxRank, max(0, rank[n.id] ?? 0))
            layers[r].append(n)
        }
        layers = orderedLayers(layers, edges: edges)

        let horizontal = direction == .leftRight || direction == .rightLeft
        // Arrows that can't run straight to the next rank (a jump over ranks, a loop back, a node to itself) arch
        // around the side: the margin there is as wide as the arches drawn in it.
        let arched = edges.filter { e in
            let r1 = rank[e.from] ?? 0, r2 = rank[e.to] ?? 0
            return abs(r2 - r1) != 1 || (direction == .bottomUp || direction == .rightLeft ? r2 > r1 : r2 < r1)
        }.count
        let hasSkipEdge = arched > 0
        let archRoom: CGFloat = 58 + CGFloat(min(arched, archTiers) - 1) * archStep
        let pad: CGFloat = 24
        let rankGap: CGFloat = horizontal ? 50 : 44
        let peerGap: CGFloat = 22
        let font = HQFont.face(ofSize: 13.5, weight: .medium)

        func nodeSize(_ n: MermaidDiagram.FlowNode) -> CGSize {
            if n.shape == .circle && (n.label == "Start" || n.label == "End" || n.label == "●") {
                return CGSize(width: 44, height: 44)
            }
            // A long label wraps inside the widest box and the box grows down to hold every line.
            let lines = n.label.components(separatedBy: "\n")
            let maxLineW = lines.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }.max() ?? 40
            let sidePad: CGFloat = n.shape == .diamond ? 42 : 28
            let w = min(maxNodeWidth, max(76, maxLineW + sidePad))
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            let textH = ceil((n.label as NSString).boundingRect(
                with: CGSize(width: w - labelInset * 2 - (n.shape == .diamond ? 20 : 0), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: para], context: nil).height)
            let h = min(maxNodeHeight, max(38, textH + (n.shape == .diamond ? 30 : 18)))
            return CGSize(width: w, height: h)
        }

        var sizes: [String: CGSize] = [:]
        for n in nodes { sizes[n.id] = nodeSize(n) }

        // A sideways chart's arrow carries its words on the line: the gap between those two ranks is wide enough
        // for the words and a piece of the line on each side of them.
        var gapAfter = Array(repeating: rankGap, count: layers.count)
        if horizontal {
            let edgeFont = HQFont.face(ofSize: 11, weight: .medium)
            for e in edges where !e.label.isEmpty {
                guard let a = rank[e.from], let b = rank[e.to], abs(a - b) == 1, gapAfter.indices.contains(min(a, b)) else { continue }
                let words = min(180, ceil((e.label as NSString).size(withAttributes: [.font: edgeFont]).width))
                gapAfter[min(a, b)] = max(gapAfter[min(a, b)], words + 10 + 36)
            }
        }

        var frames: [String: CGRect] = [:]
        if horizontal {
            var x = pad
            var lastGap = rankGap
            let topPad: CGFloat = hasSkipEdge ? archRoom : pad
            let bottomPad: CGFloat = pad
            let colHeights: [CGFloat] = layers.map { layer in
                layer.reduce(0) { $0 + (sizes[$1.id]?.height ?? 40) } + CGFloat(max(0, layer.count - 1)) * peerGap
            }
            let contentH = colHeights.max() ?? 60
            let totalH = contentH + topPad + bottomPad
            for (li, layer) in layers.enumerated() where !layer.isEmpty {
                let colW = layer.map { sizes[$0.id]?.width ?? 90 }.max() ?? 90
                var y = topPad + (contentH - colHeights[li]) / 2
                for n in layer {
                    let s = sizes[n.id] ?? CGSize(width: 90, height: 40)
                    frames[n.id] = CGRect(x: x + (colW - s.width) / 2, y: y, width: s.width, height: s.height)
                    y += s.height + peerGap
                }
                lastGap = gapAfter[li]
                x += colW + lastGap
            }
            let totalW = max(240, x - lastGap + pad)
            let sgBoxes = computeSubgraphs(subgraphs: subgraphs, nodes: nodes, frames: frames)
            return FlowLayout(size: CGSize(width: totalW, height: max(140, totalH)), direction: direction,
                              nodeFrames: frames, nodes: nodes, subgraphBoxes: sgBoxes)
        } else {
            var y = pad
            let sidePad: CGFloat = hasSkipEdge ? archRoom : pad
            let rowWidths: [CGFloat] = layers.map { layer in
                layer.reduce(0) { $0 + (sizes[$1.id]?.width ?? 90) } + CGFloat(max(0, layer.count - 1)) * peerGap
            }
            let contentW = rowWidths.max() ?? 200
            let totalW = max(260, contentW + pad + sidePad)
            for (li, layer) in layers.enumerated() where !layer.isEmpty {
                let rowH = layer.map { sizes[$0.id]?.height ?? 40 }.max() ?? 40
                var x = pad + (contentW - rowWidths[li]) / 2
                for n in layer {
                    let s = sizes[n.id] ?? CGSize(width: 90, height: 40)
                    frames[n.id] = CGRect(x: x, y: y + (rowH - s.height) / 2, width: s.width, height: s.height)
                    x += s.width + peerGap
                }
                y += rowH + rankGap
            }
            let totalH = max(140, y - rankGap + pad)
            let sgBoxes = computeSubgraphs(subgraphs: subgraphs, nodes: nodes, frames: frames)
            return FlowLayout(size: CGSize(width: totalW, height: totalH), direction: direction,
                              nodeFrames: frames, nodes: nodes, subgraphBoxes: sgBoxes)
        }
    }

    static let maxNodeWidth: CGFloat = 220, maxNodeHeight: CGFloat = 150, labelInset: CGFloat = 8

    /// Each node's rank: how many steps it sits from the start. An arrow that points back to an earlier step (a
    /// retry, a loop) doesn't count, so a loop leaves its nodes in the order they were written instead of pushing
    /// the loop's top below its own bottom. Linear in nodes and edges.
    static func flowRanks(nodes: [String], edges: [(from: String, to: String)]) -> [String: Int] {
        var known = Set(nodes)
        var order = nodes
        for e in edges { for id in [e.from, e.to] where known.insert(id).inserted { order.append(id) } }
        var outgoing: [String: [String]] = [:]
        var incoming: [String: Int] = [:]
        for e in edges where e.from != e.to {
            outgoing[e.from, default: []].append(e.to)
            incoming[e.to, default: 0] += 1
        }
        // Depth-first from the nodes nothing points at (then any left over, for a diagram that is one big loop):
        // an edge into a node still on the walk's own path points backwards.
        var state: [String: UInt8] = [:]   // 1 on the path, 2 done
        var back = Set<[String]>()
        func walk(from root: String) {
            guard state[root] == nil else { return }
            var stack: [(id: String, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                let outs = outgoing[top.id] ?? []
                if top.next < outs.count {
                    stack[stack.count - 1].next += 1
                    let to = outs[top.next]
                    switch state[to] {
                    case nil: state[to] = 1; stack.append((to, 0))
                    case 1: back.insert([top.id, to])
                    default: break
                    }
                } else {
                    state[top.id] = 2
                    stack.removeLast()
                }
            }
        }
        for id in order where (incoming[id] ?? 0) == 0 { walk(from: id) }
        for id in order { walk(from: id) }
        // Longest path over what is left, which has no loops.
        var forward: [String: [String]] = [:]
        var waiting: [String: Int] = [:]
        for (from, outs) in outgoing {
            for to in outs where !back.contains([from, to]) {
                forward[from, default: []].append(to)
                waiting[to, default: 0] += 1
            }
        }
        var rank: [String: Int] = [:]
        var queue = order.filter { (waiting[$0] ?? 0) == 0 }
        for id in queue { rank[id] = 0 }
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            for to in forward[cur] ?? [] {
                rank[to] = max(rank[to] ?? 0, (rank[cur] ?? 0) + 1)
                waiting[to, default: 1] -= 1
                if waiting[to] == 0 { queue.append(to) }
            }
        }
        for id in order where rank[id] == nil { rank[id] = 0 }
        return rank
    }

    /// Each rank's nodes in an order that keeps arrows short: a node sits under the middle of the nodes pointing at
    /// it, and a subgraph's nodes stay together so its box holds them and nothing else.
    private static func orderedLayers(_ layers: [[MermaidDiagram.FlowNode]], edges: [MermaidDiagram.FlowEdge]) -> [[MermaidDiagram.FlowNode]] {
        guard layers.count > 1, layers.contains(where: { $0.count > 1 }) else { return layers }
        var neighbours: [String: [String]] = [:]
        for e in edges where e.from != e.to {
            neighbours[e.from, default: []].append(e.to)
            neighbours[e.to, default: []].append(e.from)
        }
        var out = layers
        var slot: [String: Double] = [:]
        func place(_ layer: [MermaidDiagram.FlowNode]) {
            for (i, n) in layer.enumerated() { slot[n.id] = layer.count == 1 ? 0.5 : Double(i) / Double(layer.count - 1) }
        }
        out.forEach(place)
        func sort(_ index: Int, towards other: Int) {
            let layer = out[index]
            guard layer.count > 1, out.indices.contains(other) else { return }
            let fixed = Set(out[other].map(\.id))
            var written: [String: Int] = [:]
            for (i, n) in layer.enumerated() { written[n.id] = i }
            func pull(_ n: MermaidDiagram.FlowNode) -> Double {
                let near = (neighbours[n.id] ?? []).filter(fixed.contains).compactMap { slot[$0] }
                return near.isEmpty ? (slot[n.id] ?? 0.5) : near.reduce(0, +) / Double(near.count)
            }
            // Groups: a subgraph's nodes as one, every other node by itself.
            var groups: [String: [MermaidDiagram.FlowNode]] = [:]
            var groupOrder: [String] = []
            for n in layer {
                let key = n.subgraph.map { "sg|" + $0 } ?? "n|" + n.id
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(n)
            }
            func middle(_ key: String) -> Double {
                let members = groups[key] ?? []
                return members.map(pull).reduce(0, +) / Double(max(1, members.count))
            }
            let firstSeen = Dictionary(uniqueKeysWithValues: groupOrder.enumerated().map { ($1, $0) })
            let sortedGroups = groupOrder.sorted { a, b in
                let ma = middle(a), mb = middle(b)
                return ma != mb ? ma < mb : (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
            }
            out[index] = sortedGroups.flatMap { key in
                (groups[key] ?? []).sorted { a, b in
                    let pa = pull(a), pb = pull(b)
                    return pa != pb ? pa < pb : (written[a.id] ?? 0) < (written[b.id] ?? 0)
                }
            }
            place(out[index])
        }
        for _ in 0..<2 {
            for i in out.indices.dropFirst() { sort(i, towards: i - 1) }
            for i in out.indices.dropLast().reversed() { sort(i, towards: i + 1) }
        }
        return out
    }

    private static func computeSubgraphs(subgraphs: [MermaidDiagram.FlowSubgraph],
                                         nodes: [MermaidDiagram.FlowNode],
                                         frames: [String: CGRect]) -> [(title: String, frame: CGRect)] {
        var out: [(String, CGRect)] = []
        for sg in subgraphs {
            let rects = nodes.filter { $0.subgraph == sg.id }.compactMap { frames[$0.id] }
            guard var union = rects.first else { continue }
            for r in rects.dropFirst() { union = union.union(r) }
            out.append((sg.title, union.insetBy(dx: -12, dy: -18).offsetBy(dx: 0, dy: -4)))
        }
        return out
    }

    private static func drawFlowchart(_ layout: FlowLayout, edges: [MermaidDiagram.FlowEdge], palette: Palette, cg: CGContext) {
        let labelFont = HQFont.face(ofSize: 13.5, weight: .medium)
        let edgeFont = HQFont.face(ofSize: 11, weight: .medium)
        let sgFont = HQFont.face(ofSize: 11, weight: .semibold)

        // Subgraphs behind edges and nodes.
        for sg in layout.subgraphBoxes {
            let path = UIBezierPath(roundedRect: sg.frame, cornerRadius: 12)
            palette.subgraphFill.setFill()
            path.fill()
            palette.subgraphStroke.setStroke()
            path.lineWidth = 1.25
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
            let titleAttrs: [NSAttributedString.Key: Any] = [.font: sgFont, .foregroundColor: palette.accent]
            (sg.title as NSString).draw(at: CGPoint(x: sg.frame.minX + 10, y: sg.frame.minY + 4), withAttributes: titleAttrs)
        }

        // Edges
        let horizontal = layout.direction == .leftRight || layout.direction == .rightLeft
        var bypassIndex = 0
        var drawnPairs = Set<[String]>()
        for edge in edges {
            guard let fromRect = layout.nodeFrames[edge.from], let toRect = layout.nodeFrames[edge.to] else { continue }
            if edge.from == edge.to {
                drawSelfLoop(edge, at: fromRect, horizontal: horizontal, palette: palette, edgeFont: edgeFont, cg: cg)
                continue
            }
            var (start, end) = edgeEndpoints(from: fromRect, to: toRect, horizontal: horizontal)
            // An arrow against the flow (a retry, a loop), or the second of a there-and-back pair, takes the arch
            // too: drawn straight it would lie on top of the arrow going the other way, words and all.
            let against: Bool = switch layout.direction {
            case .topDown: toRect.midY < fromRect.midY
            case .bottomUp: toRect.midY > fromRect.midY
            case .leftRight: toRect.midX < fromRect.midX
            case .rightLeft: toRect.midX > fromRect.midX
            }
            let returning = drawnPairs.contains([edge.to, edge.from])
            drawnPairs.insert([edge.from, edge.to])

            // Detect skip-rank / back edges that would pass through intervening nodes, and arch cleanly around them.
            let lineBox = CGRect(
                x: min(start.x, end.x) - 2,
                y: min(start.y, end.y) - 2,
                width: abs(end.x - start.x) + 4,
                height: abs(end.y - start.y) + 4
            )
            var obstacle: CGRect?
            for (otherID, rect) in layout.nodeFrames where otherID != edge.from && otherID != edge.to {
                if rect.insetBy(dx: -4, dy: -4).intersects(lineBox) {
                    obstacle = obstacle?.union(rect) ?? rect
                }
            }

            cg.saveGState()
            palette.edgeColor.setStroke()
            cg.setLineWidth(edge.style == .thick ? 2.5 : 1.5)
            if edge.style == .dashed { cg.setLineDash(phase: 0, lengths: [5, 4]) }
            let labelPoint: CGPoint
            let tangentFrom: CGPoint
            if against || returning, obstacle == nil { obstacle = fromRect.union(toRect) }
            if let obs = obstacle {
                let tier = CGFloat(bypassIndex % archTiers) * archStep
                bypassIndex += 1
                if horizontal {
                    start = CGPoint(x: fromRect.midX, y: fromRect.minY)
                    end = CGPoint(x: toRect.midX, y: toRect.minY)
                    let archY = min(start.y, end.y, obs.minY) - 42 - tier
                    let ctrl = CGPoint(x: (start.x + end.x) / 2, y: archY)
                    cg.move(to: start)
                    cg.addQuadCurve(to: end, control: ctrl)
                    labelPoint = CGPoint(x: 0.25 * start.x + 0.5 * ctrl.x + 0.25 * end.x,
                                         y: 0.25 * start.y + 0.5 * ctrl.y + 0.25 * end.y)
                    tangentFrom = ctrl
                } else {
                    start = CGPoint(x: fromRect.maxX, y: fromRect.midY)
                    end = CGPoint(x: toRect.maxX, y: toRect.midY)
                    let archX = max(start.x, end.x, obs.maxX) + 44 + tier
                    let ctrl = CGPoint(x: archX, y: (start.y + end.y) / 2)
                    cg.move(to: start)
                    cg.addQuadCurve(to: end, control: ctrl)
                    labelPoint = CGPoint(x: 0.25 * start.x + 0.5 * ctrl.x + 0.25 * end.x,
                                         y: 0.25 * start.y + 0.5 * ctrl.y + 0.25 * end.y)
                    tangentFrom = ctrl
                }
            } else {
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                cg.move(to: start)
                if horizontal {
                    cg.addCurve(to: end, control1: CGPoint(x: mid.x, y: start.y), control2: CGPoint(x: mid.x, y: end.y))
                    tangentFrom = CGPoint(x: mid.x, y: end.y)
                } else {
                    cg.addCurve(to: end, control1: CGPoint(x: start.x, y: mid.y), control2: CGPoint(x: end.x, y: mid.y))
                    tangentFrom = CGPoint(x: end.x, y: mid.y)
                }
                labelPoint = mid
            }
            cg.strokePath()
            cg.restoreGState()

            if edge.directed {
                drawArrowHead(at: end, from: tangentFrom == end ? start : tangentFrom, color: palette.edgeColor, cg: cg)
            }
            drawEdgeLabel(edge.label, at: labelPoint, font: edgeFont, palette: palette)
        }

        // Nodes
        for node in layout.nodes {
            guard let frame = layout.nodeFrames[node.id] else { continue }
            let path = shapePath(node.shape, in: frame)
            palette.nodeFill.setFill()
            path.fill()
            (node.shape == .diamond || node.shape == .circle ? palette.accent : palette.nodeStroke).setStroke()
            path.lineWidth = node.shape == .diamond || node.shape == .circle ? 1.6 : 1.25
            path.stroke()

            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: palette.textColor, .paragraphStyle: para]
            let inset = frame.insetBy(dx: labelInset + (node.shape == .diamond ? 10 : 0), dy: 4)
            let measured = (node.label as NSString).boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude),
                                                                 options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                                 attributes: attrs, context: nil)
            let textH = min(ceil(measured.height), inset.height)
            let textRect = CGRect(x: inset.minX, y: frame.midY - textH / 2, width: inset.width, height: textH)
            // A label past the tallest box is cut at the box, never drawn over its neighbours.
            (node.label as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
                                          attributes: attrs, context: nil)
        }
    }

    /// How many arches sit side by side before they share a lane again, and the gap between lanes.
    static let archTiers = 6
    static let archStep: CGFloat = 14

    /// A node's arrow to itself: a small loop off its side (its top, in a sideways chart), with the words beside it.
    private static func drawSelfLoop(_ edge: MermaidDiagram.FlowEdge, at r: CGRect, horizontal: Bool, palette: Palette,
                                     edgeFont: UIFont, cg: CGContext) {
        let start: CGPoint, end: CGPoint, c1: CGPoint, c2: CGPoint, labelPoint: CGPoint
        if horizontal {
            start = CGPoint(x: r.midX - 10, y: r.minY); end = CGPoint(x: r.midX + 10, y: r.minY)
            c1 = CGPoint(x: r.midX - 28, y: r.minY - 34); c2 = CGPoint(x: r.midX + 28, y: r.minY - 34)
            labelPoint = CGPoint(x: r.midX, y: r.minY - 32)
        } else {
            start = CGPoint(x: r.maxX, y: r.midY - 8); end = CGPoint(x: r.maxX, y: r.midY + 8)
            c1 = CGPoint(x: r.maxX + 34, y: r.midY - 26); c2 = CGPoint(x: r.maxX + 34, y: r.midY + 26)
            labelPoint = CGPoint(x: r.maxX + 30, y: r.midY)
        }
        cg.saveGState()
        palette.edgeColor.setStroke()
        cg.setLineWidth(edge.style == .thick ? 2.5 : 1.5)
        if edge.style == .dashed { cg.setLineDash(phase: 0, lengths: [5, 4]) }
        cg.move(to: start)
        cg.addCurve(to: end, control1: c1, control2: c2)
        cg.strokePath()
        cg.restoreGState()
        if edge.directed { drawArrowHead(at: end, from: c2, color: palette.edgeColor, cg: cg) }
        drawEdgeLabel(edge.label, at: labelPoint, font: edgeFont, palette: palette)
    }

    private static func drawEdgeLabel(_ label: String, at point: CGPoint, font: UIFont, palette: Palette) {
        guard !label.isEmpty else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: palette.secondaryText, .paragraphStyle: para]
        let natural = (label as NSString).size(withAttributes: attrs)
        let sz = CGSize(width: min(ceil(natural.width), 180), height: ceil(natural.height))
        let pill = CGRect(x: point.x - sz.width / 2 - 5, y: point.y - sz.height / 2 - 2, width: sz.width + 10, height: sz.height + 4)
        let patch = UIBezierPath(roundedRect: pill, cornerRadius: 5)
        if palette.labelKnockout {
            patch.fill(with: .clear, alpha: 1)      // the line gives way to the words; the card shows through
        } else {
            palette.labelPillFill.setFill()
            patch.fill()
        }
        (label as NSString).draw(in: CGRect(x: pill.minX + 5, y: pill.minY + 2, width: sz.width, height: sz.height), withAttributes: attrs)
    }

    private static func edgeEndpoints(from a: CGRect, to b: CGRect, horizontal: Bool) -> (CGPoint, CGPoint) {
        if horizontal {
            if b.midX >= a.midX {
                return (CGPoint(x: a.maxX, y: a.midY), CGPoint(x: b.minX, y: b.midY))
            } else {
                return (CGPoint(x: a.minX, y: a.midY), CGPoint(x: b.maxX, y: b.midY))
            }
        } else {
            if b.midY >= a.midY {
                return (CGPoint(x: a.midX, y: a.maxY), CGPoint(x: b.midX, y: b.minY))
            } else {
                return (CGPoint(x: a.midX, y: a.minY), CGPoint(x: b.midX, y: b.maxY))
            }
        }
    }

    private static func shapePath(_ shape: MermaidDiagram.NodeShape, in r: CGRect) -> UIBezierPath {
        switch shape {
        case .rect:
            return UIBezierPath(roundedRect: r, cornerRadius: 6)
        case .rounded:
            return UIBezierPath(roundedRect: r, cornerRadius: 12)
        case .stadium:
            return UIBezierPath(roundedRect: r, cornerRadius: r.height / 2)
        case .circle:
            return UIBezierPath(ovalIn: r)
        case .diamond:
            let p = UIBezierPath()
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.close()
            return p
        case .hexagon:
            let dx = min(14, r.width * 0.16)
            let p = UIBezierPath()
            p.move(to: CGPoint(x: r.minX + dx, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - dx, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - dx, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + dx, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
            p.close()
            return p
        case .cylinder:
            return UIBezierPath(roundedRect: r, cornerRadius: min(16, r.height * 0.35))
        }
    }

    private static func drawArrowHead(at tip: CGPoint, from tail: CGPoint, color: UIColor, cg: CGContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let len: CGFloat = 8
        let spread: CGFloat = .pi / 6
        let p1 = CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread))
        let p2 = CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread))
        cg.saveGState()
        color.setFill()
        cg.move(to: tip)
        cg.addLine(to: p1)
        cg.addLine(to: p2)
        cg.closePath()
        cg.fillPath()
        cg.restoreGState()
    }

    // MARK: Sequence Diagram

    private struct SequenceLayout {
        var size: CGSize
        var participants: [String]
        var xForParticipant: [String: CGFloat]
        var messages: [MermaidDiagram.SequenceMessage]
        var headerHeight: CGFloat
        var rowHeight: CGFloat
        var columnSpacing: CGFloat
    }

    private static func sequenceLayout(participants: [String], messages: [MermaidDiagram.SequenceMessage]) -> SequenceLayout {
        let pad: CGFloat = 24
        let headerH: CGFloat = 34
        let rowH: CGFloat = 42
        // Columns stand far enough apart for the longest words between two neighbours, up to a point; past it the
        // words are cut with an ellipsis rather than run over the next lifeline.
        let msgFont = HQFont.face(ofSize: 11, weight: .medium)
        var place: [String: Int] = [:]
        for (i, p) in participants.enumerated() { place[p] = i }
        var widest: CGFloat = 0
        for m in messages where !m.text.isEmpty {
            guard let a = place[m.from], let b = place[m.to] else { continue }
            let span = CGFloat(max(1, abs(a - b)))
            widest = max(widest, ceil((m.text as NSString).size(withAttributes: [.font: msgFont]).width) / span)
        }
        let colSpacing = min(250, max(136, widest + 28))
        var map: [String: CGFloat] = [:]
        for (i, p) in participants.enumerated() {
            map[p] = pad + colSpacing / 2 + CGFloat(i) * colSpacing
        }
        let w = max(280, pad * 2 + CGFloat(max(1, participants.count)) * colSpacing)
        let h = pad * 2 + headerH + 20 + CGFloat(max(1, messages.count)) * rowH + 16
        return SequenceLayout(size: CGSize(width: w, height: h), participants: participants,
                              xForParticipant: map, messages: messages, headerHeight: headerH, rowHeight: rowH,
                              columnSpacing: colSpacing)
    }

    private static func drawSequence(_ layout: SequenceLayout, palette: Palette, cg: CGContext) {
        let pad: CGFloat = 24
        let headFont = HQFont.face(ofSize: 12, weight: .semibold)
        let msgFont = HQFont.face(ofSize: 11, weight: .medium)
        let topY = pad
        let bottomY = layout.size.height - pad

        for name in layout.participants {
            guard let cx = layout.xForParticipant[name] else { continue }
            // Lifeline
            cg.saveGState()
            palette.nodeStroke.setStroke()
            cg.setLineWidth(1.25)
            cg.setLineDash(phase: 0, lengths: [4, 4])
            cg.move(to: CGPoint(x: cx, y: topY + layout.headerHeight))
            cg.addLine(to: CGPoint(x: cx, y: bottomY))
            cg.strokePath()
            cg.restoreGState()

            // Header box
            let boxW = min(layout.columnSpacing - 14, max(108, ceil((name as NSString).size(withAttributes: [.font: headFont]).width) + 20))
            let box = CGRect(x: cx - boxW / 2, y: topY, width: boxW, height: layout.headerHeight)
            let path = UIBezierPath(roundedRect: box, cornerRadius: 8)
            palette.nodeFill.setFill()
            path.fill()
            palette.accent.setStroke()
            path.lineWidth = 1.4
            path.stroke()
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: headFont, .foregroundColor: palette.textColor, .paragraphStyle: para]
            (name as NSString).draw(in: box.insetBy(dx: 6, dy: 8), withAttributes: attrs)
        }

        for (i, msg) in layout.messages.enumerated() {
            guard let x1 = layout.xForParticipant[msg.from], let x2 = layout.xForParticipant[msg.to] else { continue }
            let y = topY + layout.headerHeight + 28 + CGFloat(i) * layout.rowHeight
            cg.saveGState()
            palette.edgeColor.setStroke()
            cg.setLineWidth(1.5)
            if msg.dashed { cg.setLineDash(phase: 0, lengths: [5, 3]) }
            if abs(x1 - x2) < 1 {
                // Self-call loop
                let loopW: CGFloat = 30
                let loopH: CGFloat = 18
                cg.move(to: CGPoint(x: x1, y: y - 6))
                cg.addLine(to: CGPoint(x: x1 + loopW, y: y - 6))
                cg.addLine(to: CGPoint(x: x1 + loopW, y: y + loopH - 6))
                cg.addLine(to: CGPoint(x: x1, y: y + loopH - 6))
                cg.strokePath()
                cg.restoreGState()
                drawArrowHead(at: CGPoint(x: x1, y: y + loopH - 6), from: CGPoint(x: x1 + loopW, y: y + loopH - 6), color: palette.edgeColor, cg: cg)
            } else {
                cg.move(to: CGPoint(x: x1, y: y))
                cg.addLine(to: CGPoint(x: x2, y: y))
                cg.strokePath()
                cg.restoreGState()
                drawArrowHead(at: CGPoint(x: x2, y: y), from: CGPoint(x: x1, y: y), color: palette.edgeColor, cg: cg)
            }
            if !msg.text.isEmpty {
                let para = NSMutableParagraphStyle()
                para.lineBreakMode = .byTruncatingTail
                let own = abs(x1 - x2) < 1
                para.alignment = own ? .left : .center
                let attrs: [NSAttributedString.Key: Any] = [.font: msgFont, .foregroundColor: palette.textColor, .paragraphStyle: para]
                let lineH = ceil((msg.text as NSString).size(withAttributes: attrs).height)
                // Between the two lifelines; a message to itself has the room to the next lifeline (or the edge).
                let room = own ? CGRect(x: x1 + 36, y: y - lineH + 6, width: max(40, min(layout.columnSpacing, layout.size.width - x1 - 8) - 44), height: lineH)
                               : CGRect(x: min(x1, x2) + 8, y: y - lineH - 4, width: max(40, abs(x1 - x2) - 16), height: lineH)
                (msg.text as NSString).draw(in: room, withAttributes: attrs)
            }
        }
    }

    // MARK: Pie Chart

    private static func drawPie(title: String, showData: Bool, slices: [MermaidDiagram.PieSlice],
                                size: CGSize, palette: Palette, cg: CGContext) {
        let total = slices.reduce(0) { $0 + $1.value }
        guard total > 0, total.isFinite else { return }
        var top: CGFloat = 18
        if !title.isEmpty {
            let titleFont = HQFont.face(ofSize: 14, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: palette.textColor]
            (title as NSString).draw(at: CGPoint(x: 20, y: top), withAttributes: attrs)
            top += 28
        }
        let radius: CGFloat = 78
        let center = CGPoint(x: 24 + radius, y: top + radius + 10)
        var startAngle: CGFloat = -.pi / 2
        for (i, slice) in slices.enumerated() {
            let sweep = CGFloat(slice.value / total) * .pi * 2
            let endAngle = startAngle + sweep
            let color = palette.sliceColors[i % palette.sliceColors.count]
            cg.saveGState()
            color.setFill()
            cg.move(to: center)
            cg.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            cg.closePath()
            cg.fillPath()
            palette.background.setStroke()
            cg.setLineWidth(1.5)
            cg.move(to: center)
            cg.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            cg.closePath()
            cg.strokePath()
            cg.restoreGState()
            startAngle = endAngle
        }

        // Legend on the right
        let legendX = center.x + radius + 28
        var ly = top + 14
        let legFont = HQFont.face(ofSize: 12, weight: .medium)
        for (i, slice) in slices.enumerated() {
            let color = palette.sliceColors[i % palette.sliceColors.count]
            let swatch = CGRect(x: legendX, y: ly + 2, width: 12, height: 12)
            color.setFill()
            UIBezierPath(roundedRect: swatch, cornerRadius: 3).fill()
            let share = slice.value / total
            let pct = share.isFinite ? Int((share * 100).rounded()) : 0
            let suffix = showData ? " (\(formatNumber(slice.value)) · \(pct)%)" : " (\(pct)%)"
            let label = slice.label + suffix
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: legFont, .foregroundColor: palette.textColor, .paragraphStyle: para]
            (label as NSString).draw(in: CGRect(x: legendX + 18, y: ly, width: max(60, size.width - legendX - 30), height: 20), withAttributes: attrs)
            ly += 24
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: Generic structured fallback

    private static func drawGeneric(title: String, lines: [String], size: CGSize, palette: Palette, cg: CGContext) {
        let titleFont = HQFont.face(ofSize: 13, weight: .semibold)
        let lineFont = HQFont.mono(ofSize: 12)
        (title as NSString).draw(at: CGPoint(x: 18, y: 16), withAttributes: [.font: titleFont, .foregroundColor: palette.accent])
        var y: CGFloat = 42
        for line in lines {
            let box = CGRect(x: 16, y: y, width: size.width - 32, height: 20)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            (line as NSString).draw(in: box, withAttributes: [.font: lineFont, .foregroundColor: palette.textColor, .paragraphStyle: para])
            y += 22
        }
    }
}
