// More › Star Map (docs/spec/3x-morepages.md §17 acceptance 1): the layout is deterministic and its stars never
// overlap at 1×, the filters (the web's "learned" rule, `V/app/starmap/text.ts:26`), the List's sections, nearest-wins
// hit-testing, the camera, and the decoders with bad data (duplicate ids included).

import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func skill(_ id: String, _ category: String = "coding", used: Int = 0, by: String? = "agent", pinned: Bool = false) -> StarMapNode {
    StarMapNode(id: id, category: category, useCount: used, createdBy: by, pinned: pinned)
}

/// `count` skills over `categories` categories of uneven size, with every kind of use count.
nonisolated private func sample(_ count: Int, categories: Int = 12, seed: UInt64 = 7) -> [StarMapNode] {
    var state = seed
    func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 33 }
    return (0..<count).map { index in
        let category = "cat-\(min(Int(next() % UInt64(categories * 2)), Int(next() % UInt64(categories))))"
        return skill("skill-\(index)", category, used: Int(next() % 5) == 0 ? 0 : Int(next() % 200), pinned: next() % 9 == 0)
    }
}

nonisolated private func parse(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

@Suite struct StarMapLayoutTests {
    @Test func theSameGraphGivesTheSamePoints() {
        let nodes = sample(300)
        let edges = (0..<200).map { StarMapEdge(source: "skill-\($0)", target: "skill-\(($0 * 7 + 3) % 300)") }
        let first = StarMapLayout(nodes: nodes, edges: edges)
        let second = StarMapLayout(nodes: nodes, edges: edges)
        #expect(first == second)
        #expect(first.stars.count == 300)
        // The order the gateway lists nodes in does not matter either.
        let shuffled = StarMapLayout(nodes: nodes.reversed(), edges: edges.reversed())
        #expect(Dictionary(uniqueKeysWithValues: shuffled.stars.map { ($0.id, $0.point) })
                == Dictionary(uniqueKeysWithValues: first.stars.map { ($0.id, $0.point) }))
        #expect(shuffled.clusters.map(\.category) == first.clusters.map(\.category))
    }

    @Test func theHashIsStableAcrossLaunches() {
        // FNV-1a of the UTF-8 bytes: fixed values, unlike Swift's per-process `hashValue`.
        #expect(StarMapLayout.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(StarMapLayout.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(StarMapLayout.stableHash("coding") == StarMapLayout.stableHash("coding"))
    }

    @Test(arguments: [1, 2, 5, 60, 700, 2000])
    func noTwoStarsOfAClusterOverlapAtOneTimes(count: Int) {
        // The worst case too: every star at the largest size.
        for nodes in [sample(count), (0..<count).map { skill("big-\($0)", "cat-\($0 % 3)", used: 500) }] {
            let layout = StarMapLayout(nodes: nodes)
            for cluster in layout.clusters {
                let stars = Array(layout.stars[cluster.first ..< cluster.first + cluster.count])
                for a in stars.indices {
                    for b in stars.indices where b > a {
                        let distance = hypot(stars[a].point.x - stars[b].point.x, stars[a].point.y - stars[b].point.y)
                        guard distance < stars[a].radius + stars[b].radius else { continue }
                        Issue.record("\(stars[a].id) and \(stars[b].id) overlap: \(distance) < \(stars[a].radius + stars[b].radius)")
                        return
                    }
                }
            }
        }
    }

    @Test func clustersKeepApartOnTheRing() {
        for count in [2, 3, 60, 2000, 5000] {
            let layout = StarMapLayout(nodes: sample(count))
            for a in layout.clusters.indices {
                for b in layout.clusters.indices where b > a {
                    let one = layout.clusters[a], two = layout.clusters[b]
                    let distance = hypot(one.center.x - two.center.x, one.center.y - two.center.y)
                    #expect(distance >= one.radius + two.radius + StarMapLayout.gap - 0.5, "\(one.category) and \(two.category) at \(count)")
                }
            }
        }
    }

    @Test func categoriesAreOrderedBySizeAndTheMostUsedIsInTheMiddle() {
        let nodes = [skill("a1", "small", used: 1), skill("b1", "large", used: 3), skill("b2", "large", used: 90),
                     skill("b3", "large"), skill("c1", "middle"), skill("c2", "middle", used: 2)]
        let layout = StarMapLayout(nodes: nodes)
        #expect(layout.clusters.map(\.category) == ["large", "middle", "small"])
        #expect(layout.clusters.map(\.count) == [3, 2, 1])
        // The largest sits at the top of the ring.
        #expect(layout.clusters[0].center.y < layout.clusters[1].center.y)
        #expect(abs(layout.clusters[0].center.x) < 0.001)
        let large = layout.stars[layout.clusters[0].first ..< layout.clusters[0].first + 3]
        #expect(large.map(\.id) == ["b2", "b1", "b3"])
        let center = layout.clusters[0].center
        let distances = large.map { hypot($0.point.x - center.x, $0.point.y - center.y) }
        #expect(distances == distances.sorted())
        // One category alone sits in the middle; one star alone sits on its centre.
        let alone = StarMapLayout(nodes: [skill("only")])
        #expect(alone.clusters[0].center == .zero)
        #expect(alone.stars[0].point == .zero)
    }

    @Test func starsAreFourToFourteenPointsAcross() {
        #expect(StarMapLayout.diameter(useCount: 0) == 4)
        #expect(StarMapLayout.diameter(useCount: -5) == 4)
        #expect(StarMapLayout.diameter(useCount: 64) == 14)
        #expect(StarMapLayout.diameter(useCount: 1_000_000) == 14)
        #expect(StarMapLayout.diameter(useCount: 4) > StarMapLayout.diameter(useCount: 1))
        let layout = StarMapLayout(nodes: sample(400))
        #expect(layout.stars.allSatisfy { $0.radius >= 2 && $0.radius <= 7 })
    }

    @Test func coloursAreStableAndDistinctWhileThePaletteLasts() {
        let twelve = (0..<12).map { "cat-\($0)" }
        let colors = StarMapLayout.colors(for: twelve)
        #expect(Set(colors.values).count == 12)
        #expect(colors == StarMapLayout.colors(for: twelve.reversed() + twelve))
        #expect(colors.values.allSatisfy { (0..<12).contains($0) })
        // More categories than colours: every one still gets a slot.
        let many = StarMapLayout.colors(for: (0..<40).map { "c\($0)" })
        #expect(many.count == 40 && many.values.allSatisfy { (0..<12).contains($0) })
        #expect(StarMapLayout.colors(for: [String]()).isEmpty)
        // The layout uses the slots it is given, so a filter never recolours a cluster.
        let layout = StarMapLayout(nodes: [skill("a", "cat-3")], colors: colors)
        #expect(layout.clusters[0].color == colors["cat-3"])
    }

    @Test func edgesKeepOnlyRealPairsOnce() {
        let nodes = [skill("a"), skill("b"), skill("c")]
        let layout = StarMapLayout(nodes: nodes, edges: [StarMapEdge(source: "a", target: "b"), StarMapEdge(source: "b", target: "a"),
                                                         StarMapEdge(source: "a", target: "a"), StarMapEdge(source: "a", target: "gone"),
                                                         StarMapEdge(source: "c", target: "a")])
        #expect(layout.edges.count == 2)
    }

    @Test func duplicateIdsAreOneStar() {
        let layout = StarMapLayout(nodes: [skill("a", used: 3), skill("a", "other", used: 9), skill("b")])
        #expect(layout.stars.map(\.id).sorted() == ["a", "b"])
        #expect(layout.clusters.count == 1)
    }

    @Test func aTapTakesTheNearestStarWithinItsTarget() {
        let layout = StarMapLayout(nodes: sample(200))
        for star in layout.stars {
            // On a star: that star, however small it is beside a larger neighbour.
            #expect(layout.hit(star.point, reach: 22).map { layout.stars[$0].id } == star.id)
        }
        // Between two stars the nearer wins, not the larger.
        let two = StarMapLayout(nodes: [skill("big", used: 200), skill("small", used: 0)])
        let big = two.stars.first { $0.id == "big" }!, small = two.stars.first { $0.id == "small" }!
        let nearSmall = CGPoint(x: small.point.x + (big.point.x - small.point.x) * 0.4, y: small.point.y + (big.point.y - small.point.y) * 0.4)
        #expect(two.hit(nearSmall, reach: 22).map { two.stars[$0].id } == "small")
        let nearBig = CGPoint(x: small.point.x + (big.point.x - small.point.x) * 0.6, y: small.point.y + (big.point.y - small.point.y) * 0.6)
        #expect(two.hit(nearBig, reach: 22).map { two.stars[$0].id } == "big")
        // Out of reach: nothing. The reach is 22 pt on screen, so half as far in the world at 2×.
        let away = CGPoint(x: big.point.x + 30, y: big.point.y)
        #expect(two.hit(away, reach: 22) == nil || two.hit(away, reach: 22).map { two.stars[$0].id } == "small")
        #expect(StarMapLayout(nodes: [skill("one")]).hit(CGPoint(x: 21, y: 0), reach: 22) == 0)
        #expect(StarMapLayout(nodes: [skill("one")]).hit(CGPoint(x: 21, y: 0), reach: 22 / 2) == nil)
        #expect(StarMapLayout().hit(.zero, reach: 22) == nil)
    }

    @Test func hitTestingMatchesAPlainSearch() {
        let layout = StarMapLayout(nodes: sample(1500))
        var state: UInt64 = 99
        func next() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(state >> 40) / CGFloat(1 << 24) }
        for _ in 0..<400 {
            let point = CGPoint(x: layout.bounds.minX + next() * layout.bounds.width, y: layout.bounds.minY + next() * layout.bounds.height)
            let reach: CGFloat = [5.5, 22, 44][Int(next() * 3) % 3]
            var best: (Int, CGFloat)?
            for (index, star) in layout.stars.enumerated() {
                let distance = hypot(star.point.x - point.x, star.point.y - point.y)
                if distance <= reach, best == nil || distance < best!.1 { best = (index, distance) }
            }
            #expect(layout.hit(point, reach: reach) == best?.0)
        }
    }

    @Test func onlyWhatIsInViewIsListed() {
        let layout = StarMapLayout(nodes: sample(2000))
        let cluster = layout.clusters[3]
        let window = CGRect(x: cluster.center.x - 60, y: cluster.center.y - 60, width: 120, height: 120)
        let listed = layout.stars(in: window)
        let plain = layout.stars.indices.filter { window.contains(layout.stars[$0].point) }.map { Int32($0) }
        #expect(listed == plain)
        #expect(listed.count < 200)
        #expect(layout.stars(in: layout.bounds.insetBy(dx: -10, dy: -10)).count == 2000)
        #expect(layout.stars(in: CGRect(x: 90_000, y: 90_000, width: 50, height: 50)).isEmpty)
        #expect(layout.stars(in: .zero).isEmpty)
    }

    @Test func aDoubleTapFindsTheClusterUnderIt() {
        let layout = StarMapLayout(nodes: sample(120))
        for (index, cluster) in layout.clusters.enumerated() {
            #expect(layout.cluster(at: cluster.center, reach: 30) == index)
        }
        #expect(layout.cluster(at: CGPoint(x: 50_000, y: 0), reach: 30) == nil)
    }

    @Test(arguments: [1, 60, 2000, 5000])
    func theWholeMapFitsWithItsNames(count: Int) {
        let layout = StarMapLayout(nodes: sample(count))
        let size = CGSize(width: 402, height: 560)
        let camera = layout.whole(in: size)
        #expect(camera.scale <= 1 && camera.scale > 0.02)
        for cluster in layout.clusters {
            let center = camera.screen(cluster.center, in: size), radius = cluster.radius * camera.scale
            let name = cluster.labelBox.size, anchor = cluster.labelAnchor
            let point = CGPoint(x: center.x + cluster.labelSide.x * (radius + StarMapLayout.labelDrop),
                                y: center.y + cluster.labelSide.y * (radius + StarMapLayout.labelDrop))
            let box = CGRect(x: point.x - name.width * anchor.x, y: point.y - name.height * anchor.y, width: name.width, height: name.height)
                .union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            #expect(CGRect(origin: .zero, size: size).insetBy(dx: 11, dy: 11).contains(box), "\(cluster.category) at \(count): \(box)")
        }
        // A small map is not blown up past 1×.
        if count <= 60 { #expect(camera.scale > 0.7) }
        #expect(StarMapLayout().whole(in: size) == StarMapCamera())
    }

    @Test func fiveThousandNodesLayOutQuickly() {
        let nodes = sample(5000)
        let edges = (0..<10_000).map { StarMapEdge(source: "skill-\($0 % 5000)", target: "skill-\(($0 * 13 + 1) % 5000)") }
        let clock = ContinuousClock()
        var layout = StarMapLayout()
        let time = clock.measure { layout = StarMapLayout(nodes: nodes, edges: edges) }
        #expect(layout.stars.count == 5000)
        #expect(time < .seconds(2), "5,000 nodes took \(time)")
    }
}

