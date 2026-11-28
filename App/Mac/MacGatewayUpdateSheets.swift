// [Mac calls 2026-11-17] Owner's call (Q20): on the Mac, Update Hermes (HermesUpdate.swift) and Update Add-on
// (AddOnUpdate.swift, which a plugin update runs in too) take the compact layout of the Mac app's own update window
// (MacAppUpdate.swift): the small icon beside the headline and its lines, the steps and What's New on cards, the Mac's
// button row with the default button last, the sheet as tall as what it shows. Built from MacUpdateSheetKit.swift, the
// same pieces the Mac app's window is drawn from. Every word, step and action is the iPhone sheet's; the close word
// the iPhone's bar carried (Not Now, Hide, Done) is a button of the row. iPhone and iPad keep their sheets.

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

extension HermesUpdate {
    /// The Mac's sheet for this run.
    func macSheet() -> UIViewController {
        let room = MacUpdateRoom()
        return MacUpdateSheetController(room: room, root: MacHermesUpdateView(update: self, room: room)) { [weak self] in
            self?.sheetClosed()
        }
    }
}

extension AddOnUpdate {
    /// The Mac's sheet for this run.
    func macSheet() -> UIViewController {
        let room = MacUpdateRoom()
        return MacUpdateSheetController(room: room, root: MacAddOnUpdateView(update: self, room: room)) { [weak self] in
            self?.sheetClosed()
        }
    }
}

// MARK: - Update Hermes

struct MacHermesUpdateView: View {
    @Bindable var update: HermesUpdate
    var room: MacUpdateRoom

    var body: some View {
        MacUpdateSheet(room: room, showsMiddle: command != nil || update.showsSteps || update.showsWhatsNew) {
            header
        } middle: {
            if let command {
                Text(command)
                    .font(Font.hqSystem(.callout, design: .monospaced))
                    .foregroundStyle(Color.hqLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .macUpdateCard()
                    .accessibilityIdentifier("hermes-update.command")
            }
            if update.showsSteps {
                MacUpdateStepsCard(items: update.steps, id: "hermes-update.steps") { step, below in
                    MacUpdateStepRow(mark: Self.mark(step.state), title: step.title, detail: Self.detail(step),
                                     below: below, idPrefix: "hermes-update", stepID: step.id.rawValue)
                }
            }
            if update.showsWhatsNew {
                MacUpdateNotes(title: "What’s New", intro: nil, items: update.commits.map(\.summary), id: "hermes-update.whats-new")
            }
        } buttons: {
            buttons
        }
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move)), value: update.phase)
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move)), value: update.steps)
        .accessibilityIdentifier("hermes-update")
    }

    private var command: String? {
        if case .ended(.cantUpdateHere(_, let command?)) = update.phase { return command }
        return nil
    }

    private var header: some View {
        MacUpdateHeader(headline: update.headline, headlineID: "hermes-update.headline") {
            MacUpdateSymbol(symbol: update.symbol)
        } lines: {
            if let versions = update.versions { MacUpdateVersions(text: versions, id: "hermes-update.versions") }
            // Which machine this is, so a gateway is never taken for a Nous agent (or the other way round).
            Label(update.place, systemImage: update.kind == .cloud ? "cloud" : "server.rack")
                .font(Font.hq(.footnote).weight(.medium))
                .foregroundStyle(Color.hqLabel2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hermes-update.place")
            if let line = update.line { MacUpdateLine(text: line, id: "hermes-update.line") }
        }
    }

    static func mark(_ state: HermesUpdateStepState) -> MacUpdateMark {
        switch state {
        case .waiting: .waiting
        case .active: .active
        case .done: .done
        case .skipped: .skipped
        case .failed: .failed
        }
    }

    /// The row's line: how long a finished step took, why a step was skipped, or what it does (or will do).
    static func detail(_ step: HermesUpdate.Step) -> String? {
        switch step.state {
        case .done:
            guard let started = step.started, let finished = step.finished else { return nil }
            return CloudCopy.elapsed(max(0, Int(finished.timeIntervalSince(started))))
        case .skipped: return HermesUpdate.skippedWords(step.id)
        default: return step.detail
        }
    }

    private var hasOutput: Bool { update.action?.lines.isEmpty == false }

    /// The Mac's order: a secondary action on the left, the close word, the default button last on the right.
    @ViewBuilder
    private var buttons: some View {
        switch update.phase {
        case .checking:
            Spacer()
            push("Hide", id: "hermes-update.close", prominent: true) { update.close() }
        case .asking:
            Spacer()
            push("Not Now", id: "hermes-update.close") { update.close() }
            push("Update", id: "hermes-update.go", prominent: true) { update.confirm() }
        case .working:
            if let started = update.workStarted ?? update.steps.first(where: { $0.id != .check })?.started {
                MacUpdateElapsed(since: started)
            }
            Spacer()
            push("Hide", id: "hermes-update.close", prominent: true) { update.close() }
        case .ended(.cantUpdateHere(_, _?)):
            Spacer()
            push("Done", id: "hermes-update.close") { update.close() }
            push("Copy Command", id: "hermes-update.copy-command", prominent: true) { update.copyCommand() }
        case .ended(.failed) where update.checkFailed:
            // Nothing started: the check can simply run again.
            push("Copy Details", id: "hermes-update.copy") { update.copyDetails() }
            Spacer()
            push("Done", id: "hermes-update.close") { update.close() }
            push("Try Again", id: "hermes-update.retry", prominent: true) { update.check() }
        case .ended(.failed):
            if update.canTryAgain {
                push("Copy Details", id: "hermes-update.copy") { update.copyDetails() }
                Spacer()
                if hasOutput { push("Show Update Output", id: "hermes-update.output") { update.openOutput() } }
                push("Done", id: "hermes-update.close") { update.close() }
                push("Try Again", id: "hermes-update.retry", prominent: true) { update.tryAgain() }
            } else {
                if hasOutput { push("Show Update Output", id: "hermes-update.output") { update.openOutput() } }
                Spacer()
                push("Done", id: "hermes-update.close") { update.close() }
                push("Copy Details", id: "hermes-update.copy", prominent: true) { update.copyDetails() }
            }
        case .ended(.updated), .ended(.unchanged), .ended(.unconfirmed):
            // What Hermes printed stays reachable after any finished run.
            if hasOutput { push("Show Update Output", id: "hermes-update.output") { update.openOutput() } }
            Spacer()
            push("Done", id: "hermes-update.close", prominent: true) { update.close() }
        case .ended:
            Spacer()
            push("Done", id: "hermes-update.close", prominent: true) { update.close() }
        }
    }

    private func push(_ title: String, id: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        MacUpdateButton(title: title, id: id, prominent: prominent, perform: perform)
    }
}

