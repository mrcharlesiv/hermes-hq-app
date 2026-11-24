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

/// One file's diff, in the steps sheet's panel, on a scrolling page titled with the file's name.
final class PullRequestDiffPage: UIViewController {
    private let patch: String
    private let path: String

    init(name: String, path: String, patch: String) {
        self.patch = patch
        self.path = path
        super.init(nibName: nil, bundle: nil)
        title = name
        navigationItem.largeTitleDisplayMode = .never
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "prcard.diffPage"
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let folder = UILabel()
        folder.text = path
        folder.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: HQFont.mono(ofSize: 13, weight: .regular))
        folder.adjustsFontForContentSizeCategory = true
        folder.textColor = HQPalette.label2
        folder.numberOfLines = 0
        stack.addArrangedSubview(folder)
        stack.addArrangedSubview(DiffPanel(lines: StepRules.diffLines(patch)))
        let margin: CGFloat = DeviceWord.isMac ? 16 : 20
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -margin),
        ])
    }
}
