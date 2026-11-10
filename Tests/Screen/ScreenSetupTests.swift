// The setup request's words and the installer the app carries (docs/spec/3x-screen.md §5.13; the web's
// `bot-screen-setup.test.ts` and `screen-setup-bundle.test.ts`).

import CryptoKit
import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct ScreenSetupTests {
    private func sha(_ text: String) -> String { ScreenSetupBundle.hex(Data(text.utf8)) }

    @Test func thePromptIsTheReviewedTextAndNeverNamesTheOldProduct() {
        let text = ScreenSetupPrompt.text
        #expect(text.utf8.count == 3_953)
        #expect(sha(text) == "fb7b7a4dc80eae6c0a0ca41068874f2e22e22d494d9345c3f59009aca11c6107")
        #expect(sha(text) == ScreenSetupPrompt.sha256)
        #expect(!text.lowercased().contains("dispatch"))
        #expect(text.hasPrefix("Set up live Mac screen sharing for me in Hermes HQ on the computer running Hermes for this chat."))
        #expect(text.contains("If this Mac still has the older screen plugin or helper app from before the rename, the installer carries their settings over and removes them so only one helper runs (macOS keeps the existing permissions); if it reports it could not remove the old plugin, run the removal command it reports yourself."))
        #expect(ScreenSetupPrompt.paragraphs.count == 5)
        #expect(ScreenSetupPrompt.queueTitle == "Set up live screen sharing on my Mac and verify it.")
    }

    @Test func theMessageEndsWithTheThreeInstallerLines() {
        let full = ScreenSetupPrompt.message(refText: "@file:/tmp/hermes-hq-screen-setup.zip", sha256: ScreenSetupBundle.expectedSHA256,
                                             helperAppPath: ScreenSetupBundle.helperAppPath)
        #expect(full.hasPrefix(ScreenSetupPrompt.text))
        #expect(full.hasSuffix("\n\nInstaller source: @file:/tmp/hermes-hq-screen-setup.zip\nSHA-256: 71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09\nSigned helper inside the bundle: hermes-hq-screen-setup/Hermes HQ Screen.app"))
        let bare = ScreenSetupPrompt.message(refText: "@file:/x.zip", sha256: "abc", helperAppPath: nil)
        #expect(bare.hasSuffix("\n\nInstaller source: @file:/x.zip\nSHA-256: abc"))
    }

    @Test func theInstallerInTheAppIsTheReviewedOne() async throws {
        let bundle = try await ScreenSetupBundle.load(from: .main)
        #expect(bundle.filename == "hermes-hq-screen-setup.zip")
        #expect(bundle.sha256 == "71ff241d0a3e803b8a457a9df5f91c14df48c1f227893d785974837af0c8de09")
        #expect(bundle.helperAppPath == "hermes-hq-screen-setup/Hermes HQ Screen.app")
        #expect(bundle.dataURL.hasPrefix("data:application/zip;base64,UEsDB"))
        let encoded = String(bundle.dataURL.dropFirst("data:application/zip;base64,".count))
        let bytes = try #require(Data(base64Encoded: encoded))
        #expect(bytes.count == 550_200)
        #expect(ScreenSetupBundle.hex(bytes) == ScreenSetupBundle.expectedSHA256)
    }

    @Test func aMissingOrAlteredInstallerIsRefused() async {
        #expect(throws: ScreenSetupError.installer(nil)) { try ScreenSetupBundle.verified(nil) }
        #expect(throws: ScreenSetupError.installer(nil)) { try ScreenSetupBundle.verified(Data(repeating: 7, count: 550_200)) }
        #expect(throws: ScreenSetupError.installer(nil)) { try ScreenSetupBundle.verified(Data("PK".utf8)) }
        await #expect(throws: ScreenSetupError.installer(nil)) { try await ScreenSetupBundle.load(from: Bundle(for: NSObject.self)) }
    }

    @Test func theGatewaysAnswerToTheAttachIsHeldToItsWord() throws {
        #expect(try ScreenSetupAttach.refText(["attached": true, "ref_text": "@file:/h/x.zip"]) == "@file:/h/x.zip")
        #expect(throws: ScreenSetupError.installer("No space left on the gateway")) {
            try ScreenSetupAttach.refText(["attached": false, "message": "No space left on the gateway"])
        }
        #expect(throws: ScreenSetupError.installer(nil)) { try ScreenSetupAttach.refText(["attached": true, "ref_text": "  "]) }
        #expect(throws: ScreenSetupError.installer(nil)) { try ScreenSetupAttach.refText(["ref_text": "@file:/h/x.zip"]) }
    }

    @Test func everyFailureSaysTheWebsWordsAndNoneNamesTheOldProduct() {
        let all: [(ScreenSetupError, String)] = [
            (.notConnected, "This bot’s gateway is no longer connected."),
            (.chatDidNotOpen, "Hermes could not open this bot’s chat. Try again."),
            (.chatChanged, "The selected chat changed before setup could start."),
            (.notReady, "This bot’s chat did not become ready for setup. Try again."),
            (.changedWhilePreparing, "The chat connection changed while preparing setup. Try again."),
            (.installer(nil), "Hermes could not receive the Mac screen installer. Try again."),
            (.installer(""), "Hermes could not receive the Mac screen installer. Try again."),
            (.installer("No space left on the gateway"), "No space left on the gateway"),
            (.changedBeforeStart, "The chat connection changed before setup could start. Try again."),
            (.notQueued, "Hermes could not queue the setup request in this chat. Try again."),
        ]
        for (failure, words) in all {
            #expect(failure.message == words)
            #expect(!failure.message.lowercased().contains("dispatch"))
        }
        #expect(ScreenSetupError.alertTitle == "Couldn’t Start Screen Setup")
    }

    @Test func theCardsWords() {
        #expect(ScreenSetupCopy.heading(controlOnly: false) == "Set Up Viewing and Control")
        #expect(ScreenSetupCopy.heading(controlOnly: true) == "Enable Screen Control")
        #expect(ScreenSetupCopy.primary(requested: false, controlOnly: false, working: false) == "Set Up with Hermes")
        #expect(ScreenSetupCopy.primary(requested: true, controlOnly: false, working: false) == "Continue with Hermes")
        #expect(ScreenSetupCopy.primary(requested: false, controlOnly: true, working: false) == "Enable Control with Hermes")
        #expect(ScreenSetupCopy.primary(requested: true, controlOnly: true, working: false) == "Continue with Hermes")
        #expect(ScreenSetupCopy.primary(requested: true, controlOnly: true, working: true) == "Opening setup…")
        #expect(ScreenSetupCopy.check(working: false) == "Check Setup")
        #expect(ScreenSetupCopy.check(working: true) == "Checking…")
        let lines = [ScreenSetupCopy.how, ScreenSetupCopy.shares, ScreenSetupCopy.update, ScreenSetupCopy.requested, ScreenSetupCopy.windows]
        #expect(lines == [
            "Hermes will install the helper, enable viewing and control, and check both permissions in one setup. Follow its progress in your bot’s chat.",
            "This shares your Mac’s entire screen and enables pointer and keyboard control for people with Screen access on your gateway. Approve Screen Recording to view, and Accessibility to click and type, on the Mac when prompted.",
            "Hermes will also check whether your gateway needs an update.",
            "Setup was requested in your bot’s chat. Hermes will report any permissions or requirements that still need attention.",
            "Live screen sharing isn’t available on Windows yet. Your bot’s latest screenshots will appear here.",
        ])
        for line in lines { #expect(!line.lowercased().contains("dispatch")) }
    }
}
