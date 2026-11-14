import UIKit

// Colours and metrics for the chat screen (spec 06 §1.2, §2, §4). Nous skin, light and dark.
// Every colour is a dynamic UIColor so attributed strings and views resolve it at draw time; a change of appearance
// only needs a redraw, never a new layout.

nonisolated extension UIColor {
    /// sRGB colour from a 0xRRGGBB literal.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func chatDynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in traits.userInterfaceStyle == .dark ? dark : light }
    }

    /// [a11y] With Increase Contrast values (spec 3x-a11y §5.2, the same numbers as HQPalette).
    static func chatDynamic(light: UIColor, dark: UIColor, highLight: UIColor, highDark: UIColor) -> UIColor {
        UIColor { traits in
            let high = traits.accessibilityContrast == .high || HQAccessibility.overrides.contrast
            if traits.userInterfaceStyle == .dark { return high ? highDark : dark }
            return high ? highLight : light
        }
    }
}

/// [backdrop] On a chat line that stands on its pill over a chat background (`ChatBaseCell.placeBacking`):
/// `ChatPalette.lineInk` draws in the primary label there.
nonisolated struct PillInkTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "hqPillInk"
}

/// The chat's colours. [desktoplook] Each reads the live theme (App/Theme); with no skin picked and the Desktop Look
/// off they are the Nous values of spec 06 §1.2, kept as literals in HermesKit/Theme/ThemeTokens.swift (`base`).
nonisolated enum ChatPalette {
    static let page = ThemedColor.make(\.page)
    static let label = ThemedColor.make(\.label)
    static let label2 = ThemedColor.make(\.label2)
    static let label3 = ThemedColor.make(\.label3)
    /// [backdrop] A line's grey words drawn straight on the page (a day, a notice, a caption): label 2, and the primary
    /// label while the line stands on its pill over a chat background (`PillInkTrait`), where label 2 measured 2.9:1 on
    /// the dark glass pills (owner, 2026-11-01). Resolved at draw time, so a cached layout serves both.
    static let lineInk = UIColor { @Sendable traits in (traits[PillInkTrait.self] ? label : label2).resolvedColor(with: traits) }
    static let tint = ThemedColor.make(\.tint)
    static let tintText = ThemedColor.make(\.tintText)
    static let onTint = ThemedColor.make(\.onTint)
    static let botBubble = ThemedColor.make(\.botBubble)
    static let meBubble = ThemedColor.make(\.meBubble)
    static let meText = ThemedColor.make(\.meText)
    static let meTime = ThemedColor.make(\.meTime)
    static let separator = ThemedColor.make(\.separator)
    static let fill1 = ThemedColor.make(\.fill1)
    static let fill2 = ThemedColor.make(\.fill2)
    /// Fill 2 as it shows on the page, opaque (verify round 3: the disabled Send circle let the rows under the composer
    /// show through it): 16 % / 32 % of (120,120,128) over #FEFEFE / #0D1015.
    static let fill2OnPage = ThemedColor.make(\.fill2OnPage)
    static let fill3 = ThemedColor.make(\.fill3)
    static let fill4 = ThemedColor.make(\.fill4)
    /// Code card inside a bubble: Fill 4 in light, #1F2023 in Nous dark (spec 06 §2.3).
    static let codeFill = ThemedColor.make(\.codeFill)
    /// The code card's fill as it shows on the bot bubble, opaque (Fill 4 over #E9E9EB in light): the clamp's fade
    /// must hide the code under it.
    static let codeFillOnBubble = ThemedColor.make(\.codeFillOnBubble)
    /// Tables keep Fill 4 in both modes, the header row Fill 4 again over it (a skin's own look may shade the header
    /// alone: `ThemeTokens.tableHead`).
    static let tableFill = ThemedColor.make(\.tableBody)
    static let tableHead = ThemedColor.make(\.tableHead)
    /// The faint line round a reply's bubble (clear unless the skin draws one, `SkinOwnLook.replyEdge`).
    static let replyEdge = ThemedColor.make(\.replyEdge)
    /// Plain code foreground: the GitHub themes' default foreground (spec 06 §2.6, light #1F2328 / dark ≈#A1ABB5).
    static let codeText = ThemedColor.make(\.codeText)
    static let inlineCodeFill = fill3
    static let red = ThemedColor.make(\.red)
    static let alertRed = ThemedColor.make(\.alertRed)
    static let green = ThemedColor.make(\.green)
    static let orange = ThemedColor.make(\.orange)
    /// Grouped background (error card): Nous sidebar seed.
    static let grouped = ThemedColor.make(\.grouped)
    /// Status line words while working: tint-text in light, label in dark (spec 06 §4.1).
    static let statusWorking = ThemedColor.make(\.statusWorking)
    // [desktoplook] Surfaces and lines only the Desktop Look draws.
    static let editor = ThemedColor.make(\.editor)
    static let elevated = ThemedColor.make(\.elevated)
    /// [Mac UI check 2026-11-13] L2, L9: the backing under a pop-up's glass on the Mac (Commands, Models, the slash
    /// drawer): the page at 86 %, so the chat behind tints the card but never reads through it as words.
    static let popupVeil = UIColor { @Sendable traits in page.resolvedColor(with: traits).withAlphaComponent(0.94) }
    static let sidebar = ThemedColor.make(\.sidebar)
    static let strokePrimary = ThemedColor.make(\.strokePrimary)
    static let strokeSecondary = ThemedColor.make(\.strokeSecondary)
    static let meBorder = ThemedColor.make(\.meBorder)
    static let composerBorder = ThemedColor.make(\.composerBorder)
    static let composerGlyph = ThemedColor.make(\.composerGlyph)
    static let caret = ThemedColor.make(\.caret)
    static let tabIdle = ThemedColor.make(\.tabIdle)
}

