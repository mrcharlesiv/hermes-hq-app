// A head as the gateway stores it (spec 1x-settings §7): every field of the web's v6 head, not just the Shapes fields
// the native renderer draws, so a save writes exactly what the web would (`storedHead`) and a seeded idea or Shuffle
// draws the same `random()` sequence as `rollHead`. Ported from `S/ui-heads/head.ts`, `labels.ts` and `topics.ts`.
// Pure value code.

import Foundation

nonisolated struct HeadRecord: Hashable, Sendable {
    static let version = 6
    /// `matrix` is native only (MatrixHead.swift); the web, and builds before it, read a saved one as a robot.
    static let themes = ["robot", "persona", "dots", "orb", "pixel", "glyph", "shape", "matrix"]
    static let shapes = ["dome", "blob", "puff", "pebble", "shield", "diamond", "cat", "ghost", "cloud", "heart", "star", "drop"]
    static let offeredShapes = Array(shapes.prefix(8))
    static let faces = ["visor", "pill", "dots", "surprised", "happy", "content", "wink", "sleepy", "bars", "side", "angry",
                        "worried", "heart", "sparkle", "dizzy", "scanner"]
    static let visors = ["band", "goggles", "screen", "none"]
    static let shells = ["ink", "color", "duo", "chrome"]
    static let colors = ["ink", "mint", "teal", "sky", "lilac", "pink", "coral", "peach", "butter", "lime", "paper",
                         "red", "grass", "forest", "cobalt", "denim", "grape", "plum", "magenta", "rose", "wine", "caramel", "cocoa", "slate"]
    static let themeColors = Array(colors.prefix(11))
    /// The editor's order, six to a row (`SHAPE_COLORS`).
    static let shapeColors = ["red", "coral", "peach", "butter", "lime", "grass", "mint", "teal", "sky", "cobalt", "lilac", "grape",
                              "rose", "pink", "magenta", "plum", "denim", "forest", "wine", "cocoa", "caramel", "ink", "slate", "paper"]
    static let antennas = ["none", "bulb", "twin", "bolt", "ring"]
    static let ears = ["none", "headset", "bolts", "fins"]
    static let mouths = ["none", "smile", "open", "cat", "grille"]
    static let hairs = ["bob", "long", "twin", "pixie", "buns", "pony"]
    static let patterns = ["face", "grid", "bloom", "ring", "spark", "wave"]
    static let tiles = ["dark", "light", "color", "none"]
    static let forms = ["round", "blob", "square", "pill", "triangle", "hex", "cloud", "drop", "star", "heart"]
    static let looks = ["slits", "dots", "ovals", "googly", "happy", "sleepy", "stars", "hearts"]
    static let specsList = ["none", "shades", "aviators", "round", "monocle"]
    /// A dot-matrix head's outlines, in the `form` field (native only, MatrixHead.swift).
    static let outlines = MatrixDesign.Silhouette.allCases.map(\.rawValue)
    static let hats = ["none", "crown", "halo", "sprout", "party", "bow", "beanie"]
    static let glyphs = ["✨", "🦊", "🧠", "🛰️", "🌵", "🐙", "⚡️", "🍋", "🪐", "🔧", "📚", "🎧", "🦉", "🧪", "🚀", "🎨", "🧭", "🫧"]

    // ICON_HEAD (`head.ts:97-100`) is the default value of every field.
    var theme = "robot"
    var color = "ink"
    var seed = 1
    var shape = "dome"
    var face = "visor"
    var visor = "band"
    var shell = "ink"
    var antenna = "bulb"
    var ears = "headset"
    var mouth = "none"
    var blush = false
    var hair = "bob"
    var pattern = "face"
    var tile = "dark"
    var eyes = true
    var glyph = "✨"
    var form = "round"
    var look = "slits"
    var specs = "none"
    var hat = "none"

    static let icon = HeadRecord()

    // MARK: parseHead (`head.ts:122-160`)

    static func parse(_ raw: JSONValue?) -> HeadRecord? {
        guard case .object(let value)? = raw else { return nil }
        func known(_ list: [String], _ field: JSONValue?) -> Bool { field?.string.map(list.contains) ?? false }
        guard known(themes, value["theme"]) || known(shapes, value["shape"]) || known(faces, value["face"]) else { return nil }
        func pick(_ list: [String], _ field: String, _ fallback: String) -> String {
            if let s = value[field]?.string, list.contains(s) { return s }
            return fallback
        }
        var head = HeadRecord()
        if case .number(let n)? = value["seed"], n.isFinite, n.rounded(.towardZero) == n {
            head.seed = Int(min(max(n, 1), 2147483647))
        } else {
            head.seed = 1
        }
        head.theme = pick(themes, "theme", "robot")
        head.color = pick(colors, "color", "mint")
        head.shape = pick(shapes, "shape", "blob")
        head.face = pick(faces, "face", "pill")
        head.visor = pick(visors, "visor", "band")
        head.shell = pick(shells, "shell", "ink")
        head.antenna = pick(antennas, "antenna", "none")
        head.ears = pick(ears, "ears", value["headset"] == .bool(true) ? "headset" : "none")
        head.mouth = pick(mouths, "mouth", "none")
        head.blush = value["blush"] == .bool(true)
        head.hair = pick(hairs, "hair", "bob")
        head.pattern = pick(patterns, "pattern", "face")
        head.tile = pick(tiles, "tile", "dark")
        head.eyes = value["eyes"] != .bool(false)
        head.glyph = cleanGlyph(value["glyph"])
        // A dot-matrix head's form is one of its outlines (a Shapes name saved by build 378 reads as the nearest one).
        head.form = head.theme == "matrix" ? MatrixDesign.Silhouette(stored: value["form"]?.string ?? "round").rawValue
            : pick(forms, "form", "round")
        head.look = pick(looks, "look", "slits")
        head.specs = pick(specsList, "specs", "none")
        head.hat = pick(hats, "hat", "none")
        let version = value["v"]?.double ?? 0
        if head.theme == "dots", head.pattern == "face", !(version >= 4) {
            let seedFaces: [(String, String)] = [("pill", "smile"), ("happy", "smile"), ("surprised", "open"), ("wink", "smile"),
                                                 ("sleepy", "grille"), ("pill", "cat")]
            var random = SeededRandom(seed: UInt32(truncatingIfNeeded: head.seed))
            _ = random.next()
            let pickFace = seedFaces[Int((random.next() * Double(seedFaces.count)).rounded(.down))]
            head.face = pickFace.0
            head.mouth = pickFace.1
        }
        if head.theme == "shape", !(version >= 5) { head.mouth = "none"; head.blush = false }
        if head.theme == "shape", !(version >= 6) { head.tile = "none" }
        return head
    }

    /// One emoji, or up to two letters (`cleanGlyph`).
    static func cleanGlyph(_ raw: JSONValue?) -> String {
        guard case .string(let text)? = raw else { return icon.glyph }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let utf16 = Array(trimmed.utf16.prefix(64))
        let cut = String(decoding: utf16, as: UTF16.self)
        let parts = cut.map { String($0) }
        if let emoji = parts.first(where: isEmoji) { return emoji }
        let letters = parts.filter { part in
            part.unicodeScalars.count == 1 && part.unicodeScalars.allSatisfy {
                switch $0.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                     .decimalNumber, .letterNumber, .otherNumber: return true
                default: return false
                }
            }
        }
        let joined = letters.prefix(2).joined()
        return joined.isEmpty ? icon.glyph : joined
    }

    static func isEmoji(_ part: String) -> Bool {
        part.unicodeScalars.contains { $0.value > 0x7F && $0.properties.isEmoji }
    }

    /// `headKey` (`head.ts:167-181`): one string per distinct picture; fields a theme doesn't draw are left out.
    var pictureKey: String {
        let b = blush ? 1 : 0
        switch theme {
        case "robot":
            let soft = shape == "blob" || shape == "cloud" ? seed : 0
            return "robot|\(shape)|\(face)|\(visor)|\(shell)|\(color)|\(antenna)|\(ears)|\(mouth)|\(b)|\(soft)"
        case "persona": return "persona|\(hair)|\(face)|\(shell)|\(color)|\(ears)|\(mouth)|\(b)|\(tile)"
        case "dots":
            return pattern == "face" ? "dots|face|\(face)|\(mouth)|\(b)|\(color)|\(tile)"
                : "dots|\(pattern)|\(color)|\(tile)|\(eyes ? 1 : 0)|\(seed)"
        case "orb": return "orb|\(color)|\(tile)|\(eyes ? 1 : 0)|\(seed)"
        case "pixel": return "pixel|\(color)|\(tile)|\(seed)"
        case "glyph": return "glyph|\(glyph)|\(color)|\(tile)"
        case "matrix": return "matrix|\(MatrixDesign.Silhouette(stored: form).rawValue)|\(look)|\(mouth)|\(b)|\(color)|\(facing)"
        default:
            return "shape|\(form)|\(look)|\(specs)|\(hat)|\(mouth)|\(b)|\(color)|\(tile)|\(form == "blob" ? seed : 0)"
        }
    }

    /// `storedHead(head)`: every field, `v: 6`, plus `headset` for builds from before Ears.
    var stored: JSONValue {
        .object([
            "v": .number(Double(Self.version)), "theme": .string(theme), "color": .string(color), "seed": .number(Double(seed)),
            "shape": .string(shape), "face": .string(face), "visor": .string(visor), "shell": .string(shell),
            "antenna": .string(antenna), "ears": .string(ears), "mouth": .string(mouth), "blush": .bool(blush),
            "hair": .string(hair), "pattern": .string(pattern), "tile": .string(tile), "eyes": .bool(eyes),
            "glyph": .string(glyph), "form": .string(form), "look": .string(look), "specs": .string(specs),
            "hat": .string(hat), "headset": .bool(ears == "headset"),
        ])
    }

    /// The record a save writes (spec §7.5–7.6): never a hat, and never Character (the owner removed it), which
    /// becomes a Shapes head. A dot-matrix head's is its outline, with no visor, antenna or ears (build 378 saved them).
    var forSaving: HeadRecord {
        var record = theme == "persona" ? themedAsShape : self
        record.hat = "none"
        if record.theme == "matrix" {
            record.form = MatrixDesign.Silhouette(stored: record.form).rawValue
            record.specs = "none"
            record.antenna = "none"
            record.ears = "none"
        }
        return record
    }

    /// The picture the native renderer draws for this record.
    var head: Head {
        Head(record: forSaving) ?? Head.defaultHead(profile: "default")
    }

    /// `Head.plain` for a record: a robot's own icon eyes, a Dots face's two tall lamp eyes (its "visor" is a bar of
    /// lamps, not eyes), slits on a Shapes or dot-matrix head; no mouth, cheeks or glasses. A pixel creature's random
    /// mouth and cheeks are left out where it is drawn (`ThemeHeadSVG.svg(plain:)`).
    var plain: HeadRecord {
        var record = self
        record.face = theme == "dots" ? "pill" : "visor"
        record.mouth = "none"
        record.blush = false
        record.look = "slits"
        record.specs = "none"
        record.hat = "none"
        return record
    }

    /// Copies a native head's Shapes fields in (a strip pick).
    mutating func setShapes(from head: Head) {
        theme = "shape"
        color = head.color.rawValue
        seed = head.seed
        form = head.form.rawValue
        look = head.look.rawValue
        specs = head.specs.rawValue
        mouth = head.mouth.rawValue
        blush = head.blush
        tile = head.tile.rawValue
        hat = "none"
    }

    /// Copies a dot-matrix head's fields in: its outline in `form`, no glasses, and no antenna or ears on the robot the
    /// web (and builds from before the Matrix theme) draw for it. The other robot fields stay as they were.
    mutating func setMatrix(from head: Head) {
        theme = "matrix"
        color = head.color.rawValue
        seed = head.seed
        form = head.silhouette.rawValue
        look = head.look.rawValue
        specs = "none"
        mouth = head.mouth.rawValue
        blush = head.blush
        antenna = "none"
        ears = "none"
        tile = "none"
        hat = "none"
    }

    /// The record of the head a bot wears until it is given another (`Head.defaultHead`): its plain Shapes head.
    static func defaultRecord(profile: String) -> HeadRecord { defaultShapeRecord(profile: profile) }

    /// ICON_HEAD dressed as the name's dot-matrix head (`Head.defaultMatrixHead`).
    static func defaultMatrixRecord(profile: String) -> HeadRecord {
        var record = HeadRecord()
        record.setMatrix(from: Head.defaultMatrixHead(profile: profile))
        return record
    }

    /// `defaultHead(profile)`: ICON_HEAD dressed as the name's plain Shapes head (the web's default).
    static func defaultShapeRecord(profile: String) -> HeadRecord {
        var record = HeadRecord()
        record.setShapes(from: Head.defaultShapeHead(profile: profile))
        return record
    }

    /// Which way a dot-matrix head faces (bit 7 of its seed): −1 left, +1 right.
    var facing: Int {
        get { MatrixHead.facing(seed: seed) }
        set { if newValue != facing { seed = MatrixHead.turned(seed: seed) } }
    }

    /// A saved head in another theme becomes a Shapes head with no board (`themed`, the editor's opening rule).
    var themedAsShape: HeadRecord {
        var record = self
        if record.theme != "shape" { record.tile = "none" }
        if record.theme == "matrix" { record.form = MatrixDesign.Silhouette(stored: record.form).shapesForm }
        record.theme = "shape"
        return record
    }

    // MARK: rollHead (`head.ts:207-242`)

    private static func any<T>(_ random: () -> Double, _ list: [T]) -> T {
        list[Int((random() * Double(list.count)).rounded(.down))]
    }

    private static func weighted(_ random: () -> Double, _ list: [(String, Double)]) -> String {
        var left = random() * list.reduce(0) { $0 + $1.1 }
        for (value, weight) in list {
            left -= weight
            if left < 0 { return value }
        }
        return list[0].0
    }

    /// A fresh head in a theme, drawing `random()` in exactly the web's order (robot fields first). Hats are drawn (so
    /// the sequence matches) and then dropped.
    static func roll(_ random: () -> Double, theme: String = "shape") -> HeadRecord {
        let persona = theme == "persona"
        var head = HeadRecord()
        head.theme = theme
        head.color = any(random, theme == "shape" ? shapeColors : themeColors)
        head.seed = 1 + Int((random() * 1e6).rounded(.down))
        head.shape = any(random, offeredShapes)
        head.face = persona
            ? weighted(random, [("visor", 5), ("happy", 2), ("content", 1.5), ("wink", 1.5), ("surprised", 1), ("side", 1), ("sleepy", 0.8),
                                ("sparkle", 0.8), ("angry", 0.6), ("worried", 0.6), ("heart", 0.5)])
            : weighted(random, [("visor", 3), ("pill", 3), ("dots", 2), ("happy", 2), ("content", 1.5), ("bars", 1.2), ("side", 1),
                                ("wink", 1), ("angry", 0.8), ("worried", 0.8), ("surprised", 1), ("sleepy", 0.8), ("sparkle", 0.7),
                                ("heart", 0.5), ("dizzy", 0.4), ("scanner", 0.8)])
        head.visor = weighted(random, [("band", 5), ("goggles", 2), ("screen", 2), ("none", 1)])
        head.shell = persona ? weighted(random, [("ink", 4), ("color", 4), ("chrome", 1.5), ("duo", 2)])
            : weighted(random, [("ink", 5), ("color", 2), ("duo", 1.5), ("chrome", 1)])
        head.antenna = weighted(random, [("bulb", 4), ("none", 2.5), ("twin", 1.5), ("bolt", 1), ("ring", 1)])
        head.ears = weighted(random, [("none", 4), ("headset", 3), ("bolts", 1.5), ("fins", 1.5)])
        head.mouth = persona ? weighted(random, [("smile", 4), ("none", 2), ("cat", 1.5), ("open", 1)])
            : weighted(random, [("none", 7), ("smile", 1.5), ("grille", 1), ("open", 0.5), ("cat", 0.5)])
        head.blush = random() < (persona ? 0.5 : 0.15)
        head.hair = any(random, hairs)
        head.pattern = any(random, patterns)
        head.tile = weighted(random, [("dark", 3), ("light", 2), ("color", 2)])
        head.eyes = random() < 0.5
        head.glyph = any(random, glyphs)
        head.form = any(random, forms)
        head.look = weighted(random, [("slits", 6), ("dots", 2), ("ovals", 2)])
        head.specs = "none"
        head.hat = "none"
        if theme == "shape" {
            head.tile = weighted(random, [("none", 8), ("dark", 1.5), ("color", 1), ("light", 0.5)])
            head.look = weighted(random, [("slits", 5), ("dots", 1.5), ("ovals", 1.5), ("googly", 1.5), ("happy", 1), ("sleepy", 0.7),
                                          ("stars", 0.6), ("hearts", 0.6)])
            head.specs = weighted(random, [("none", 6), ("shades", 1.5), ("aviators", 0.7), ("round", 0.9), ("monocle", 0.5)])
            _ = weighted(random, [("none", 5), ("crown", 1), ("halo", 0.8), ("sprout", 1), ("party", 0.8), ("bow", 0.8), ("beanie", 0.8)])
            head.hat = "none"
            head.mouth = weighted(random, [("none", 5), ("smile", 2.5), ("open", 0.7), ("cat", 0.7), ("grille", 0.5)])
            head.blush = random() < 0.25
        }
        if theme == "dots" {
            if random() < 0.45 { head.pattern = "face" }
            head.mouth = weighted(random, [("smile", 4), ("none", 2), ("cat", 1), ("open", 1), ("grille", 1)])
            head.blush = random() < 0.2
        }
        if theme == "matrix" {
            // Native only: drawn after every other field, so the other themes' sequences are the web's. Every outline
            // equally; no glasses, antenna or ears.
            head.color = any(random, shapeColors.filter { $0 != "slate" && $0 != "paper" })
            head.tile = "none"
            head.form = any(random, outlines)
            head.look = weighted(random, [("slits", 5), ("ovals", 2), ("dots", 2), ("happy", 1), ("googly", 1), ("sleepy", 0.7),
                                          ("stars", 0.6), ("hearts", 0.6)])
            head.specs = "none"
            head.antenna = "none"
            head.ears = "none"
            // Drawn and dropped, like the hat: a dot-matrix head has no mouth (MatrixDesign).
            _ = weighted(random, [("none", 6), ("smile", 2), ("open", 0.6), ("cat", 0.6), ("grille", 0.6)])
            head.mouth = "none"
            head.blush = random() < 0.15
        }
        return head
    }

    /// `ideasFor(theme, about, random, count)`: fresh heads; the first half take what the bot is about (a Shapes head
    /// keeps its rolled backdrop).
    static func ideas(theme: String = "shape", about: String, random: () -> Double, count: Int = 10) -> [HeadRecord] {
        let topic = HeadTopics.topic(for: about)
        let half = Int((Double(count) / 2).rounded(.up))
        return (0..<count).map { index in
            var head = roll(random, theme: theme)
            guard let topic, index < half else { return head }
            let tile = head.tile
            head.apply(topic)
            head.theme = theme
            if theme == "shape" || theme == "matrix" { head.tile = tile }
            if theme == "matrix" { head.applyMatrix(topic, outline: index == 0) }
            return head
        }
    }

    /// The editor's seeded ideas for a bot: `seededRandom(nameHash("<profile>|<theme>|<round>"))`.
    static func ideas(profile: String, about: String, round: Int, theme: String = "shape") -> [HeadRecord] {
        var random = SeededRandom(seed: max(Head.nameHash("\(profile)|\(theme)|\(round)"), 0))
        return ideas(theme: theme, about: about, random: { random.next() })
    }

    mutating func apply(_ parts: [String: String]) {
        for (key, value) in parts {
            switch key {
            case "glyph": glyph = value
            case "color": color = value
            case "face": face = value
            case "pattern": pattern = value
            case "visor": visor = value
            case "hair": hair = value
            case "ears": ears = value
            case "mouth": mouth = value
            case "shape": shape = value
            case "antenna": antenna = value
            case "tile": tile = value
            default: break
            }
        }
    }

    /// A topic's robot words as a dot-matrix head's parts: the eyes it suits and, with `outline` (the first idea, so
    /// the rest keep their own), the outline (a guard's shield, a gardener's leaf, a forecaster's cloud). The robot's
    /// antenna and ears and any mouth the topic set stay off.
    mutating func applyMatrix(_ topic: [String: String], outline: Bool) {
        let outlines = ["🛡️": "shield", "🌵": "leaf", "⛅️": "cloud", "🌙": "cloud", "🪐": "round", "🧭": "round", "💻": "square",
                        "📊": "square", "📅": "square", "✉️": "wide", "🕹️": "wide", "🏡": "arch", "🚀": "drop", "🍳": "pebble",
                        "🛠️": "hex"]
        if outline, let glyph = topic["glyph"], let form = outlines[glyph] { self.form = form }
        antenna = "none"
        ears = "none"
        mouth = "none"
        let looks = ["happy": "happy", "sleepy": "sleepy", "heart": "hearts", "sparkle": "stars", "dots": "dots", "surprised": "ovals"]
        if let face = topic["face"], let look = looks[face] { self.look = look }
    }

    /// My Style applied to this bot: the style's look, this bot's colour, seed and glyph.
    func applyingStyle(_ style: HeadRecord) -> HeadRecord {
        var next = style
        next.color = color
        next.seed = seed
        next.glyph = glyph
        next.hat = "none"
        return next.forSaving
    }

    // MARK: The desktop copy (`mirror.ts`)

    static let mirrorSize = 288

    /// Whether an avatar data URL is this app's own copy of a head: a PNG whose IHDR says exactly 288 × 288.
    static func isHeadMirror(_ dataURL: String?) -> Bool {
        let prefix = "data:image/png;base64,"
        guard let dataURL, dataURL.hasPrefix(prefix) else { return false }
        let head = String(dataURL.dropFirst(prefix.count).prefix(32))
        guard let bytes = Data(base64Encoded: head), bytes.count >= 24 else { return false }
        func int(_ at: Int) -> UInt32 {
            bytes[bytes.startIndex + at..<bytes.startIndex + at + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        return int(16) == UInt32(mirrorSize) && int(20) == UInt32(mirrorSize)
    }

    /// A copy that desktop should draw inverted on a dark page carries this PNG text chunk ("hermes-hq" =
    /// "invert-on-dark") straight after the 33-byte header, so its data URL always holds these exact characters. The
    /// Hermes HQ desktop theme matches them (`scripts/desktop-theme/global.css`); every image decoder skips the chunk.
    static let darkFlipMark = "AAAAGHRFWHRoZXJtZXMtaHEAaW52ZXJ0LW9uLWRhcmu4VO/y"

    /// `png` with `darkFlipMark` after its header; unchanged when it isn't a PNG.
    static func withDarkFlipMark(_ png: Data) -> Data {
        let header = 33
        guard png.count > header, png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let chunk = Data(base64Encoded: darkFlipMark) else { return png }
        return png.prefix(header) + chunk + png.dropFirst(header)
    }
}

/// What a bot is about, from its name and description (`S/ui-heads/topics.ts`): the parts that suit it.
nonisolated enum HeadTopics {
    static let entries: [(JSRegex, [String: String])] = [
        (JSRegex(#"\b(deploy\w*|ship\w*|release\w*|launch\w*|ci|cd|build\w*|pipeline)\b"#), ["glyph": "🚀", "color": "coral", "face": "scanner", "pattern": "ring"]),
        (JSRegex(#"\b(mail|inbox|email\w*|letter\w*|repl(y|ies))\b"#), ["glyph": "✉️", "color": "sky", "face": "content", "pattern": "wave"]),
        (JSRegex(#"\b(research\w*|paper\w*|stud(y|ies)|scholar\w*|read\w*|librar\w*|book\w*)\b"#), ["glyph": "📚", "color": "lilac", "visor": "goggles", "face": "pill", "hair": "long"]),
        (JSRegex(#"\b(code\w*|coding|dev\w*|engineer\w*|program\w*|bug\w*|debug\w*|review\w*|repo\w*)\b"#), ["glyph": "💻", "color": "teal", "visor": "screen", "face": "bars", "pattern": "grid"]),
        (JSRegex(#"\b(writ\w*|draft\w*|blog\w*|editor\w*|copy|muse|idea\w*|stor(y|ies)|poet\w*)\b"#), ["glyph": "✍️", "color": "pink", "face": "sparkle", "pattern": "bloom"]),
        (JSRegex(#"\b(ops|server\w*|infra\w*|sysadmin|devops|home\s?lab|network\w*|monitor\w*|uptime)\b"#), ["glyph": "🛠️", "color": "butter", "ears": "bolts", "face": "bars", "pattern": "grid"]),
        (JSRegex(#"\b(garden\w*|plant\w*|water\w*|farm\w*|green\w*|grow\w*)\b"#), ["glyph": "🌵", "color": "lime", "face": "happy", "pattern": "bloom"]),
        (JSRegex(#"\b(money|financ\w*|budget\w*|ledger|account\w*|invoice\w*|tax\w*|bank\w*|trad\w*)\b"#), ["glyph": "💰", "color": "butter", "visor": "goggles", "face": "side"]),
        (JSRegex(#"\b(music|song\w*|playlist\w*|audio|podcast\w*|dj)\b"#), ["glyph": "🎧", "color": "lilac", "ears": "headset", "face": "content", "pattern": "wave"]),
        (JSRegex(#"\b(calendar|schedul\w*|meeting\w*|plan\w*|agenda|remind\w*|todo\w*|task\w*)\b"#), ["glyph": "📅", "color": "peach", "face": "pill", "pattern": "ring"]),
        (JSRegex(#"\b(news|headline\w*|press|brief\w*|digest)\b"#), ["glyph": "📰", "color": "paper", "visor": "goggles", "face": "side"]),
        (JSRegex(#"\b(travel\w*|trip\w*|flight\w*|map\w*|route\w*|navigat\w*)\b"#), ["glyph": "🧭", "color": "sky", "face": "surprised", "pattern": "spark"]),
        (JSRegex(#"\b(health|fitness|workout\w*|running|gym|diet)\b"#), ["glyph": "💪", "color": "mint", "face": "happy"]),
        (JSRegex(#"\b(cook\w*|food|recipe\w*|kitchen|meal\w*|chef)\b"#), ["glyph": "🍳", "color": "peach", "face": "happy", "mouth": "smile"]),
        (JSRegex(#"\b(night\w*|dream\w*|moon|late)\b"#), ["glyph": "🌙", "color": "lilac", "face": "sleepy", "tile": "dark"]),
        (JSRegex(#"\b(secur\w*|guard\w*|watch\w*|audit\w*|sentinel|firewall)\b"#), ["glyph": "🛡️", "color": "ink", "face": "angry", "shape": "shield", "visor": "band"]),
        (JSRegex(#"\b(data|analy\w*|report\w*|metric\w*|chart\w*|stat\w*|sql)\b"#), ["glyph": "📊", "color": "teal", "visor": "screen", "face": "dots", "pattern": "grid"]),
        (JSRegex(#"\b(support|help\w*|chat\w*|customer\w*|concierge|assist\w*)\b"#), ["glyph": "💬", "color": "mint", "ears": "headset", "face": "happy", "mouth": "smile", "pattern": "face"]),
        (JSRegex(#"\b(shop\w*|order\w*|store|cart|deliver\w*|grocer\w*)\b"#), ["glyph": "🛒", "color": "coral", "face": "pill"]),
        (JSRegex(#"\b(photo\w*|image\w*|design\w*|art|draw\w*|paint\w*|creativ\w*)\b"#), ["glyph": "🎨", "color": "pink", "face": "sparkle", "pattern": "bloom", "hair": "buns"]),
        (JSRegex(#"\b(scien\w*|lab|experiment\w*|chem\w*|physic\w*|math\w*)\b"#), ["glyph": "🧪", "color": "lime", "visor": "goggles", "face": "surprised"]),
        (JSRegex(#"\b(space|astro\w*|orbit\w*|star\w*|planet\w*|satellite)\b"#), ["glyph": "🪐", "color": "lilac", "antenna": "ring", "face": "sparkle", "pattern": "spark", "tile": "dark"]),
        (JSRegex(#"\b(scout\w*|search\w*|find\w*|explor\w*|hunt\w*|crawl\w*)\b"#), ["glyph": "🔭", "color": "teal", "visor": "goggles", "antenna": "twin", "face": "side"]),
        (JSRegex(#"\b(game\w*|play\w*|arcade|retro)\b"#), ["glyph": "🕹️", "color": "pink", "face": "happy", "visor": "screen"]),
        (JSRegex(#"\b(home|house|family|kid\w*|chore\w*)\b"#), ["glyph": "🏡", "color": "peach", "face": "happy"]),
        (JSRegex(#"\b(weather|rain\w*|storm\w*|forecast\w*)\b"#), ["glyph": "⛅️", "color": "sky", "antenna": "bolt", "face": "content"]),
        (JSRegex(#"\b(learn\w*|teach\w*|tutor\w*|school|class\w*|language\w*)\b"#), ["glyph": "🎓", "color": "butter", "visor": "goggles", "face": "pill", "hair": "pony"]),
    ]

    private static let apostrophes = JSRegex(#"[’']"#)
    private static let nonWords = JSRegex(#"[^\p{L}\p{N}\s.-]+"#)

    /// `plain`: lower case, apostrophes gone, anything but letters, digits, spaces, "." and "-" as a space.
    static func plain(_ text: String) -> String { nonWords.replaceAll(apostrophes.replaceAll(text.lowercased(), ""), " ") }

    static func topic(for about: String) -> [String: String]? {
        let text = plain(about)
        return entries.first { $0.0.test(text) }?.1
    }
}

/// The names the editor shows (`S/ui-heads/labels.ts`).
nonisolated enum HeadLabels {
    static let forms: [String: String] = ["round": "Round", "blob": "Blob", "square": "Square", "pill": "Pill", "triangle": "Triangle",
                                          "hex": "Hex", "cloud": "Cloud", "drop": "Drop", "star": "Star", "heart": "Heart"]
    static let looks: [String: String] = ["slits": "Slits", "dots": "Dots", "ovals": "Ovals", "googly": "Googly", "happy": "Happy",
                                          "sleepy": "Sleepy", "stars": "Stars", "hearts": "Hearts"]
    static let specs: [String: String] = ["none": "None", "shades": "Shades", "aviators": "Aviators", "round": "Round", "monocle": "Monocle"]
    /// A Shapes head's mouth names (`DOT_MOUTHS`: the grille is a line).
    static let mouths: [String: String] = ["none": "None", "smile": "Smile", "open": "Oh", "cat": "Cat", "grille": "Line"]
    static let colors: [String: String] = [
        "ink": "Ink", "mint": "Mint", "teal": "Teal", "sky": "Sky", "lilac": "Lilac", "pink": "Bubblegum", "coral": "Coral",
        "peach": "Peach", "butter": "Butter", "lime": "Lime", "paper": "Paper", "red": "Red", "grass": "Grass", "forest": "Forest",
        "cobalt": "Cobalt", "denim": "Denim", "grape": "Grape", "plum": "Plum", "magenta": "Magenta", "rose": "Rose", "wine": "Wine",
        "caramel": "Caramel", "cocoa": "Cocoa", "slate": "Slate",
    ]
    static let tiles: [String: String] = ["dark": "Dark", "light": "Light", "color": "Color", "none": "None"]
    /// A dot-matrix head's outline names (in the `form` field).
    static let outlines: [String: String] = ["round": "Round", "square": "Square", "tall": "Tall", "wide": "Wide", "pebble": "Pebble",
                                             "cloud": "Cloud", "arch": "Arch", "shield": "Shield", "drop": "Drop", "leaf": "Leaf",
                                             "hex": "Hex", "octagon": "Octagon", "heart": "Heart"]
    static let themes: [String: String] = ["robot": "Robot", "persona": "Character", "dots": "Dots", "orb": "Orb", "pixel": "Pixel",
                                           "glyph": "Emoji", "shape": "Shapes", "matrix": "Matrix"]
    /// The themes the editor offers, in its order (Character was removed by the owner; Shapes, every bot's own head
    /// until it is given another, leads).
    static let offeredThemes = ["shape", "matrix", "robot", "dots", "orb", "pixel", "glyph"]
    static let facings: [String: String] = ["left": "Left", "right": "Right"]
    static let shapes: [String: String] = ["dome": "Hermes HQ", "blob": "Round", "puff": "Block", "pebble": "Wide", "shield": "Bucket",
                                           "diamond": "Hex", "cat": "Cat", "ghost": "Ghost", "cloud": "Cloud", "heart": "Heart",
                                           "star": "Star", "drop": "Drop"]
    static let faces: [String: String] = ["visor": "Bright", "pill": "Beans", "dots": "Dots", "surprised": "Wide", "happy": "Happy",
                                          "content": "Content", "wink": "Wink", "sleepy": "Sleepy", "bars": "Deadpan", "side": "Side-Eye",
                                          "angry": "Grumpy", "worried": "Worried", "heart": "Smitten", "sparkle": "Sparkle",
                                          "dizzy": "Dizzy", "scanner": "Scanner"]
    /// A lamp face's eyes (`DOT_FACES`: its visor is a band).
    static let dotFaces: [String: String] = faces.merging(["visor": "Visor"]) { $1 }
    static let visors: [String: String] = ["band": "Visor", "goggles": "Goggles", "screen": "Screen", "none": "None"]
    static let shells: [String: String] = ["ink": "Ink", "color": "Color", "duo": "Two-Tone", "chrome": "Chrome"]
    static let antennas: [String: String] = ["none": "None", "bulb": "Bulb", "twin": "Twin", "bolt": "Bolt", "ring": "Halo"]
    static let ears: [String: String] = ["none": "None", "headset": "Headset", "bolts": "Bolts", "fins": "Fins"]
    /// A robot's mouth names (`MOUTH_LABELS`: the grille is a grille).
    static let robotMouths: [String: String] = ["none": "None", "smile": "Smile", "open": "Oh", "cat": "Cat", "grille": "Grille"]
    static let patterns: [String: String] = ["face": "Face", "grid": "Ripple", "bloom": "Bloom", "ring": "Ring", "spark": "Spark", "wave": "Voice"]

    /// A head in a few words for VoiceOver ("Robot, Teal, Wink"): its theme, its colour and the theme's main part.
    static func summary(_ head: HeadRecord) -> String {
        let part: String? = switch head.theme {
        case "robot": shapes[head.shape]
        case "dots": patterns[head.pattern]
        case "glyph": head.glyph
        case "shape": forms[head.form]
        case "matrix": outlines[head.form]
        default: nil
        }
        return ([themes[head.theme] ?? head.theme, colors[head.color] ?? head.color] + [part].compactMap { $0 }).joined(separator: ", ")
    }
}