@Suite struct StarMapCameraTests {
    let size = CGSize(width: 400, height: 600)

    @Test func screenAndWorldAreInverse() {
        let camera = StarMapCamera(scale: 2.5, center: CGPoint(x: 40, y: -10))
        let point = CGPoint(x: 123, y: 456)
        let back = camera.screen(camera.world(point, in: size), in: size)
        #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        #expect(camera.screen(camera.center, in: size) == CGPoint(x: 200, y: 300))
    }

    @Test func aPinchKeepsThePointUnderTheFingers() {
        var camera = StarMapCamera()
        let anchor = CGPoint(x: 310, y: 120)
        let before = camera.world(anchor, in: size)
        camera.zoom(by: 1.8, at: anchor, in: size, floor: 0.5)
        let after = camera.world(anchor, in: size)
        #expect(abs(camera.scale - 1.8) < 0.0001)
        #expect(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001)
    }

    @Test func theZoomStaysBetweenItsLimits() {
        var camera = StarMapCamera()
        for _ in 0..<20 { camera.zoom(by: 2, at: .zero, in: size, floor: 0.5) }
        #expect(camera.scale == 4)
        for _ in 0..<20 { camera.zoom(by: 0.5, at: .zero, in: size, floor: 0.5) }
        #expect(camera.scale == 0.5)
        // A map too large for 0.5× may go as far out as it takes to see it whole.
        #expect(StarMapCamera.floor(fit: 0.2) == 0.2)
        #expect(StarMapCamera.floor(fit: 0.9) == 0.5)
        #expect(StarMapCamera.floor(fit: 3) == 0.5)
        #expect(StarMapCamera.floor(fit: 0) == 0.05)
    }

