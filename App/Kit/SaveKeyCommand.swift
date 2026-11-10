// ⌘Return saves an editor sheet, as it does in New Job (`JobEditorSheet`): someone who learns it there tries it in
// Edit Bot, Edit Head or New Prompt. With a sheet up the menu's Send is off, so the key is the page's own. A page with
// nothing to save offers no command (the key then does nothing, as the dimmed Save button does).

import UIKit

extension UIKeyCommand {
    static func save(_ title: String, _ action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: "\r", modifierFlags: .command)
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
