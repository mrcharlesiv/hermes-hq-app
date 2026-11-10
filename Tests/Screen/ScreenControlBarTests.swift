// The bar under a bot's Screen (docs/spec/3x-screen.md §5.5–§5.7), laid out in a real window: upright (keys, then
// modifiers and Paste, then the caption and buttons) and sideways (one row).

import Testing
import UIKit
@testable import HermesHQNative

@MainActor
@Suite("Screen control bar", .serialized)
struct ScreenControlBarTests {
    private func hosted(width: CGFloat, sideways: Bool) async -> (UIWindow, ScreenControlBar)? {
        guard let scene = await ScreenHosting.scene() else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: sideways ? 402 : 874)
        let root = UIViewController()
        if sideways { root.traitOverrides.verticalSizeClass = .compact }
        window.rootViewController = root
        window.isHidden = false
        let bar = ScreenControlBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(bar)
        let slim = bar.heightAnchor.constraint(equalToConstant: 0)
        slim.priority = UILayoutPriority(240)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor), bar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor), slim,
        ])
        return (window, bar)
    }

    /// Every visible button and the caption, by identifier, in the bar's own coordinates.
    private func frames(_ bar: ScreenControlBar) -> [String: CGRect] {
        bar.window?.layoutIfNeeded()
        var out: [String: CGRect] = [:]
        func walk(_ view: UIView, hidden: Bool) {
            let hidden = hidden || view.isHidden
            if let id = view.accessibilityIdentifier, !id.isEmpty, view !== bar, !hidden { out[id] = view.convert(view.bounds, to: bar) }
            view.subviews.forEach { walk($0, hidden: hidden) }
        }
        walk(bar, hidden: false)
        return out
    }

    private func show(_ name: String, _ bar: ScreenControlBar, _ all: [String: CGRect]) {
        let parts = all.sorted { ($0.value.minY, $0.value.minX) < ($1.value.minY, $1.value.minX) }
            .map { "\($0.key.replacingOccurrences(of: "screen.", with: ""))=\(Int($0.value.minX)),\(Int($0.value.minY)) \(Int($0.value.width))x\(Int($0.value.height))" }
        print("BAR \(name) \(Int(bar.bounds.width))x\(Int(bar.bounds.height)): \(parts.joined(separator: " | "))")
    }

    private func model(_ change: (inout ScreenControlBar.Model) -> Void) -> ScreenControlBar.Model {
        var model = ScreenControlBar.Model()
        model.caption = "Hermes is in control"
        model.take = ControlWords.take
        change(&model)
        return model
    }

    private var control: ScreenControlBar.Model {
        model { $0.caption = "You are in control"; $0.take = nil; $0.give = true; $0.keyboard = true; $0.mac = true }
    }

    private let keyIds = ["screen.keyboard.toggle", "screen.key.esc", "screen.key.tab", "screen.key.left", "screen.key.up",
                          "screen.key.down", "screen.key.right", "screen.mod.ctrl", "screen.mod.alt", "screen.mod.meta", "screen.paste"]

    @Test func uprightWatchingIsOneRowAndTheBarIsOnlyAsTallAsItsButton() async {
        guard let (window, bar) = await hosted(width: 402, sideways: false) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        bar.model = model { _ in }
        let all = frames(bar)
        show("upright watching", bar, all)
        guard let caption = all["screen.caption"], let take = all["screen.take"] else { Issue.record("caption and Take over: \(all)"); return }
        #expect(bar.bounds.height <= 70, "one row: \(bar.bounds.height)")
        #expect(caption.maxX <= take.minX, "the caption and the button share the row")
        #expect(caption.minX >= 16 && abs(take.maxX - (402 - 16)) < 1, "inside the side margins, the button at the far edge")
        #expect(take.height >= 44)
        #expect(take.width >= 120 && take.width <= 200, "the button is as wide as its words, not half the row: \(take)")
        #expect(caption.width > take.width, "the caption has the rest")
        #expect(all["screen.give"] == nil && all["screen.force"] == nil && all["screen.keyboard.toggle"] == nil)
    }

    @Test func twoButtonsOnANarrowScreenSitUnderTheCaption() async {
        guard let (window, bar) = await hosted(width: 402, sideways: false) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        bar.model = model { $0.caption = "You were in control"; $0.held = true; $0.take = ControlWords.resume; $0.give = true }
        var all = frames(bar)
        show("upright held", bar, all)
        guard let caption = all["screen.caption"], let take = all["screen.take"], let give = all["screen.give"] else { Issue.record("\(all)"); return }
        #expect(caption.maxY <= give.minY, "the caption has its own line")
        #expect(caption.height < 30, "and is not squeezed into a column of letters: \(caption)")
        #expect(abs(give.width - take.width) < 1 && give.maxX <= take.minX, "the two buttons share the row equally")
        #expect(abs(give.minY - take.minY) < 1)

        bar.model = model { $0.caption = "Another viewer is in control"; $0.force = true }
        all = frames(bar)
        show("upright other viewer", bar, all)
        guard let force = all["screen.force"], let other = all["screen.take"], let words = all["screen.caption"] else { Issue.record("\(all)"); return }
        #expect(words.maxY <= force.minY && words.height < 30)
        #expect(force.maxX <= other.minX && other.maxX <= 402 - 16 + 0.5)
    }

    @Test func uprightTypingHasTheKeysThenTheModifiersThenTheCaption() async {
        guard let (window, bar) = await hosted(width: 402, sideways: false) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        var typing = control
        bar.model = typing
        var all = frames(bar)
        show("upright control", bar, all)
        #expect(all["screen.keyboard.toggle"] != nil && all["screen.key.esc"] == nil, "only the keyboard button until the keyboard is up")
        #expect(all["screen.fit"] == nil, "Fit only while zoomed")

        typing.typing = true
        typing.fit = true
        bar.model = typing
        all = frames(bar)
        show("upright typing", bar, all)
        for id in keyIds + ["screen.fit"] {
            guard let frame = all[id] else { Issue.record("\(id) is missing"); continue }
            #expect(frame.width >= 43.5 && frame.height >= 43.5, "\(id) keeps a 44 pt target: \(frame)")
            #expect(frame.width <= 90, "\(id) is not stretched: \(frame)")
        }
        guard let esc = all["screen.key.esc"], let ctrl = all["screen.mod.ctrl"], let give = all["screen.give"], let paste = all["screen.paste"] else { return }
        #expect(esc.maxY <= ctrl.minY && ctrl.maxY <= give.minY, "three rows: keys, modifiers and Paste, the caption and Hand back")
        #expect(abs(paste.minY - ctrl.minY) < 1, "Paste sits with the modifiers")

        // Off the Mac there is no ⌥ or ⌘.
        typing.mac = false
        bar.model = typing
        all = frames(bar)
        #expect(all["screen.mod.ctrl"] != nil && all["screen.mod.alt"] == nil && all["screen.mod.meta"] == nil && all["screen.paste"] != nil)

        // An armed modifier is drawn selected.
        typing.armed = [.ctrl]
        bar.model = typing
        let buttons = bar.descendants(of: UIButton.self)
        #expect(buttons.first { $0.accessibilityIdentifier == "screen.mod.ctrl" }?.isSelected == true)
        #expect(buttons.first { $0.accessibilityIdentifier == "screen.mod.ctrl" }?.accessibilityTraits.contains(.selected) == true)
    }

    @Test func sidewaysEverythingIsOneRowAndHandBackStaysInReach() async {
        guard let (window, bar) = await hosted(width: 874, sideways: true) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        bar.model = model { _ in }
        var all = frames(bar)
        show("sideways watching", bar, all)
        #expect(bar.bounds.height <= 70)
        if let take = all["screen.take"] {
            #expect(take.width >= 120 && take.width <= 200 && abs(take.maxX - (874 - 16)) < 1, "Take over keeps its size on a wide screen: \(take)")
        } else {
            Issue.record("Take over is missing: \(all)")
        }

        bar.model = control
        all = frames(bar)
        show("sideways control", bar, all)
        guard let toggle = all["screen.keyboard.toggle"], let caption = all["screen.caption"], let give = all["screen.give"] else { Issue.record("\(all)"); return }
        #expect(bar.bounds.height <= 70, "one row: \(bar.bounds.height)")
        #expect(toggle.maxX <= caption.minX && caption.maxX <= give.minX)
        #expect(toggle.width <= 70, "the keyboard button keeps its own size: \(toggle)")
        #expect(give.width >= 120 && give.width <= 200 && abs(give.maxX - (874 - 16)) < 1, "so does Hand back: \(give)")

        var typing = control
        typing.typing = true
        typing.fit = true
        bar.model = typing
        all = frames(bar)
        show("sideways typing", bar, all)
        #expect(bar.bounds.height <= 70, "still one row with every key: \(bar.bounds.height)")
        #expect(all["screen.caption"] == nil, "the caption gives its room to the keys")
        guard let back = all["screen.give"], let first = all["screen.keyboard.toggle"] else { Issue.record("\(all)"); return }
        #expect(abs(back.maxX - (874 - 16)) < 1 && back.width >= 43.5 && back.width <= 60, "Hand back is a 44 pt icon at the far edge: \(back)")
        if let keys = all["screen.keys"] { #expect(keys.maxX <= back.minX, "the keys end before it: \(keys)") }
        #expect(first.width <= 70, "\(first)")
        for id in keyIds + ["screen.fit"] {
            guard let frame = all[id] else { Issue.record("\(id) is missing"); continue }
            #expect(abs(frame.midY - back.midY) < 2, "\(id) is on the one row")
            #expect(frame.width >= 43.5 && frame.width <= 90, "\(id): \(frame)")
        }
        let iconed = bar.descendants(of: UIButton.self).first { $0.accessibilityIdentifier == "screen.give" }
        #expect(iconed?.accessibilityLabel == "Give Back" && iconed?.largeContentTitle == "Give Back" && iconed?.showsLargeContentViewer == true)
        #expect(iconed?.configuration?.title == nil && iconed?.configuration?.image != nil, "an icon, with its name for VoiceOver")

        // Back to watching sideways (keyboard down): the worded button returns.
        bar.model = control
        all = frames(bar)
        #expect((all["screen.give"]?.width ?? 0) >= 120)
        let worded = bar.descendants(of: UIButton.self).first { $0.accessibilityIdentifier == "screen.give" }
        #expect(worded?.configuration?.title == "Give Back" && worded?.configuration?.image == nil)
    }

    /// Review finding 4: sideways with the keyboard up, Paste was drawn cut in half under "Hand back". Every key must
    /// be whole inside the visible part of the row, at the full 874 pt and at the 750 pt an iPhone 17 Pro has between
    /// its safe areas, with the Mac's modifiers and Fit showing.
    @Test func sidewaysTypingShowsEveryKeyWhole() async {
        for width in [874.0, 750.0] {
            guard let (window, bar) = await hosted(width: width, sideways: true) else { Issue.record("no window scene"); return }
            defer { window.isHidden = true }
            var typing = control
            typing.typing = true
            typing.fit = true
            bar.model = typing
            let all = frames(bar)
            show("sideways typing \(Int(width))", bar, all)
            guard let keys = all["screen.keys"], let back = all["screen.give"] else { Issue.record("\(all)"); continue }
            #expect(back.maxX <= width - 16 + 0.5 && back.width >= 43.5)
            for id in keyIds + ["screen.fit"] {
                guard let frame = all[id] else { Issue.record("\(id) is missing at \(width)"); continue }
                #expect(frame.minX >= keys.minX - 0.5 && frame.maxX <= keys.maxX + 0.5, "\(id) is whole inside the row at \(Int(width)): \(frame) in \(keys)")
                #expect(frame.maxX <= back.minX, "\(id) is clear of Hand back at \(Int(width))")
                #expect(frame.width >= 43.5, "\(id) keeps its 44 pt target")
            }
            let scroll = bar.descendants(of: ScreenKeysScrollView.self).first { $0.accessibilityIdentifier == "screen.keys" }
            #expect(scroll?.overflows == false, "nothing to scroll to at \(Int(width)): content \(String(describing: scroll?.contentSize)) in \(String(describing: scroll?.bounds))")
        }
    }

    /// A phone too narrow for every key (an iPhone SE sideways, 667 pt): the row scrolls and shows its indicator.
    @Test func aRowTooNarrowForItsKeysScrollsAndSaysSo() async {
        guard let (window, bar) = await hosted(width: 520, sideways: true) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        var typing = control
        typing.typing = true
        typing.fit = true
        bar.model = typing
        let all = frames(bar)
        show("sideways typing 520", bar, all)
        guard let scroll = bar.descendants(of: ScreenKeysScrollView.self).first(where: { $0.accessibilityIdentifier == "screen.keys" }) else { Issue.record("no key row"); return }
        #expect(scroll.overflows && scroll.showsHorizontalScrollIndicator && scroll.contentSize.width > scroll.bounds.width)
        if let keys = all["screen.keys"], let back = all["screen.give"] { #expect(keys.maxX <= back.minX, "the row ends before Hand back") }
    }

    @Test func atTheLargestTextSizeTheButtonsStackAndKeepTheirTargets() async {
        guard let (window, bar) = await hosted(width: 402, sideways: false) else { Issue.record("no window scene"); return }
        defer { window.isHidden = true }
        window.rootViewController?.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        bar.model = model { $0.caption = "Another viewer is in control"; $0.force = true }
        let all = frames(bar)
        show("AX5 other viewer", bar, all)
        guard let caption = all["screen.caption"], let force = all["screen.force"], let take = all["screen.take"] else { Issue.record("\(all)"); return }
        #expect(caption.maxY <= force.minY && force.maxY <= take.minY, "the caption, then each button on its own line")
        #expect(force.width > 300 && take.width > 300, "full-width buttons")
        #expect(caption.minX >= 16 && force.maxX <= 402 - 16 + 0.5)
    }
}

private extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { view in ((view as? T).map { [$0] } ?? []) + view.descendants(of: type) }
    }
}
