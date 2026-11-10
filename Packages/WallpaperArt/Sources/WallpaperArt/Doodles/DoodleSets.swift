// The eight pictures: which drawings, which colours, and the one way in.

import CoreGraphics
import Foundation

nonisolated enum DoodleSet: String, CaseIterable, Sendable {
    case gaming, forest, peaks, sports, rose, lilac, travel, cafe

    init?(scene: String) {
        switch scene {
        case "doodleGaming": self = .gaming
        case "doodleForest": self = .forest
        case "doodlePeaks": self = .peaks
        case "doodleSports": self = .sports
        case "doodleRose": self = .rose
        case "doodleLilac": self = .lilac
        case "doodleTravel": self = .travel
        case "doodleCafe": self = .cafe
        default: return nil
        }
    }

    /// What each picture has to show, whatever its shape.
    private var keyNames: Set<String> {
        switch self {
        case .gaming: ["pad", "keyboard", "mouse", "phones", "d20", "dice", "chest", "handheld", "cabinet", "potion", "swordShield", "trophy"]
        case .forest: ["fox", "owl", "rabbit", "hedgehog", "beaver", "frog", "woodpecker", "hammock", "cookPot", "canoe", "lantern", "axe", "pack", "pine", "oak"]
        case .peaks: ["peaks", "iceAxe", "rope", "carabiner", "quickdraw", "goggles", "skis", "boot", "map", "compass", "summitFlag", "cableCar", "helmet", "alpinePack"]
        case .sports: ["soccerBall", "basketball", "football", "volleyball", "tennisBall", "baseballBat", "tennisRacket", "badminton", "sneaker", "whistle", "trophy", "medal", "boxingGloves", "golfBag", "golfTee", "hockeySticks", "hockeyHelmet"]
        case .rose: ["rose", "ribbon", "butterfly", "perfume", "bow", "gem", "teacup", "handbag", "lipstick"]
        case .lilac: ["swan", "swallowtail", "lunaMoth", "hangingMoon", "shootingStar", "crystals", "streamingRibbon", "teapot", "stackedCups", "moonCup", "moonPerfume", "tearPerfume", "clam", "scallop", "conch", "slippers", "wisteria", "harp", "musicBox"]
        case .travel: ["suitcase", "propPlane", "palmIsland", "passport", "camera", "foldedMap", "compassRose", "sailboat", "rowHouses", "domeHouse", "aviators", "lighthouse", "toucan", "scooter", "train", "balloon", "globe"]
        case .cafe: ["latteCup", "mokaPot", "croissant", "bookStack", "monstera", "pothos", "recordPlayer", "cakeDome", "pencilCup", "cakeSlice", "openBook", "grinder", "frenchPress", "dripper", "vinyl", "deskLamp", "radio", "catLoaf", "gooseneck"]
        }
    }

    /// Pale drawings that would go hollow in the Dark picture: they always stand forward there, bare paper included.
    private var standNames: Set<String> {
        switch self {
        case .gaming: []
        case .forest: ["raccoon"]
        case .peaks: ["peaks", "ibex"]
        case .sports: ["soccerBall", "hoop", "trophy", "volleyball", "golfTee", "rollerSkate", "cricket", "sneaker"]
        case .rose: []
        case .lilac: ["swan", "teapot", "clam", "stackedCups", "moonCup"]
        case .travel: []
        case .cafe: []
        }
    }

    func glyphs() -> [DoodleGlyph] {
        var list = allGlyphs()
        let keys = keyNames
        for i in list.indices where keys.contains(list[i].name) { list[i].key = true }
        return list
    }

    private func allGlyphs() -> [DoodleGlyph] {
        switch self {
        case .gaming: DoodleGaming.all()
        case .forest: DoodleForest.all()
        case .peaks: DoodlePeaks.all()
        case .sports: DoodleSports.all()
        case .lilac: DoodleLilac.all()
        case .travel: DoodleTravel.all()
        case .cafe: DoodleCafe.all()
        case .rose: DoodleRose.all()
        }
    }

    var seed: UInt64 {
        switch self {
        case .gaming: 0x58ff35ad8
        case .forest: 0x13c6f06c9
        case .peaks: 0x9E378D10
        case .sports: 0x5d13c9a07
        case .lilac: 0x1DAA68082
        case .travel: 0x79c4a2d16
        case .cafe: 0x8e36d04b2
        case .rose: 0x4f1bbe11f
        }
    }

    func style(dark: Bool) -> DoodleStyle {
        typealias A = DoodleStyle.Anchor
        func h(_ v: UInt32) -> BackdropPreset.Ink { DoodleColor.hex(v) }
        /// Four soft patches of colour, top to bottom.
        func field(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> [A] {
            [A(x: 0.1, y: 0.05, c: h(a), r: 0.42), A(x: 0.95, y: 0.28, c: h(b), r: 0.4), A(x: 0.1, y: 0.62, c: h(c), r: 0.38), A(x: 0.9, y: 0.92, c: h(d), r: 0.42)]
        }
        var s: DoodleStyle
        switch (self, dark) {
        case (.gaming, false):
            s = DoodleStyle(
                ground: field(0xB4A4DE, 0xA098DE, 0x8C98DE, 0x7D9ED8),
                ink: field(0x46348E, 0x3C3496, 0x323E9C, 0x2A5094),
                spots: [h(0xD6D8F6), h(0xF29C75), h(0x5CC4BA)], spotAlpha: [0.7, 0.8, 0.76],
                paper: h(0xCBCCF0), paperAlpha: 0.32, gel: h(0xF6F6FF), gelAlpha: 0.75, mottle: 0.6)
            s.shade = h(0x2C2C7C)
            s.shadeAlpha = 0.24
            s.accent = h(0x322C78)
            s.inkAlpha = 0.68
            s.detailAlpha = 0.46
        case (.gaming, true):
            s = DoodleStyle(
                ground: field(0x171338, 0x1B123C, 0x11193C, 0x0E2236),
                ink: field(0x6E66BE, 0x7E62B8, 0x5A74BC, 0x4E92A8),
                spots: [h(0x2C2C6A), h(0x7C404C), h(0x134C5A)], spotAlpha: [0.8, 0.78, 0.8],
                paper: h(0x1E1E4C), paperAlpha: 0.5, gel: h(0xB0B3EC), gelAlpha: 0.4, mottle: 0.58)
            s.shade = h(0x06061A)
            s.shadeAlpha = 0.42
            s.accent = h(0x07071C)
            s.inkAlpha = 0.6
            s.detailAlpha = 0.42
            s.lifted = [h(0x40408E), h(0x9A5864), h(0x206C7E)]
            s.liftCount = 5
            s.liftedPaper = h(0x34346E)
            s.liftedPaperAlpha = 0.72
        case (.forest, false):
            s = DoodleStyle(
                ground: field(0xDDD6B4, 0xBFCDAE, 0x9FC0AC, 0x8DB4A6),
                ink: field(0x6C6E48, 0x566F52, 0x4B7158, 0x3F6D64),
                spots: [h(0x8FB486), h(0xAC7E56), h(0xD99C72)], spotAlpha: [0.7, 0.74, 0.66],
                paper: h(0xE8E4CC), paperAlpha: 0.4, gel: h(0xF8F5E2), gelAlpha: 0.7, mottle: 0.6)
            s.shade = h(0x3C5040)
            s.shadeAlpha = 0.22
            s.accent = h(0x46604E)
            s.inkAlpha = 0.72
            s.detailAlpha = 0.4
        case (.forest, true):
            s = DoodleStyle(
                ground: field(0x1A2219, 0x15241B, 0x10211E, 0x0D1E24),
                ink: field(0x6F8F72, 0x618A68, 0x578A70, 0x4F8A84),
                spots: [h(0x2A4D38), h(0x5A4228), h(0x6E3C24)], spotAlpha: [0.84, 0.82, 0.82],
                paper: h(0x1F302A), paperAlpha: 0.5, gel: h(0xBFC09A), gelAlpha: 0.4, mottle: 0.58)
            s.shade = h(0x040806)
            s.shadeAlpha = 0.42
            s.accent = h(0x050A08)
            s.inkAlpha = 0.58
            s.detailAlpha = 0.4
            s.lifted = [h(0x336048), h(0x664A2C), h(0x7C4428)]
            s.liftCount = 3
            s.liftedPaper = h(0x7C8870)
            s.liftedPaperAlpha = 0.8
        case (.peaks, false):
            s = DoodleStyle(
                ground: field(0xDCE8EC, 0xC6DBE4, 0xB0CCDC, 0x9CBDD2),
                ink: field(0x3F5F78, 0x38597A, 0x325480, 0x2C4E7C),
                spots: [h(0x9DCBE0), h(0x7E9BB2), h(0xEFA27A)], spotAlpha: [0.72, 0.7, 0.74],
                paper: h(0xF2F7F8), paperAlpha: 0.62, gel: h(0xFFFFFF), gelAlpha: 0.8, mottle: 0.55)
            s.shade = h(0x2E4C72)
            s.shadeAlpha = 0.22
            s.accent = h(0x294566)
            s.inkAlpha = 0.68
            s.detailAlpha = 0.42
        case (.peaks, true):
            s = DoodleStyle(
                ground: field(0x16242E, 0x132230, 0x101F30, 0x0D1B2C),
                ink: field(0x6C93AC, 0x648CAC, 0x5C86AC, 0x5580A8),
                spots: [h(0x1E4A62), h(0x2F4356), h(0x7A4630)], spotAlpha: [0.84, 0.82, 0.82],
                paper: h(0x24384A), paperAlpha: 0.52, gel: h(0xBFD6E2), gelAlpha: 0.42, mottle: 0.58)
            s.shade = h(0x050B12)
            s.shadeAlpha = 0.42
            s.accent = h(0x060C14)
            s.inkAlpha = 0.6
            s.detailAlpha = 0.42
            s.lifted = [h(0x265A76), h(0x3C566E), h(0x824A30)]
            s.liftCount = 3
            s.liftedPaper = h(0x5A768A)
            s.liftedPaperAlpha = 0.86
        case (.sports, false):
            s = DoodleStyle(
                ground: field(0xF6D98A, 0xF4CE78, 0xF0C068, 0xEBB25E),
                ink: field(0x24506A, 0x1F4C6C, 0x1E4A70, 0x1E4670),
                spots: [h(0xE9694A), h(0x4A9DAE), h(0xFFEAA6)], spotAlpha: [0.78, 0.76, 0.8],
                paper: h(0xFFF7DE), paperAlpha: 0.72, gel: h(0xFFFFFF), gelAlpha: 0.75, mottle: 0.55)
            s.shade = h(0x7A3F20)
            s.shadeAlpha = 0.2
            s.accent = h(0x2C5C80)
            s.inkAlpha = 0.72
            s.detailAlpha = 0.46
        case (.sports, true):
            s = DoodleStyle(
                ground: field(0x201A0A, 0x1E1A0C, 0x1A180E, 0x171612),
                ink: field(0xBC964A, 0xB69048, 0xAE8A48, 0xA8864A),
                spots: [h(0x7E3322), h(0x1F5560), h(0x6C5420)], spotAlpha: [0.84, 0.84, 0.82],
                paper: h(0x332C18), paperAlpha: 0.52, gel: h(0xF2DFA6), gelAlpha: 0.4, mottle: 0.58)
            s.shade = h(0x0A0804)
            s.shadeAlpha = 0.42
            s.accent = h(0x0A0806)
            s.inkAlpha = 0.58
            s.detailAlpha = 0.4
            s.lifted = [h(0x98402A), h(0x266674), h(0x7A6026)]
            s.liftCount = 3
            s.liftedPaper = h(0x6A5A30)
            s.liftedPaperAlpha = 0.8
        case (.lilac, false):
            s = DoodleStyle(
                ground: field(0xE2D0EA, 0xD8C4E8, 0xCDBBE6, 0xC2B2E2),
                ink: field(0x6E5692, 0x68528F, 0x5F4F90, 0x584C8E),
                spots: [h(0xC48CC8), h(0xF4D68C), h(0x9AD2C2)], spotAlpha: [0.66, 0.74, 0.7],
                paper: h(0xF8F2FA), paperAlpha: 0.62, gel: h(0xFFFFFF), gelAlpha: 0.82, mottle: 0.55)
            s.shade = h(0x4A3280)
            s.shadeAlpha = 0.18
            s.accent = h(0x5A4488)
            s.inkAlpha = 0.68
            s.detailAlpha = 0.42
        case (.lilac, true):
            s = DoodleStyle(
                ground: field(0x241530, 0x221434, 0x1E1436, 0x1A1434),
                ink: field(0xA58CC8, 0x9E88C8, 0x9684C8, 0x8E82C6),
                spots: [h(0x5C2F6C), h(0x6E5A2E), h(0x2E5C5A)], spotAlpha: [0.84, 0.82, 0.82],
                paper: h(0x36264C), paperAlpha: 0.52, gel: h(0xE0D0F0), gelAlpha: 0.42, mottle: 0.58)
            s.shade = h(0x080410)
            s.shadeAlpha = 0.42
            s.accent = h(0x0A0614)
            s.inkAlpha = 0.6
            s.detailAlpha = 0.42
            s.lifted = [h(0x743A88), h(0x6C5A30), h(0x387270)]
            s.liftCount = 3
            s.liftedPaper = h(0x624E88)
            s.liftedPaperAlpha = 0.8
        case (.travel, false):
            s = DoodleStyle(
                ground: field(0xC6EAE2, 0xB6E2E0, 0xA4DADC, 0x92D0D8),
                ink: field(0x11505E, 0x0F4C60, 0x0E4A62, 0x0D4664),
                spots: [h(0xF08E70), h(0xF7DB96), h(0x53B4C6)], spotAlpha: [0.78, 0.82, 0.76],
                paper: h(0xFBFBF0), paperAlpha: 0.72, gel: h(0xFFFFFF), gelAlpha: 0.8, mottle: 0.55)
            s.shade = h(0x0C3E58)
            s.shadeAlpha = 0.18
            s.accent = h(0x0E4458)
            s.inkAlpha = 0.72
            s.detailAlpha = 0.46
        case (.travel, true):
            s = DoodleStyle(
                ground: field(0x07282E, 0x07262E, 0x062430, 0x052030),
                ink: field(0x579EA4, 0x5298A2, 0x4D94A0, 0x49909E),
                spots: [h(0x763A2D), h(0x665C34), h(0x15596A)], spotAlpha: [0.84, 0.82, 0.84],
                paper: h(0x133640), paperAlpha: 0.52, gel: h(0xD0ECEC), gelAlpha: 0.34, mottle: 0.58)
            s.shade = h(0x020A0E)
            s.shadeAlpha = 0.42
            s.accent = h(0x020C10)
            s.inkAlpha = 0.58
            s.detailAlpha = 0.4
            s.lifted = [h(0x7F3D29), h(0x6B6235), h(0x186272)]
            s.liftCount = 3
        case (.cafe, false):
            s = DoodleStyle(
                ground: field(0xF0E2CA, 0xEAD8BC, 0xE2CBAA, 0xD8BE9C),
                ink: field(0x5E412E, 0x5A3E2C, 0x56392A, 0x503628),
                spots: [h(0xD09C62), h(0xA8B68C), h(0xC96E52)], spotAlpha: [0.74, 0.74, 0.74],
                paper: h(0xFBF4E4), paperAlpha: 0.7, gel: h(0xFFFAF0), gelAlpha: 0.8, mottle: 0.55)
            s.shade = h(0x4A2C18)
            s.shadeAlpha = 0.18
            s.accent = h(0x6C4C36)
            s.inkAlpha = 0.72
            s.detailAlpha = 0.46
        case (.cafe, true):
            s = DoodleStyle(
                ground: field(0x201610, 0x1E1510, 0x1C1410, 0x19120E),
                ink: field(0xB69C82, 0xB0967C, 0xAA9076, 0xA28870),
                spots: [h(0x6E4A28), h(0x47523C), h(0x74392A)], spotAlpha: [0.84, 0.82, 0.84],
                paper: h(0x54402E), paperAlpha: 0.7, gel: h(0xEFDFC6), gelAlpha: 0.36, mottle: 0.58)
            s.shade = h(0x0A0604)
            s.shadeAlpha = 0.42
            s.accent = h(0x0A0604)
            s.inkAlpha = 0.58
            s.detailAlpha = 0.4
            s.lifted = [h(0x7E562E), h(0x566248), h(0x884430)]
            s.liftCount = 3
        case (.rose, false):
            s = DoodleStyle(
                ground: field(0xF4CDC6, 0xF1BEC2, 0xF3C4B8, 0xE5B8CE),
                ink: field(0xA45452, 0x9C4662, 0xA45050, 0x8E467A),
                spots: [h(0xEC9AA8), h(0xA8C49C), h(0xF2CC90)], spotAlpha: [0.62, 0.68, 0.7],
                paper: h(0xFAE4DC), paperAlpha: 0.42, gel: h(0xFFF4EE), gelAlpha: 0.8, mottle: 0.55)
            s.shade = h(0x8A3A58)
            s.shadeAlpha = 0.2
            s.accent = h(0x96466A)
            s.inkAlpha = 0.74
            s.detailAlpha = 0.42
        case (.rose, true):
            s = DoodleStyle(
                ground: field(0x27111A, 0x2A1020, 0x26121C, 0x1F1026),
                ink: field(0xA86472, 0xA45C7A, 0xA86A60, 0x8E6098),
                spots: [h(0x5A2340), h(0x3C4E3E), h(0x764E32)], spotAlpha: [0.82, 0.8, 0.8],
                paper: h(0x341A2A), paperAlpha: 0.5, gel: h(0xDDB8BE), gelAlpha: 0.4, mottle: 0.58)
            s.shade = h(0x0C040A)
            s.shadeAlpha = 0.42
            s.accent = h(0x0E040A)
            s.inkAlpha = 0.6
            s.detailAlpha = 0.42
            s.lifted = [h(0x842E54), h(0x485E4C), h(0x865C3C)]
            s.liftCount = 3
        }
        if dark { s.ceiling = 0.575 }
        return s
    }
}

nonisolated extension DoodleSet {
    /// The picture's unit: phones use their short side, so every modern iPhone and a picker tile get the same arrangement.
    /// A squarer screen gets the same area of drawings at a smaller scale, so an iPad is as rich as a phone and no drawing looms.
    static func layoutShape(width: Int, height: Int) -> (unit: Double, wu: Double, hu: Double) {
        let short = Double(min(width, height)), long = Double(max(width, height))
        let ratio = long / short
        let shrink = ratio >= 2.1 ? 1 : (2.168 / ratio).squareRoot()
        let unit = short / shrink
        // Rounded up a little; the rest is cropped.
        let wu = (Double(width) / unit * 50).rounded(.up) / 50, hu = (Double(height) / unit * 50).rounded(.up) / 50
        return (unit, wu, hu)
    }

    func picture(width: Int, height: Int, dark: Bool, layoutSeed: UInt64? = nil) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let lib = glyphs()
        let shape = Self.layoutShape(width: width, height: height)
        var items = DoodlePack.layout(lib, wu: shape.wu, hu: shape.hu, seed: layoutSeed ?? seed)
        let style = style(dark: dark)
        // A few of the largest drawings stand forward.
        if style.liftCount > 0 {
            let order = items.indices.sorted { items[$0].size > items[$1].size }
            var chosen = 0
            for i in stride(from: 0, to: order.count, by: 2) where chosen < style.liftCount {
                items[order[i]].lift = true
                chosen += 1
            }
        }
        if style.lifted != nil {
            let stands = standNames
            if !stands.isEmpty {
                for i in items.indices where stands.contains(lib[items[i].glyph].name) { items[i].lift = true }
            }
        }
        return DoodlePainter.paint(lib, items, style: style, width: width, height: height, seed: seed, unitOverride: shape.unit)
    }
}

nonisolated enum DoodleArt {
    /// `scene` is one of the eight ids ("doodleGaming", "doodleForest", ...). A finished opaque image, or nil for an unknown id.
    static func render(scene: String, width: Int, height: Int, dark: Bool) -> CGImage? {
        DoodleSet(scene: scene)?.picture(width: width, height: height, dark: dark)
    }
}
