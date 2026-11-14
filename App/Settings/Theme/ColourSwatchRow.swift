// [message-colour] [bot-colour] A row of colour swatches with the system's colour well at its end: Settings › Chat
// Bubbles › Colour (your messages everywhere) and Bot Info › Settings › Colour (your messages in one bot's chat).
// Each swatch is drawn in the colour a message gets: a colour is deepened until its text reads
// (`ThemeResolver.paintMessage`).

import SwiftUI

/// One choice in the row.
struct ColourSwatch: Identifiable, Hashable {
    /// What the choice is stored as ("theme" for the theme's own).
    var id: String
    var title: String
    /// The message colour the swatch is drawn in; nil for a choice with no one colour (Bot's Face), drawn plain.
    var colour: MessageColour?
    /// A mark that tells the choice apart from a named colour of the same shade, shown until it is picked.
    var symbol: String?

    init(id: String, title: String, colour: MessageColour?, symbol: String? = nil) {
        self.id = id
        self.title = title
        self.colour = colour
        self.symbol = symbol
    }

    /// A choice of Chat Bubbles › Colour.
    init(_ colour: MessageColour) {
        id = colour.swatchID
        title = colour.title
        self.colour = colour == .botFace ? nil : colour
        symbol = colour == .theme ? "paintpalette.fill" : colour == .botFace ? "face.smiling" : nil
    }
}

struct ColourSwatchRow: View {
    var title: String
    /// The picked choice's name, on the title's line.
    var value: String
    /// The theme the swatches are drawn in.
    var state: ThemeState
    var swatches: [ColourSwatch]
    /// The picked swatch's id; "custom" for a colour from the well.
    var picked: String
    /// The custom colour picked, if one is.
    var custom: UInt32?
    /// The start of each swatch's accessibility identifier.
    var identifier: String
    var pick: (ColourSwatch) -> Void
    var pickCustom: (UInt32) -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var draft: Color?
    @State private var pending: Task<Void, Never>?

