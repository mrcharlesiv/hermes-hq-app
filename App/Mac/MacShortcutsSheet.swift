// [mac-audit K] Owner 2026-11-02: Help › Keyboard Shortcuts. A sheet listing every key the menu bar offers, menu by
// menu, made from the same command lists `KeyCommands.build` puts in the menu bar (so it can never list a key the app
// doesn't have), each named as `validate` names it now, with the second keys (`KeyCommands.alternates`) on the same
// row as the command they repeat.

#if targetEnvironment(macCatalyst)
import UIKit

@MainActor enum KeyShortcutsSheet {
    struct Row: Equatable {
        var title: String
        var keys: [String]
    }

    struct Section: Equatable {
        var title: String
        var rows: [Row]
        /// A line under the section (the Terminal's: what View's text size keys do while it is in front).
        var footer: String? = nil
    }

    /// The menus' key commands as they read now; a command `validate` hides (a ⌘6 with no sixth place) is left out.
    static func sections() -> [Section] {
        let delegate = UIApplication.shared.delegate as? AppDelegate
        func collect(_ elements: [UIMenuElement]) -> [UIKeyCommand] {
            elements.flatMap { element -> [UIKeyCommand] in
                if let menu = element as? UIMenu { return collect(menu.children) }
                return (element as? UIKeyCommand).map { [$0] } ?? []
            }
        }
        let menus: [(String, [UIMenuElement])] = [
            ("Hermes HQ", [KeyCommands.settingsItem()]),
            ("File", KeyCommands.fileItems()),
            ("Edit", KeyCommands.editItems()),
            ("View", KeyCommands.viewItems()),
            ("Chat", ChatMenuBar.menu().children),
            ("Help", KeyCommands.helpItems()),
        ]
        var out: [Section] = []
        var place: [Selector: (section: Int, row: Int)] = [:]   // a command's row, for its second keys
        for (title, elements) in menus {
            var section = Section(title: title, rows: [])
            for command in collect(elements) {
                let original = command.title
                delegate?.validate(command)
                // [keys] Mac UI check 2026-11-13 (K8): ⌘W and ⇧⌘W are listed under their own names whatever is on show;
                // `validate` hides ⇧⌘W while ⌘W itself reads Close Window (always so in the Settings window), and the
                // list opened there lost the row.
                let closing = command.action == KeyCommands.closeChat || command.action == KeyCommands.closeWindow
                // [keys] Round 3: Escape's item hides while its step is View › Back's; its key is still listed.
                let escape = command.action == KeyCommands.escape
                guard closing || escape || !command.attributes.contains(.hidden), let input = command.input else { continue }
                // Escape's item is named for what it would do this moment (with this sheet up, "Close"); here, all of it.
                let name = command.action == KeyCommands.escape ? "Stop Reply, Close or Go Back" : closing ? original : command.title
                // One action under one name (the tabs share theirs, told apart by their place).
                if command.propertyList == nil, let action = command.action { place[action] = (out.count, section.rows.count) }
                section.rows.append(Row(title: name, keys: [keyName(input, command.modifierFlags)]))
            }
            if !section.rows.isEmpty { out.append(section) }
        }
        // The second keys: ⌘. (Escape's), ↑ / ↓ and Return with no field taking them, ⌘=. Not ⌃Tab / ⌃⇧Tab: they
        // walk the window's tabs first ([mac-session-tabs]), so Window lists them, beside Show Next / Previous Tab.
        for command in KeyCommands.alternates {
            guard let action = command.action, let at = place[action], let input = command.input, input != "\t" else { continue }
            out[at.section].rows[at.row].keys.append(keyName(input, command.modifierFlags))
        }
        // [mac-session-tabs] Window lists the tab keys: the window's own tabs, and the Terminal's while this gateway has one.
        let hasTerminal = KeyCommands.root?.placedTabs.contains(where: { $0.tabBarItem.accessibilityIdentifier == "tab-page-terminal" }) == true
        out.insert(window(hasTerminal: hasTerminal), at: out.firstIndex { $0.title == "Help" } ?? out.count)
        return out
    }

    /// [keys] Mac UI check 2026-11-13 (K7) + [Mac AAA 2026-11-17] Q10 + [mac-session-tabs]: the Window menu's tab keys.
    static func window(hasTerminal: Bool) -> Section {
        var rows: [Row] = []
        for command in KeyCommands.windowItems() {
            if command.action == KeyCommands.terminalNewTab, !hasTerminal { continue }
            guard let input = command.input else { continue }
            var keys = [keyName(input, command.modifierFlags)]
            if command.action == KeyCommands.terminalPreviousTab { keys.append("⌃⇧⇥") }
            if command.action == KeyCommands.terminalNextTab { keys.append("⌃⇥") }
            rows.append(Row(title: command.title, keys: keys))
        }
        let footer = hasTerminal
            ? "Show Next Tab and Show Previous Tab walk the tabs at the top of the window, or the Terminal’s tabs while it is in front. While the Terminal is in front, Make Text Bigger, Actual Size and Make Text Smaller (⌘+ ⌘0 ⌘-) size its text, not the app’s."
            : "Show Next Tab and Show Previous Tab walk the tabs at the top of the window, wrapping round at either end."
        return Section(title: "Window", rows: rows, footer: footer)
    }