    @Test func panningMovesTheMapWithTheFingerAndStaysOnIt() {
        var camera = StarMapCamera(scale: 2, center: .zero)
        camera.pan(by: CGSize(width: 100, height: -40))
        #expect(camera.center == CGPoint(x: -50, y: 20))
        camera.pan(by: CGSize(width: -100_000, height: 0))
        camera.clamp(to: CGRect(x: -300, y: -300, width: 600, height: 600))
        #expect(camera.center.x == 300)
    }

    @Test func fittingAndStarSizes() {
        #expect(StarMapLayout.fit(CGRect(x: 0, y: 0, width: 800, height: 400), in: CGSize(width: 432, height: 632)) == 0.5)
        #expect(StarMapLayout.fit(.zero, in: size) == 1)
        #expect(StarMapCamera(scale: 1).starRadius(7) == 7)
        #expect(StarMapCamera(scale: 0.5).starRadius(7) == 3.5)
        #expect(StarMapCamera(scale: 0.1).starRadius(2) == 0.75)
        #expect(StarMapCamera(scale: 4).starRadius(7) == 14)
        // Labels come on above 1.6×.
        #expect(StarMapCamera.labelZoom == 1.6)
    }
}

@Suite struct StarMapRulesTests {
    let nodes = [skill("alpha", "coding", used: 3, by: "agent"), skill("beta", "coding", used: 0, by: "learn", pinned: true),
                 skill("gamma", "coding", used: 12, by: nil), skill("delta", "writing", used: 0, by: "agent"),
                 skill("Echo", "writing", used: 0, by: "user"), skill("zeta", "email", used: 1, by: nil),
                 StarMapNode(id: "memory:memory:0:abc", label: "A note", kind: .memory, category: "memory", createdBy: "memory")]

