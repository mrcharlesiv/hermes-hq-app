import CoreGraphics
import Foundation
import Testing
@testable import HermesHQNative

/// [moods] What a bot's face acts out: the tool rules, the hub's timing (a step held long enough to see, "done" and
/// "failed" once, waiting for you first, replays ignored) and every act's faces fitting every head.
struct BotMoodTests {
    @Test(arguments: [
        ("terminal", BotMood.running), ("functions.execute_code", .running), ("read_file", .reading), ("web_extract", .reading),
        ("web_search", .searching), ("session_search", .searching), ("write_file", .writing), ("patch", .writing),
        ("memory", .writing), ("message_agent", .messaging), ("delegate_task", .messaging), ("image_generate", .making),
        ("text_to_speech", .making), ("clarify", .asking), ("browser_click", .browsing), ("computer_use", .browsing),
        ("GMAIL_SEND_EMAIL", .messaging), ("notion_search_pages", .searching), ("GOOGLEDRIVE_UPLOAD_FILE", .writing),
        ("SLACK_FETCH_CONVERSATION_HISTORY", .reading), ("mystery", .running),
    ] as [(String, BotMood)])
    func toolsMapToMoods(tool: String, mood: BotMood) {
        #expect(BotMood(tool: tool) == mood, "\(tool)")
    }

    @Test func noToolNoMood() {
        #expect(BotMood(tool: nil) == nil)
        #expect(BotMood(tool: " ") == nil)
    }

    @Test func onceMoodsLastTheirLength() {
        for mood in BotMood.allCases {
            #expect(mood.once == (mood == .done || mood == .failed))
            #expect(mood.once == (mood.length > 0))
        }
    }

    // MARK: The hub

    @MainActor private final class Hub {
        let moods = BotMoods()
        var now: CFTimeInterval = 1000

        init() {
            moods.usesTimers = false
            moods.clock = { [unowned self] in self.now }
        }

        func event(_ type: String, _ payload: [String: JSONValue] = [:], replayed: Bool = false) {
            var event = GatewayEvent(type: type, sessionId: "s1", seq: nil, payload: .object(payload))
            event.replayed = replayed
            moods.handle(event, profile: "bot")
        }

        func tool(_ name: String) { event("tool.start", ["name": .string(name)]) }

        /// Time passes; the hub's timer would fire.
        func wait(_ seconds: Double) {
            now += seconds
            moods.tick("bot")
        }

        var mood: BotMood? { moods.mood(for: "bot") }
    }

    @MainActor @Test func aTurnActsOutEachStep() {
        let hub = Hub()
        #expect(hub.mood == nil)
        hub.moods.started("bot")
        #expect(hub.mood == .thinking)
        hub.tool("terminal")
        #expect(hub.mood == .running, "thinking gives way to a step at once")
        hub.wait(0.5)
        hub.event("tool.complete")
        #expect(hub.mood == .running, "a step that ends at once still shows its whole dwell")
        hub.wait(BotMood.dwell)
        #expect(hub.mood == .thinking)
        hub.event("message.delta")
        #expect(hub.mood == .replying)
        hub.event("message.complete", ["status": .string("complete")])
        #expect(hub.mood == .done, "the end of a turn shows at once")
        hub.wait(BotMood.done.length)
        #expect(hub.mood == nil)
    }

    @MainActor @Test func aStepWaitsForTheLastOnesDwell() {
        let hub = Hub()
        hub.tool("read_file")
        hub.wait(0.3)
        hub.tool("web_search")
        hub.wait(0.3)
        hub.tool("write_file")
        #expect(hub.mood == .reading)
        hub.wait(BotMood.dwell)
        #expect(hub.mood == .writing, "the newest step waiting takes over")
    }

