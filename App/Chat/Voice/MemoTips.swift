// The two memo tips (spec 1x-voice §3.7, V8), never TipKit (no extra framework at launch). "Now Hold to Record" after
// the permission prompt answered Allow; "Hold to Record" once after the first tap-locked memo. They never time out;
// closing one (or learning the gesture) retires it for good. Drawn as the Talk tip's card in the chat
// (TalkTipBubble.swift), not a popover: a popover took the next tap anywhere on the screen.

import UIKit

enum MemoTips {
    static func key(_ tip: MemoTip) -> String {
        switch tip {
        case .nowHold: "hq.voice.tip.nowHold"
        case .holdToRecord: "hq.voice.tip.holdToRecord"
        case .talk: "hq.voice.tip.talk"
        }
    }

    /// [talk] The bot the Talk tip names (set by the chat's voice host before it shows).
    static var talkName = "Hermes"

    /// Done, or tips are off (Settings › Chat › In-App Tips).
    static func isDone(_ tip: MemoTip) -> Bool { !InAppTips.isOn || UserDefaults.standard.bool(forKey: key(tip)) }
    static func finish(_ tip: MemoTip) { UserDefaults.standard.set(true, forKey: key(tip)) }

    static func title(_ tip: MemoTip) -> String {
        switch tip {
        // [mac] Stress test 2026-10-28 #27: the titles name the mouse's way too, as the messages under them do.
        case .nowHold: DeviceWord.isMac ? "Now Click and Hold to Record" : "Now Hold to Record"
        case .holdToRecord: DeviceWord.isMac ? "Click and Hold to Record" : "Hold to Record"
        case .talk: "Talk with \(talkName)"
        }
    }

    static func message(_ tip: MemoTip) -> String {
        switch tip {
        // [mac] A mouse holds the button down: "click and hold", as the screen viewers' hints say.
        case .nowHold: DeviceWord.isMac ? "Click and hold the mic and talk, then let go to send." : "Hold the mic and talk, then let go to send."
        case .holdToRecord: DeviceWord.isMac ? "Next time, click and hold the mic and let go to send." : "Next time, hold the mic and let go to send."
        // Names the control: the composer has two voice buttons, and "Tap" alone pointed at neither.
        // [mac] Stress test 2026-10-28 #12: the Mac's card runs the title ("Talk with Ivy") into these words, so they
        // don't name the bot a second time.
        // Round 2: shorter, so it fits two lines in a narrow window.
        case .talk: DeviceWord.isMac ? "Click the waveform to talk out loud. Click and hold the mic for a voice memo."
            : "\(DeviceWord.Tap) the waveform button to talk out loud with \(talkName). Hold the mic to send a voice memo."
        }
    }
}
