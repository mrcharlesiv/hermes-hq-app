// [m9/composer] The composer stream's pure rules (docs/spec/3x-composer.md §1, §2, §12, §15.3, §16).

import UIKit
import Testing
@testable import HermesHQNative

struct EmptyReturnTests {
    @Test func everyCombination() {
        for running in [false, true] {
            for waiting in [0, 1, 3] {
                for paused in [false, true] {
                    for canAct in [false, true] {
                        let rule = EmptyReturn.decide(running: running, waiting: waiting, paused: paused, canAct: canAct)
                        if !canAct || waiting == 0 || paused {
                            #expect(rule == .nothing, "running \(running) waiting \(waiting) paused \(paused) canAct \(canAct)")
                        } else {
                            #expect(rule == (running ? .sendNowHead : .sendNext))
                        }
                    }
                }
            }
        }
    }

    @Test func aFieldWithWordsStillSendsAndAnEmptyOneIsSwallowed() {
        // The iPad stream's rule is untouched: only the swallowed (empty) case reaches `EmptyReturn`.
        #expect(ReturnKey.decide(hardware: true, shift: false, option: false, marked: false, empty: false) == .send)
        #expect(ReturnKey.decide(hardware: true, shift: false, option: false, marked: false, empty: true) == .swallow)
        #expect(ReturnKey.decide(hardware: false, shift: false, option: false, marked: false, empty: true) == .pass)
    }
}

struct QueueWordsTests {
    @Test func editPutsTheQueuedWordsUnderWhatIsTyped() {
        #expect(QueueWords.editedField(current: "", queued: "Fix teh typo") == "Fix teh typo")
        #expect(QueueWords.editedField(current: "  \n", queued: "Fix teh typo") == "Fix teh typo")
        #expect(QueueWords.editedField(current: "Also this ", queued: "Fix teh typo") == "Also this\nFix teh typo")
        #expect(QueueWords.editedField(current: "Also this", queued: "") == "Also this")
    }

    @Test func theWebsHeaders() {
        #expect(QueueWords.header(count: 1, paused: true, running: false) == "Queue Paused")
        #expect(QueueWords.header(count: 2, paused: true, running: false) == "Queue Paused · 2 Messages")
        #expect(QueueWords.header(count: 2, paused: true, running: true) == "Queue Paused · 2 Messages")
        #expect(QueueWords.header(count: 1, paused: false, running: false) == "Queued")
        #expect(QueueWords.header(count: 4, paused: false, running: false) == "4 Queued")
        #expect(QueueWords.header(count: 1, paused: false, running: true) == "Queued · Sends After This Reply")
        #expect(QueueWords.header(count: 3, paused: false, running: true) == "3 Queued · Send After This Reply")
    }

    @Test func resumeOnlyWhilePausedWithSomethingWaiting() {
        #expect(QueueWords.showsResume(count: 1, paused: true))
        #expect(!QueueWords.showsResume(count: 0, paused: true))
        #expect(!QueueWords.showsResume(count: 2, paused: false))
    }

    @Test func spokenHeader() {
        #expect(QueueWords.spokenHeader(count: 2, paused: true, running: false) == "Queue paused, 2 messages")
        #expect(QueueWords.spokenHeader(count: 1, paused: true, running: false) == "Queue paused, 1 message")
        #expect(QueueWords.spokenHeader(count: 1, paused: false, running: true) == "1 message queued, sends after this reply")
    }

    @Test func nothingTheUserSeesSaysDispatch() {
        for count in [1, 2] { for paused in [false, true] { for running in [false, true] {
            #expect(!QueueWords.header(count: count, paused: paused, running: running).localizedCaseInsensitiveContains("dispatch"))
        } } }
    }
}

struct CommandInsertTests {
    private func insert(_ command: String, _ draft: String) -> (String, Int) {
        let result = ComposerView.commandInsert(command, into: draft)
        return (result.text, result.caret)
    }

    @Test func aPickedCommandGoesAheadOfTheDraft() {
        #expect(insert("/compress", "") == ("/compress ", 10))
        #expect(insert("/compress", "keep the tests") == ("/compress keep the tests", 10))
    }

    @Test func aCommandAlreadyInTheFieldIsReplaced() {
        #expect(insert("/compress", "/goal x") == ("/compress x", 10))
        #expect(insert("/compress", "/goal") == ("/compress ", 10))
        #expect(insert("/compress", "/") == ("/compress ", 10))
        // A path is not a command: it stays as the draft.
        #expect(insert("/compress", "/home/me notes") == ("/compress /home/me notes", 10))
    }
}

struct ComposerKeyboardTests {
    @Test func leftoverLineBreaksAreBlank() {
        #expect(ComposerKeyboard.isLeftoverLineBreaks("\n"))
        #expect(ComposerKeyboard.isLeftoverLineBreaks("\n\n\n"))
        #expect(ComposerKeyboard.isLeftoverLineBreaks(" \n\t"))
        #expect(ComposerKeyboard.isLeftoverLineBreaks("\r\n"))
        #expect(!ComposerKeyboard.isLeftoverLineBreaks(""))
        #expect(!ComposerKeyboard.isLeftoverLineBreaks("   "), "plain spaces are left alone")
        #expect(!ComposerKeyboard.isLeftoverLineBreaks("a\n"))
        #expect(!ComposerKeyboard.isLeftoverLineBreaks("\na"))
    }