    @MainActor @Test func failuresAndInterruptions() {
        let hub = Hub()
        hub.tool("terminal")
        hub.event("error")
        #expect(hub.mood == .failed)
        hub.tool("terminal")
        #expect(hub.mood == .running, "a new turn's step takes over from a failure still playing")
        hub.event("message.complete", ["status": .string("interrupted")])
        #expect(hub.mood == nil)
        hub.tool("terminal")
        hub.event("message.complete", ["status": .string("error")])
        #expect(hub.mood == .failed)
        hub.tool("terminal")
        hub.event("session.interrupt")
        #expect(hub.mood == nil)
    }

    @MainActor @Test func replaysAreOldNews() {
        let hub = Hub()
        hub.event("tool.start", ["name": .string("terminal")], replayed: true)
        #expect(hub.mood == nil)
        hub.tool("terminal")
        hub.event("message.complete", replayed: true)
        #expect(hub.mood == nil, "a replayed ending clears quietly, no celebration")
    }

    @MainActor @Test func askingComesFirst() {
        let hub = Hub()
        hub.tool("terminal")
        hub.moods.setAsking("bot", true)
        #expect(hub.mood == .asking)
        #expect(hub.moods.since("bot") == nil)
        hub.moods.setAsking("bot", false)
        #expect(hub.mood == .running)
    }

    @MainActor @Test func theTurnsEndSettlesItsStep() {
        let hub = Hub()
        hub.tool("terminal")
        hub.moods.settle("bot")
        #expect(hub.mood == nil, "a step the events never ended goes with the turn")
        hub.event("message.complete")
        hub.moods.settle("bot")
        #expect(hub.mood == .done, "a celebration plays out")
        hub.moods.started("bot")
        #expect(hub.mood == .done, "a new turn's thinking doesn't cut it short")
    }

    @MainActor @Test func aForgottenStepGoesStale() {
        let hub = Hub()
        hub.tool("terminal")
        hub.wait(BotMoods.stale - 1)
        #expect(hub.mood == .running)
        hub.wait(2)
        #expect(hub.mood == nil)
    }

    @MainActor @Test func nobodysEventsAreIgnored() {
        let moods = BotMoods()
        moods.usesTimers = false
        moods.handle(GatewayEvent(type: "tool.start", sessionId: "s", seq: nil, payload: ["name": .string("terminal")]), profile: nil)
        moods.reset()
        #expect(moods.mood(for: "") == nil)
    }

    // MARK: The acts

    /// Two poses alike (a whole turn is no turn).
    private func alike(_ a: FaceBody, _ b: FaceBody) -> Bool {
        func angle(_ x: Double, _ y: Double) -> Bool {
            let d = (x - y).truncatingRemainder(dividingBy: 360)
            return abs(d) < 0.01 || abs(abs(d) - 360) < 0.01
        }
        return abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 && abs(a.squash - b.squash) < 0.001
            && angle(a.roll, b.roll) && angle(a.turn, b.turn) && angle(a.tip, b.tip)
    }

    private func alike(_ a: FaceEyes, _ b: FaceEyes) -> Bool {
        abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 && abs(a.lids - b.lids) < 0.001
    }

