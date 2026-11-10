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
        ]
        var out: [Section] = []
        var place: [Selector: (section: Int, row: Int)] = [:]   // a command's row, for its second keys
        for (title, elements) in menus {
            var section = Section(title: title, rows: [])
            for command in collect(elements) {
                delegate?.validate(command)
                guard !command.attributes.contains(.hidden), let input = command.input else { continue }
                // Escape's item is named for what it would do this moment (with this sheet up, "Close"); here, all of it.
                let name = command.action == KeyCommands.escape ? "Stop Reply, Close or Go Back" : command.title
                // One action under one name (the tabs share theirs, told apart by their place).
                if command.propertyList == nil, let action = command.action { place[action] = (out.count, section.rows.count) }
                section.rows.append(Row(title: name, keys: [keyName(input, command.modifierFlags)]))
            }
            if !section.rows.isEmpty { out.append(section) }
        }
        // The second keys: ⌃Tab / ⌃⇧Tab, ⌘. (Escape's), ↑ / ↓ and Return with no field taking them, ⌘=.
        for command in KeyCommands.alternates {
            guard let action = command.action, let at = place[action], let input = command.input else { continue }
            out[at.section].rows[at.row].keys.append(keyName(input, command.modifierFlags))
        }
        return out
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

    static func present() {
        // [mac] Mac polish #12: over the window in front (the Settings window when it is), not the main window behind it.
        guard let host: UIViewController = KeyCommands.settingsInFront ?? KeyCommands.root else { return }
        let list = KeyShortcutsList(sections: sections())
        let sheet = ChatSheet.wrap(list, title: "Keyboard Shortcuts")
        (KeyCommands.presented(host) ?? host).present(sheet, animated: true)
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
