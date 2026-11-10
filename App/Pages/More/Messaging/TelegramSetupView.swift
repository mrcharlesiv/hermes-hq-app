// "Set Up with Telegram" (docs/spec/3x-morepages.md §12): Open Telegram is the way on a phone; the QR code is for
// Telegram on another device (`B/fe-pages-gates.ts` r1-114). The sheet follows `TelegramSetup`: waiting, connected,
// expired. Closing it before Finish gives the pairing back.

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum TelegramQR {
    /// `payload` as a QR code (CoreImage `CIQRCodeGenerator`), black on white, sharp at `side` points.
    static func image(_ payload: String, side: CGFloat = 220, scale: CGFloat = 3) -> UIImage? {
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let factor = max(1, (side * scale / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

struct TelegramSetupView: View {
    let setup: TelegramSetup
    @State private var typedIds = ""
    @State private var openFailed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch setup.phase {
                case .idle, .starting:
                    busy("Starting…")
                case .waiting(let start):
                    waiting(start)
                case .ready(let bot, let owner):
                    ready(bot: bot, owner: owner, applying: false)
                case .applying:
                    busy("Saving…")
                case .applied(let applied):
                    connected(applied.botUsername)
                case .expired:
                    message(symbol: "clock.badge.xmark", title: "Link Expired", text: TelegramSetup.expiredText, button: "Start Again")
                        .accessibilityIdentifier("telegram.expired")
                case .failed(let reason):
                    message(symbol: "exclamationmark.triangle", title: "Couldn’t Start Telegram Setup", text: reason, button: "Try Again")
                        .accessibilityIdentifier("telegram.failed")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color.hqGroupedPage)
        .scrollDismissesKeyboard(.interactively)
    }

    private func busy(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(Color.hqLabel2)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("telegram.busy")
    }

    @ViewBuilder
    private func waiting(_ start: TelegramSetupStart) -> some View {
        // Audit 863 (08d-13): without a link to open, the words don't send you to a button that isn't there.
        Text(start.openURL != nil
             ? "\(DeviceWord.Tap) Open Telegram and confirm there. Hermes creates the bot and finds your Telegram user ID for you."
             : "Scan the code with Telegram and confirm there. Hermes creates the bot and finds your Telegram user ID for you.")
            .font(Font.hq(.body))
            .foregroundStyle(Color.hqLabel)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        if let url = start.openURL {
            Button {
                UIApplication.shared.open(url) { opened in
                    Task { @MainActor in openFailed = !opened }
                }
            } label: {
                Label("Open Telegram", systemImage: "paperplane.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .hqGlassProminentButtonStyle()
            .accessibilityIdentifier("telegram.open")
        }
        if openFailed {
            Text("Telegram didn’t open. Install Telegram on this \(DeviceWord.name), or scan the code with Telegram on another device.")
                .font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let image = TelegramQR.image(start.qrPayload) {
            VStack(spacing: 10) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Telegram setup code")
                    .accessibilityIdentifier("telegram.qr")
                Text("The QR code is for Telegram on another device.")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Telegram…").foregroundStyle(Color.hqLabel2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("telegram.waiting")
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                if let left = setup.remaining(at: timeline.date) {
                    Text("Expires in \(left)").font(Font.hq(.footnote).monospacedDigit()).foregroundStyle(Color.hqLabel2)
                }
            }
            if let notice = setup.notice {
                Text(notice).font(Font.hq(.footnote)).foregroundStyle(Color.hqOrange).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connected(_ bot: String?) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(Font.hq(.largeTitle)).imageScale(.large).foregroundStyle(Color.green).accessibilityHidden(true)
            Text(Self.connectedText(bot)).font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("telegram.connected")
        }
        .padding(.top, 24)
    }

    static func connectedText(_ bot: String?) -> String {
        let name = bot?.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")) ?? ""
        return name.isEmpty ? "Connected to Telegram" : "Connected to @\(name)"
    }

    @ViewBuilder
    private func ready(bot: String?, owner: String?, applying: Bool) -> some View {
        connected(bot)
        if let owner {
            Text("Only you (Telegram user \(owner)) can message this bot at first. You can approve more people later.")
                .font(Font.hq(.subheadline)).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Telegram User ID").font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2)
                TextField("Telegram User ID", text: $typedIds)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.hqGroupedCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("telegram.user-id")
                Text("Telegram didn’t say who you are. Type your numeric Telegram user ID (the bot @userinfobot tells you), so only you can message this bot.")
                    .font(Font.hq(.footnote)).foregroundStyle(Color.hqLabel2).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let notice = setup.notice {
            Text(notice).font(Font.hq(.footnote)).foregroundStyle(Color.hqRed).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("telegram.notice")
        }
        let allowed = owner.map { [$0] } ?? TelegramSetup.userIds(typedIds)
        Button {
            if let allowed { setup.finish(allowed: allowed) }
        } label: {
            Text("Finish").frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .hqGlassProminentButtonStyle()
        .disabled(allowed == nil)
        .accessibilityIdentifier("telegram.finish")
    }

    private func message(symbol: String, title: String, text: String, button: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(Font.hq(.largeTitle)).imageScale(.large).foregroundStyle(Color.hqLabel3).accessibilityHidden(true)
            Text(title).font(Font.hq(.title3).weight(.semibold)).foregroundStyle(Color.hqLabel).multilineTextAlignment(.center)
            Text(text).foregroundStyle(Color.hqLabel2).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button { setup.start() } label: { Text(button).frame(maxWidth: .infinity).padding(.vertical, 6) }
                .hqGlassProminentButtonStyle()
                .accessibilityIdentifier("telegram.restart")
        }
        .padding(.top, 24)
        .accessibilityElement(children: .contain)
    }
}
