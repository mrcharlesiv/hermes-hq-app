// [settings] The one door for the app's haptics (docs/spec/3x-settings.md §1; the web's `src/ui-kit/haptics.ts`).
// Settings › Sounds & Haptics › Haptics turns every one of them off. The system's own taps (switches, pickers,
// context menus, pull to refresh) are iOS's and stay as they are.
//
// Nothing else in App/ or HermesKit/ may create a feedback generator or use `.sensoryFeedback(`:
// `HapticsGateTests` scans the sources and fails on one. Call `Haptics.play(.selection)` instead.

import CoreHaptics
import UIKit

enum Haptics {
    nonisolated enum Kind: String, Equatable, Sendable, CaseIterable {
        case selection, light, medium, rigid, soft, success, warning, error
    }

    /// `UserDefaults` key (Bool, absent = on). On this iPhone only.
    nonisolated static let key = "hqn.haptics"

    /// The Share extension is another process: it reads the same answer from the App Group's defaults.
    nonisolated static let sharedKey = "hqn.haptics"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            if let group = ShareIdentity.appGroup { UserDefaults(suiteName: group)?.set(newValue, forKey: sharedKey) }
        }
    }

    /// Tests and the DEBUG probe: receives every cue that would have played, instead of the system.
    static var sink: ((Kind) -> Void)?

    /// How many generators this process has asked the system for (the stress plan's L10: zero while off).
    private(set) static var generatorsMade = 0

    static func play(_ kind: Kind) {
        guard isOn else { return }
        if let sink { return sink(kind) }
        generatorsMade += 1
        switch kind {
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    /// Wakes the Taptic Engine just before a cue that must land on time (a drag threshold). Nothing while off.
    static func prepare(_ kind: Kind) {
        guard isOn, sink == nil else { return }
        switch kind {
        case .selection: UISelectionFeedbackGenerator().prepare()
        case .light: UIImpactFeedbackGenerator(style: .light).prepare()
        case .medium: UIImpactFeedbackGenerator(style: .medium).prepare()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).prepare()
        case .soft: UIImpactFeedbackGenerator(style: .soft).prepare()
        case .success, .warning, .error: UINotificationFeedbackGenerator().prepare()
        }
    }

    #if DEBUG
    /// `-HQDebugHapticsProbe YES`: cues are counted instead of played (the Simulator has no Taptic Engine), on a
    /// one-point element "debug.haptics" whose value reads "count=3 last=selection", so a UI test can tell that the
    /// switch really silences a gesture.
    private static var probeCount = 0
    private static weak var probeView: UIView?

    static func installProbeIfAsked() {
        guard UserDefaults.standard.bool(forKey: "HQDebugHapticsProbe") else { return }
        sink = { kind in
            probeCount += 1
            showProbe(last: kind.rawValue)
        }
    }

    /// Puts the element up before the first cue, so a test can read "count=0".
    static func showProbe(last: String = "none") {
        guard UserDefaults.standard.bool(forKey: "HQDebugHapticsProbe") else { return }
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        guard let window else { return }
        let view = probeView ?? {
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.haptics"
            probeView = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        view.accessibilityValue = "count=\(probeCount) last=\(last)"
    }
    #endif
}

// MARK: - Revving

extension Haptics {
    /// [thinking-effects] A drive that revs, for the thinking bar (owner 2026-11-01: "a haptic feedback that
    /// accelerates. It gets more aggressive as you slide it towards the highest effort"). While a finger holds the bar
    /// a hum runs under it, rising in strength and pitch with `drive` (0 at Off, 1 at the top level), and the bar asks
    /// for a pulse on its own beat, faster and harder as it climbs, so each knock lands with the light it draws. A
    /// level crossed knocks harder the higher it is; reaching the top lands a double hit with a falling rumble.
    /// Core Haptics where the phone has it; elsewhere impact taps (no hum). Settings › Haptics off: nothing at all.
    @MainActor
    final class Rev {
        /// How a drive feels, from drive 0 to drive 1.
        nonisolated struct Profile: Equatable, Sendable {
            /// The hum's strength and pitch (0 = no hum).
            var hum: ClosedRange<Float>
            var humSharpness: ClosedRange<Float>
            /// Beats a second.
            var rate: ClosedRange<Double>
            var pulse: ClosedRange<Float>
            var pulseSharpness: ClosedRange<Float>

            /// The beat's rate at `drive`: it multiplies, so each step up the bar speeds it by the same share and it
            /// feels like acceleration rather than a dial.
            func beatsPerSecond(_ drive: Double) -> Double {
                let d = min(1, max(0, drive))
                return rate.lowerBound * pow(rate.upperBound / rate.lowerBound, d)
            }
            /// Strength along a range, eased so the top of the bar gets the most of it.
            static func along(_ range: ClosedRange<Float>, _ drive: Double, curve: Double = 1.6) -> Float {
                let d = Float(pow(min(1, max(0, drive)), curve))
                return range.lowerBound + (range.upperBound - range.lowerBound) * d
            }
        }

        private let profile: Profile
        private var engine: CHHapticEngine?
        private var hum: CHHapticAdvancedPatternPlayer?
        private var running = false
        private var lastTap: CFTimeInterval = 0
        /// The engine rests a moment after the finger lifts, so the drop's thud can still ring out.
        private var resting: Task<Void, Never>?

        init(profile: Profile) { self.profile = profile }

        nonisolated static var hasEngine: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

        /// A finger on the bar: the engine wakes and the hum starts, silent until `set`.
        func begin() {
            guard Haptics.isOn, Haptics.sink == nil, !running else { return }
            running = true
            resting?.cancel()
            guard Self.hasEngine else { return }
            do {
                let engine = try engine ?? makeEngine()
                self.engine = engine
                try engine.start()
                if profile.hum.upperBound > 0 {
                    // A long continuous event, looped: the hum lasts as long as the finger does.
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                    ], relativeTime: 0, duration: 30)
                    let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                    player.loopEnabled = true
                    try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)],
                                              atTime: CHHapticTimeImmediate)
                    try player.start(atTime: CHHapticTimeImmediate)
                    hum = player
                }
            } catch {
                AppLog.trace("haptics", "rev engine failed: \(error.localizedDescription)")
            }
        }

        private func makeEngine() throws -> CHHapticEngine {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false
            // The system took it away (a call, the app going away): the next touch starts it again.
            engine.resetHandler = { [weak self] in Task { @MainActor in self?.hum = nil; self?.running = false } }
            engine.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.hum = nil; self?.running = false } }
            return engine
        }

        /// The hum at `drive`; `motion` (0…1, how fast the finger moves) lifts it, so a still finger idles lower.
        /// `override` pulls it toward a level of the caller's (weight 1: only that level).
        func set(drive: Double, motion: Double, hum override: (level: Float, weight: Float)? = nil) {
            guard running, let hum else { return }
            var strength = Profile.along(profile.hum, drive) * Float(0.6 + 0.4 * min(1, max(0, motion)))
            if let override { strength += (override.level - strength) * override.weight }
            let pitch = Profile.along(profile.humSharpness, drive, curve: 1) - 0.5
            try? hum.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: strength, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: pitch, relativeTime: 0),
            ], atTime: CHHapticTimeImmediate)
        }

        /// One beat at `drive`; `scale` and `sharpen` change it from the profile's.
        func pulse(drive: Double, scale: Float = 1, sharpen: Float = 0) {
            guard running else { return }
            knock(Profile.along(profile.pulse, drive) * scale, min(1, Profile.along(profile.pulseSharpness, drive, curve: 1) + sharpen))
        }

        /// Something big passing: one dull knock.
        func thump() {
            guard running else { return }
            knock(0.5, 0.2)
        }

        /// Out of the top level as the finger lifts: a thud, a rumble dying away, and a small tick as it docks. Call
        /// before `end()`.
        func dropOut() {
            guard Haptics.isOn else { return }
            if let sink = Haptics.sink { return sink(.medium) }
            guard running, let engine else { return Haptics.play(.medium) }
            let events = [
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
                ], relativeTime: 0),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ], relativeTime: 0, duration: 0.29),
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
                ], relativeTime: 0.3),
            ]
            let fall = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.29, value: 0),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.295, value: 1),   // the curve scales every event: back up for the tick
            ], relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: events, parameterCurves: [fall]),
               let player = try? engine.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }

        /// A level crossed: a knock that grows with the level.
        func click(drive: Double) {
            guard Haptics.isOn else { return }
            if let sink = Haptics.sink { return sink(.selection) }
            guard running else { return Haptics.play(.selection) }
            knock(Float(0.55 + 0.45 * min(1, max(0, drive))), Float(0.55 + 0.4 * drive))
        }

        /// The top level reached: a heavy hit, a sharp one on its heels, and a rumble falling away.
        func jump() {
            guard Haptics.isOn else { return }
            if let sink = Haptics.sink { return sink(.rigid) }
            guard running, let engine else { return Haptics.play(.rigid) }
            let events = [
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
                ], relativeTime: 0),
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.95),
                ], relativeTime: 0.07),
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
                ], relativeTime: 0.07, duration: 0.5),
            ]
            let fall = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.07, value: 1),
                CHHapticParameterCurve.ControlPoint(relativeTime: 0.57, value: 0),
            ], relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: events, parameterCurves: [fall]),
               let player = try? engine.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }

        /// The finger lifts: the hum stops; the engine rests until the next touch.
        func end() {
            guard running else { return }
            running = false
            try? hum?.stop(atTime: CHHapticTimeImmediate)
            hum = nil
            resting?.cancel()
            resting = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                self?.engine?.stop(completionHandler: nil)
            }
        }

        private func knock(_ intensity: Float, _ sharpness: Float) {
            guard let engine else {
                // No Core Haptics: impact taps, at most 25 a second (the generator can't keep up past that).
                let now = CACurrentMediaTime()
                guard now - lastTap > 0.04 else { return }
                lastTap = now
                generatorsMade += 1
                UIImpactFeedbackGenerator(style: sharpness > 0.6 ? .rigid : .heavy).impactOccurred(intensity: CGFloat(intensity))
                return
            }
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }
    }
}
