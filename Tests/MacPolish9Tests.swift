// Mac polish round (2026-11-06), batch 9: updates, add-ons, permissions and device words. The unit tests run on the
// iPhone simulator, so they pin the iPhone's words (unchanged where an item is Mac only) and the Mac's links and
// rules where those are pure.

import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct MacPolish9Tests {
    // MARK: #11 The way back to a refused permission

    /// The Mac opens the permission's own Privacy & Security pane (the iPhone's app-settings link opens nothing there).
    @Test func macLinksOpenEachPrivacyPane() {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        #expect(PrivacySettingsLink.macURL(.microphone)?.absoluteString == base + "?Privacy_Microphone")
        #expect(PrivacySettingsLink.macURL(.camera)?.absoluteString == base + "?Privacy_Camera")
        #expect(PrivacySettingsLink.macURL(.photos)?.absoluteString == base + "?Privacy_Photos")
        #expect(PrivacySettingsLink.macURL(.contacts)?.absoluteString == base + "?Privacy_Contacts")
        #expect(PrivacySettingsLink.macURL(.location)?.absoluteString == base + "?Privacy_LocationServices")
        #expect(PrivacySettingsLink.macURL(.calendars)?.absoluteString == base + "?Privacy_Calendars")
        #expect(PrivacySettingsLink.macURL(.reminders)?.absoluteString == base + "?Privacy_Reminders")
        #expect(PrivacySettingsLink.macURL(.privacy)?.absoluteString == base)
        #expect(PrivacySettingsLink.macURL(.notifications)?.absoluteString == UIApplication.openNotificationSettingsURLString)
        for pane in PrivacySettingsLink.Pane.allCases { #expect(PrivacySettingsLink.macURL(pane) != nil) }
    }

    /// The iPhone keeps the app's own page in Settings and its words.
    @Test func iPhoneKeepsSettingsAndItsWords() {
        #expect(PrivacySettingsLink.url(.microphone)?.absoluteString == UIApplication.openSettingsURLString)
        #expect(PrivacySettingsLink.place == "Settings")
        #expect(PrivacySettingsLink.openTitle == "Open Settings")
        #expect(MemoNotice.failure(code: "permission-denied", message: nil).actionTitle == "Open Settings")
        #expect(TalkNotice.Action.openSettings.title == "Open Settings")
        #expect(VoiceTestStatus.microphoneOff.text == "Allow the microphone in Settings")
    }

    /// Device Access opens the refused kind's own pane.
    @Test func deviceAccessKindsOpenTheirPane() {
        #expect(DeviceAccessSettingsModel.pane(.contacts) == .contacts)
        #expect(DeviceAccessSettingsModel.pane(.location) == .location)
        #expect(DeviceAccessSettingsModel.pane(.reminders) == .reminders)
        #expect(DeviceAccessSettingsModel.pane(.calendar) == .calendars)
        #expect(DeviceAccessSettingsModel.pane(.photos) == .photos)
        #expect(DeviceAccessSettingsModel.pane(.drafts) == .privacy)
    }
}

@Suite struct MacPolish9DeviceAccessTests {
    // MARK: #26 A Mac window behind another app's is open

    @Test func aMacWindowOnScreenCountsAsOpen() {
        #expect(DeviceAccessCenter.onScreen(.foregroundActive))
        #expect(DeviceAccessCenter.onScreen(.foregroundInactive), "behind another app's window: still open")
        #expect(!DeviceAccessCenter.onScreen(.background), "minimized, hidden or closed")
        #expect(!DeviceAccessCenter.onScreen(.unattached))
    }

    // MARK: #142 Device Access's device words (the iPhone's, unchanged)

    @Test func iPhoneKeepsItsDeviceAccessWords() {
        let app = AppIdentity.current.displayName
        #expect(DeviceAccessKindView.lockedFooter == "With While Locked on, a bot can ask while \(app) is closed or this iPhone is locked. iOS asks you to allow Location “Always”, and now and then reminds you that \(app) used it in the background.")
        #expect(DeviceAccess.Kind.drafts.footer.hasSuffix("nothing is sent until you tap Send."))
        #expect(DeviceAccessConsent.message(.drafts).contains("nothing is sent until you tap Send"))
    }
}

@Suite struct MacPolish9UpdateSheetTests {
    // MARK: #48 A failed add-on update marks the step that failed

    @MainActor @Test func aFailedAddOnUpdateMarksTheStepUnderWay() {
        let update = AddOnUpdate()
        update.found(setUp: false, why: "", bot: "Hermes", both: false)
        update.work()
        update.step(.install, .done)
        update.step(.restart, .done)
        update.step(.verify, .active, detail: AddOnUpdate.eachBot)
        update.end(.failed(title: AddOnUpdate.stillNeed(["Gym"]), reason: AddOnUpdate.stillNeedReason(count: 1, bot: "Hermes")))
        #expect(update.steps.first { $0.id == .verify }?.state == .failed, "not back to an empty circle")
        #expect(update.steps.filter { $0.state == .failed }.count == 1)
        #expect(update.showsSteps)

        // Any other ending leaves an unfinished step waiting, as before.
        update.found(setUp: false, why: "", bot: "Hermes", both: false)
        update.work()
        update.step(.install, .active)
        update.end(.unreachable)
        #expect(update.steps.first { $0.id == .install }?.state == .waiting)
    }
}

@Suite struct MacPolish9LogTests {
    // MARK: #49 A hang line keeps the app's own frames readable

    @Test func hangFramesAreNotTakenForIds() {
        let line = "main thread stalled 851 ms in libsystem_kernel.dylib mach_msg2_trap ← QuartzCore _ZN2CA11Transaction6commitEv ← Hermes HQ.debug.dylib +0x1a2b3c4 ← Hermes HQ +0x83e4dc0"
        #expect(AppLog.logged(line, code: true) == line, "no frame turned into a #tag")
        #expect(AppLog.logged(line, code: false) != line, "an ordinary line still tags id-like words")
        let chat = "resume 20251027_101010_ab12cd"
        #expect(AppLog.logged(chat, code: false) == "resume \(AppLog.tag("20251027_101010_ab12cd"))")
        #expect(AppLog.logged("open https://my-mac.tail1234.ts.net/x", code: true).contains("my-mac") == false, "hosts are still tagged")
    }

    @Test func theDebugDylibIsTheAppsOwnCode() {
        let app = LoadedImages.appBinary
        #expect(LoadedImages.isApp(app))
        #expect(LoadedImages.isApp(app + ".debug.dylib"))
        #expect(!LoadedImages.isApp("UIKitCore") && !LoadedImages.isApp("libswiftCore.dylib"))
    }
}

@Suite struct MacPolish9WordsTests {
    // MARK: #143 The device by name, not "your phone"

    @Test func tooLargeNamesTheDevice() {
        #expect(ArtifactFiles.tooLargeText == "This file is too large to open on this \(DeviceWord.name).")
        // The sign-in guide keeps the web's words on the iPhone (OnboardingCopyTests compares them).
        #expect(OnboardingCopy.Manual.text2.hasSuffix(DeviceWord.name == "iPhone" ? "Hermes turns your phone away." : "Hermes turns your \(DeviceWord.name) away."))
    }
}

@Suite struct MacPolish9AddOnWordsTests {
    // MARK: #145 No raw add-on words: Python error names, tools' code names

    @Test func driftWordsLeaveOutPythonErrorNames() throws {
        func health(_ drift: [String]) throws -> JSONValue {
            try JSONValue.parse(JSONSerialization.data(withJSONObject: ["installed": false, "protocol": 3, "drift": drift]))
        }
        #expect(BrowserHealth.driftWords(try health(["browser tools unavailable (ImportError)"])) == "browser tools unavailable")
        #expect(BrowserHealth.driftWords(try health(["tools gone (ModuleNotFoundError: No module named 'x')", "hook moved (AttributeError)"]))
                == "tools gone; hook moved")
        #expect(BrowserHealth.driftWords(try health(["the browser hook moved (an error in Hermes 0.22.6)"]))
                == "the browser hook moved (an error in Hermes 0.22.6)", "an aside in words stays")
        #expect(BrowserHealth.driftWords(try health(["(ImportError)"])) == nil, "nothing left to say")
    }

    @Test func whatsNewLinesLeaveOutCodeNames() {
        let lines = AddOnChanges.changes(subjects: [
            "hermes-hq-browser 3.8.0: works on Hermes 0.22.6 and newer (browser_exec only) and still on 0.22.5 and older; a plugin reload runs the changed code",
        ], plugin: "hermes-hq-browser", after: "3.7.0")
        #expect(lines.first?.line == "Works on Hermes 0.22.6 and newer and still on 0.22.5 and older")
        #expect(AddOnChanges.tidy("faster restarts (see `hermes_cli.plugins`)") == "Faster restarts")
        #expect(AddOnChanges.tidy("fewer reads (e.g. on launch)") == "Fewer reads (e.g. on launch)")
    }
}