/// Fixed geometry (points) from spec 06. Text sizes come from Dynamic Type (see `ChatStyle`).
nonisolated enum ChatMetrics {
    static let sideInset: CGFloat = 16
    /// 12 pt unless Theme › Bubble Corners says otherwise; joined corners are the same. [desktop-corners] The Desktop
    /// Look's own Corners there (4 pt, the desktop's, unless another was picked).
    static var bubbleRadius: CGFloat { CGFloat(ThemeTable.bubbleCorners) }
    /// 6 pt padding + the 1 pt (transparent) border, top and bottom. [mac] 9: Grok Bot's 7 on the screen at 77 %.
    static let bubblePadV: CGFloat = DeviceWord.isMac ? 9 : 7
    /// 12 pt padding + 1 pt border at the sides. [mac] 16: Grok Bot's 12 on the screen.
    static let bubblePadH: CGFloat = DeviceWord.isMac ? 16 : 13
    static let tailSize = CGSize(width: 8, height: 17)
    /// [mac] 728 (560 on the screen, Grok Bot's bubbles) in its 1280 column (`ReadableColumn`).
    static let userMaxWidth: CGFloat = DeviceWord.isMac ? 728 : 320
    /// [mac] A reply stops at the old readable column's text width while the column itself is Grok Bot's 960 pt.
    static let replyMaxWidth: CGFloat = DeviceWord.isMac ? 728 : .greatestFiniteMagnitude
    static let userMaxFraction: CGFloat = 0.8
    static let runGap: CGFloat = 2
    static let turnGap: CGFloat = 6
    static let runSeconds: TimeInterval = 300
    static let dayGapSeconds: TimeInterval = 1800
    /// Time inside a bubble: 10 pt from the trailing edge, 5 pt from the bottom.
    static let timeTrailing: CGFloat = 10
    static let timeBottom: CGFloat = 5
    static let timeReserveGap: CGFloat = 12
    /// The radius of a bubble's bottom-trailing corner, where its time sits (`BubbleShape`'s corners): yours is square
    /// under the tail.
    static func timeCorner(mine: Bool, joinsBelow: Bool, tail: Bool) -> CGFloat {
        mine && tail ? 0 : bubbleRadius
    }
    /// How far a bubble's time moves in from that corner, left and up alike. A corner rounder than 12 pt (Theme ›
    /// Bubble Corners) curves in closer to the time, so the time moves in until its gap to the curve is the one it has
    /// at 12 (owner 2026-10-29, at 24 pt: "the time is too close to the edge. That can't happen no matter what radius
    /// you pick."). `trailing`/`bottom`: the time's distance from the bubble's edges; `round`: its own corner (the
    /// photo time's capsule; 0 for plain text).
    static func timeShift(corner r: CGFloat, trailing a: CGFloat = timeTrailing, bottom b: CGFloat = timeBottom,
                          round q: CGFloat = 0) -> CGFloat {
        // The gap between the time's bottom-trailing corner and the bubble's outline.
        func gap(_ r: CGFloat) -> CGFloat {
            let u = r - a - q, v = r - b - q
            return u > 0 && v > 0 ? r - q - (u * u + v * v).squareRoot() : min(a, b)
        }
        let standard = CGFloat(ThemeState.defaultBubbleCorners)
        let want = gap(standard)
        guard r > standard, gap(r) < want else { return 0 }
        // Moving in by d leaves (u - d, v - d) to the curve's centre, which may be at most `reach` away.
        let u = r - a - q, v = r - b - q, reach = r - q - want
        let room = 2 * reach * reach - (u - v) * (u - v)
        guard room > 0 else { return ceil(max(u, v)) }
        return ceil((u + v - room.squareRoot()) / 2)
    }
    static func timeShift(mine: Bool, joinsBelow: Bool, tail: Bool) -> CGFloat {
        timeShift(corner: timeCorner(mine: mine, joinsBelow: joinsBelow, tail: tail))
    }
    static var codeRadius: CGFloat { HQShape.radius(10, .card) }   // [desktoplook]
    static let codeStrip: CGFloat = 40
    static let codePadH: CGFloat = 12
    static let codePadV: CGFloat = 10
    /// [Mac UI check 2026-11-13] V9: 52 left a long one-line box's faded end against the copy glyph; 64 clears it.
    static let codeCompactTrailing: CGFloat = 64
    static let codeCompactMinHeight: CGFloat = 44
    static let tableCellPadH: CGFloat = 10
    /// [transcript] A narrow table's card is at least this wide (its footer's Expand at the largest text).
    static let tableStripMinWidth: CGFloat = 132
    /// [transcript] The table card's footer (row count and Expand) under the grid: a caption line and 8 pt above and
    /// below it, at least 36 pt.
    static func tableFooter(_ style: ChatStyle) -> CGFloat { max(36, ceil(style.codeLabel.lineHeight) + 16) }
    static let tableCellPadV: CGFloat = 6
    static let ruleSpace: CGFloat = 12
    /// A code card's code area clamps at 120 pt; a 28 pt fade and a toggle cover its bottom (spec 06 §2.6).
    static let codeClamp: CGFloat = 120
    static let codeFade: CGFloat = 28
    /// Your long message clamps at 10 lines, then "Show More" (spec 06 §2.1).
    static let userClampLines = 10
    // Tool rows (spec 06 §3.1)
    static let toolGlyph: CGFloat = 18
    static let toolChevron: CGFloat = 14
    static let toolRowMin: CGFloat = 40
    static let toolRowPadV: CGFloat = 8
    static let toolRowPadH: CGFloat = 2
    static let toolGap: CGFloat = 8
    static var insetCardRadius: CGFloat { HQShape.radius(14, .card) }   // [desktoplook]
    static let stepMinHeight: CGFloat = 44
    static let stepPadV: CGFloat = 10
    // Composer (spec 06 §4.3)
    /// [mac] Grok Bot's 44 pt composer on the screen at 77 %: 51 in the Desktop Look (its box adds 3 above and below),
    /// 54 in the iOS look (its glass reaches 1 pt further).
    /// [composer-bar] The iPhone's iOS look is one 44 pt glass bar holding ☰, +, the field, the mic and a 36 pt circle
    /// 4 pt in from its end (the web's voice circle, `inset: 4px`); the Desktop Look's box keeps its 40.
    /// [desktop-composer] The composer's metrics follow the bar it draws (`ThemeState.boxComposer`), not the look: the
    /// Desktop Look's glass bar is the iOS look's.
    static var control: CGFloat {
        guard DeviceWord.isMac else { return ThemeTable.current.state.boxComposer ? 40 : 44 }
        return ThemeTable.current.state.boxComposer ? 51 : 54
    }
    // [desktoplook] UX study #200: keyboard down, the Desktop Look's box (drawn 4 pt outside the row) meets the
    // message column's 16 pt gutter; the standard look keeps 26.
    // [mac] Stress test 2026-10-28 #53: in the iOS look on the Mac the composer (and the Talk card and docked cards on
    // its edges) starts at the bubbles' 16 pt, so the three line up; the Desktop Look's box already does (20 − 4).
    @MainActor static var composerSideDown: CGFloat { Theme.boxComposer ? 20 : DeviceWord.isMac ? sideInset : 26 }
    // [desktoplook] Over the keys the Desktop Look's box (drawn 4 pt outside the row, 3 pt below it) lines up with the
    // keyboard's keys, 7 pt in, and keeps 11 pt clear of the keyboard's round top (owner 2026-10-20: the box sat on the
    // curve and its corners clashed with the keyboard's).
    @MainActor static var composerSideUp: CGFloat { Theme.boxComposer ? 11 : 8 }
    /// [mac] 21: Grok Bot's composer sits 16 pt above the window's foot.
    static let composerBottomDown: CGFloat = DeviceWord.isMac ? 21 : 29
    @MainActor static var composerBottomUp: CGFloat { Theme.boxComposer ? 14 : 8 }
    static let composerGap: CGFloat = 6
    /// [mac] The same near-capsule on the Mac's taller field.
    static var fieldRadius: CGFloat { HQShape.radius(DeviceWord.isMac ? 25 : 18, .field) }   // [desktoplook]
    static let fieldPadH: CGFloat = 14
    static let fieldMaxLines = 6
    static let glassSpacing: CGFloat = 6
    // Jump button (spec 06 §4.4)
    static let jumpSize: CGFloat = 44
    static let jumpTrailing: CGFloat = 16
    static let jumpAboveComposer: CGFloat = 16
    /// Space between the newest row and the composer's top. [mac-ui-issues] 16 on the Mac: its box rises 3 pt above the
    /// row, so at 8 the newest bubble sat 4 px above the box on the screen and read as stuck to it.
    static let composerContentGap: CGFloat = DeviceWord.isMac ? 16 : 8
    /// Transcript top: 12 pt below the bar plus the status line's reserved height.
    static let transcriptTopGap: CGFloat = 12
    static let statusLineHeight: CGFloat = 22
    /// The status pill's top from the bar's foot: tucked 4 pt under the iOS look's glass bar; [desktoplook] 4 pt below
    /// the Desktop Look's solid bar (Mac polish #78: tucked under it, "Waking up…" lost its top outline).
    @MainActor static var statusPillTop: CGFloat { Theme.isDesktop ? 4 : -4 }
}