    @Test func aSendDropsTheEndsAndKeepsInnerBlankLines() {
        #expect(ComposerKeyboard.sendText("a\n\n") == "a")
        #expect(ComposerKeyboard.sendText("\n\n a") == "a")
        #expect(ComposerKeyboard.sendText("a\n\nb\n") == "a\n\nb")
    }

    @Test @MainActor func theFieldsSettingsAreTheOnesMessagesUses() {
        let view = UITextView()
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.autocapitalizationType = .none
        ComposerKeyboard.apply(to: view)
        #expect(view.autocorrectionType == .yes)
        #expect(view.spellCheckingType == .yes)
        #expect(view.autocapitalizationType == .sentences)
        #expect(view.returnKeyType == .default)
        #expect(view.keyboardType == .default)
    }
}

struct ModelLoadTests {
    @Test func whenASecondTryHelps() {
        #expect(ModelLoad.tries == 2)
        #expect(ModelLoad.secondTryHelps(RPCError(code: 5033, message: "model inventory failed", data: nil)))
        #expect(ModelLoad.secondTryHelps(RPCError.timedOut("model.options", after: .seconds(30))))
        #expect(ModelLoad.secondTryHelps(RPCError.connectionLost("model.options")))
        #expect(!ModelLoad.secondTryHelps(RPCError(code: 4000, message: "invalid params for model.options", data: nil)))
        #expect(!ModelLoad.secondTryHelps(RPCError(code: -32601, message: "method not found", data: nil)))
        #expect(!ModelLoad.secondTryHelps(CancellationError()))
        #expect(!ModelLoad.secondTryHelps(MenusError.offline))
    }

    @Test func theWords() {
        #expect(ModelLoad.words(for: MenusError.offline, offline: false) == "You’re offline.")
        #expect(ModelLoad.words(for: RPCError(code: 5033, message: "x", data: nil), offline: true) == "You’re offline.")
        #expect(ModelLoad.words(for: RPCError.timedOut("model.options", after: .seconds(30)), offline: false)
                == "The computer running Hermes didn’t answer in time.")
        #expect(ModelLoad.words(for: RPCError.connectionLost("model.options"), offline: false) == "The computer running Hermes didn’t answer in time.")
        #expect(ModelLoad.words(for: RPCError(code: 5033, message: " model inventory failed \n", data: nil), offline: false)
                == "model inventory failed")
        #expect(ModelLoad.words(for: RPCError(code: 5033, message: "  ", data: nil), offline: false) == nil)
        let long = String(repeating: "abcdefghi ", count: 40)
        let cut = ModelLoad.words(for: RPCError(code: 5033, message: long, data: nil), offline: false) ?? ""
        #expect(cut.hasSuffix("…"))
        #expect(cut.count <= ModelLoad.messageLimit + 1)
        #expect(ModelLoad.failureTitle == "Couldn’t Load Models")
    }

    @Test func theCommandsSheetSaysOfflineAndNamesTheComputer() {
        #expect(CommandsLoad.words(for: MenusError.offline) == "You’re offline.")
        #expect(CommandsLoad.words(for: RPCError.timedOut("commands.catalog", after: .seconds(30)))
                == "The computer running Hermes didn’t answer in time.")
        #expect(CommandsLoad.words(for: RPCError(code: 5000, message: "boom", data: nil))
                == "The computer running Hermes didn’t send its list of commands. Show Details has the reason.")
    }
}

struct MenusErrorWordsTests {
    @Test func aGatewaysOwnReasonInWords() {
        #expect(MenusError.text(HTTPError(status: 409, body: #"{"detail":"Title 'Taken' is already in use"}"#))
                == "Title 'Taken' is already in use")
        #expect(MenusError.text(RPCError(code: 4000, message: "session not found", data: nil)) == "session not found")
    }

    @Test func neverAnErrorPageJSONOrABareNumber() {
        let html = MenusError.text(HTTPError(status: 502, body: "<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head></html>"))
        #expect(!html.contains("<") && !html.contains("502"), "\(html)")
        let json = MenusError.text(HTTPError(status: 500, body: #"{"ok":false,"trace":"Traceback…"}"#))
        #expect(!json.contains("{") && !json.contains("500"), "\(json)")
        #expect(MenusError.text(HTTPError(status: 500, body: nil)) == "The computer running Hermes couldn’t do that. Try again.")
        struct Odd: Error { let field = 7 }
        #expect(MenusError.text(Odd()) == "Something went wrong. Try again.")
        // Show Details keeps everything.
        #expect(MenusError.details(HTTPError(status: 502, body: "<html>x</html>")).contains("<html>x</html>"))
    }
}
