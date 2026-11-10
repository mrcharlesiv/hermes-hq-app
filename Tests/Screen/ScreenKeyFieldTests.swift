// The hidden field that feeds the bot's screen (docs/spec/3x-screen.md §5.6), driven the way the iOS keyboard drives
// any text field: `insertText` and `deleteBackward` on a first responder in a real window.

import Testing
import UIKit
@testable import HermesHQNative

// [mac-audit #27] 2026-11-02: the Mac's ScreenKeyField is a plain key-reading view (no UITextField), so these iPhone
// tests don't compile for Mac Catalyst; they run on the iPhone simulator.
#if !targetEnvironment(macCatalyst)
@MainActor
@Suite("Screen key field", .serialized)
struct ScreenKeyFieldTests {
    private func hosted() async -> (UIWindow, ScreenKeyField)? {
        guard let scene = await ScreenHosting.scene() else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        let field = ScreenKeyField()
        root.view.addSubview(field)
        return (window, field)
    }

    @Test func everyInsertedCharacterIsHandedOnOnceAndTheFieldStaysEmpty() async {
        guard let (window, field) = await hosted() else { Issue.record("no window scene"); return }
        defer { field.resignFirstResponder(); window.isHidden = true }
        var texts: [String] = []
        var keys: [ScreenKeys.Named] = []
        var focus: [Bool] = []
        field.onText = { texts.append($0) }
        field.onKey = { key, _ in keys.append(key) }
        field.onFocusChange = { focus.append($0) }
        guard field.becomeFirstResponder() else { Issue.record("the field did not take the keyboard"); return }
        #expect(focus == [true])

        for piece in ["H", "i", " ", "é", " ", "€", "👋", "你好"] { field.insertText(piece) }
        #expect(texts == ["H", "i", " ", "é", " ", "€", "👋", "你好"], "one hand-over per commit, spaces included")
        #expect((field.text ?? "").isEmpty, "the field holds nothing")

        // Delete on the (always empty) field is BackSpace for the bot's screen; Return is Return.
        field.deleteBackward()
        field.deleteBackward()
        #expect(keys == [.backspace, .backspace])
        #expect(field.textFieldShouldReturn(field) == false)
        #expect(keys == [.backspace, .backspace, .enter])
        #expect(texts.count == 8, "named keys are not text")

        field.resignFirstResponder()
        #expect(focus == [true, false])
        // Text that lands after the keyboard left goes nowhere.
        field.insertText("x")
        #expect(texts.count == 8)
    }

    @Test func theFieldOffersNoEditMenuAndNoCaret() {
        let field = ScreenKeyField()
        #expect(field.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil) == false)
        #expect(field.canPerformAction(#selector(UIResponderStandardEditActions.selectAll(_:)), withSender: nil) == false)
        #expect(field.caretRect(for: field.beginningOfDocument) == .zero)
        #expect(field.autocorrectionType == .no && field.autocapitalizationType == .none && field.spellCheckingType == .no)
        #expect(field.accessibilityLabel == "Type on the bot’s screen")
    }

    /// Review finding: a named key held with two or more modifiers reached nothing (one command per single modifier).
    @Test func namedKeysCarryEveryHeldModifier() {
        let field = ScreenKeyField()
        var got: [(ScreenKeys.Named, Set<ScreenKeys.Modifier>)] = []
        field.onKey = { got.append(($0, $1)) }
        let commands = field.keyCommands ?? []
        #expect(commands.count == 23 * 16, "7 keys, then Home, End, Page Up/Down and F1-F12 (audit 09-18)")
        #expect(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        func press(_ input: String, _ flags: UIKeyModifierFlags) -> Bool {
            guard let command = commands.first(where: { $0.input == input && $0.modifierFlags == flags }) else { return false }
            field.perform(command.action, with: command)
            return true
        }
        #expect(press(UIKeyCommand.inputLeftArrow, [.command, .shift]))                  // ⌘⇧←
        #expect(press("\t", [.control, .shift]))                                         // Ctrl+Shift+Tab
        #expect(press(UIKeyCommand.inputRightArrow, [.alternate, .shift]))               // ⌥⇧→
        #expect(press(UIKeyCommand.inputDelete, [.control, .alternate, .command, .shift]))
        #expect(press(UIKeyCommand.inputEscape, []))
        #expect(press(UIKeyCommand.inputHome, [.shift]))
        #expect(press(UIKeyCommand.f5, []))
        #expect(got.count == 7)
        guard got.count == 7 else { return }
        #expect(got[5].0 == .home && got[5].1 == [.shift])
        #expect(got[6].0 == .f5 && got[6].1.isEmpty)
        #expect(got[0].0 == .left && got[0].1 == [.meta, .shift])
        #expect(got[1].0 == .tab && got[1].1 == [.ctrl, .shift])
        #expect(got[2].0 == .right && got[2].1 == [.alt, .shift])
        #expect(got[3].0 == .delete && got[3].1 == [.ctrl, .alt, .meta, .shift])
        #expect(got[4].0 == .escape && got[4].1.isEmpty)
    }
}
#endif