    private static let size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Color.hqLabel)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(Color.hqLabel2).accessibilityIdentifier("\(identifier)Name")
            }
            .accessibilityHidden(true)   // each swatch says its own name
            // One row where they all fit (the Mac, the iPad); on the iPhone even rows of six (owner 2026-11-08: no
            // wasted space). The system's colour well is a circle on the iPhone and a wider pill on the Mac.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(swatches) { swatch($0) }
                    well
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0, alignment: .leading), count: 6), alignment: .leading, spacing: 8) {
                    ForEach(swatches) { swatch($0) }
                    well
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The bubble and its text for `colour` in the theme and appearance on show; a plain chip for no colour.
    private func look(_ colour: MessageColour?) -> (fill: Color, ink: Color) {
        guard let colour else { return (Color.hqBotBubble, Color.hqLabel) }
        var probe = state
        probe.messageColour = colour
        // [Mac UI check 2026-11-13] The Desktop Look keeps its own box whatever the colour (`appliedMessageColour`), so
        // there all nine swatches came out its one near-black fill: each is drawn as the iOS look paints it instead.
        probe.desktopLook = false
        let tokens = ThemeResolver.resolve(probe).tokens(dark: scheme == .dark)
        return (Color(uiColor: tokens.meBubble.uiColor), Color(uiColor: tokens.meText.uiColor))
    }

    private func swatch(_ swatch: ColourSwatch) -> some View {
        let on = picked == swatch.id
        let look = look(swatch.colour)
        return Button {
            guard !on else { return }
            Haptics.play(.selection)
            pending?.cancel()
            draft = nil
            pick(swatch)
        } label: {
            Circle().fill(look.fill)
                .frame(width: Self.size, height: Self.size)
                .overlay {
                    Image(systemName: on ? "checkmark" : swatch.symbol ?? "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(look.ink)
                        .opacity(on || swatch.symbol != nil ? 1 : 0)
                }
                .overlay { Circle().strokeBorder(Color.hqLabel, lineWidth: on ? 2 : 0).padding(-4) }
                .frame(width: Self.size + 6, height: Self.size + 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
        .accessibilityIdentifier("\(identifier).\(swatch.id)")
    }

    /// Any colour, from the system's colour panel. A drag there sends a stream of colours: the chats repaint once it
    /// rests.
    private var well: some View {
        let on = picked == "custom"
        let shown = draft ?? custom.map { Color(uiColor: RGBA(hex: $0).uiColor) } ?? look(swatches.first { $0.id == picked }?.colour ?? .theme).fill
        return ColorPicker("Custom Color", selection: Binding(get: { shown }, set: { next in
            draft = next
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(next).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
            let hex = byte(r) << 16 | byte(g) << 8 | byte(b)
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                pickCustom(hex)
            }
        }), supportsOpacity: false)
        .labelsHidden()
        .fixedSize()
        .overlay { Capsule().strokeBorder(Color.hqLabel, lineWidth: on ? 2 : 0).padding(-4).allowsHitTesting(false) }
        .frame(height: Self.size + 6)
        .padding(.trailing, 4)
        .accessibilityIdentifier("\(identifier).custom")
    }
}

extension MessageColour {
    /// [message-colour] The swatches of Chat Bubbles › Colour, in the row's order (Custom follows them).
    static let offered: [MessageColour] = [.theme, .botFace] + Preset.allCases.map(MessageColour.preset)

    /// The swatch that shows this colour: its stored name, "theme" for the theme's own, "custom" for the well.
    var swatchID: String {
        switch self {
        case .theme: "theme"
        case .custom: "custom"
        case .botFace, .preset: stored ?? "theme"
        }
    }

    var customHex: UInt32? {
        if case .custom(let hex) = self { return hex }
        return nil
    }

    var title: String {
        switch self {
        case .theme: "Theme"
        case .botFace: "Bot’s Face"
        case .custom: "Custom"
        case .preset(let preset):
            switch preset {
            case .blue: "Blue"
            case .indigo: "Indigo"
            case .purple: "Purple"
            case .pink: "Pink"
            case .red: "Red"
            case .orange: "Orange"
            case .green: "Green"
            case .teal: "Teal"
            case .graphite: "Graphite"
            }
        }
    }
}

// MARK: - Bot Info › Settings › Colour

/// [bot-colour] One bot's own message colour: what Chat Bubbles says (the default), its face, a named colour or any
/// other. Only in the iOS look: the Desktop Look keeps its own boxes.
struct BotColourSection: View {
    var bot: Bot
    @State private var choice = BotMessageColour.Choice.app

    private var account: String? { DefaultProjectFolder.activeAccount }

    static let note = "The color of your own messages in this bot’s chat. The first choice follows Settings › Chat Bubbles; the second is the color of this bot’s face."

    var body: some View {
        let state = Theme.shared.state
        if !state.desktopLook {
            Section {
                ColourSwatchRow(title: "Color", value: Self.title(choice), state: state, swatches: swatches(state),
                                picked: Self.swatchID(choice), custom: Self.customHex(choice), identifier: "bot-info.colour") { swatch in
                    set(BotMessageColour.Choice(stored: swatch.id))
                } pickCustom: { hex in
                    set(.colour(.custom(hex)))
                }
                .hqRowPadding(4)
            } header: { HQSectionLabel {
                Text("Messages")
            } } footer: { HQSectionFooter {
                Text(Self.note)
            } }
            .onAppear { choice = BotMessageColour.choice(account: account, profile: bot.id) }
        }
    }

    private func set(_ next: BotMessageColour.Choice) {
        guard next != choice else { return }
        choice = next
        BotMessageColour.set(next, account: account, profile: bot.id)
        AppLog.trace("settings", "bot message colour \(next.stored ?? "app")")
    }

    private func swatches(_ state: ThemeState) -> [ColourSwatch] {
        let face = Head.resolve(bot.head, profile: bot.id).messageColour
        // What Chat Bubbles gives this bot's chat today.
        let app = state.messageColour == .botFace ? face : state.messageColour
        return [ColourSwatch(id: "app", title: "Same as Chat Bubbles", colour: app, symbol: "bubble.left.and.bubble.right.fill"),
                ColourSwatch(id: "face", title: "Face", colour: face, symbol: "face.smiling")]
            + MessageColour.Preset.allCases.map { ColourSwatch(.preset($0)) }
    }

    static func title(_ choice: BotMessageColour.Choice) -> String {
        switch choice {
        case .app: "Chat Bubbles"
        case .face: "Face"
        case .colour(let colour): colour.title
        }
    }

    static func swatchID(_ choice: BotMessageColour.Choice) -> String {
        switch choice {
        case .app: "app"
        case .face: "face"
        case .colour(let colour): colour.swatchID
        }
    }

    static func customHex(_ choice: BotMessageColour.Choice) -> UInt32? {
        if case .colour(let colour) = choice { return colour.customHex }
        return nil
    }
}
