// "Restart your gateway to use this change." (docs/spec/3x-morepages.md §12 (6)): the notice Messaging and Webhooks
// show after a change the gateway does not serve hot, and Status & Maintenance's Restart Gateway row. One confirmation, one
// progress line, the same words everywhere.

import SwiftUI
import UIKit

@MainActor
enum GatewayRestart {
    /// "Restart Your Gateway?" · "Bots stop for a moment and running replies are interrupted." · Restart / Cancel.
    static func confirm(from presenter: UIViewController?, then run: @escaping () -> Void) {
        TextPrompt.confirm(title: "Restart Your Gateway?", message: "Bots stop for a moment and running replies are interrupted.",
                           action: "Restart", from: presenter, done: run)
    }

    /// Stress test 2026-10-28 #10: this Hermes has no status route for the restart.
    static let untrackedText = "Restart sent. This Hermes doesn’t report a restart’s progress, so it can’t be followed here."

    /// What the row says for `phase`: nil at rest.
    static func words(_ phase: GatewayActionRun.Phase) -> (text: String, isError: Bool, isBusy: Bool)? {
        switch phase {
        case .idle: return nil
        case .running: return ("Restarting…", false, true)
        case .stalled: return ("Still restarting. This page updates when your gateway is back.", false, true)
        case .untracked: return (GatewayRestart.untrackedText, false, false)
        case .finished(true, _): return ("Gateway Restarted", false, false)
        case .finished(false, let line): return (line ?? "The gateway didn’t restart.", true, false)
        case .failed(let reason): return (reason, true, false)
        }
    }
}

/// The notice with its Restart Gateway button, as a list section.
struct GatewayRestartNotice: View {
    var text = "Restart your gateway to use this change."
    var run: GatewayActionRun
    var canWrite: Bool
    var restart: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(text).foregroundStyle(Color.hqLabel).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Color.hqOrange)
                }
                GatewayRestartProgress(run: run)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gateway-restart.notice")
            if canWrite, !run.isBusy {
                // [mac] Stress test 2026-10-28 #51: a push button at the row's trailing edge on the Mac.
                Button(DeviceWord.isMac ? "Restart Gateway…" : "Restart Gateway", action: restart)
                    .accessibilityIdentifier("gateway-restart.button")
                    .hqMacPushButton()
            }
        }
    }
}

/// "Restarting…" with a spinner, then "Gateway Restarted" or the failure's last line.
struct GatewayRestartProgress: View {
    var run: GatewayActionRun

    var body: some View {
        if let words = GatewayRestart.words(run.phase) {
            HStack(spacing: 8) {
                if words.isBusy { ProgressView().controlSize(.small) }
                Text(words.text)
                    .font(Font.hq(.subheadline))
                    // Green is for "Gateway Restarted" only: a restart that can't be followed isn't known to have worked.
                    .foregroundStyle(words.isError ? Color.hqRed : (words.isBusy || run.phase == .untracked ? Color.hqLabel2 : Color.green))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("gateway-restart.progress")
        }
    }
}