    /// Each of a mood's routines starts and ends on the mood's own pose, so any one can follow any other; a once-only
    /// mood's go from standing back to standing in the mood's time.
    @Test(arguments: BotMood.allCases)
    func routinesJoinUp(mood: BotMood) {
        for facing in [-1, 1] {
            let clips = FaceRoutines.clips(mood, facing: facing)
            #expect(!clips.isEmpty)
            let home = mood.once ? (body: FaceBody.rest, eyes: FaceEyes.rest) : clips[0].first
            for (index, clip) in clips.enumerated() {
                let label = "\(mood) facing \(facing), routine \(index)"
                #expect(clip.length >= 1.5, "\(label) is \(clip.length) s")
                #expect(alike(clip.first.body, home.body) && alike(clip.first.eyes, home.eyes), "\(label) starts elsewhere")
                #expect(alike(clip.last.body, home.body) && alike(clip.last.eyes, home.eyes), "\(label) ends elsewhere")
                #expect(zip(clip.body, clip.body.dropFirst()).allSatisfy { $0.at <= $1.at }, "\(label)")
                #expect(clip.marks.allSatisfy { (0..<clip.length).contains($0) }, "\(label)")
                if mood.once { #expect(abs(clip.length - mood.length) < 0.001, "\(label) plays \(clip.length) s") }
            }
            let act = MatrixAct.make(mood, design: MatrixDesign(facing: facing))
            #expect(act.once == mood.once)
        }
        // Writing's lines and browsing's pointer run beside the routines, so every routine is as long as they are.
        #expect(FaceRoutines.clips(.writing, facing: 1).allSatisfy { abs($0.length - (2 * MatrixAct.lineLength + MatrixAct.typingPause)) < 0.001 })
        #expect(FaceRoutines.clips(.browsing, facing: 1).allSatisfy { abs($0.length - Double(MatrixAct.stops.count) * MatrixAct.stopLength) < 0.001 })
    }

    /// A face plays a mood's routines in its own order, never one twice running (round the loop too), and the same
    /// order for the same seed (a bot's row and its chat's header move together).
    @Test(arguments: BotMood.allCases)
    func loopsShuffle(mood: BotMood) {
        for seed in [1, 7, 4242, 99_999] {
            let loop = FaceLoop(mood, facing: 1, seed: seed)
            let again = FaceLoop(mood, facing: 1, seed: seed)
            #expect(loop.clips.map(\.body) == again.clips.map(\.body))
            #expect(abs(loop.period - loop.clips.reduce(0) { $0 + $1.length }) < 0.001)
            if mood.once {
                #expect(loop.clips.count == 1)
            } else {
                #expect(loop.clips.count == 2 * FaceRoutines.clips(mood, facing: 1).count)
                let next = Array(loop.clips.dropFirst()) + [loop.clips[0]]
                if loop.clips.count > 2 {
                    #expect(zip(loop.clips, next).allSatisfy { $0.body != $1.body || $0.eyes != $1.eyes }, "\(mood), seed \(seed)")
                }
            }
            let samples = loop.samples()
            #expect(samples.first?.at == 0)
            #expect(abs((samples.last?.at ?? 0) - loop.period) < 0.001)
            #expect(zip(samples, samples.dropFirst()).allSatisfy { $1.at > $0.at && $1.at - $0.at < 0.05 }, "\(mood): a gap")
        }
        #expect(abs(FaceLoop(mood, facing: 1, seed: 3).pose(at: -0.5).body.x - FaceLoop(mood, facing: 1, seed: 3).pose(at: FaceLoop(mood, facing: 1, seed: 3).period - 0.5).body.x) < 0.001)
    }

    /// Eases go where they're told and the springy one runs past it on the way.
    @Test func easesLandAndOvershoot() {
        for ease in [FaceEase.linear, .glide, .spring, .drop, .rise] {
            #expect(abs(ease(0)) < 0.001 && abs(ease(1) - 1) < 0.001)
        }
        #expect((0...20).map { FaceEase.spring(Double($0) / 20) }.max()! > 1.05)
        #expect(abs(FaceEase.linear(0.3) - 0.3) < 0.001)
    }

    /// Every face an act goes through, on every head (each a head's own: slit eyes, nothing else): each dark LED ringed
    /// by lit ones (a glitch's slid rows aside, which only move where the dots are drawn).
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func everyActFits(silhouette: MatrixDesign.Silhouette) {
        for facing in [-1, 1] {
            let body = MatrixHead.leds(silhouette, facing: facing)
            func lit(_ col: Int, _ row: Int) -> Bool { (0..<MatrixHead.grid).contains(row) && (0..<MatrixHead.grid).contains(col) && body[row][col] }
            let design = MatrixDesign(silhouette: silhouette, facing: facing)
            for mood in BotMood.allCases {
                for pose in MatrixAct.make(mood, design: design).poses {
                    for cell in MatrixHead.faceLEDs(design, pose: pose).keys {
                        let ring = (-1...1).allSatisfy { dy in (-1...1).allSatisfy { dx in lit(cell.col + dx, cell.row + dy) } }
                        #expect(ring, "\(silhouette) facing \(facing), \(mood) at \(pose.key): \(cell.col),\(cell.row)")
                    }
                }
            }
        }
    }

    /// Each act shows on the head's own eyes: done and making look up, failed screws them shut and glitches, replying
    /// and messaging look aside.
    @Test func actsChangeTheFace() {
        let design = MatrixDesign()
        let rest = MatrixHead.faceLEDs(design, pose: .rest)
        for mood in [BotMood.done, .failed, .making, .replying, .messaging] {
            let faces = MatrixAct.make(mood, design: design).poses.map { MatrixHead.faceLEDs(design, pose: $0) }
            #expect(faces.contains { $0 != rest }, "\(mood) looks like the face at rest")
        }
        #expect(MatrixAct.make(.failed, design: design).poses.contains { $0.glitch > 0 })
    }

    /// The body acts too: replying nods, messaging turns to its side, done jumps, failed shakes its head, searching
    /// looks both ways.
    @Test func routinesMoveTheBody() {
        func bodies(_ mood: BotMood) -> [FaceBody] { FaceRoutines.clips(mood, facing: 1).flatMap { $0.body.map(\.value) } }
        #expect(FaceRoutines.clips(.replying, facing: 1).contains { $0.marks.count >= 3 && $0.body.contains { $0.value.tip > 5 } })
        #expect(bodies(.messaging).contains { $0.turn > 15 })
        #expect(FaceRoutines.clips(.messaging, facing: -1).flatMap { $0.body.map(\.value) }.contains { $0.turn < -15 })
        #expect(FaceRoutines.clips(.done, facing: 1).allSatisfy { $0.body.contains { $0.value.y < -0.1 } })
        #expect(FaceRoutines.clips(.done, facing: 1).contains { $0.body.contains { abs($0.value.roll) >= 359 } })
        #expect(bodies(.failed).contains { $0.x < 0 } && bodies(.failed).contains { $0.x > 0 })
        #expect(bodies(.searching).contains { $0.turn > 15 } && bodies(.searching).contains { $0.turn < -15 })
        #expect(FaceRoutines.clips(.making, facing: 1).allSatisfy { $0.first.eyes.y < -0.35 }, "making looks up at it")
    }

    /// A soft body wobbles on after the body moves, within bounds; a loop's wobble runs round seamlessly, and one played
    /// once is still by its end (where it's held).
    @Test(arguments: BotMood.allCases)
    func softBodiesWobbleOn(mood: BotMood) {
        let loop = FaceLoop(mood, facing: 1, seed: 7)
        let samples = loop.softSamples(once: mood.once)
        let wobble = FaceJelly.follow(samples, period: loop.period, once: mood.once)
        #expect(wobble.count == samples.count)
        #expect(wobble.allSatisfy { $0.squash >= -0.16 && $0.squash <= 0.2 && abs($0.lean) <= 0.14 })
        #expect(wobble.contains { abs($0.squash) > 0.02 || abs($0.lean) > 0.02 }, "\(mood) barely wobbles")
        let first = wobble[0], last = wobble[wobble.count - 1]
        if mood.once {
            #expect(first == .rest && last == .rest)
        } else {
            #expect(abs(first.squash - last.squash) < 0.01 && abs(first.lean - last.lean) < 0.01, "\(mood) jumps as it loops")
        }
    }

    @Test func aLandingSquashesTheJelly() {
        // Done's hop lands at 0.66 s and the body is still from about 0.96 s: the jelly stretches as it falls, the body
        // squashes as it lands, and then the jelly settles, once, softly, never ringing on (owner: "Never jittery").
        let loop = FaceLoop(.done, facing: 1, seed: 1)
        let samples = loop.softSamples(once: true), wobble = FaceJelly.follow(samples, period: loop.period, once: true)
        let falling = zip(samples, wobble).filter { $0.0.at > 0.45 && $0.0.at < 0.72 }.map(\.1.squash)
        #expect((falling.min() ?? 0) < -0.03)
        #expect((samples.filter { $0.at > 0.6 && $0.at < 0.95 }.map(\.body.squash).max() ?? 0) > 0.03)
        let after = zip(samples, wobble).filter { $0.0.at > 1.0 }.map(\.1)
        #expect(after.allSatisfy { abs($0.squash) < 0.02 && abs($0.lean) < 0.05 })
    }

    /// A soft body follows its routine on springs: none of its moves starts or stops dead (its speed never jumps from one
    /// frame to the next as the routine's does), a loop runs round without a jump, and one played once starts where it does.
    @Test(arguments: BotMood.allCases)
    func softBodiesMoveSmoothly(mood: BotMood) {
        let loop = FaceLoop(mood, facing: 1, seed: 3)
        let raw = loop.samples(rate: 60), soft = loop.softSamples(once: mood.once)
        #expect(raw.count == soft.count && zip(raw, soft).allSatisfy { $0.at == $1.at && $0.eyes.lids == $1.eyes.lids })
        let channels: [(String, (FaceBody, FaceEyes) -> Double)] = [
            ("x", { b, _ in b.x * 100 }), ("y", { b, _ in b.y * 100 }), ("roll", { b, _ in b.roll }), ("turn", { b, _ in b.turn }),
            ("tip", { b, _ in b.tip }), ("squash", { b, _ in b.squash * 100 }), ("look x", { _, e in e.x * 10 }), ("look y", { _, e in e.y * 10 }),
        ]
        for (name, value) in channels {
            // How suddenly its speed changes, frame to frame, at worst.
            func jolt(_ s: [(at: Double, body: FaceBody, eyes: FaceEyes)]) -> Double {
                let v = s.map { value($0.body, $0.eyes) }
                return (1..<(v.count - 2)).map { abs(v[$0 + 2] - 3 * v[$0 + 1] + 3 * v[$0] - v[$0 - 1]) }.max() ?? 0
            }
            let before = jolt(raw), after = jolt(soft)
            if before > 0.03 { #expect(after < before * 0.6, "\(mood) \(name): \(after) vs \(before)") }
            let first = value(soft[0].body, soft[0].eyes), last = value(soft[soft.count - 1].body, soft[soft.count - 1].eyes)
            if mood.once {
                #expect(abs(first - value(raw[0].body, raw[0].eyes)) < 1e-9)
            } else {
                #expect(abs(first - last).truncatingRemainder(dividingBy: 360) < 0.05, "\(mood) \(name) jumps as it loops")
            }
        }
    }

    /// The eyes lead the head: while it swings round, they're already further round than the routine has them (they got
    /// there first, and come back toward its middle as it catches up), and once it's still they're where the routine has
    /// them.
    @Test(arguments: [BotMood.searching, .messaging, .thinking, .failed])
    func eyesLeadTheHead(mood: BotMood) {
        let loop = FaceLoop(mood, facing: 1, seed: 5)
        let raw = loop.samples(rate: 60), soft = loop.softSamples(once: mood.once)
        var ahead: [Double] = []
        for i in 1..<(soft.count - 1) {
            let speed = (soft[i + 1].body.turn - soft[i - 1].body.turn) / (soft[i + 1].at - soft[i - 1].at)
            if abs(speed) > 40 { ahead.append((soft[i].eyes.x - raw[i].eyes.x) * (speed > 0 ? 1 : -1)) }
        }
        #expect(!ahead.isEmpty && ahead.reduce(0, +) / Double(ahead.count) > 0.02, "\(mood): \(ahead.reduce(0, +) / Double(max(ahead.count, 1)))")
        let settled = (12..<soft.count).filter { i in
            abs(soft[i].body.turn - raw[i].body.turn) < 0.2 && abs(soft[i].body.tip - raw[i].body.tip) < 0.2
                && abs(raw[i].eyes.x - raw[i - 12].eyes.x) < 1e-9 && abs(raw[i].eyes.y - raw[i - 12].eyes.y) < 1e-9
        }
        #expect(settled.allSatisfy { abs(soft[$0].eyes.x - raw[$0].eyes.x) < 0.12 })
    }

    /// However far a soft head's eyes look, they stay on the face: moved as far as `room` allows each way, the box round
    /// them is still inside the outline, and a box already at the edge has no room that way.
    @Test func eyesStayOnTheFace() {
        let outline = (0..<40).map { i -> CGPoint in
            let a = Double(i) / 40 * 2 * .pi
            return CGPoint(x: 512 + cos(a) * 300, y: 512 + sin(a) * 300)
        }
        func inside(_ box: CGRect) -> Bool {
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY),
             CGPoint(x: box.maxX, y: box.maxY)].allSatisfy { hypot($0.x - 512, $0.y - 512) <= 300 }
        }
        let box = CGRect(x: 412, y: 430, width: 200, height: 60)
        let room = FaceJelly.room(for: box, in: outline, margin: 20)
        #expect(room.left > 60 && room.right > 60 && room.up > 100 && room.down > 100)
        for moved in [box.offsetBy(dx: room.right, dy: 0), box.offsetBy(dx: -room.left, dy: 0),
                      box.offsetBy(dx: 0, dy: -room.up), box.offsetBy(dx: 0, dy: room.down)] {
            #expect(inside(moved))
        }
        let edge = FaceJelly.room(for: CGRect(x: 760, y: 490, width: 40, height: 40), in: outline, margin: 20)
        #expect(edge.right == 0 && edge.left > 100)
    }

