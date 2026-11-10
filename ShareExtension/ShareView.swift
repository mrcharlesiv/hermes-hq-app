// [share] The share sheet: what's being shared, an optional message, the bot it goes to, and Send
// (docs/spec/3x-share.md §7.2, §8). Port of build 240's ShareExtension/ShareView.swift.
//
// System list and bars, so it reads like the share sheets around it. The only custom surface is the progress card,
// which is real Liquid Glass. Item rows keep 12 pt of vertical padding and bot rows 13 pt; text wraps instead of
// truncating at large type sizes, except file names and link hosts.
//
// Row insets: SwiftUI reads `.listRowInsets` from a row's ROOT view only. Every row therefore sets its insets on the
// outermost view (`rowPadding()`, or on the Button itself for a bot), with the list's own 15 pt top and bottom taken
// out, so a row's padding is the 12-13 pt written here and nothing is added on top of it.

import SwiftUI
import UIKit

struct ShareView: View {
    @Bindable var model: ShareModel
    @FocusState private var typing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(ShareSheetState.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }
                            .accessibilityIdentifier("share.cancel")
                    }
                    if !model.isBlocked {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") { typing = false; model.send() }
                                .fontWeight(.semibold)
                                .disabled(!model.canSend)
                                .accessibilityIdentifier("share.send")
                        }
                    }
                }
        }
        .overlay { progress }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: model.phase)
        .interactiveDismissDisabled(model.isSending)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .blocked(let failure):
            ContentUnavailableView {
                Label(ShareSheetState.blockedTitle, systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(failure.message)
                    .accessibilityIdentifier("share.blocked")
            }
        default:
            ScrollViewReader { proxy in
                List {
                    if !model.items.isEmpty || !model.unreadable.isEmpty || model.phase == .loading { itemsSection }
                    Section {
                        TextField(ShareSheetState.messagePlaceholder(imagesOnly: !model.items.isEmpty && model.items.allSatisfy { $0.kind == .image }),
                                  text: $model.message, axis: .vertical)
                            .lineLimit(1...6)
                            .focused($typing)
                            .rowPadding()
                            .accessibilityIdentifier("share.message")
                    }
                    botsSection
                    if let failure = model.failure { failureSection(failure) }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
                .disabled(model.isSending)
                .opacity(isBusy ? 0.45 : 1)
                // A failed send's message is the list's last box: brought into view, so the sheet doesn't look as if
                // nothing happened when it sits below a long list of bots (UX study 2026-10-19 #89).
                .onChange(of: model.failure) { _, failure in
                    guard failure != nil else { return }
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(Self.failureId, anchor: .top) }
                    }
                }
            }
        }
    }

    /// The card is up: sending, or just sent.
    private var isBusy: Bool {
        switch model.phase {
        case .sending, .sent: return true
        default: return false
        }
    }

    // MARK: What's shared

    @ViewBuilder private var itemsSection: some View {
        Section {
            if model.phase == .loading && model.items.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(ShareSheetState.preparing).foregroundStyle(.secondary)
                }
                .rowPadding()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("share.preparing")
            }
            let images = model.items.filter { $0.kind == .image }
            if !images.isEmpty {
                // The strip runs to the card's edges and its thumbnails slide under them; the content carries the inset.
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images) { item in
                                Group {
                                    if let thumbnail = item.thumbnail {
                                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 64, height: 64)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityElement()
                                .accessibilityLabel(item.name)
                                .accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("share.photo")
                            }
                        }
                    }
                    .contentMargins(.horizontal, 16, for: .scrollContent)
                    // What the Photos sheet calls "Location Included" stays on the phone.
                    Label(ShareSheetState.photoPrivacy, systemImage: "location.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("share.photo-privacy")
                }
                .padding(.vertical, 12)
                .listRowInsets(EdgeInsets())
            }
            ForEach(model.items.filter { $0.kind != .image }) { item in
                itemRow(item)
            }
            ForEach(Array(model.unreadable.enumerated()), id: \.offset) { _, name in
                Label(ShareSheetState.unreadable(name), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).rowPadding()
                    .accessibilityIdentifier("share.unreadable")
            }
            if let line = ShareSheetState.overCap(model.skipped) {
                Label(line, systemImage: "info.circle")
                    .foregroundStyle(.secondary).rowPadding()
                    .accessibilityIdentifier("share.over-cap")
            }
            // A ✕ (and a swipe) leaves it out, so one big file no longer means cancelling the whole share.
            ForEach(model.oversized) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(ShareSheetState.oversized(item.name, limit: model.limit), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(ShareSheetState.oversizedHint).font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("share.oversized")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(ShareSheetState.remove) \(item.name)")
                    .accessibilityIdentifier("share.oversized.remove")
                }
                .rowPadding()
                .swipeActions(edge: .trailing) {
                    Button(ShareSheetState.remove, role: .destructive) { model.remove(item) }
                }
            }
        }
    }

    // The leading symbols have a minimum width, not a fixed one: at the largest type sizes a symbol is wider than
    // 28 pt and would otherwise spill over the text beside it.
    @ViewBuilder private func itemRow(_ item: SharedItem) -> some View {
        switch item.kind {
        case .link(let url):
            HStack(spacing: 12) {
                Image(systemName: "link").font(.title3).foregroundStyle(.tint).frame(minWidth: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.host() ?? url.absoluteString).font(.body).lineLimit(1)
                    Text(url.absoluteString).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .rowPadding()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.link")
        case .text(let text):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "text.quote").font(.title3).foregroundStyle(.secondary).frame(minWidth: 28).accessibilityHidden(true)
                // The row shows the start of a long text; all of it is sent.
                Text(String(text.prefix(600))).font(.callout).lineLimit(4).foregroundStyle(.primary)
            }
            .rowPadding()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.text")
        case .file, .image:
            HStack(spacing: 12) {
                Image(systemName: "doc").font(.title3).foregroundStyle(.secondary).frame(minWidth: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.body).lineLimit(1).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .rowPadding()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("share.file")
        }
    }

    // MARK: Who it goes to

    @ViewBuilder private var botsSection: some View {
        Section {
            if model.bots.isEmpty {
                Text(ShareSheetState.noBots).foregroundStyle(.secondary).rowPadding()
                    .accessibilityIdentifier("share.no-bots")
            }
            ForEach(model.bots) { bot in
                // The button itself is the element VoiceOver reads, so a bot that cannot receive is read as dimmed.
                // It is the row's root, so the insets go here: the whole row, padding included, is the bot's to tap.
                Button { model.choose(bot) } label: { botRow(bot) }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .disabled(!bot.canReceive)
                    .accessibilityLabel(ShareSheetState.spoken(bot))
                    .accessibilityAddTraits(model.selection == bot.key ? .isSelected : [])
                    .accessibilityIdentifier("share.bot." + bot.profile)
            }
        } header: {
            Text(ShareSheetState.botsHeader(gateway: model.gateway))
        }
    }

    private func botRow(_ bot: ShareBot) -> some View {
        HStack(spacing: 12) {
            BotFace(bot: bot, picture: model.face(bot))
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.body).foregroundStyle(bot.canReceive ? .primary : .secondary)
                Text(ShareSheetState.subtitle(bot)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.selection == bot.key {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private static let failureId = "share.failure-row"

    private func failureSection(_ failure: ShareFailure) -> some View {
        Section {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).rowPadding()
                .accessibilityIdentifier("share.failure")
                .id(Self.failureId)
            if failure.retryable {
                Button(ShareSheetState.tryAgain) { typing = false; model.send() }
                    .rowPadding()
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("share.try-again")
            }
        }
    }

    // MARK: Sending

    /// One card from "Connecting…" to "Sent to Ivy": what it says changes at once (two cards cross-fading would show
    /// both sentences over each other for a moment).
    @ViewBuilder private var progress: some View {
        if isBusy {
            VStack(spacing: 14) {
                switch model.phase {
                case .sent(let name):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green).accessibilityHidden(true)
                    Text(ShareSheetState.sent(to: name)).font(.headline).multilineTextAlignment(.center)
                case .sending(let step):
                    ProgressView().controlSize(.large)
                    Text(ShareSheetState.label(step)).font(.headline).multilineTextAlignment(.center)
                default:
                    EmptyView()
                }
            }
            .animation(nil, value: model.phase)
            .padding(.horizontal, 28).padding(.vertical, 24)
            .frame(minWidth: 160)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(.horizontal, 32)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(isSent ? "share.sent" : "share.progress")
        }
    }

    private var isSent: Bool { if case .sent = model.phase { return true }; return false }
}

/// The bot's face as the Bots list draws it, in the app's rounded-square silhouette (22.37 %); its initial on the tint
/// colour when the app had no picture to give.
struct BotFace: View {
    let bot: ShareBot
    let picture: UIImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 36 * 0.2237, style: .continuous)
        Group {
            if let picture {
                Image(uiImage: picture).resizable().scaledToFill()
            } else {
                ZStack {
                    shape.fill(Color(hex: bot.color) ?? Color.accentColor)
                    Text(bot.initial).font(.headline).foregroundStyle(.white)
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(shape)
        .opacity(bot.canReceive ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}

private extension View {
    func rowPadding() -> some View {
        padding(.vertical, 12).listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
    }
}

private extension Color {
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255)
    }
}
