// Owner 2026-11-23: the Hermes HQ Discord server, findable from the app. A card heads More once, until it's closed (it
// says where the link stays), and a Discord pill sits beside Website and GitHub at the foot of More for good
// (`MoreLinksFooter`). The card is a More row drawn by its owner, so it isn't a page in More search, Settings › Tabs,
// Quick Actions or Open Quickly (they all skip `card` rows).

import SwiftUI
import UIKit

@MainActor
enum HQCommunity {
    /// The server's permanent invite (never expires; checked 2026-11-23 against Discord's invite API: "Hermes HQ").
    static let discordInvite = URL(string: "https://discord.gg/KP9cDXD6ET")!
    /// Discord's blurple.
    static let blurple = UIColor(red: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255, alpha: 1)
    /// The More section the card stands in: first in `PagesTabs.sectionOrder`.
    static let sectionID = "community"
    static let dismissedKey = "hqn.more.discordInvite.closed"

    static var cardClosed: Bool {
        get { UserDefaults.standard.bool(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// Opened by the system, not the in-app browser, so the Discord app takes it when it's installed (it claims
    /// discord.gg links) and the browser opens it otherwise.
    static func openInvite(from place: String) {
        AppLog.note("screen", "discord invite: \(place)")
        UIApplication.shared.open(discordInvite)
    }

    static func closeCard() {
        AppLog.note("screen", "discord invite: card closed")
        cardClosed = true
        PagesTabs.moreRowsChanged()
    }

    /// The card's More section. `-HQDebugDiscordCard YES` shows it again for screenshots and tests.
    static func registerMoreCard() {
        if UserDefaults.standard.bool(forKey: "HQDebugDiscordCard") { cardClosed = false }
        PagesTabs.registerMoreSection(MoreSection(id: sectionID, header: nil) {
            guard !cardClosed else { return [] }
            return [MoreRow(id: "discord-invite", title: "Join the Hermes HQ Discord", symbol: nil, image: nil, tile: .clear, make: {
                openInvite(from: "more card")
                return nil
            }, card: {
                UIHostingConfiguration { DiscordInviteCard() }.margins(.vertical, 0)
            })]
        })
    }
}

/// The card at the top of More: the Discord mark, what the server is for, a Join button, and a close button.
struct DiscordInviteCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .headline) private var markSize: CGFloat = 40

    private var blurple: Color { Color(uiColor: HQCommunity.blurple) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if !typeSize.isAccessibilitySize { mark }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Join the Hermes HQ Discord")
                        .font(Font.hq(.headline))
                        .foregroundStyle(Color.hqLabel)
                    Text("Chat with other people using Hermes HQ, share feedback and hear about new builds first. Close this and the link stays at the bottom of More.")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    HQCommunity.closeCard()
                } label: {
                    Image(systemName: "xmark")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel3)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.hqLabel3.opacity(0.15)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityHint("Hides this card. The Discord link stays at the bottom of More.")
                .accessibilityIdentifier("more.discord.close")
            }
            Button {
                HQCommunity.openInvite(from: "more card join")
            } label: {
                Text("Join the Discord")
                    .font(Font.hq(.subheadline).weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(blurple)
            .accessibilityHint("Opens the Hermes HQ server in Discord.")
            .accessibilityIdentifier("more.discord.join")
        }
        // No identifier here: on a stack SwiftUI hands it to every child, over the buttons' own (the cell has
        // `more-row-discord-invite`).
        .padding(.vertical, 14)
    }

    private var mark: some View {
        RoundedRectangle(cornerRadius: markSize * 0.25, style: .continuous)
            .fill(blurple)
            .frame(width: markSize, height: markSize)
            .overlay {
                Image("Platforms/discord").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: markSize * 0.6, height: markSize * 0.6)
            }
            .accessibilityHidden(true)
    }
}
