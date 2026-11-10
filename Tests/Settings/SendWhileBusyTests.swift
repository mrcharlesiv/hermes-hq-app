// [send-while-busy] Settings › Chat › Send While Replying (tester 2026-11-08): what a tap on Send does while
// a reply runs, with ⌘Return doing the other one and Send's hold menu saying which.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor struct SendWhileBusyTests {
    @Test func steerStaysTheDefault() {
        let key = SendWhileBusy.key
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        #expect(SendWhileBusy.chosen == .steer)
        UserDefaults.standard.set("nonsense", forKey: key)
        #expect(SendWhileBusy.chosen == .steer)
        SendWhileBusy.chosen = .queue
        #expect(SendWhileBusy.chosen == .queue)
    }

    @Test func aTapFollowsTheSettingAndCommandReturnDoesTheOther() {
        #expect(!SendWhileBusy.queues(chosen: .steer))
        #expect(SendWhileBusy.queues(chosen: .queue))
        #expect(SendWhileBusy.queues(command: true, chosen: .steer))
        #expect(!SendWhileBusy.queues(command: true, chosen: .queue))
    }

    @Test func theHoldMenuSaysWhichWhateverTheSetting() {
        for chosen in SendWhileBusy.allCases {
            #expect(SendWhileBusy.queues(picked: .queue, chosen: chosen))
            #expect(!SendWhileBusy.queues(picked: .steer, chosen: chosen))
            #expect(SendWhileBusy.queues(picked: .queue, command: true, chosen: chosen))
        }
    }

    @Test func itFollowsTheOwnerToTheirOtherDevicesAndCanBeFound() {
        #expect(SyncedSettingKeys.settings.contains(SendWhileBusy.key))
        let entry = SettingsSearch.appRows.first { $0.id == "app:send-while-busy" }
        #expect(entry?.label == "Send While Replying")
    }
}
