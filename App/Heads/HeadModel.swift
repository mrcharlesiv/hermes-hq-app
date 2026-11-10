// A bot's picture as a small record (spec 02 §10.2–10.3), ported from the web app's `src/ui-heads/head.ts`.
// Pure value code: no UIKit, usable from any thread. Drawing lives in HeadGeometry / HeadRenderer.

import Foundation

/// A parsed head record. Only the fields a Shapes or dot-matrix head draws are kept; the robot-only fields are read
/// for validation only (an old record with a robot `shape`/`face` still counts as "a head was saved").
nonisolated struct Head: Hashable, Sendable {
    /// `matrix` (native only, MatrixHead.swift): the dot-matrix head (every bot's default until 2026-11-08; now `shape`).
    enum Theme: String, CaseIterable, Sendable { case robot, persona, dots, orb, pixel, glyph, shape, matrix }
    enum ColorName: String, CaseIterable, Sendable {
        case ink, mint, teal, sky, lilac, pink, coral, peach, butter, lime, paper
        case red, grass, forest, cobalt, denim, grape, plum, magenta, rose, wine, caramel, cocoa, slate
    }
    enum Form: String, CaseIterable, Sendable { case round, blob, square, pill, triangle, hex, cloud, drop, star, heart }
    enum Look: String, CaseIterable, Sendable { case slits, dots, ovals, googly, happy, sleepy, stars, hearts }
    enum Specs: String, CaseIterable, Sendable { case none, shades, aviators, round, monocle }
    enum Hat: String, CaseIterable, Sendable { case none, crown, halo, sprout, party, bow, beanie }
    enum Mouth: String, CaseIterable, Sendable { case none, smile, open, cat, grille }
    enum Tile: String, CaseIterable, Sendable { case dark, light, color, none }

    var theme: Theme = .shape
    var color: ColorName = .mint
    /// Keeps a generated picture (the blob's wobble) the same on every device. Clamped to [1, 2^31 − 1].
    var seed: Int = 1
    var form: Form = .round
    var look: Look = .slits
    var specs: Specs = .none
    /// Parsed for fidelity, never drawn: the owner rejected hats on Shapes heads (spec 06 §12).
    var hat: Hat = .none
    var mouth: Mouth = .none
    var blush: Bool = false
    var tile: Tile = .none
    /// A dot-matrix head's outline (saved in `form`; a Shapes head's is `form` itself).
    var silhouette: MatrixDesign.Silhouette = .round
    /// A Robot, Dots, Orb, Pixel or Emoji head: the whole stored record, drawn by ThemeHeadSVG. Nil for a Shapes or
    /// dot-matrix head.
    var themed: HeadRecord?

    /// Robot head shapes and faces from `head.ts` (only used to decide whether a record names a head at all).
    static let robotShapes: Set<String> = ["dome", "blob", "puff", "pebble", "shield", "diamond", "cat", "ghost",
                                           "cloud", "heart", "star", "drop"]
    static let robotFaces: Set<String> = ["visor", "pill", "dots", "surprised", "happy", "content", "wink", "sleepy",
                                          "bars", "side", "angry", "worried", "heart", "sparkle", "dizzy", "scanner"]

    /// `parseHead` (`head.ts:117-160`): nil when `raw` is not an object or names no known theme/shape/face.
    /// Every unknown field value falls back exactly as the web does.
    static func parse(_ raw: JSONValue?) -> Head? {
        guard case .object(let value)? = raw else { return nil }
        func known(_ list: Set<String>, _ field: JSONValue?) -> Bool { field?.string.map(list.contains) ?? false }
        let themeNames = Set(Theme.allCases.map(\.rawValue))
        guard known(themeNames, value["theme"]) || known(robotShapes, value["shape"]) || known(robotFaces, value["face"])
        else { return nil }
        func pick<T: RawRepresentable>(_ field: String, _ fallback: T) -> T where T.RawValue == String {
            value[field]?.string.flatMap(T.init(rawValue:)) ?? fallback
        }
        var head = Head()
        head.theme = pick("theme", Theme.robot)
        head.color = pick("color", ColorName.mint)
        // Number.isInteger(seed) ? clamp(seed, 1, 2^31 - 1) : 1
        if case .number(let n)? = value["seed"], n.isFinite, n.rounded(.towardZero) == n {
            head.seed = Int(min(max(n, 1), 2147483647))
        } else {
            head.seed = 1
        }
        head.form = pick("form", Form.round)
        head.look = pick("look", Look.slits)
        head.specs = pick("specs", Specs.none)
        head.hat = pick("hat", Hat.none)
        head.mouth = pick("mouth", Mouth.none)
        head.blush = value["blush"]?.bool == true
        head.tile = pick("tile", Tile.dark)
        // `Number(value.v)`: a missing or unreadable version reads as old.
        let version = value["v"]?.double ?? 0
        if head.theme == .shape && !(version >= 5) { head.mouth = .none; head.blush = false }
        if head.theme == .shape && !(version >= 6) { head.tile = .none }
        return head
    }

    /// The picture a bot wears: its saved head, else its §10.3 default. A Character head (a theme the owner removed)
    /// falls back to the default.
    static func resolve(_ raw: JSONValue?, profile: String) -> Head {
        if let head = parse(raw), head.theme == .shape { return head }
        if let record = HeadRecord.parse(raw) { return Head(record: record) ?? defaultHead(profile: profile) }
        return defaultHead(profile: profile)
    }

    init() {}

    /// A head from a full record: a Shapes or dot-matrix head as its fields, the drawn themes carrying the record; nil
    /// for Character.
    init?(record: HeadRecord) {
        if record.theme == "shape" {
            guard let head = Head.parse(record.stored) else { return nil }
            self = head
            return
        }
        if record.theme == "matrix" {
            self.init()
            theme = .matrix
            color = ColorName(rawValue: record.color) ?? .mint
            seed = min(max(record.seed, 1), 2147483647)
            silhouette = MatrixDesign.Silhouette(stored: record.form)
            look = Look(rawValue: record.look) ?? .slits
            mouth = Mouth(rawValue: record.mouth) ?? .none
            blush = record.blush
            return
        }
        guard ThemeHeadSVG.drawnThemes.contains(record.theme) else { return nil }
        self.init()
        theme = Theme(rawValue: record.theme) ?? .robot
        color = ColorName(rawValue: record.color) ?? .mint
        seed = record.seed
        themed = record
    }

    /// The head a bot wears until it is given another: the name's plain Shapes head (`defaultShapeHead`), as the web
    /// draws it (owner 2026-11-08: Shapes, not the dot-matrix head, is every bot's default).
    static func defaultHead(profile: String) -> Head { defaultShapeHead(profile: profile) }

    /// The dot-matrix head picked from the profile name (trimmed, lower case), each bot's default from build 378 until
    /// 2026-11-08; still what the Matrix app icon and the Cloud forge draw. The same face, in the same colour family, on
    /// every device: one of the outlines (a heart only when it's given one). Its record still picks build 378's eyes,
    /// smile and blush (most often slits); every one is drawn with slit eyes and nothing else (`plain`).
    static func defaultMatrixHead(profile: String) -> Head {
        let key = defaultKey(profile)
        let hash = max(nameHash(key), 1)
        var random = SeededRandom(seed: hash)
        var head = Head()
        head.theme = .matrix
        head.color = matrixColours[Int(hash % UInt32(matrixColours.count))]
        let seed = Int(hash) % 2147483647
        head.seed = seed == 0 ? 1 : seed
        // The outline has a stream of its own ("matrix:" + the name: of the few tried, one of those that spread the
        // owner's bots over the most outlines). The name's own stream still draws build 378's head shape, antenna, ears
        // and visor and drops them, so every bot keeps the eyes, mouth and blush it had then.
        var outline = SeededRandom(seed: max(nameHash("matrix:" + key), 1))
        head.silhouette = pick(&outline, [(.round, 2), (.square, 2), (.tall, 1.5), (.wide, 1.5), (.pebble, 1.5), (.cloud, 1.5),
                                          (.arch, 1.5), (.shield, 1.5), (.drop, 1.5), (.leaf, 1.5), (.hex, 1.5), (.octagon, 1.5)])
        _ = random.next()
        head.look = pick(&random, [(.slits, 6), (.ovals, 3), (.dots, 2), (.happy, 1)])
        for _ in 0..<3 { _ = random.next() }
        head.mouth = pick(&random, [(.none, 12), (.smile, 1)])
        head.blush = random.next() < 0.08
        return head
    }

    /// One of `list`, each as likely as its weight.
    private static func pick<T>(_ random: inout SeededRandom, _ list: [(T, Double)]) -> T {
        var left = random.next() * list.reduce(0) { $0 + $1.1 }
        for (value, weight) in list {
            left -= weight
            if left < 0 { return value }
        }
        return list[0].0
    }

    /// Twelve colour families evenly round the wheel, so neighbouring bots rarely share one.
    static let matrixColours: [ColorName] = [.red, .peach, .butter, .lime, .grass, .mint, .teal, .sky, .cobalt, .lilac, .grape, .pink]

    /// What a default head is picked from: the profile name trimmed and in lower case ("default" when empty).
    static func defaultKey(_ profile: String) -> String {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// `defaultHead` (`head.ts:246-258`): the web's default, a plain Shapes head picked from the profile name.
    static func defaultShapeHead(profile: String) -> Head {
        let hash = max(nameHash(defaultKey(profile)), 1)
        var random = SeededRandom(seed: hash)
        let colours = Head.defaultColours
        var head = Head()
        head.theme = .shape
        head.color = colours[Int(hash % UInt32(colours.count))]
        let seed = Int(hash) % 2147483647
        head.seed = seed == 0 ? 1 : seed
        let forms: [Form] = [.round, .blob, .square, .pill, .hex, .cloud]
        head.form = forms[Int((random.next() * Double(forms.count)).rounded(.down))]
        head.look = .slits; head.specs = .none; head.hat = .none; head.mouth = .none; head.blush = false
        head.tile = .none
        return head
    }

    /// SHAPE_COLORS without ink, slate and paper, in the editor's order (`head.ts:30-31,250`).
    static let defaultColours: [ColorName] = [.red, .coral, .peach, .butter, .lime, .grass, .mint, .teal, .sky, .cobalt,
                                              .lilac, .grape, .rose, .pink, .magenta, .plum, .denim, .forest, .wine,
                                              .cocoa, .caramel]

    /// FNV-1a 32-bit over the text's code points (`head.ts:185-189`).
    static func nameHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for scalar in text.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16777619
        }
        return hash
    }

    /// One string per distinct picture (`headKey`, shape branch): what drawings are cached on.
    var cacheKey: String {
        if let themed { return themed.pictureKey }
        if theme == .matrix {
            return "matrix|\(silhouette.rawValue)|\(look.rawValue)|\(mouth.rawValue)|\(blush ? 1 : 0)|\(color.rawValue)|"
                + "\(MatrixHead.facing(seed: seed))"
        }
        return "shape|\(form.rawValue)|\(look.rawValue)|\(specs.rawValue)|\(hat.rawValue)|\(mouth.rawValue)|\(blush ? 1 : 0)|"
            + "\(color.rawValue)|\(tile.rawValue)|\(form == .blob ? seed : 0)"
    }

    /// The head as the app draws it: its eyes and nothing else, and only the normal eyes (owner 2026-10-28: "only have
    /// eyes on their faces and only one kind of eyes - the normal ones"). Slits on a Shapes or dot-matrix head, no
    /// glasses, mouth, cheeks or hat; a drawn theme's record as `HeadRecord.plain`. The saved record keeps its fields,
    /// and the drawers stay the web's.
    var plain: Head {
        var head = self
        head.look = .slits
        head.specs = .none
        head.hat = .none
        head.mouth = .none
        head.blush = false
        head.themed = themed?.plain
        return head
    }
}

/// mulberry32, exactly as `seededRandom` in `head.ts:190-197` (32-bit wrapping arithmetic).
nonisolated struct SeededRandom: Sendable {
    private var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
}

/// How a head is posed: idle at rest; thinking/speaking while its bot works (spec 02 §10.4 item 5).
nonisolated enum HeadState: String, Hashable, Sendable { case idle, thinking, speaking, done, offline }