    /// A soft body is solid: facing ahead it's its own outline; turned, its side shows (it never thins to a card) and
    /// its face rides round its front, narrowing toward its edge and gone round its back.
    @Test func softBodiesAreSolid() {
        let outline = (0..<40).map { i -> CGPoint in
            let a = Double(i) / 40 * 2 * .pi
            return CGPoint(x: 512 + cos(a) * 300, y: 512 + sin(a) * 250)
        }
        let solid = FaceSolid(outline: outline, side: 1024)
        let edge = HeadGeometry.spline(outline).dense
        // Facing ahead, its edge is the outline's.
        for (b, r) in solid.rest.enumerated() {
            let a = Double(b) / Double(FaceSolid.bins) * 2 * .pi
            let want = 1 / sqrt(pow(cos(a) / 300, 2) + pow(sin(a) / 250, 2))
            #expect(abs(r - want) < 3, "bin \(b): \(r) for \(want)")
        }
        #expect(edge.count > 40)
        func width(_ reach: [Double]) -> Double { reach[0] + reach[FaceSolid.bins / 2] }
        // Side on it's as wide as it is deep (a card would be a line); part way round, in between.
        let front = width(solid.rest), side = width(solid.reach(turn: 90, tip: 0)), part = width(solid.reach(turn: 35, tip: 0))
        #expect(abs(side - 2 * solid.depth) < 0.08 * side, "side on: \(side), deep \(2 * solid.depth)")
        #expect(part < front && part > side)
        let tipped = solid.reach(turn: 0, tip: 90)
        #expect(abs(tipped[FaceSolid.bins / 4] + tipped[3 * FaceSolid.bins / 4] - 2 * solid.depth) < 0.08 * 2 * solid.depth)
        // A turn edges it a little, never by more than its depth makes it grow.
        for turn in stride(from: -180.0, through: 180, by: 15) {
            #expect(solid.reach(turn: turn, tip: 0).allSatisfy { $0 > 0 && $0 < 320 }, "turn \(turn)")
        }
        // The face, a little above the middle: right as it turns right, down as it tips, narrower, and round the back.
        let eyes = CGPoint(x: 512, y: 470)
        let ahead = solid.seat(eyes, turn: 0, tip: 0)
        #expect(abs(ahead.dx) < 1e-6 && abs(ahead.dy) < 1e-6 && abs(ahead.wide - 1) < 1e-6 && abs(ahead.high - 1) < 1e-6)
        #expect(ahead.facing > 0.9)
        let right = solid.seat(eyes, turn: 30, tip: 0), down = solid.seat(eyes, turn: 0, tip: 30)
        #expect(right.dx > 40 && right.wide < 0.95 && right.facing > 0.5)
        #expect(down.dy > 20 && down.high < 0.97)
        #expect(solid.seat(eyes, turn: 180, tip: 0).facing < 0)
        #expect(solid.seat(eyes, turn: -30, tip: 0).dx < -40)
        // Turned and looking the same way (a look is a little more turn), the eyes are still inside its edge.
        for turn in [30.0, -30, 50] {
            let look = solid.seat(eyes, turn: turn + (turn > 0 ? 32 : -32), tip: 12)
            let x = eyes.x + look.dx - solid.middle.x, y = eyes.y + look.dy - solid.middle.y
            var a = atan2(y, x)
            if a < 0 { a += 2 * .pi }
            let bin = Int((a / (2 * .pi) * Double(FaceSolid.bins)).rounded()) % FaceSolid.bins
            #expect(hypot(x, y) < solid.reach(turn: turn, tip: 0)[bin] - 20, "turn \(turn)")
        }
    }

