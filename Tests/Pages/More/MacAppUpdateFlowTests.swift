// [mac-update] The Mac download's update sheet, its pure half (HermesKit/Pages/More/MacAppUpdateFlow.swift): What's New
// out of the appcast's notes (both the run-in feeds already live and the line-per-item ones), the download's words, the
// failure words, and what the next launch says from the note left before the app quit to install.

import Foundation
import Testing
@testable import HermesHQNative

struct MacAppUpdateNotesTests {
    @Test func splitsTheRunInNotesOfTheLiveFeed() {
        // The appcast for Mac 919, as gethermeshq.com serves it.
        let notes = MacAppUpdateNotes("What's new since the last Mac update: - Math in replies is drawn as real math: fractions, roots, sums, aligned steps, cases and matrices. - Command-Delete is now Delete Chat, and it asks first. Archive Chat moved to Control-Command-A. - Dragging the sidebar's edge to make it wider or narrower works again (in 915 it all but froze). - The sidebar's lists no longer slide sideways.")
        #expect(notes.intro == nil)
        #expect(notes.items == [
            "Math in replies is drawn as real math: fractions, roots, sums, aligned steps, cases and matrices.",
            "Command-Delete is now Delete Chat, and it asks first. Archive Chat moved to Control-Command-A.",
            "Dragging the sidebar's edge to make it wider or narrower works again (in 915 it all but froze).",
            "The sidebar's lists no longer slide sideways.",
        ])
    }

    @Test func readsALinePerItem() {
        let notes = MacAppUpdateNotes("What’s new since the last Mac update:\n- One thing - with a dash inside.\n- Another.\n\nA closing paragraph.")
        #expect(notes.intro == nil)
        #expect(notes.items == ["One thing - with a dash inside.", "Another.", "A closing paragraph."])
    }

    @Test func keepsARealIntro() {
        let notes = MacAppUpdateNotes("Hermes HQ now updates itself with a window you can watch. - It shows the download.")
        #expect(notes.intro == "Hermes HQ now updates itself with a window you can watch.")
        #expect(notes.items == ["It shows the download."])
    }

    @Test func aDashInsideASentenceIsNotAnItem() {
        let notes = MacAppUpdateNotes("- Rows light up - even in sheets.")
        #expect(notes.items == ["Rows light up - even in sheets."])
    }

    @Test func emptyNotes() {
        #expect(MacAppUpdateNotes(nil) == .empty)
        #expect(MacAppUpdateNotes("  \n ") == .empty)
    }
}

struct MacAppUpdateTransferTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func readsProgressSpeedAndTimeLeft() {
        var transfer = MacAppUpdateTransfer(expected: 52_800_000)
        transfer.begin(at: start)
        #expect(transfer.words(at: start) == "0.0 of 52.8 MB")
        for second in 1...4 { transfer.add(5_000_000, at: start.addingTimeInterval(Double(second))) }
        let now = start.addingTimeInterval(4)
        #expect(transfer.fraction.map { abs($0 - 20 / 52.8) < 0.001 } == true)
        #expect(transfer.speed(at: now).map { abs($0 - 5_000_000) < 1 } == true)
        #expect(transfer.secondsLeft(at: now) == 7)   // 32.8 MB at 5 MB/s
        #expect(transfer.words(at: now) == "20.0 of 52.8 MB · About 7 s left")
    }

    @Test func noSizeYet() {
        var transfer = MacAppUpdateTransfer()
        #expect(transfer.fraction == nil)
        #expect(transfer.words(at: start) == "Starting…")
        transfer.add(820_000, at: start)
        #expect(transfer.words(at: start) == "820 KB")
    }

    @Test func moreThanExpectedGrowsTheSize() {
        var transfer = MacAppUpdateTransfer(expected: 1_000)
        transfer.add(1_500, at: start)
        #expect(transfer.fraction == 1)
        #expect(transfer.expected == 1_500)
    }
}

struct MacAppUpdateWordsTests {
    @Test func sizes() {
        #expect(MacAppUpdateWords.size(52_795_660) == "52.8 MB")
        #expect(MacAppUpdateWords.size(1_200_000_000) == "1.2 GB")
        #expect(MacAppUpdateWords.size(999) == "1 KB")
        #expect(MacAppUpdateWords.size(21_400_000, unit: false, like: 52_800_000) == "21.4")
    }