// MARK: - Update Add-on (and a plugin's update)

struct MacAddOnUpdateView: View {
    @Bindable var update: AddOnUpdate
    var room: MacUpdateRoom

    var body: some View {
        MacUpdateSheet(room: room, showsMiddle: update.showsChanges || update.showsSteps) {
            MacUpdateHeader(headline: update.headline, headlineID: "addon-update.headline") {
                MacUpdateSymbol(symbol: update.symbol)
            } lines: {
                if let line = update.line { MacUpdateLine(text: line, id: "addon-update.line") }
            }
        } middle: {
            if update.showsChanges {
                VStack(alignment: .leading, spacing: 8) {
                    Text(update.setUp ? "What’s Included" : "What’s Changing")
                        .font(Font.hq(.footnote).weight(.semibold))
                        .foregroundStyle(Color.hqLabel2)
                    ForEach(update.changes) { MacAddOnChangesCard(item: $0, setUp: update.setUp) }
                }
            }
            if update.showsSteps {
                VStack(alignment: .leading, spacing: 8) {
                    MacUpdateStepsCard(items: update.steps, id: "addon-update.steps") { step, below in
                        MacUpdateStepRow(mark: Self.mark(step.state), title: step.title, detail: Self.detail(step),
                                         below: below, idPrefix: "addon-update", stepID: step.id.rawValue)
                    }
                    if update.phase == .asking {
                        MacUpdateFootnote { Text(AddOnUpdate.takesAboutAMinute) }
                    }
                }
            }
        } buttons: {
            buttons
        }
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move)), value: update.phase)
        .animation(HQMotion.swiftUI(.smooth(duration: HQMotion.move)), value: update.steps)
        .accessibilityIdentifier("addon-update")
    }

    static func mark(_ state: AddOnUpdate.StepState) -> MacUpdateMark {
        switch state {
        case .waiting: .waiting
        case .active: .active
        case .done: .done
        case .skipped: .skipped
        case .failed: .failed
        }
    }

    static func detail(_ step: AddOnUpdate.Step) -> String? {
        if step.state == .done {
            guard let started = step.started, let finished = step.finished else { return nil }
            return CloudCopy.elapsed(max(0, Int(finished.timeIntervalSince(started))))
        }
        return step.detail
    }

    @ViewBuilder
    private var buttons: some View {
        switch update.phase {
        case .idle:
            Spacer()
            push("Done", id: "addon-update.close", prominent: true) { update.close() }
        case .checking:
            Spacer()
            push("Hide", id: "addon-update.close", prominent: true) { update.close() }
        case .asking:
            if update.offersRestartChoice { restartChooser }
            Spacer()
            push("Not Now", id: "addon-update.close") { update.close() }
            push(update.setUp ? "Set Up" : "Update", id: "addon-update.go", prominent: true) { update.confirm() }
        case .working:
            if let started = update.steps.first?.started { MacUpdateElapsed(since: started) }
            Spacer()
            push("Hide", id: "addon-update.close", prominent: true) { update.close() }
        case .ended(.unreachable), .ended(.failed):
            Spacer()
            push("Done", id: "addon-update.close") { update.close() }
            push("Try Again", id: "addon-update.retry", prominent: true) { update.retry() }
        case .ended(.slow):
            Spacer()
            push("Done", id: "addon-update.close") { update.close() }
            push("Open \(update.botName)’s Chat", id: "addon-update.chat", prominent: true) { update.openBotChat() }
        case .ended(.yours):   // [manual-restart]
            Spacer()
            push("Done", id: "addon-update.close") { update.close() }
            push(AddOnUpdate.askInstead(update.botName), id: "addon-update.ask-bot", prominent: true) { update.askBotInstead() }
        case .ended(.more):   // [plugin-ask-bot]
            Spacer()
            push("Done", id: "addon-update.close") { update.close() }
            push(PluginUpdateFlow.shared.handOffButton, id: "addon-update.ask-bot-update", prominent: true) { PluginUpdateFlow.shared.askBotToFinish() }
        case .ended:
            Spacer()
            push("Done", id: "addon-update.close", prominent: true) { update.close() }
        }
    }

    /// [manual-restart] The switch for restarting Hermes yourself, at the row's left as a Mac sheet's option sits beside
    /// its buttons. Owner 2026-11-10: a toggle, not a menu.
    private var restartChooser: some View {
        Toggle(isOn: Binding(get: { update.byHand }, set: { update.chooseRestart(byHand: $0) })) {
            Text(AddOnUpdate.byHandToggle)
                .font(Font.hq(.subheadline))
                .foregroundStyle(Color.hqLabel)
                .lineLimit(1)
                .fixedSize()
        }
        .controlSize(.regular)
        .fixedSize()
        .accessibilityIdentifier("addon-update.restart-choice")
    }

    private func push(_ title: String, id: String, prominent: Bool = false, perform: @escaping () -> Void) -> some View {
        MacUpdateButton(title: title, id: id, prominent: prominent, perform: perform)
    }
}

