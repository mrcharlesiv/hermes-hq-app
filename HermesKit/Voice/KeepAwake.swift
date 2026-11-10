// The screen stays awake while something voice-shaped is running (docs/spec/3x-talk.md §10.2; the web app's
// `src/voice-keep-awake.ts`). Reference-counted: `UIApplication.isIdleTimerDisabled` is written only when the number
// of holds crosses zero. The one file of HermesKit/Voice that touches UIApplication.

import UIKit

@MainActor
enum KeepAwake {
    /// The String is the chat's scope.
    enum Owner: Hashable, Sendable {
        case memo(String), dictation, conversation, turn(String), diagnostics
        var name: String {
            switch self {
            case .memo: "voice memo"
            case .dictation: "dictation"
            case .conversation: "conversation"
            case .turn: "reply"
            case .diagnostics: "diagnostics"
            }
        }
    }

    static let changed = Notification.Name("hq.voice.keepawake.changed")
    /// The longest a running reply keeps the screen awake.
    static let turnCap: TimeInterval = 600

    private static var holds: [Owner: Task<Void, Never>?] = [:]
    /// What the idle timer was before the first hold (another feature may have set it).
    private static var before = false
    /// Tests replace the write to UIApplication.
    static var apply: (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }
    static var read: () -> Bool = { UIApplication.shared.isIdleTimerDisabled }

    static var count: Int { holds.count }
    static var owners: [Owner] { Array(holds.keys) }
    static func isHeld(_ owner: Owner) -> Bool { holds[owner] != nil }

    /// Holds for `owner` (again replaces its cap). `cap` releases it by itself after that long.
    static func hold(_ owner: Owner, cap: TimeInterval? = nil) {
        let wasEmpty = holds.isEmpty
        if let existing = holds[owner] { existing?.cancel() }
        let fresh = holds[owner] == nil
        var timer: Task<Void, Never>?
        if let cap {
            timer = Task { @MainActor in
                try? await Task.sleep(for: .seconds(cap))
                guard !Task.isCancelled else { return }
                release(owner)
            }
        }
        holds[owner] = .some(timer)
        if wasEmpty {
            before = read()
            apply(true)
        }
        if fresh {
            VoiceEvents.note("screen kept awake for \(owner.name) (\(holds.count))")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func release(_ owner: Owner) {
        guard let existing = holds.removeValue(forKey: owner) else { return }
        existing?.cancel()
        if holds.isEmpty { apply(before) }
        VoiceEvents.note("screen released by \(owner.name) (\(holds.count))")
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// The app left the screen: capped holds end now; the others end with their feature.
    static func appLeftScreen() {
        for (owner, timer) in holds where timer != nil { release(owner) }
    }

    /// Tests only.
    static func reset() {
        for (_, timer) in holds { timer?.cancel() }
        holds = [:]
        before = false
    }
}