    /// A key as the menu bar draws it: ⌃⌥⇧⌘ then the key ("⇧⌘F", "⌘↩", "⎋").
    static func keyName(_ input: String, _ flags: UIKeyModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.alternate) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        switch input {
        case "\r": out += "↩"
        case "\t": out += "⇥"
        case " ": out += "Space"
        case UIKeyCommand.inputEscape: out += "⎋"
        case UIKeyCommand.inputDelete: out += "⌫"
        case UIKeyCommand.inputUpArrow: out += "↑"
        case UIKeyCommand.inputDownArrow: out += "↓"
        case UIKeyCommand.inputLeftArrow: out += "←"
        case UIKeyCommand.inputRightArrow: out += "→"
        default: out += input.uppercased()
        }
        return out
    }

    /// A key as `keyName` draws it, in words for VoiceOver ("⇧⌘F" → "Shift Command F").
    static func spokenKey(_ drawn: String) -> String {
        let names: [Character: String] = ["⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command", "↩": "Return",
                                          "⇥": "Tab", "⎋": "Escape", "⌫": "Delete", "↑": "Up Arrow", "↓": "Down Arrow",
                                          "←": "Left Arrow", "→": "Right Arrow"]
        var words: [String] = []
        var rest = Substring(drawn)
        while let first = rest.first, let name = names[first] {
            words.append(name)
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { words.append(rest == "," ? "Comma" : rest == "/" ? "Slash" : rest == "[" ? "Left Bracket" : rest == "]" ? "Right Bracket" : String(rest)) }
        return words.joined(separator: " ")
    }

    static func present(tries: Int = 8) {
        // [mac] Mac polish #12: over the window in front (File, Settings, or main window), never hidden behind it.
        let keyRoot = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        guard let host: UIViewController = keyRoot ?? KeyCommands.settingsInFront ?? KeyCommands.root else { return }
        let over = KeyCommands.presented(host) ?? host
        // [keys] 2026-11-14 (Mac full pass, round 3): picked while a sheet was still closing (this one's Done a moment
        // before), it was presented on that leaving sheet and never showed. It waits for the sheet to go; and a second
        // pick while the list is up leaves the one on show.
        if over.isBeingDismissed || over.presentingViewController?.isBeingDismissed == true {
            guard tries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { present(tries: tries - 1) } }
            return
        }
        if (over as? UINavigationController)?.viewControllers.first is KeyShortcutsList { return }
        let list = KeyShortcutsList(sections: sections())
        let sheet = ChatSheet.wrap(list, title: "Keyboard Shortcuts")
        // [keys] Round 3: with one pane on show `wrap` gives it the page sheet, nearly as tall as the window (9 pt from
        // its top at 900 × 600). It is the other sheets' form sheet, sized from the window it opens over.
        SheetStyle.macTall(sheet, from: over)
        // The list follows its rows' height (`wrap`'s fit), up to the main window's room; over the smaller Settings
        // window that ran past its foot. It stops at the room of the window it opens over.
        if let window = over.view.window ?? host.view.window {
            MacSheetFit.cap(sheet, at: SheetStyle.macTallHeight(window))
        }
        over.present(sheet, animated: true)
    }
}

private final class KeyShortcutsList: UITableViewController {
    private let sections: [KeyShortcutsSheet.Section]

    init(sections: [KeyShortcutsSheet.Section]) {
        self.sections = sections
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = HQPalette.sheetPage
        tableView.allowsSelection = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "key")
        tableView.accessibilityIdentifier = "shortcuts.list"
    }

    // [mac] Mac polish #89: drawn as its sibling sheets are (the Files sheet, Chat Info): in the Desktop Look the look's
    // outlined boxes, not iOS's rounded grey cards, and its capital labels; the look's body size for the rows (the
    // system's value cell kept 17 pt, a size bigger than every other sheet's rows).
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        DesktopTableOutliner.attach(to: tableView)
    }

    override func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        let title = sections[section].title
        var content = UIListContentConfiguration.header().hqScaled()
        if Theme.isDesktop {
            content.attributedText = NSAttributedString(string: title.uppercased(), attributes: DesktopLayout.labelAttributes())
        } else {
            content.text = title
        }
        header.contentConfiguration = content.hqMacSectionHeader()
        header.accessibilityLabel = title
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { sections[section].footer }

    /// The footer in the look's secondary words, as the sheets' other notes.
    override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
        guard let footer = view as? UITableViewHeaderFooterView, let text = sections[section].footer else { return }
        var content = UIListContentConfiguration.footer().hqScaled()
        content.text = text
        content.textProperties.font = HQFont.preferred(.footnote)
        content.textProperties.color = HQPalette.label2
        footer.contentConfiguration = content
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "key", for: indexPath)
        let row = sections[indexPath.section].rows[indexPath.row]
        var content = UIListContentConfiguration.valueCell().hqScaled()
        content.text = row.title
        content.textProperties.font = HQFont.preferred(.body)
        content.textProperties.color = HQPalette.label
        content.secondaryText = row.keys.joined(separator: "   ")
        content.secondaryTextProperties.font = HQFont.preferred(.body)
        content.secondaryTextProperties.color = HQPalette.label2
        cell.contentConfiguration = content
        cell.accessibilityLabel = row.title
        // [Mac AAA 2026-11-16] VoiceOver read the command's name only, never its key: the key is the row's value, in words.
        cell.accessibilityValue = row.keys.map(KeyShortcutsSheet.spokenKey).joined(separator: ", or ")
        return cell
    }
}

extension AppDelegate {
    @objc func hqKeyboardShortcuts(_ sender: Any?) {
        AppLog.note("keys", "keyboard shortcuts")
        KeyShortcutsSheet.present()
    }
}
#endif