    @Test func theFilters() {
        func ids(_ filter: StarMapFilter) -> [String] { nodes.filter(filter.matches).map(\.id) }
        #expect(ids(.all).count == 7)
        #expect(ids(.used) == ["alpha", "gamma", "zeta"])
        // The web's "learned" badge: written by Hermes itself, or taught with /learn. Never a memory.
        #expect(ids(.learned) == ["alpha", "beta", "delta"])
        #expect(StarMapFilter.allCases.map(\.title) == ["All", "Used", "Learned"])
    }

    @Test func theListsSections() {
        let all = StarMapRules.sections(nodes, filter: .all)
        #expect(all.map(\.header) == ["Coding · 3", "Writing · 2", "Email · 1"])
        #expect(all[0].nodes.map(\.id) == ["gamma", "alpha", "beta"])
        #expect(all[1].nodes.map(\.id) == ["delta", "Echo"])
        #expect(StarMapRules.subtitle(all) == "6 skills across 3 categories")
        let used = StarMapRules.sections(nodes, filter: .used)
        #expect(used.map(\.header) == ["Coding · 2", "Email · 1"])
        #expect(StarMapRules.subtitle(used) == "3 skills across 2 categories")
        #expect(StarMapRules.sections(nodes, filter: .learned).map(\.header) == ["Coding · 2", "Writing · 1"])
        #expect(StarMapRules.sections([], filter: .all).isEmpty)
        // The Map draws memories as stars too; the List shows them as cards instead.
        #expect(StarMapRules.stars(nodes, filter: .all).count == 7)
        #expect(StarMapRules.stars(nodes, filter: .used).count == 3)
    }

