// Seams between Bot Info's Computer group, the "is using its screen" notice (presence stream) and the Bot Screen
// viewer (screen stream). Each side sets or reads these; neither imports the other. All nil until a stream sets them.

import SwiftUI
import UIKit

@MainActor enum BotComputerHooks {
    /// Bot Info › Computer, first row: the Screen row ("Watch Screen" / "View Screen" / "Latest Screenshots", value
    /// "Live"), drawn and handled by the screen stream. nil, or a nil answer: no row.
    static var screenRow: ((Bot, UIViewController) -> AnyView?)?
    /// Opens the Bot Screen viewer for a bot (the notice's Watch). nil: no "is using its screen" notice is shown.
    static var openScreen: ((Bot, UIViewController) -> Void)?
    /// A Bot Screen viewer is on screen (any bot): no notices meanwhile.
    static var screenIsOpen: (() -> Bool)?
    /// [terminal] Bot Info › Computer, after Watch Browser: the Terminal row (App/Terminal/TerminalHooks.swift).
    static var terminalRow: ((Bot, UIViewController) -> AnyView?)?
}
