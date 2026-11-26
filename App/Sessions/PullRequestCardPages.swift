// [pr-card-detail] Owner 2026-11-21 (option B of artifacts/coding-pr-review/mock1.html): the pages the PR card pushes
// inside its sheet: the check runs (a plain list, each run's name and state mark) and one file's diff, drawn by the
// steps sheet's own `DiffPanel` (App/Chat/Activity/StepSheets.swift) from `StepRules.diffLines`, not a second diff view.

import SwiftUI
import UIKit

/// A check run's state mark: a check, a red cross, or the Working quarter ring.
struct PullRequestCheckMark: View {
    let state: SessionPRChecks.State

    var body: some View {
        switch state {
        case .passed: PRVerdictMark(verdict: .passed(nil), ink: Color.hqLabel2)
        case .failed: PRVerdictMark(verdict: .failing(1), ink: Color.hqLabel2)
        case .running: PRVerdictMark(verdict: .running, ink: Color.hqLabel2)
        }
    }
}

/// The runs of a pull request's checks: failed first, then running, then passed (the add-on's order).
struct PullRequestRunsPage: View {
    let runs: [SessionPRChecks.Run]
    var onOpen: ((URL) -> Void)? = nil

    var body: some View {
        List { Group {
            Section {
                ForEach(Array(runs.enumerated()), id: \.offset) { place, run in
                    runRow(run)
                        .accessibilityIdentifier("prcard.run.\(place)")
                }
            }
        }.hqMacSettingsRowInsets() }
        .settingsList()
        .accessibilityIdentifier("prcard.runs")
    }