/// [addon-whats-new] One add-on in the update, on a card: its name and versions ("0.9.33 → 0.9.40"), then a line per
/// newer version (expandable past 3), a loading note while fetching, or a clear fallback summary when no lines exist.
private struct MacAddOnChangesCard: View {
    var item: AddOnUpdate.Changing
    var setUp: Bool
    @State private var expanded = false

    private static let previewLimit = 3

    private var shownLines: [AddOnChanges.Change] {
        expanded ? item.lines : Array(item.lines.prefix(Self.previewLimit))
    }

    private var hiddenCount: Int { max(0, item.lines.count - Self.previewLimit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Font.hq(.body).weight(.semibold))
                        .foregroundStyle(Color.hqLabel)
                    if let note = item.note {   // [plugin-updates] which bots get it
                        Text(note)
                            .font(Font.hq(.footnote))
                            .foregroundStyle(Color.hqLabel2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let versions = AddOnUpdate.versions(from: item.from, to: item.to, setUp: setUp) {
                    MacUpdateVersions(text: versions, id: "addon-update.versions")
                } else if item.loading {
                    ProgressView().controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
            if item.loading && item.lines.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking what’s new…")
                        .font(Font.hq(.subheadline))
                        .foregroundStyle(Color.hqLabel2)
                }
                .accessibilityIdentifier("addon-update.loading-changes")
            } else if item.lines.isEmpty, let fallback = item.fallback, !fallback.isEmpty {
                Text(fallback)
                    .font(Font.hq(.subheadline))
                    .foregroundStyle(Color.hqLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("addon-update.fallback")
            } else {
                ForEach(shownLines, id: \.version) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(change.version)
                            .font(Font.hq(.caption).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.hqLabel2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            // [Mac AAA 2026-11-16] Room for "0.9.40": one column across the cards.
                            .frame(minWidth: 52, alignment: .leading)
                        Text(change.line)
                            .font(Font.hq(.subheadline))
                            .foregroundStyle(Color.hqLabel)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("addon-update.change")
                }
                if hiddenCount > 0 {
                    Button {
                        withAnimation(HQMotion.swiftUI(.smooth(duration: HQMotion.move))) { expanded.toggle() }
                    } label: {
                        Text(expanded ? "Show Fewer" : "Show \(hiddenCount) Earlier \(hiddenCount == 1 ? "Update" : "Updates")")
                            .font(Font.hq(.footnote).weight(.medium))
                            .foregroundStyle(Color.hqTint)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .accessibilityIdentifier("addon-update.more-changes")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .macUpdateCard()
    }
}
#endif