    /// Writing's two lines sit on the head's own LEDs, under the eyes, on every outline.
    @Test(arguments: MatrixDesign.Silhouette.allCases)
    func typingLinesSitOnTheHead(silhouette: MatrixDesign.Silhouette) {
        for facing in [-1, 1] {
            let design = MatrixDesign(silhouette: silhouette, facing: facing)
            let body = MatrixHead.leds(design)
            let lines = MatrixActMasks.typingLines(design)
            #expect(!lines.isEmpty, "\(silhouette) facing \(facing)")
            let eyes = MatrixHead.faceLEDs(design, pose: .rest).filter { $0.value != .blush }.keys.map(\.row)
            for line in lines {
                #expect(line.last - line.first + 1 >= 4)
                #expect((line.first...line.last).allSatisfy { body[line.row][$0] }, "\(silhouette) row \(line.row)")
                #expect(line.row > (eyes.min() ?? 0), "\(silhouette): a line above the eyes")
            }
        }
    }

    @Test(arguments: BotMood.allCases)
    func actPicturesAreDrawn(mood: BotMood) throws {
        for dark in [false, true] {
            let design = MatrixDesign(silhouette: .cloud)
            let act = MatrixAct.make(mood, design: design)
            let pictures = MatrixActPictures.draw(design, mood: mood, side: 44, scale: 3, dark: dark)
            #expect(pictures.faces.count == act.poses.count)
            #expect(pictures.lit != nil)
            let masks = [MatrixAct.Effect.rain: 2, .sparkle: 3, .burst: 3][act.effect ?? .flash] ?? 0
            #expect(pictures.masks.count == masks, "\(mood)")
            let lit = try #require(pictures.lit)
            #expect(lit.width == 132 && lit.height == 132)
        }
    }

