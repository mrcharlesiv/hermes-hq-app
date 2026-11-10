// DEBUG: every act a dot-matrix face plays (BotMood), on one screen for a recording: `-HQDemoFaces` (add
// `-HQDemoFacesDark` for a dark page). Twelve bots' default heads, one mood each, large and at list size; "done" and
// "failed" play again every few seconds. `-HQDemoFacesTheme blob` or `dots` shows the same moods on Shapes blobs or
// Dots heads (each of the six patterns twice) instead.

#if DEBUG
import UIKit

enum FaceMoodsDemo {
    /// The bots whose heads act, one per mood (in `BotMood.allCases` order): different outlines and colours.
    static let names = ["default", "home", "inbox", "app", "northwind", "gym", "otto", "finance", "maple-revenue-operator",
                        "bike-shop", "ivy", "hermes"]

    static func makeRoot(dark: Bool, theme: String?) -> UIViewController {
        let screen = FaceMoodsDemoController()
        screen.theme = theme
        screen.overrideUserInterfaceStyle = dark ? .dark : .light
        return screen
    }

    /// Bot `index`'s head: its default, or one of `theme`'s (an idea of the bot's own, so colours and faces vary).
    static func head(_ index: Int, theme: String?) -> Head {
        let name = names[index % names.count]
        guard let theme else { return Head.defaultMatrixHead(profile: name) }
        var record = HeadRecord.ideas(profile: name, about: "", round: 0, theme: theme == "blob" ? "shape" : theme)[0]
        if theme == "blob" { record.form = "blob"; record.tile = "none" }
        if theme == "dots" { record.pattern = HeadRecord.patterns[index % HeadRecord.patterns.count] }
        return Head(record: record) ?? Head.resolve(nil, profile: name)
    }
}

private final class FaceMoodsDemoController: UIViewController {
    private var timer: Timer?
    var theme: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = theme.map { "What each bot is doing: \($0 == "blob" ? "Blob" : "Dots")" } ?? "What each bot is doing"
        title.font = .systemFont(ofSize: 22, weight: .bold)
        let big = grid(side: 92, columns: 3, label: 13)
        let small = grid(side: 40, columns: 6, label: 10)
        let caption = UILabel()
        caption.text = "At list size"
        caption.font = .systemFont(ofSize: 15, weight: .semibold)
        caption.textColor = .secondaryLabel   // system-ink-ok: debug-only demo
        let stack = UIStackView(arrangedSubviews: [title, big, caption, small])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(26, after: big)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
        play()
        // The once-only acts again and again.
        timer = Timer.scheduledTimer(withTimeInterval: 3.4, repeats: true) { _ in
            MainActor.assumeIsolated {
                for (index, mood) in BotMood.allCases.enumerated() where mood.once {
                    for size in ["big", "small"] { BotMoods.shared.show(mood, for: Self.follow(index, size)) }
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        timer?.invalidate()
    }

    private static func follow(_ index: Int, _ size: String) -> String { "demo-\(size)-\(index)" }

    private func play() {
        for (index, mood) in BotMood.allCases.enumerated() {
            for size in ["big", "small"] { BotMoods.shared.show(mood, for: Self.follow(index, size)) }
        }
    }

    private func grid(side: CGFloat, columns: Int, label size: CGFloat) -> UIView {
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = side > 60 ? 12 : 8
        let moods = BotMood.allCases
        for start in stride(from: 0, to: moods.count, by: columns) {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = side > 60 ? 20 : 14
            for index in start..<min(start + columns, moods.count) {
                let name = FaceMoodsDemo.names[index % FaceMoodsDemo.names.count]
                let head = HeadView(side: side)
                head.translatesAutoresizingMaskIntoConstraints = false
                head.configure(head: FaceMoodsDemo.head(index, theme: theme), phase: HeadView.phase(for: name),
                               follows: Self.follow(index, side > 60 ? "big" : "small"))
                let word = UILabel()
                word.text = moods[index].rawValue
                word.font = .systemFont(ofSize: size, weight: .medium)
                word.textColor = .secondaryLabel   // system-ink-ok: debug-only demo
                word.textAlignment = .center
                let cell = UIStackView(arrangedSubviews: [head, word])
                cell.axis = .vertical
                cell.alignment = .center
                cell.spacing = 6
                NSLayoutConstraint.activate([
                    head.widthAnchor.constraint(equalToConstant: side), head.heightAnchor.constraint(equalToConstant: side),
                    cell.widthAnchor.constraint(equalToConstant: max(side, side > 60 ? 100 : 44)),
                ])
                row.addArrangedSubview(cell)
            }
            rows.addArrangedSubview(row)
        }
        return rows
    }
}
#endif