    @ViewBuilder private func runRow(_ run: SessionPRChecks.Run) -> some View {
        let content = HStack(alignment: run.summary == nil ? .center : .firstTextBaseline, spacing: 10) {
            PullRequestCheckMark(state: run.state)
                .frame(width: HQFont.scaled(14))
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name)
                    .font(Font.hq(.body))
                    .foregroundStyle(Color.hqLabel)
                    .lineLimit(2)
                if let summary = run.summary {
                    Text(summary)
                        .font(Font.hq(.footnote))
                        .foregroundStyle(run.state == .failed ? Color.hqRed : Color.hqLabel2)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if run.url != nil, onOpen != nil {
                Image(systemName: "arrow.up.right")
                    .font(Font.hq(.caption).weight(.semibold))
                    .foregroundStyle(Color.hqLabel3)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        let spoken = "\(run.name), \(Self.stateWord(run.state))"
        if let url = run.url, let onOpen {
            Button { onOpen(url) } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                .accessibilityHint("Opens on GitHub")
                .accessibilityAddTraits(.isButton)
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
        }
    }

    static func stateWord(_ state: SessionPRChecks.State) -> String {
        switch state {
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .running: return "Running"
        }
    }
}

/// One file's diff on a scrolling page titled with the file's name. Tapping any code line opens an inline comment
/// composer that sends a targeted `file:line` comment straight to the chat's bot.
final class PullRequestDiffPage: UIViewController {
    private let patch: String
    private let path: String
    private let fileName: String
    private let botName: String?
    private let onComment: ((String) -> Void)?

    init(name: String, path: String, patch: String, botName: String? = nil, onComment: ((String) -> Void)? = nil) {
        self.fileName = name
        self.patch = patch
        self.path = path
        self.botName = botName
        self.onComment = onComment
        super.init(nibName: nil, bundle: nil)
        title = name
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let host = UIHostingController(rootView: InteractivePullRequestDiffView(
            fileName: fileName,
            path: path,
            lines: PullRequestDiffLines.parse(patch),
            botName: botName,
            onComment: onComment
        ))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        host.didMove(toParent: self)
    }
}

private struct InteractivePullRequestDiffView: View {
    let fileName: String
    let path: String
    let lines: [PullRequestDiffLines.Line]
    let botName: String?
    let onComment: ((String) -> Void)?

    @State private var selectedLineID: Int? = nil
    @State private var draftNote = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: path)
                    .font(Font.hq(.footnote).monospaced())
                    .foregroundStyle(Color.hqLabel2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DeviceWord.isMac ? 16 : 20)

                if let botName, onComment != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.tap")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqTintText)
                            .accessibilityHidden(true)
                        Text("Tap any line to send a comment to \(botName).")
                            .font(Font.hq(.caption))
                            .foregroundStyle(Color.hqLabel2)
                    }
                    .padding(.horizontal, DeviceWord.isMac ? 16 : 20)
                }

                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        diffRow(line)
                    }
                }
                .background(Color.hqGroupedCard)
                .clipShape(RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: HQShape.radius(12, .control), style: .continuous).strokeBorder(Color.hqStroke.opacity(0.6), lineWidth: 0.5))
                .padding(.horizontal, DeviceWord.isMac ? 16 : 14)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("step.diff")
            }
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .accessibilityIdentifier("prcard.diffPage")
    }

    @ViewBuilder private func diffRow(_ line: PullRequestDiffLines.Line) -> some View {
        let canComment = onComment != nil && line.kind != .hunk && line.number != nil
        let isSelected = selectedLineID == line.id
        let rowBg: Color = switch line.kind {
        case .added: Color.hqGreen.opacity(0.14)
        case .removed: Color.hqRed.opacity(0.14)
        case .hunk: Color.hqTint.opacity(0.08)
        case .context: .clear
        }
        let textColor: Color = switch line.kind {
        case .added: Color.hqGreen
        case .removed: Color.hqRed
        case .hunk: Color.hqTintText
        case .context: Color.hqLabel
        }

        VStack(alignment: .leading, spacing: 0) {
            let content = HStack(alignment: .top, spacing: 8) {
                Text(verbatim: line.number.map(String.init) ?? "···")
                    .font(Font.hqSystem(.caption2, design: .monospaced))
                    .foregroundStyle(Color.hqLabel3)
                    .frame(minWidth: 28, alignment: .trailing)
                Text(verbatim: line.text)
                    .font(Font.hqSystem(.caption, design: .monospaced))
                    .foregroundStyle(textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if canComment {
                    Image(systemName: isSelected ? "bubble.left.fill" : "plus.bubble")
                        .hqSymbolFont(11, cap: 18)
                        .foregroundStyle(isSelected ? Color.hqTint : Color.hqLabel3.opacity(0.6))
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.hqTint.opacity(0.16) : rowBg)
            .contentShape(Rectangle())

            if canComment {
                Button {
                    Haptics.play(.selection)
                    withAnimation(HQMotion.swiftUI(.snappy(duration: 0.2))) {
                        if selectedLineID == line.id {
                            selectedLineID = nil
                        } else {
                            selectedLineID = line.id
                            draftNote = ""
                        }
                    }
                } label: { content }
                .buttonStyle(.plain)
                .accessibilityIdentifier("prcard.diffLine.\(line.kind).\(line.number ?? line.id)")
            } else {
                content
            }

            if isSelected, let lineNum = line.number, let onComment {
                let targetBot = botName ?? "Bot"
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(verbatim: "\(fileName):\(lineNum)")
                            .font(Font.hq(.caption2).monospaced().weight(.semibold))
                            .foregroundStyle(Color.hqTintText)
                        Spacer()
                        Button("Cancel") {
                            withAnimation(HQMotion.swiftUI(.snappy(duration: 0.2))) { selectedLineID = nil }
                        }
                        .font(Font.hq(.caption).weight(.medium))
                        .foregroundStyle(Color.hqLabel2)
                    }

                    TextField("Ask \(targetBot) about this line…", text: $draftNote, axis: .vertical)
                        .font(Font.hq(.subheadline))
                        .padding(9)
                        .background(Color.hqPage, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.hqTint.opacity(0.45), lineWidth: 1))
                        .accessibilityIdentifier("prcard.diffComment.field")

                    HStack {
                        Spacer()
                        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        Button {
                            guard !trimmed.isEmpty else { return }
                            Haptics.play(.selection)
                            let msg = PullRequestDiffLines.commentMessage(path: path, lineNumber: lineNum, codeLine: line.text, note: trimmed)
                            selectedLineID = nil
                            draftNote = ""
                            onComment(msg)
                        } label: {
                            Label("Send to \(targetBot)", systemImage: "paperplane.fill")
                                .font(Font.hq(.caption).weight(.bold))
                                .foregroundStyle(Color.hqOnTint)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(trimmed.isEmpty ? Color.hqLabel3 : Color.hqTint, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(trimmed.isEmpty)
                        .accessibilityIdentifier("prcard.diffComment.send")
                    }
                }
                .padding(10)
                .background(Color.hqTint.opacity(0.08))
                .overlay(alignment: .leading) { Rectangle().fill(Color.hqTint).frame(width: 3) }
                .accessibilityIdentifier("prcard.diffComment")
            }
        }
    }
}
