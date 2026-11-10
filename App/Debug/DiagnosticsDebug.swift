// [diagnostics] DEBUG-only hooks for the diagnostics stream's UI tests and screenshots (compiled out of Release;
// docs/spec/3x-diagnostics.md §15). None carries a secret.
//
// - `-HQDebugFieldFixture week`   seven made-up daily summaries and three made-up iOS reports are written to the kept
//                                 files, so "Field metrics, from iOS" and "Reports from iOS" can be seen on a
//                                 simulator (MetricKit delivers nothing there)
// - `-HQDebugPlantError <n>`      logs one error n times, 2 s after launch, that carries a made-up ticket in a web
//                                 address and a made-up bearer key: what is stored, shown and copied must not hold them
// - `-HQPrintLogs`                3 s after launch, the newest crash record and the crash and stall events waiting to be
//                                 sent, printed to stdout (a Mac app's container can't be read from outside it: run the
//                                 binary itself, `"Hermes HQ.app/Contents/MacOS/Hermes HQ" -HQPrintLogs`)
// - Darwin notification `hqn.memory.warn` (`xcrun simctl spawn <udid> notifyutil -p hqn.memory.warn`) posts the
//   system's memory warning while the app runs
// - Darwin notification `hqn.power.toggle` flips the power saver override while the app runs (observed once, in
//   App/Offline/OfflineDebug.swift, the settings stream's hook)
// With `-HQDebugExposeStatus YES` the window carries a one-point element "debug.diag" whose value is
// "warm=<decoded transcripts in memory> trims=<memory trims run> dropped=<the last trim's count> power=<power events>
// saving=<0|1>", refreshed twice a second.

#if DEBUG
import UIKit

enum DiagnosticsDebug {
    static let plantedError = "POST https://x.example/a?ticket=abc123DEF456ghi789JKL012 Authorization: Bearer sk-live-0123456789abcdef"

    private static weak var probe: UIView?
    private static var timer: Timer?

    /// `-HQHangTest`: keeps the main thread busy in a function of the app's own, so the sampled stack names it.
    @inline(never) static func busyMainThread(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        var spin = 0
        while Date() < end { spin &+= 1 }
        AppLog.note("debug", "hang test done (\(spin > 0 ? "spun" : "idle"))")
    }

    static func applyAtLaunch() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("-HQPrintLogs") {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { printLogs() }
        }
        if defaults.string(forKey: "HQDebugFieldFixture") == "week" {
            FieldHistory.seedFixture(build: StabilityCounts.build)
        }
        let planted = defaults.integer(forKey: "HQDebugPlantError")
        if planted > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                for _ in 0..<planted { AppLog.note("error", plantedError) }
            }
        }
        // `-HQDebugScreenFault "<screen>|<message>|<A,B>"`: that problem 3 s after launch and again 1 s later (one entry).
        if let fault = defaults.string(forKey: "HQDebugScreenFault")?.components(separatedBy: "|"), fault.count >= 2 {
            let names = fault.count > 2 ? fault[2].components(separatedBy: ",") : []
            for delay in [3.0, 4.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ScreenFault.report(screen: fault[0], message: fault[1], path: names) }
            }
        }
        observeDarwin("hqn.memory.warn") {
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: UIApplication.shared)
        }
        // `hqn.power.toggle` is the settings stream's (OfflineDebug): a second observer here would flip it back at once.
        guard defaults.bool(forKey: "HQDebugExposeStatus") else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { publish() } }
    }

    nonisolated private static func printLogs() {
        let log = DiagnosticLog.shared
        if let newest = log.crashRecords().first, let text = try? String(contentsOf: newest, encoding: .utf8) {
            print("== \(newest.lastPathComponent)\n\(text)")
        }
        let waiting = ["sending.jsonl", "outbox.jsonl"].flatMap { name in
            ((try? String(contentsOf: log.directory.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n")
        }.filter { $0.contains(#""k":"crash."#) || $0.contains(#""k":"main.hang"#) }
        print("== \(waiting.count) crash and stall event(s) waiting to be sent\n" + waiting.suffix(80).joined(separator: "\n"))
        fflush(stdout)
    }

    private static var handlers: [String: @MainActor () -> Void] = [:]

    private static func observeDarwin(_ name: String, _ handler: @escaping @MainActor () -> Void) {
        handlers[name] = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, name, _, _ in
            guard let name = name?.rawValue as String? else { return }
            DispatchQueue.main.async { DiagnosticsDebug.handlers[name]?() }
        }, name as CFString, nil, .deliverImmediately)
    }

    private static func publish() {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let view = probe ?? {
            let view = UIView(frame: CGRect(x: 4, y: 0, width: 1, height: 1))
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = true
            view.accessibilityIdentifier = "debug.diag"
            probe = view
            return view
        }()
        if view.superview !== window { window.addSubview(view) }
        view.accessibilityValue = "warm=\(TranscriptCache.shared.memoryCount) trims=\(MemoryTrim.runs) dropped=\(MemoryTrim.lastDropped) "
            + "power=\(PowerLog.shared.events) saving=\(PowerState.shared.saving ? 1 : 0)"
    }
}
#endif
