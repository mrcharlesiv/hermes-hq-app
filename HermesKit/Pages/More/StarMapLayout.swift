// The Star Map's layout (docs/spec/3x-morepages.md §17, D-M14). Pure and deterministic: the same nodes always give the
// same points, whatever order the gateway lists them in. Computed once per graph, off the main thread.
//
// - Categories sit on a ring, the largest at the top, then clockwise by size (ties by name). One category alone sits in
//   the middle.
// - Inside a category the stars lie on a golden-angle spiral, the most used in the middle (rank of `useCount`, ties by
//   id), so no two overlap at 1×.
// - A star is 4–14 pt across by `useCount`.
// World units are points at 1×; the origin is the middle of the ring.

import CoreGraphics
import Foundation

nonisolated struct StarMapLayout: Sendable, Equatable {
    struct Star: Sendable, Equatable {
        var id: String
        var label: String
        var cluster: Int
        var point: CGPoint
        /// Half the star's width at 1× (2–7 pt).
        var radius: CGFloat
        var pinned: Bool
        var useCount: Int
    }

    struct Cluster: Sendable, Equatable {
        var category: String
        var title: String
        var center: CGPoint
        /// Reaches the outer edge of its outermost star.
        var radius: CGFloat
        /// Its stars are `stars[first ..< first + count]`, most used first.
        var first: Int
        var count: Int
        var color: Int
        var isMemory: Bool
        /// Which way its name lies from its centre: away from the middle of the ring, where nothing else is drawn
        /// (straight down for a cluster alone).
        var labelSide: CGPoint = CGPoint(x: 0, y: 1)

        /// Where the name is anchored (world), `labelDrop` beyond the cluster's edge.
        var labelPoint: CGPoint {
            CGPoint(x: center.x + labelSide.x * (radius + StarMapLayout.labelDrop), y: center.y + labelSide.y * (radius + StarMapLayout.labelDrop))
        }
        /// The unit point of the name's box that sits on `labelPoint`, so the text grows away from the cluster.
        var labelAnchor: CGPoint { CGPoint(x: 0.5 - labelSide.x * 0.5, y: 0.5 - labelSide.y * 0.5) }
        /// Room the name is given in the map's bounds (a guess at its size at 1×: the real text is measured when drawn).
        var labelBox: CGRect {
            let width = CGFloat(title.count) * 7.5 + 10, height: CGFloat = 20
            let anchor = labelAnchor, point = labelPoint
            return CGRect(x: point.x - width * anchor.x, y: point.y - height * anchor.y, width: width, height: height)
        }
        /// Its stars and its name.
        var box: CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2).union(labelBox)
        }
    }

    struct Edge: Sendable, Equatable {
        var a: Int32
        var b: Int32
    }

    var stars: [Star] = []
    var clusters: [Cluster] = []
    var edges: [Edge] = []
    /// Everything drawn at 1×, cluster labels included.
    var bounds: CGRect = .zero
    private var grid: [Int64: [Int32]] = [:]

    // MARK: Constants

    /// Spiral step: star `i` of a cluster is `spacing × √(i + ½)` from its centre. The closest pair of such a spiral
    /// is about 1.5 × spacing apart, more than the 14 pt of two of the largest stars.
    static let spacing: CGFloat = 11
    static let goldenAngle: CGFloat = .pi * (3 - 5.squareRoot())
    static let minDiameter: CGFloat = 4
    static let maxDiameter: CGFloat = 14
    /// Room between neighbouring clusters on the ring.
    static let gap: CGFloat = 30
    /// From a cluster's edge to its name.
    static let labelDrop: CGFloat = 8
    static let cell: CGFloat = 64
    /// Category colours come from a palette of this many (`StarMapPalette` in the app).
    static let paletteCount = 12

    static func diameter(useCount: Int) -> CGFloat {
        min(maxDiameter, minDiameter + CGFloat(max(0, useCount)).squareRoot() * 1.25)
    }

    // MARK: Colour

    /// FNV-1a: stable across launches and devices (Swift's own `hashValue` is seeded per process).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return hash
    }

    /// A palette slot per category: its stable hash, moved to the next free slot when another category of this graph
    /// (earlier by name) already has it, so two clusters share a colour only when there are more than `count`.
    /// Computed from the whole graph, not the filtered one, so a filter never recolours a cluster.
    static func colors(for categories: some Sequence<String>, count: Int = paletteCount) -> [String: Int] {
        var out: [String: Int] = [:]
        var taken = Set<Int>()
        guard count > 0 else { return out }
        for category in Set(categories).sorted() {
            var slot = Int(stableHash(category) % UInt64(count))
            if taken.count < count { while taken.contains(slot) { slot = (slot + 1) % count } }
            taken.insert(slot)
            out[category] = slot
        }
        return out
    }

    // MARK: Building

    init() {}

    /// `colors` maps a category to its palette slot (see `colors(for:)`); a category it lacks gets its own hash.
    init(nodes: [StarMapNode], edges: [StarMapEdge] = [], colors: [String: Int] = [:]) {
        var groups: [String: [StarMapNode]] = [:]
        var seen = Set<String>()
        for node in nodes where seen.insert(node.id).inserted { groups[node.category, default: []].append(node) }
        let ordered = groups.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }

        // Each cluster around its own origin first.
        var built: [(category: String, stars: [Star], radius: CGFloat, memory: Bool)] = []
        for (category, members) in ordered {
            let ranked = members.sorted { $0.useCount != $1.useCount ? $0.useCount > $1.useCount : $0.id < $1.id }
            let phase = CGFloat(Self.stableHash(category) % 3600) / 3600 * 2 * .pi
            var stars: [Star] = []
            var reach: CGFloat = 0
            for (index, node) in ranked.enumerated() {
                let distance = ranked.count == 1 ? 0 : Self.spacing * (CGFloat(index) + 0.5).squareRoot()
                let angle = phase + CGFloat(index) * Self.goldenAngle
                let radius = Self.diameter(useCount: node.useCount) / 2
                stars.append(Star(id: node.id, label: node.label, cluster: built.count,
                                  point: CGPoint(x: distance * cos(angle), y: distance * sin(angle)),
                                  radius: radius, pinned: node.pinned, useCount: node.useCount))
                reach = max(reach, distance + radius)
            }
            built.append((category, stars, max(reach, 12), members.allSatisfy { $0.kind == .memory }))
        }

        // Then the clusters on the ring.
        let centers = Self.ring(built.map(\.radius))
        var index: [String: Int32] = [:]
        var box = CGRect.null
        for (number, cluster) in built.enumerated() {
            let center = centers[number]
            let far = hypot(center.x, center.y)
            let made = Cluster(category: cluster.category, title: StarMapRules.categoryTitle(cluster.category), center: center,
                               radius: cluster.radius, first: stars.count, count: cluster.stars.count,
                               color: colors[cluster.category] ?? Int(Self.stableHash(cluster.category) % UInt64(Self.paletteCount)),
                               isMemory: cluster.memory,
                               labelSide: far > 0.5 ? CGPoint(x: center.x / far, y: center.y / far) : CGPoint(x: 0, y: 1))
            clusters.append(made)
            for var star in cluster.stars {
                star.point = CGPoint(x: center.x + star.point.x, y: center.y + star.point.y)
                index[star.id] = Int32(stars.count)
                grid[Self.key(star.point), default: []].append(Int32(stars.count))
                stars.append(star)
            }
            box = box.union(made.box)
        }
        bounds = box.isNull ? .zero : box

        var pairs = Set<Int64>()
        for edge in edges {
            guard let a = index[edge.source], let b = index[edge.target], a != b else { continue }
            guard pairs.insert(Int64(min(a, b)) << 32 | Int64(max(a, b))).inserted else { continue }
            self.edges.append(Edge(a: a, b: b))
        }
    }

    /// Centres for clusters of these radii (largest first): on a ring just wide enough that neighbours keep `gap`
    /// between them, starting at the top and going clockwise, the spare angle shared out evenly.
    static func ring(_ radii: [CGFloat]) -> [CGPoint] {
        guard radii.count > 1 else { return radii.map { _ in .zero } }
        let reach = radii.map { $0 + gap / 2 }
        func spread(_ ring: CGFloat) -> CGFloat { reach.reduce(0) { $0 + 2 * asin(min(1, $1 / ring)) } }
        var low = reach.max() ?? 1
        var high = max(low, reach.reduce(0, +))
        if spread(low) > 2 * .pi {
            for _ in 0..<48 {
                let middle = (low + high) / 2
                if spread(middle) > 2 * .pi { low = middle } else { high = middle }
            }
        } else {
            high = low
        }
        let ring = high
        let widths = reach.map { 2 * asin(min(1, $0 / ring)) }
        let spare = max(0, 2 * .pi - widths.reduce(0, +)) / CGFloat(radii.count)
        var angle = -CGFloat.pi / 2
        var out: [CGPoint] = []
        for (number, width) in widths.enumerated() {
            if number > 0 { angle += (widths[number - 1] + width) / 2 + spare }
            out.append(CGPoint(x: ring * cos(angle), y: ring * sin(angle)))
        }
        return out
    }

    // MARK: Looking things up

    private static func key(_ point: CGPoint) -> Int64 { key(Int((point.x / cell).rounded(.down)), Int((point.y / cell).rounded(.down))) }
    private static func key(_ column: Int, _ row: Int) -> Int64 { Int64(column) << 32 | Int64(UInt32(truncatingIfNeeded: row)) }

    /// The stars whose centre is inside `rect` (grown by the caller for their size), in drawing order.
    func stars(in rect: CGRect) -> [Int32] {
        guard !stars.isEmpty, !rect.isEmpty else { return [] }
        let minColumn = Int((rect.minX / Self.cell).rounded(.down)), maxColumn = Int((rect.maxX / Self.cell).rounded(.down))
        let minRow = Int((rect.minY / Self.cell).rounded(.down)), maxRow = Int((rect.maxY / Self.cell).rounded(.down))
        // Zoomed far out the window covers more cells than there are stars: walk the stars instead.
        if (maxColumn - minColumn + 1) * (maxRow - minRow + 1) > max(64, stars.count / 2) {
            return stars.indices.compactMap { rect.contains(stars[$0].point) ? Int32($0) : nil }
        }
        var out: [Int32] = []
        for column in minColumn...maxColumn {
            for row in minRow...maxRow {
                guard let members = grid[Self.key(column, row)] else { continue }
                for member in members where rect.contains(stars[Int(member)].point) { out.append(member) }
            }
        }
        out.sort()
        return out
    }

    /// The star a tap at `point` means: the nearest centre within `reach` (22 pt on screen, so the target is 44 pt at
    /// any zoom). A larger star is not preferred over a nearer one. Ties go to the earlier star.
    func hit(_ point: CGPoint, reach: CGFloat) -> Int? {
        guard reach > 0 else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for member in stars(in: CGRect(x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)) {
            let star = stars[Int(member)]
            let distance = hypot(star.point.x - point.x, star.point.y - point.y)
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (Int(member), distance) }
        }
        return best?.index
    }

    /// The cluster a double tap at `point` means: the one whose edge is nearest, when within `reach` of it.
    func cluster(at point: CGPoint, reach: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (number, cluster) in clusters.enumerated() {
            let distance = hypot(cluster.center.x - point.x, cluster.center.y - point.y) - cluster.radius
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance { best = (number, distance) }
        }
        return best?.index
    }

    /// The whole map in a view of `size`: the largest zoom (at most `most`) at which every cluster and its name are
    /// inside, `margin` points clear of the edges, and the world point to centre on. A name keeps its size on screen
    /// whatever the zoom, so far out it takes more of the map than its `labelBox` at 1×.
    /// `names` is how much larger than the guess the names are drawn (larger text sizes).
    func whole(in size: CGSize, most: CGFloat = 1, margin: CGFloat = 12, names: CGFloat = 1) -> StarMapCamera {
        guard !clusters.isEmpty, size.width > margin * 2, size.height > margin * 2 else { return StarMapCamera() }
        /// What the map covers on screen at `scale`, measured from the world origin.
        func extent(_ scale: CGFloat) -> CGRect {
            var box = CGRect.null
            for cluster in clusters {
                let radius = cluster.radius * scale
                box = box.union(CGRect(x: cluster.center.x * scale - radius, y: cluster.center.y * scale - radius, width: radius * 2, height: radius * 2))
                let guess = cluster.labelBox.size, anchor = cluster.labelAnchor
                let name = CGSize(width: guess.width * max(1, names), height: guess.height * max(1, names))
                let point = CGPoint(x: cluster.center.x * scale + cluster.labelSide.x * (radius + Self.labelDrop),
                                    y: cluster.center.y * scale + cluster.labelSide.y * (radius + Self.labelDrop))
                box = box.union(CGRect(x: point.x - name.width * anchor.x, y: point.y - name.height * anchor.y, width: name.width, height: name.height))
            }
            return box
        }
        func fits(_ scale: CGFloat) -> Bool {
            let box = extent(scale)
            return box.width <= size.width - margin * 2 && box.height <= size.height - margin * 2
        }
        var scale = most
        if !fits(most) {
            var low: CGFloat = 0.02, high = most
            for _ in 0..<32 {
                let middle = (low + high) / 2
                if fits(middle) { low = middle } else { high = middle }
            }
            scale = low
        }
        let box = extent(scale)
        return StarMapCamera(scale: scale, center: CGPoint(x: box.midX / scale, y: box.midY / scale))
    }

    /// The scale at which `rect` (world) fills a view of `size`, with `margin` points to spare on each side.
    static func fit(_ rect: CGRect, in size: CGSize, margin: CGFloat = 16) -> CGFloat {
        guard rect.width > 0, rect.height > 0, size.width > margin * 2, size.height > margin * 2 else { return 1 }
        return min((size.width - margin * 2) / rect.width, (size.height - margin * 2) / rect.height)
    }
}