    @Test func theWords() {
        #expect(StarMapRules.subtitle(skills: 1, categories: 1) == "1 skill across 1 category")
        #expect(StarMapRules.subtitle(skills: 0, categories: 0) == "0 skills across 0 categories")
        #expect(StarMapRules.usedLine(0) == "Not used yet")
        #expect(StarMapRules.usedLine(1) == "Used 1 time")
        #expect(StarMapRules.usedLine(42) == "Used 42 times")
        #expect(StarMapRules.categoryTitle("software-development") == "Software Development")
        #expect(StarMapRules.categoryTitle("mlops") == "Mlops")
        #expect(StarMapRules.categoryTitle("GitHub") == "GitHub")
        #expect(StarMapRules.categoryTitle("") == "General")
        #expect(StarMapRules.createdByWord("agent") == "Hermes")
        #expect(StarMapRules.createdByWord("learn") == "Taught by You")
        #expect(StarMapRules.createdByWord(nil) == nil)
        #expect(StarMapRules.kindWord(nodes[6]) == "Memory")
        #expect(StarMapRules.kindWord(nodes[0]) == "Skill")
        #expect(StarMapRules.stateWord("stale") == "Stale")
        #expect(StarMapRules.clusterSpoken(title: "Coding", count: 42, memory: false) == "Coding, 42 skills")
        #expect(StarMapRules.clusterSpoken(title: "Memory", count: 1, memory: true) == "Memory, 1 memory")
        #expect(!StarMapRules.folds("short"))
        #expect(StarMapRules.folds(String(repeating: "x", count: 20_000)))
        #expect(StarMapRules.folds("a\nb\nc\nd\ne"))
        let shown = [StarMapRules.subtitle(skills: 2, categories: 1), StarMapRules.usedLine(3), StarMapRules.createdByWord("agent") ?? ""]
        #expect(!shown.joined().lowercased().contains("dispatch"))
    }

