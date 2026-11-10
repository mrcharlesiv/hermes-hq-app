// "Describe it" (`S/ui-heads/describe.ts`): a few typed words turned into head parts, entirely on the phone. It reads
// the words it knows (a theme, a colour, a head, eyes, extras, a subject) and ignores the rest. Pure value code.

import Foundation

nonisolated enum HeadDescribe {
    /// What the words asked for, and the words understood as people would say them ("Got it: …").
    struct Described: Equatable {
        var parts: [String: String]
        var understood: [String]
    }

    static let topicNames = ["shipping", "mail", "reading", "code", "writing", "ops", "plants", "money", "music", "planning", "news",
                             "travel", "health", "food", "night", "security", "data", "support", "shopping", "art", "science", "space",
                             "scouting", "games", "home", "weather", "learning"]

    /// The words a description can use. Order matters where one phrase contains another.
    static let words: [(JSRegex, [String: String], String)] = [
        // themes (Character is not offered: its words pick nothing)
        (JSRegex(#"\b(robot\w*|bot|android|mech\w*)\b"#), ["theme": "robot"], "robot"),
        (JSRegex(#"\b(dots?|lamps?)\b"#), ["theme": "dots"], "dots"),
        // After Dots, so "dot matrix" is a dot-matrix head (a later word wins).
        (JSRegex(#"\b(matrix|leds?)\b"#), ["theme": "matrix"], "matrix"),
        (JSRegex(#"\b(orb|ball|sphere|bubble|glass|marble|aura)\b"#), ["theme": "orb"], "orb"),
        (JSRegex(#"\b(pixel\w*|8.?bit|sprite|creature|monster|alien|invader|critter)\b"#), ["theme": "pixel"], "pixel"),
        (JSRegex(#"\b(emoji|letters?|initials?|monogram)\b"#), ["theme": "glyph"], "emoji"),
        (JSRegex(#"\b(shapes?|grok|geometric)\b"#), ["theme": "shape"], "shapes"),
        // colours
        (JSRegex(#"\b(purple|violet|lilac|lavender)\b"#), ["color": "lilac"], "purple"),
        (JSRegex(#"\b(blue|sky|azure|navy)\b"#), ["color": "sky"], "blue"),
        (JSRegex(#"\b(teal|cyan|aqua|turquoise)\b"#), ["color": "teal"], "teal"),
        (JSRegex(#"\b(mint|seafoam)\b"#), ["color": "mint"], "mint"),
        (JSRegex(#"\b(green|lime)\b"#), ["color": "lime"], "green"),
        (JSRegex(#"\b(red|coral|crimson|scarlet)\b"#), ["color": "coral"], "red"),
        (JSRegex(#"\b(orange|peach|amber)\b"#), ["color": "peach"], "orange"),
        (JSRegex(#"\b(yellow|gold\w*|butter)\b"#), ["color": "butter"], "yellow"),
        (JSRegex(#"\b(pink|rose|magenta|bubblegum)\b"#), ["color": "pink"], "pink"),
        (JSRegex(#"\b(white|cream|paper|beige|ivory)\b"#), ["color": "paper"], "white"),
        (JSRegex(#"\b(black|ink|noir)\b"#), ["color": "ink"], "black"),
        // robot heads
        (JSRegex(#"\b(cat|kitty|kitten|feline)\b"#), ["shape": "cat", "mouth": "cat"], "cat"),
        // heads (a Shapes head's word sets its form; a robot's, its head)
        (JSRegex(#"\b(triangle\w*|pyramid)\b"#), ["form": "triangle"], "triangle"),
        (JSRegex(#"\b(cloud\w*|fluffy)\b"#), ["form": "cloud"], "cloud"),
        (JSRegex(#"\b(drop\w*|droplet|tear\w*)\b"#), ["form": "drop"], "drop"),
        (JSRegex(#"\b(blob\w*|bean)\b"#), ["form": "blob"], "blob"),
        (JSRegex(#"\b(pill|capsule)\b"#), ["form": "pill", "shape": "pebble"], "pill"),
        (JSRegex(#"\b(ghost|spooky|phantom)\b"#), ["shape": "ghost", "outline": "arch"], "ghost"),
        (JSRegex(#"\b(round|ball.?head|circle)\b"#), ["shape": "blob", "form": "round"], "round"),
        (JSRegex(#"\b(square|block\w*|boxy|box|tv)\b"#), ["shape": "puff", "form": "square"], "block"),
        (JSRegex(#"\b(wide|flat)\b"#), ["shape": "pebble", "outline": "wide"], "wide"),
        (JSRegex(#"\b(bucket)\b"#), ["shape": "shield"], "bucket"),
        (JSRegex(#"\b(hex\w*|gem)\b"#), ["shape": "diamond", "form": "hex"], "hex"),
        (JSRegex(#"\b(dispatch|hermes|classic|original|logo)\b"#), ["shape": "dome", "face": "visor", "visor": "band"], "Hermes HQ"),
        // a dot-matrix head's own outlines (native only; the Shapes words above give it the nearest outline)
        (JSRegex(#"\b(lanky|tall head|long face)\b"#), ["outline": "tall"], "tall"),
        (JSRegex(#"\b(pebble|stone|egg)\b"#), ["outline": "pebble"], "pebble"),
        (JSRegex(#"\b(arch|arched|tombstone)\b"#), ["outline": "arch"], "arch"),
        (JSRegex(#"\b(shield|badge|crest)\b"#), ["outline": "shield"], "shield"),
        (JSRegex(#"\b(leaf|leafy|petal)\b"#), ["outline": "leaf"], "leaf"),
        (JSRegex(#"\b(octagon\w*|stop.?sign)\b"#), ["outline": "octagon"], "octagon"),
        // eyes
        (JSRegex(#"\b(sleepy|tired|drowsy|asleep)\b"#), ["face": "sleepy", "look": "sleepy"], "sleepy"),
        (JSRegex(#"\b(happy|cheerful|joy\w*|smiling|glad)\b"#), ["face": "happy", "look": "happy"], "happy"),
        (JSRegex(#"\b(calm|content|peaceful|chill|relaxed)\b"#), ["face": "content"], "calm"),
        (JSRegex(#"\b(grumpy|angry|mad|fierce|stern|serious)\b"#), ["face": "angry"], "grumpy"),
        (JSRegex(#"\b(worried|anxious|nervous|sad)\b"#), ["face": "worried"], "worried"),
        (JSRegex(#"\b(wink\w*|cheeky|playful)\b"#), ["face": "wink"], "winking"),
        (JSRegex(#"\b(love|loving|smitten|hearts?)\b"#), ["face": "heart", "form": "heart", "look": "hearts"], "smitten"),
        (JSRegex(#"\b(sparkl\w*|starry|magic\w*|excited)\b"#), ["face": "sparkle", "look": "stars"], "sparkly"),
        (JSRegex(#"\b(dizzy|confused|broken)\b"#), ["face": "dizzy"], "dizzy"),
        (JSRegex(#"\b(deadpan|bored|blank|neutral)\b"#), ["face": "bars"], "deadpan"),
        (JSRegex(#"\b(surprised|shocked|wide.?eyed|curious)\b"#), ["face": "surprised"], "wide-eyed"),
        (JSRegex(#"\b(side.?eye|suspicious|skeptical|sly)\b"#), ["face": "side"], "side-eye"),
        (JSRegex(#"\b(scanner|cylon|laser)\b"#), ["face": "scanner", "visor": "band"], "scanner"),
        // visor, shell, extras
        (JSRegex(#"\b(sun ?glasses|shades|cool)\b"#), ["specs": "shades"], "sunglasses"),
        (JSRegex(#"\b(aviators?|pilot)\b"#), ["specs": "aviators"], "aviators"),
        (JSRegex(#"\b(monocle|fancy|posh)\b"#), ["specs": "monocle"], "monocle"),
        (JSRegex(#"\b(goggles|glasses|spectacles|nerd\w*)\b"#), ["visor": "goggles", "specs": "round"], "goggles"),
        (JSRegex(#"\b(screen|monitor|display)\b"#), ["visor": "screen"], "screen"),
        (JSRegex(#"\b(no visor|bare)\b"#), ["visor": "none"], "no visor"),
        (JSRegex(#"\b(visor)\b"#), ["visor": "band"], "visor"),
        (JSRegex(#"\b(chrome|metal\w*|silver|steel)\b"#), ["shell": "chrome"], "chrome"),
        (JSRegex(#"\b(two.?tone|duo)\b"#), ["shell": "duo"], "two-tone"),
        (JSRegex(#"\b(colou?red|colou?rful|bright|painted)\b"#), ["shell": "color"], "coloured"),
        (JSRegex(#"\b(twin antenna\w*|two antenna\w*|antennae)\b"#), ["antenna": "twin"], "twin antennae"),
        (JSRegex(#"\b(bolt|lightning|electric)\b"#), ["antenna": "bolt"], "bolt"),
        (JSRegex(#"\b(halo|angel\w*)\b"#), ["antenna": "ring"], "halo"),
        (JSRegex(#"\b(googly|silly|goofy)\b"#), ["look": "googly"], "googly eyes"),
        (JSRegex(#"\b(antenna)\b"#), ["antenna": "bulb"], "antenna"),
        (JSRegex(#"\b(headset|headphones?|earphones?)\b"#), ["ears": "headset"], "headset"),
        (JSRegex(#"\b(bolts|screws)\b"#), ["ears": "bolts"], "bolts"),
        (JSRegex(#"\b(fins?|wings?)\b"#), ["ears": "fins"], "fins"),
        (JSRegex(#"\b(blush\w*|shy|rosy|cute)\b"#), ["blush": "true"], "blush"),
        (JSRegex(#"\b(smile|smiley)\b"#), ["mouth": "smile"], "smile"),
        (JSRegex(#"\b(grille|speaker|vent)\b"#), ["mouth": "grille"], "grille"),
        // dots patterns and tiles
        (JSRegex(#"\b(wave\w*|voice|sound|equali[sz]er)\b"#), ["pattern": "wave"], "voice wave"),
        (JSRegex(#"\b(ring|loader|circle of)\b"#), ["pattern": "ring"], "ring"),
        (JSRegex(#"\b(bloom|flower|sun)\b"#), ["pattern": "bloom"], "bloom"),
        (JSRegex(#"\b(ripple|grid)\b"#), ["pattern": "grid"], "ripple"),
        (JSRegex(#"\b(spark|star)\b"#), ["pattern": "spark", "form": "star"], "spark"),
        (JSRegex(#"\b(slits?|slanted)\b"#), ["look": "slits"], "slit eyes"),
        (JSRegex(#"\b(ovals?|tall eyes)\b"#), ["look": "ovals"], "oval eyes"),
        (JSRegex(#"\b(dark|night|midnight)\b"#), ["tile": "dark"], "dark"),
        (JSRegex(#"\b(light|daylight)\b"#), ["tile": "light"], "light"),
        (JSRegex(#"\b(transparent|floating|no (?:background|backdrop|board|tile))\b"#), ["tile": "none"], "no backdrop"),
        (JSRegex(#"\b(eyes|face)\b"#), ["eyes": "true", "pattern": "face"], "eyes"),
    ]

    private static let board = JSRegex(#"\b(dark|night|midnight|light|daylight)\b"#)

    /// The first emoji in the text (with its variation selector or joined parts), if any.
    static func firstEmoji(_ text: String) -> String? {
        text.first { HeadRecord.isEmoji(String($0)) }.map(String.init)
    }

    /// Reads a description: an emoji makes an Emoji head; a subject ("deploys", "garden") brings its parts; named parts
    /// win over a subject's. Nothing understood gives no parts.
    static func describe(_ text: String) -> Described {
        let plain = HeadTopics.plain(text)
        var parts: [String: String] = [:]
        var understood: [String] = []
        if let index = HeadTopics.entries.firstIndex(where: { $0.0.test(plain) }) {
            parts.merge(HeadTopics.entries[index].1) { $1 }
            understood.append(topicNames[index])
        }
        var themed = false
        for (pattern, word, name) in words where pattern.test(plain) {
            parts.merge(word) { $1 }
            understood.append(name)
            if word["theme"] != nil { themed = true }
        }
        if let emoji = firstEmoji(text) {
            parts["glyph"] = emoji
            parts["theme"] = "glyph"
            understood.insert(emoji, at: 0)
        } else if !themed {
            // A subject alone picks no theme; its emoji shows only on an Emoji head.
            parts["theme"] = nil
        }
        // Eyes or a mouth make a lamp matrix a face.
        if parts["face"] != nil || parts["mouth"] != nil, parts["pattern"] == nil { parts["pattern"] = "face" }
        // Googly eyes, dark glasses or a monocle only a Shapes head wears.
        if parts["theme"] == nil, parts["look"] == "googly" || parts["tile"] == "none"
            || ["shades", "aviators", "monocle"].contains(parts["specs"] ?? "") {
            parts["theme"] = "shape"
        }
        // A Shapes head stands free unless a board was asked for (a subject's dark board isn't one).
        if parts["theme"] == "shape", !board.test(plain) { parts["tile"] = "none" }
        var seen = Set<String>()
        return Described(parts: parts, understood: understood.filter { seen.insert($0).inserted })
    }
}

extension HeadRecord {
    /// Lays described parts over this head (Describe it): booleans as "true", hats never.
    mutating func applyDescribed(_ parts: [String: String]) {
        for (key, value) in parts {
            switch key {
            case "theme": theme = value
            case "form": form = value
            case "look": look = value
            case "specs": specs = value
            case "shell": shell = value
            case "blush": blush = value == "true"
            case "eyes": eyes = value == "true"
            default: apply([key: value])
            }
        }
        hat = "none"
        // A dot-matrix head takes an outline word, else the outline nearest its form; a Shapes head a form it has.
        if theme == "matrix" {
            form = parts["outline"] ?? MatrixDesign.Silhouette(stored: form).rawValue
        } else if theme == "shape", !HeadRecord.forms.contains(form) {
            form = MatrixDesign.Silhouette(stored: form).shapesForm
        }
    }
}
