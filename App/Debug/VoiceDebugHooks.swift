// DEBUG-only launch hooks for voice memos (spec 1x-voice §8.3; compiled out of Release). The simulator's microphone is
// not reliable, so UI tests record with a fixture recorder that writes a synthetic 16 kHz WAV:
//
// - `-HQDebugMemoFixture granted|undetermined|denied`  use the fixture recorder (simulator only); `undetermined` becomes
//                                                     granted 0.3 s after the "prompt"
// - `-HQDebugMemoStartDelay <s>`                      time before a take starts recording (default 0.08)
// - `-HQDebugMemoLimit <s>`                           the take's length limit (fixture only)
// - `-HQDebugMemoInterruptAfter <s>`                  stop the take that long after it starts recording…
// - `-HQDebugMemoInterruptReason interrupted|route-lost|reset`   …for this reason (default interrupted)
// - `-HQDebugSendOnRelease NO`                        a held memo stops into review instead of sending (this launch)
// - `-HQDebugResetVoice YES`                          forget the memo speed, the tips, drafts, shapes, played memos and
//                                                     word fixes
// - `-HQDebugLiveWords "<words>"`                     [live words] every memo and Talk take "hears" these words (Apple's
//                                                     engine doesn't run in simulators); `-hq.voice.liveWords NO` turns
//                                                     Live Words off
// - `-HQDebugLiveWordsFile <wav>`                     [live words] a memo's words come from this recording through the
//                                                     real engine instead of the microphone (the Mac, with no microphone)
// Screenshots only (synthetic recorder inputs through the real reducer and views, once the chat opened with
// -HQDebugOpenBot): `-HQDebugMemoShot pressing|holding|armed|lockNear|locked|review|playing|confirm|send|bubblePlaying`
// (after `-HQDebugMemoShotDelay <s>`, default 1.2; `-HQDebugMemoShotReply YES` swipe-replies to the latest bot message first),
// `-HQDebugMemoShotNotice denied|stopped|transcript|draft|save|record`, `-HQDebugMemoShotTip nowHold|holdToRecord`;
// `-HQDebugMemoScrollProbe <pt/s>` runs the chat scroll probe (A-P3); `-HQDebugMemoProbe YES` exposes the locked
// recorder's live waveform to UI tests (`memo.live`).

#if DEBUG
import UIKit

enum VoiceDebugHooks {
    private static var defaults: UserDefaults { .standard }

    /// `-HQDebugMemoProbe YES`: the locked recorder's live waveform is readable by UI tests (`memo.live`, its value
    /// "bars=<n>;distinct=<heights>").
    static let probe = UserDefaults.standard.bool(forKey: "HQDebugMemoProbe")

    static func applyBeforeLaunch() {
        if defaults.bool(forKey: "HQDebugResetVoice") {
            for key in [MemoPlayer.speedKey, MemoTips.key(.nowHold), MemoTips.key(.holdToRecord), MemoController.sendOnReleaseKey,
                        WordFixes.key] {   // [live words]
                defaults.removeObject(forKey: key)
            }
            MemoPaths.purgeAll()
        }
        if let words = defaults.string(forKey: "HQDebugLiveWords"), !words.isEmpty { LiveWords.debugScript = words }   // [live words]
        if let path = defaults.string(forKey: "HQDebugLiveWordsFile"), !path.isEmpty { LiveWords.debugFile = URL(fileURLWithPath: path) }
        if defaults.object(forKey: "HQDebugSendOnRelease") != nil {
            MemoController.debugSendOnRelease = defaults.bool(forKey: "HQDebugSendOnRelease")
        }
        #if targetEnvironment(simulator)
        if let permission = defaults.string(forKey: "HQDebugMemoFixture"), ["granted", "undetermined", "denied"].contains(permission) {
            var fixture = MemoRecorder.Fixture(permission: permission)
            if defaults.object(forKey: "HQDebugMemoStartDelay") != nil { fixture.startDelay = defaults.double(forKey: "HQDebugMemoStartDelay") }
            if defaults.object(forKey: "HQDebugMemoLimit") != nil { fixture.limit = defaults.double(forKey: "HQDebugMemoLimit") }
            if defaults.object(forKey: "HQDebugMemoInterruptAfter") != nil {
                fixture.interruptAfter = defaults.double(forKey: "HQDebugMemoInterruptAfter")
                fixture.interruptReason = MemoStopReason(rawValue: defaults.string(forKey: "HQDebugMemoInterruptReason") ?? "") ?? .interrupted
            }
            MemoRecorder.shared.fixture = fixture
        }
        #endif
    }