    @Test func theShownStateIsMadeOffTheMainThread() async {
        let graph = StarMapGraph(nodes: nodes, edges: [StarMapEdge(source: "alpha", target: "gamma"), StarMapEdge(source: "alpha", target: "delta")],
                                 memory: [StarMapMemoryCard(id: 0, source: "memory", title: "A note", body: "A note\nmore")])
        let all = await StarMapModel.Shown.make(graph, filter: .all, generation: 4)
        #expect(all.subtitle == "6 skills across 3 categories")
        #expect(all.skills == 6 && all.layout.stars.count == 7 && all.layout.edges.count == 2 && all.memory.count == 1 && all.generation == 4)
        let used = await StarMapModel.Shown.make(graph, filter: .used, generation: 5)
        #expect(used.layout.stars.count == 3 && used.layout.edges.count == 1 && used.memory.isEmpty)
        // A cluster keeps its colour under a filter.
        let color = all.layout.clusters.first { $0.category == "coding" }?.color
        #expect(used.layout.clusters.first { $0.category == "coding" }?.color == color)
    }
}

@Suite struct StarMapWireTests {
    @Test func theGraphAsTheGatewaySendsIt() throws {
        let graph = try StarMapGraph(json: parse("""
        {"nodes":[{"id":"review-prs","label":"review-prs","kind":"skill","timestamp":1757000000,"category":"coding","useCount":7,
                   "state":"active","createdBy":"agent","pinned":true},
                  {"id":"memory:profile:0:abc123","label":"Likes short notes","kind":"memory","memorySource":"profile","timestamp":null,
                   "category":"memory","useCount":0,"state":"active","createdBy":"memory","pinned":false}],
         "edges":[{"source":"memory:profile:0:abc123","target":"review-prs"}],
         "clusters":[{"category":"coding","count":1},{"category":"memory","count":1}],
         "memory":[{"source":"profile","title":"Likes short notes","body":"Likes short notes\\nAlways.","timestamp":1757000000,"fingerprint":"abc123"}],
         "stats":{"nodes":1,"related_edges":0}}
        """))
        #expect(graph.nodes.count == 2 && graph.edges.count == 1 && graph.memory.count == 1)
        #expect(graph.nodes[0] == StarMapNode(id: "review-prs", kind: .skill, category: "coding", useCount: 7, createdBy: "agent",
                                              pinned: true, timestamp: 1_757_000_000))
        #expect(graph.nodes[1].kind == .memory && graph.nodes[1].memorySource == "profile" && graph.nodes[1].timestamp == nil)
        #expect(graph.memory[0].body == "Likes short notes\nAlways.")
        #expect(!graph.isEmpty)
    }

    @Test func badRowsAreSkippedNeverACrash() throws {
        let graph = try StarMapGraph(json: parse("""
        {"nodes":[{"id":"a","useCount":"12","pinned":"true","category":null,"state":null,"createdBy":null},
                  {"id":"a","label":"a second copy"},
                  {"label":"no id"}, {"id":""}, {"id":null}, null, 7, "text", [], {"id":["x"]},
                  {"id":42,"label":17,"kind":"planet","useCount":-3,"pinned":1,"category":"  "},
                  {"id":"m","kind":"memory","useCount":null,"timestamp":"1757000000"}],
         "edges":[{"source":"a","target":"42"},{"source":"42","target":"a"},{"source":"a","target":"a"},
                  {"source":"a","target":"gone"},{"source":"a"},null,"x",{"source":1,"target":2}],
         "clusters":"none",
         "memory":[{"title":"","body":""},{"title":"T"},{"body":"B","source":7,"timestamp":"soon"},null,3,[]],
         "stats":null}
        """))
        #expect(graph.nodes.map(\.id) == ["a", "42", "m"])
        #expect(graph.nodes[0].useCount == 12 && graph.nodes[0].pinned && graph.nodes[0].category == "general" && graph.nodes[0].state == "active")
        #expect(graph.nodes[0].label == "a", "the first node with an id wins")
        #expect(graph.nodes[1].label == "17" && graph.nodes[1].kind == .skill && graph.nodes[1].useCount == 0 && graph.nodes[1].pinned)
        #expect(graph.nodes[2].category == "memory" && graph.nodes[2].timestamp == 1_757_000_000)
        #expect(graph.edges == [StarMapEdge(source: "a", target: "42")])
        #expect(graph.memory.map(\.title) == ["T", ""])
        #expect(graph.memory.map(\.id) == [0, 1])
        #expect(graph.memory[1].source == "memory" && graph.memory[1].timestamp == nil)
    }

    @Test func whatIsNotAGraphIsAnError() {
        for text in ["[]", "null", "7", "\"graph\"", "{}", "{\"nodes\":null}", "{\"nodes\":{\"id\":\"a\"}}", "{\"nodes\":\"many\"}"] {
            #expect(throws: PagesMessageError.self, "\(text)") { _ = try StarMapGraph(json: parse(text)) }
        }
        #expect((try? StarMapGraph(json: parse("{\"nodes\":[]}")))?.isEmpty == true)
    }

    @Test func aLargeGraphWithDuplicatesDecodes() throws {
        var rows: [JSONValue] = []
        for index in 0..<6000 {
            rows.append(.object(["id": .string("s\(index % 5000)"), "category": .string("c\(index % 12)"), "useCount": .number(Double(index % 50))]))
        }
        let graph = try StarMapGraph(json: .object(["nodes": .array(rows), "edges": .array((0..<10_000).map {
            .object(["source": .string("s\($0 % 5000)"), "target": .string("s\(($0 * 3 + 1) % 5000)")])
        })]))
        #expect(graph.nodes.count == 5000)
        #expect(Set(graph.nodes.map(\.id)).count == 5000)
        #expect(graph.edges.count <= 5000 && graph.edges.count > 4000)
    }

    @Test func theNodesText() throws {
        let detail = try StarMapNodeDetail(json: parse("{\"ok\":true,\"kind\":\"skill\",\"id\":\"a\",\"label\":\"a\",\"content\":\"\\n# A\\nSteps.\\n\"}"))
        #expect(detail.content == "# A\nSteps.")
        #expect(try StarMapNodeDetail(json: parse("{\"content\":null}")).content == "")
        #expect(try StarMapNodeDetail(json: parse("{\"content\":12}")).content == "12")
        #expect(throws: PagesMessageError.self) { _ = try StarMapNodeDetail(json: parse("[1]")) }
    }

    @Test func theCallsSendExactlyTheirKeys() async throws {
        let client = MoreFakeClient { request in
            request.path == StarMapAPI.graphPath ? ["nodes": [["id": "a"]]] : ["ok": true, "content": "text"]
        }
        #expect(try await StarMapAPI.graph(client, profile: "default").nodes.count == 1)
        _ = try await StarMapAPI.graph(client, profile: nil)
        _ = try await StarMapAPI.graph(client, profile: "inbox")
        #expect(try await StarMapAPI.node(client, id: "memory:profile:0:ab c&d", profile: "default").content == "text")
        _ = try await StarMapAPI.node(client, id: "a", profile: "inbox")
        #expect(client.log.map(\.method) == Array(repeating: "GET", count: 5))
        #expect(client.log.map(\.path) == ["/api/learning/graph", "/api/learning/graph", "/api/learning/graph", "/api/learning/node", "/api/learning/node"])
        #expect(client.log.map(\.query) == [[:], [:], ["profile": "inbox"], ["id": "memory:profile:0:ab c&d"], ["id": "a", "profile": "inbox"]])
        #expect(client.log.allSatisfy { $0.body == nil })
    }

    @Test func aMissingNodeIsToldFromAFailure() async {
        let gone = MoreFakeClient { _ in throw HTTPError(status: 404, body: "{\"detail\":\"skill 'a' not found\"}") }
        do { _ = try await StarMapAPI.node(gone, id: "a", profile: nil); Issue.record("expected a 404") } catch {
            #expect(StarMapAPI.isMissing(error))
        }
        let broken = MoreFakeClient { _ in throw HTTPError(status: 500, body: "{\"detail\":\"boom\"}") }
        do { _ = try await StarMapAPI.node(broken, id: "a", profile: nil); Issue.record("expected a 500") } catch {
            #expect(!StarMapAPI.isMissing(error))
        }
    }
}