    @Test func versions() {
        #expect(MacAppUpdateWords.version("1.0.3", build: "925") == "1.0.3 (925)")
        #expect(MacAppUpdateWords.version("925", build: "925") == "925")
        #expect(MacAppUpdateWords.version(nil, build: "925") == "build 925")
        #expect(MacAppUpdateWords.version("", build: "") == "?")
    }

    @Test func times() {
        #expect(MacAppUpdateWords.timeLeft(1) == "Almost done")
        #expect(MacAppUpdateWords.timeLeft(42) == "About 42 s left")
        #expect(MacAppUpdateWords.timeLeft(61) == "About 2 min left")
        #expect(MacAppUpdateWords.took(0.2) == "1 s")
        #expect(MacAppUpdateWords.took(64) == "1 min 4 s")
        #expect(MacAppUpdateWords.took(120) == "2 min")
    }

    @Test func upToDateReasons() {
        #expect(MacAppUpdateWords.upToDate(reason: 1, current: "1.0.2 (925)", latest: "1.0.2 (925)") == "1.0.2 (925) is the newest version.")
        #expect(MacAppUpdateWords.upToDate(reason: 2, current: "1.0.2 (930)", latest: "1.0.2 (925)") == "This copy (1.0.2 (930)) is newer than the website’s (1.0.2 (925)).")
        #expect(MacAppUpdateWords.upToDate(reason: 3, current: "x", latest: "1.1 (950)").contains("newer version of macOS"))
    }

    @Test func failures() {
        #expect(MacAppUpdateWords.failure(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, description: "").line.contains("isn’t connected"))
        #expect(MacAppUpdateWords.failure(domain: "SUSparkleErrorDomain", code: 1003, description: "").headline == "Move Hermes HQ to Applications First")
        #expect(MacAppUpdateWords.failure(domain: "SUSparkleErrorDomain", code: 3001, description: "").headline == "The Update Wasn’t Signed Right")
        #expect(MacAppUpdateWords.failure(domain: "Other", code: 9, description: "It broke.").line == "It broke.")
        #expect(MacAppUpdateWords.isCancel(domain: "SUSparkleErrorDomain", code: 4007))
        #expect(MacAppUpdateWords.wantsWebsite(domain: "SUSparkleErrorDomain", code: 4005))
        #expect(!MacAppUpdateWords.wantsWebsite(domain: "SUSparkleErrorDomain", code: 2001))
    }
}

struct MacAppUpdateRecordTests {
    private let at = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private func record(onQuit: Bool = false) -> MacAppUpdateRecord {
        MacAppUpdateRecord(fromBuild: "919", fromDisplay: "1.0.2 (919)", toBuild: "925", toDisplay: "1.0.2 (925)", notes: "- New.", at: at, onQuit: onQuit)
    }

    @Test func theNewBuildSaysUpdated() {
        #expect(record().outcome(runningBuild: "925", now: at.addingTimeInterval(20)) == .updated)
        #expect(record(onQuit: true).outcome(runningBuild: "925", now: at.addingTimeInterval(86_400)) == .updated)
        #expect(record().outcome(runningBuild: "925", now: at.addingTimeInterval(15 * 86_400)) == .nothing)
    }

    @Test func theOldBuildSoonAfterARestartDidntFinish() {
        #expect(record().outcome(runningBuild: "919", now: at.addingTimeInterval(40)) == .didntFinish)
        #expect(record().outcome(runningBuild: "919", now: at.addingTimeInterval(3_600)) == .nothing)
        #expect(record().outcome(runningBuild: "930", now: at.addingTimeInterval(40)) == .nothing)
    }

    @Test func laterKeepsWaitingOnTheOldBuild() {
        let later = record(onQuit: true)
        #expect(later.outcome(runningBuild: "919", now: at.addingTimeInterval(40)) == .nothing)
        #expect(later.keepsWaiting(runningBuild: "919", now: at.addingTimeInterval(40)))
        #expect(!record().keepsWaiting(runningBuild: "919", now: at.addingTimeInterval(40)))
    }

    @Test func roundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "MacAppUpdateRecordTests"))
        defer { defaults.removePersistentDomain(forName: "MacAppUpdateRecordTests") }
        record().save(defaults)
        #expect(MacAppUpdateRecord.load(defaults) == record())
        MacAppUpdateRecord.clear(defaults)
        #expect(MacAppUpdateRecord.load(defaults) == nil)
    }
}