    static func chatShown(_ chat: ChatViewController) {
        let controller = MemoController.shared
        func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
        }
        let delay = defaults.object(forKey: "HQDebugMemoShotDelay") != nil ? defaults.double(forKey: "HQDebugMemoShotDelay") : 1.2
        if defaults.bool(forKey: "HQDebugMemoShotReply") {
            // Swipe to Reply on the latest bot message first, so the memo records (and sends) under its quote.
            after(max(0.3, delay - 0.6)) {
                guard let last = chat.session.messages.last(where: { $0.role == .assistant }) else { return }
                chat.menus?.beginReply(last.id)
                chat.view.endEditing(true)
            }
        }
        if let shot = defaults.string(forKey: "HQDebugMemoShot"), shot == "bubblePlaying" {
            // The newest memo in the chat plays at 1.5×.
            after(delay) {
                guard let memo = chat.session.messages.compactMap({ VoiceMemo.parse($0.plainText) })
                        .last(where: { $0.hasTranscript && !MemoLoadFailures.contains($0.path) }) else { return }
                if MemoPlayer.shared.speed == 1 { MemoPlayer.shared.cycleSpeed() }
                MemoPlayer.shared.play(memo.path, resolve: MemoPlaybackContexts.resolver(path: memo.path, scope: chat.voice.scope))
            }
        } else if let shot = defaults.string(forKey: "HQDebugMemoShot") {
            after(delay) {
                chat.voice.debugDown()
                switch shot {
                case "send": after(1.6) { controller.input(.up(at: CACurrentMediaTime() * 1000)) }
                case "holding": after(0.5) { controller.input(.move(dx: -24, dy: -6)) }
                case "armed": after(0.5) { controller.input(.move(dx: -140, dy: 0)) }
                case "lockNear": after(0.5) { controller.input(.move(dx: 0, dy: -52)) }
                case "locked", "review", "playing", "confirm":
                    after(0.3) { controller.input(.up(at: CACurrentMediaTime() * 1000)) }
                    if shot == "review" || shot == "playing" { after(3.5) { controller.input(.stop) } }
                    if shot == "playing" { after(4.5) { chat.voice.debugPlayReview() } }
                    if shot == "confirm" { after(11.2) { controller.input(.delete) } }
                default: break
                }
            }
        }
        if let kind = defaults.string(forKey: "HQDebugMemoShotNotice") {
            after(1.2) {
                let scope = chat.voice.scope
                let notice: MemoNotice
                switch kind {
                case "denied": notice = MemoNotice.failure(code: "permission-denied", message: nil)
                case "stopped": notice = MemoNotice(tone: .info, title: "Recording Stopped",
                                                    message: "\(MemoNotice.why(.interrupted)) Your 0:12 memo is waiting in the message field.")
                case "transcript": notice = MemoNotice.noTranscript(bot: chat.voice.botName, detail: "HTTP 500: Transcription failed")
                case "draft": notice = MemoNotice(tone: .warning, title: "Memo Saved as a Draft",
                                                  message: "It didn’t send. It’s waiting in the message field of your chat with \(chat.voice.botName).")
                case "save": notice = MemoNotice(tone: .error, title: "Couldn’t Save the Memo", message: "The recording couldn’t be saved on this iPhone.")
                default: notice = MemoNotice.failure(code: "start-failed", message: nil)
                }
                controller.post(notice, scope: scope)
            }
        }
        if defaults.object(forKey: "HQDebugMemoScrollProbe") != nil {
            // A-P3: the scroll probe over a chat of memos (speed in pt/s), 3 s after it opens.
            let speed = defaults.double(forKey: "HQDebugMemoScrollProbe")
            after(3) { ChatScrollProbe(chat: chat, speed: CGFloat(speed > 0 ? speed : 3000), legSeconds: 6).start() }
        }
        if let tip = defaults.string(forKey: "HQDebugMemoShotTip") {
            after(1.4) { chat.voice.memoShowTip(tip == "holdToRecord" ? .holdToRecord : .nowHold) }
        }
    }
}
#endif