    @Test func litPictureLeavesTheFaceOut() throws {
        let design = MatrixDesign(silhouette: .round, eyes: .ovals)
        let act = MatrixAct.make(.searching, design: design)
        let skip = act.faceCells(design)
        let full = try #require(MatrixHeadRenderer.makeLitImage(design, side: 40, scale: 1, dark: false))
        let faceless = try #require(MatrixHeadRenderer.makeLitImage(design, side: 40, scale: 1, dark: false, skip: skip))
        let rim = try #require(MatrixHeadRenderer.makeLitImage(design, side: 40, scale: 1, dark: false, rim: 2))
        func alpha(_ image: CGImage, _ cell: MatrixHead.Cell) -> UInt8 {
            let data = image.dataProvider!.data! as Data
            let x = cell.col * 2 + 1, y = cell.row * 2 + 1
            return data[y * image.bytesPerRow + x * 4 + 3]
        }
        let eye = try #require(skip.first)
        #expect(alpha(full, eye) > 0, "the full picture lights the face's LEDs")
        #expect(alpha(faceless, eye) == 0, "a flare never covers the face")
        #expect(alpha(full, MatrixHead.Cell(10, 10)) > 0)
        #expect(alpha(rim, MatrixHead.Cell(10, 10)) == 0, "the rim leaves the middle out")
    }
}