/// Where the map is looked at from: `center` is the world point in the middle of the view.
nonisolated struct StarMapCamera: Sendable, Equatable {
    static let minZoom: CGFloat = 0.5
    static let maxZoom: CGFloat = 4
    /// Star names are drawn above this.
    static let labelZoom: CGFloat = 1.6

    var scale: CGFloat = 1
    var center: CGPoint = .zero

    func screen(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (world.x - center.x) * scale + size.width / 2, y: (world.y - center.y) * scale + size.height / 2)
    }

    func world(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (screen.x - size.width / 2) / scale + center.x, y: (screen.y - size.height / 2) / scale + center.y)
    }

    func visible(in size: CGSize, margin: CGFloat = 0) -> CGRect {
        let width = (size.width + margin * 2) / scale, height = (size.height + margin * 2) / scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// The smallest zoom allowed: 0.5×, or less when the whole map needs it to fit (`fit`), so a large map can always
    /// be seen whole.
    static func floor(fit: CGFloat) -> CGFloat { max(0.05, min(minZoom, fit)) }

    /// Multiplies the zoom by `factor`, keeping the world point under `anchor` (a screen point) where it is.
    mutating func zoom(by factor: CGFloat, at anchor: CGPoint, in size: CGSize, floor: CGFloat) {
        let before = world(anchor, in: size)
        scale = min(Self.maxZoom, max(floor, scale * factor))
        let after = world(anchor, in: size)
        center.x += before.x - after.x
        center.y += before.y - after.y
    }

    mutating func pan(by translation: CGSize) {
        center.x -= translation.width / scale
        center.y -= translation.height / scale
    }

    /// Keeps some of the map on screen: the centre never leaves the map's bounds.
    mutating func clamp(to bounds: CGRect) {
        guard !bounds.isEmpty else { center = .zero; return }
        center.x = min(bounds.maxX, max(bounds.minX, center.x))
        center.y = min(bounds.maxY, max(bounds.minY, center.y))
    }

    /// A star's half-width on screen: with the zoom below 1× (never under 0.75 pt), gently above it.
    func starRadius(_ radius: CGFloat) -> CGFloat {
        scale <= 1 ? max(0.75, radius * scale) : radius * scale.squareRoot()
    }
}
