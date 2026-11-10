// [a11y] DEBUG only: the in-app accessibility walker (spec 3x-a11y §2.5). `-HQA11yAudit YES` adds a one-point
// element "debug.a11y" to the key window; reading its value walks what is on screen and returns JSON:
// {"findings":[{"code":…,"what":…,"where":…}],"elements":N,"actions":{"<identifier or label>":["Pin",…]},"settings":{…}}.
// It sees what XCUITest's own audit cannot: fonts that ignore the text size, allow-lists, custom action names.

#if DEBUG
import UIKit

@MainActor enum HQA11yAudit {
    struct Finding: Codable, Equatable { var code: String; var what: String; var `where`: String }
    struct Report: Codable { var findings: [Finding]; var elements: Int; var actions: [String: [String]]; var settings: [String: String] = [:]; var hints: [String: String] = [:] }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "HQA11yAudit") }
    private static weak var probe: Probe?
    /// Milliseconds from the last tap on "Jump to Latest" until the chat was at the end; nil while it is moving.
    static var jumpSettleMs: Double?

    /// Called when a window becomes key and after announcements; cheap when off.
    static func install() {
        guard enabled, let window = keyWindow else { return }
        let made = probe ?? {
            let p = Probe(frame: CGRect(x: 1, y: 0, width: 1, height: 1))
            p.isAccessibilityElement = true
            p.accessibilityIdentifier = "debug.a11y"
            p.accessibilityLabel = "audit"
            probe = p
            return p
        }()
        if made.window !== window { window.addSubview(made) }
        HQAnnounceProbe.update()
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    }

    final class Probe: UILabel {
        override var accessibilityValue: String? {
            get {
                let report = HQA11yAudit.run()
                return (try? JSONEncoder().encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            }
            set {}
        }
    }

    /// Identifiers (prefix match) of text allowed to keep a fixed size or to truncate (spec §3.4, §4.4).
    static let fixedFontAllowed = ["debug.", "head.", "badge", "gateway-switcher.dot", "reply-peek.initial", "memo.live"]
    static let truncationAllowed = ["debug.", "row.time", "attachment.name", "url", "host", "badge", "composer.placeholder"]

    static func run() -> Report {
        var report = Report(findings: [], elements: 0, actions: [:])
        guard let scene = keyWindow?.windowScene else { return report }
        let now = HQAccessibility.current
        let size = now.contentSize
        func flag(_ on: Bool) -> String { on ? "1" : "0" }
        report.settings = ["size": size.rawValue, "reduceMotion": flag(now.reduceMotion), "reduceTransparency": flag(now.reduceTransparency),
                           "contrast": flag(now.increaseContrast), "bold": flag(now.boldText), "buttonShapes": flag(now.buttonShapes),
                           "voiceOver": flag(now.voiceOver), "chatBold": flag(ChatStyleCache.shared.style(for: size).bold),
                           "chatBody": String(format: "%.1f", ChatStyleCache.shared.style(for: size).body.pointSize)]
        if let jumpSettleMs { report.settings["jumpSettleMs"] = String(format: "%.1f", jumpSettleMs) }
        rendered(scene, into: &report)
        // The topmost app window that holds content (a presented sheet lives in the same window).
        for window in scene.windows where !window.isHidden && window.alpha > 0 {
            walk(window, window: window, into: &report)
            if size.isAccessibilityCategory { texts(window, window: window, size: size, into: &report) }
        }
        return report
    }

    // MARK: What is really drawn (not the settings read back)

    /// Rendered facts for the chat: the weight and natural width of the lowest visible message text (the transcript is
    /// drawn with TextKit, so no UILabel carries it), how many bubbles are on screen and how many of them have an
    /// edge (Increase Contrast), and whether the push stand-in is solid (Reduce Transparency).
    private static func rendered(_ scene: UIWindowScene, into report: inout Report) {
        var texts: [(y: CGFloat, view: TextDrawView)] = []
        var bubbles = 0, edged = 0
        func visit(_ view: UIView, _ window: UIWindow) {
            if view.isHidden || view.alpha < 0.01 { return }
            if let shape = view as? BubbleShapeView, window.bounds.intersects(shape.convert(shape.bounds, to: window)) {
                bubbles += 1
                if shape.shapeLayer.lineWidth >= 1, shape.shapeLayer.strokeColor != nil { edged += 1 }
            }
            if let text = view as? TextDrawView, text.debugTextLength >= 12 {
                let frame = text.convert(text.bounds, to: window)
                if window.bounds.intersects(frame) { texts.append((frame.minY, text)) }
            }
            for sub in view.subviews { visit(sub, window) }
        }
        for window in scene.windows where !window.isHidden { visit(window, window) }
        report.settings["bubbles"] = String(bubbles)
        report.settings["bubblesEdged"] = String(edged)
        if let last = texts.max(by: { $0.y < $1.y })?.view, let font = last.debugFirstFont {
            let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            report.settings["textWeight"] = String(format: "%.2f", (traits?[.weight] as? CGFloat) ?? 0)
            report.settings["textPointSize"] = String(format: "%.1f", font.pointSize)
            report.settings["textWidth"] = String(format: "%.0f", last.debugNaturalWidth)
        }
        report.settings["systemBoldsFonts"] = HQAccessibility.systemBoldsFonts ? "1" : "0"
    }

    // MARK: Accessibility tree

    private static func walk(_ object: NSObject, window: UIWindow, into report: inout Report, depth: Int = 0) {
        guard depth < 60 else { return }
        if let view = object as? UIView {
            if view.isHidden || view.alpha < 0.01 || view.accessibilityElementsHidden { return }
            if view is Probe || (view.accessibilityIdentifier ?? "").hasPrefix("debug.") { return }
        }
        // Custom actions can sit on a container (a list cell) rather than on the element inside it.
        if !object.isAccessibilityElement, let actions = object.accessibilityCustomActions, !actions.isEmpty {
            report.actions[identifier(of: object) ?? String(describing: type(of: object))] = actions.map(\.name)
        }
        if object.isAccessibilityElement { check(object, window: window, into: &report); return }
        if let elements = object.accessibilityElements, !elements.isEmpty {
            for case let element as NSObject in elements { walk(element, window: window, into: &report, depth: depth + 1) }
            return
        }
        if let view = object as? UIView {
            // System bars and the keyboard are the system's to label.
            let name = String(describing: type(of: view))
            if name.hasPrefix("_UIRemote") || name.contains("Keyboard") { return }
            for sub in view.subviews { walk(sub, window: window, into: &report, depth: depth + 1) }
        }
    }

    private static let symbolish = try! NSRegularExpression(pattern: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#)

    private static func check(_ element: NSObject, window: UIWindow, into report: inout Report) {
        report.elements += 1
        let label = element.accessibilityLabel ?? ""
        let value = element.accessibilityValue ?? ""
        let hint = element.accessibilityHint ?? ""
        let identifier = Self.identifier(of: element) ?? ""
        if !hint.isEmpty, !identifier.isEmpty { report.hints[identifier] = hint }
        let traits = element.accessibilityTraits
        let name = identifier.isEmpty ? String(label.prefix(40)) : identifier
        let place = identifier.isEmpty ? String(describing: type(of: element)) : identifier
        let interactive = !traits.isDisjoint(with: [.button, .link, .adjustable]) || element is UIControl
        // In a system bar the system names and sizes the element (bar button items, tab items, the search field).
        let systemChrome = (element as? UIView).map { inSystemBar($0) } ?? false

        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.isEmpty,
           interactive || traits.contains(.image), !(element is UITextField), !(element is UITextView), !systemChrome {
            report.findings.append(Finding(code: "no-label", what: String(describing: type(of: element)), where: place))
        }
        let whole = label as NSString
        if symbolish.firstMatch(in: label, range: NSRange(location: 0, length: whole.length)) != nil || label.contains(".fill") {
            // A file name or a host is words to its reader; only flag on controls and images.
            if interactive || traits.contains(.image) {
                report.findings.append(Finding(code: "raw-symbol", what: label, where: place))
            }
        }
        for text in [label, value, hint] where text.range(of: "dispatch", options: .caseInsensitive) != nil {
            report.findings.append(Finding(code: "banned-word", what: String(text.prefix(80)), where: place))
        }
        if interactive, !systemChrome, !traits.contains(.notEnabled) {
            let frame = element.accessibilityFrame
            if frame.width > 0, frame.height > 0, frame.width < 43.5 || frame.height < 43.5,
               UIAccessibility.convertToScreenCoordinates(window.bounds, in: window).intersects(frame) {
                // A hit area larger than the drawn frame counts (point(inside:) overrides, or a link inside text).
                if !traits.contains(.link), !((element as? UIView).map(hitAreaReaches44) ?? false) {
                    report.findings.append(Finding(code: "small-target",
                                                   what: "\(Int(frame.width))x\(Int(frame.height)) \(label.prefix(30))", where: place))
                }
            }
        }
        if let actions = element.accessibilityCustomActions, !actions.isEmpty {
            report.actions[name] = actions.map(\.name)
        }
    }

    private static func identifier(of object: NSObject) -> String? {
        if let known = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier { return known }
        guard object.responds(to: NSSelectorFromString("accessibilityIdentifier")) else { return nil }
        return object.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func inSystemBar(_ view: UIView) -> Bool {
        var v: UIView? = view
        while let current = v {
            if current is UINavigationBar || current is UITabBar || current is UIToolbar || current is UISearchBar { return true }
            v = current.superview
        }
        return false
    }

    private static func hitAreaReaches44(_ view: UIView) -> Bool {
        let b = view.bounds
        let dx = max(0, (44 - b.width) / 2 - 0.5), dy = max(0, (44 - b.height) / 2 - 0.5)
        return view.point(inside: CGPoint(x: b.minX - dx, y: b.midY), with: nil)
            && view.point(inside: CGPoint(x: b.maxX + dx - 0.1, y: b.midY), with: nil)
            && view.point(inside: CGPoint(x: b.midX, y: b.minY - dy), with: nil)
            && view.point(inside: CGPoint(x: b.midX, y: b.maxY + dy - 0.1), with: nil)
    }

    // MARK: Text that ignores the size, or is cut

    private static func texts(_ view: UIView, window: UIWindow, size: UIContentSizeCategory, into report: inout Report) {
        if view.isHidden || view.alpha < 0.01 { return }
        if view is UINavigationBar || view is UITabBar || view is UIToolbar { return }   // system; Large Content Viewer
        let identifier = view.accessibilityIdentifier ?? ""
        if identifier.hasPrefix("debug.") { return }
        if let label = view as? UILabel, let text = label.text, !text.isEmpty, label.bounds.width > 0,
           window.bounds.intersects(label.convert(label.bounds, to: window)) {
            let place = identifier.isEmpty ? String(text.prefix(30)) : identifier
            if !fixedFontAllowed.contains(where: identifier.hasPrefix), isFixed(label.font) {
                report.findings.append(Finding(code: "fixed-font", what: "\(label.font.pointSize) pt", where: place))
            }
            if !truncationAllowed.contains(where: identifier.hasPrefix), label.lineBreakMode != .byTruncatingMiddle {
                let fit = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
                let lines = label.numberOfLines
                let cut = fit.height > label.bounds.height + 2 || (lines == 1 && label.intrinsicContentSize.width > label.bounds.width + 2)
                if cut, !label.adjustsFontSizeToFitWidth {
                    report.findings.append(Finding(code: "truncated", what: "\(lines) line(s)", where: place))
                }
            }
        }
        for sub in view.subviews { texts(sub, window: window, size: size, into: &report) }
    }

    /// A font that follows the text size comes from a text style or `UIFontMetrics`; UIKit marks both in the
    /// descriptor. A capped font (`maximumPointSize`) is still marked, so caps do not read as fixed.
    static func isFixed(_ font: UIFont) -> Bool {
        let attributes = font.fontDescriptor.fontAttributes
        if attributes[.textStyle] != nil { return false }
        if attributes.keys.contains(where: { $0.rawValue.contains("TextStyle") || $0.rawValue.contains("UIFontMetrics") }) { return false }
        // `UIFontMetrics.scaledFont` returns a font whose descriptor carries the style it was scaled against.
        return !String(describing: font.fontDescriptor).contains("TextStyle")
    }
}
#endif
