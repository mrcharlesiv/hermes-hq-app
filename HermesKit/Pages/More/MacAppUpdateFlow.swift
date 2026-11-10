// [mac-update] The pure half of the Mac download's own update sheet (App/Mac/MacAppUpdate.swift). Owner 2026-11-10:
// "The Mac app needs a better update UI UX. It just kinda like falls off and you can't see what it is doing." Sparkle's
// stock windows said little, the release notes were one run-on paragraph, and after Install the app simply vanished.
// Here: the What's New lines out of the appcast's plain-text notes, the download's words ("21.4 of 52.8 MB · About 6 s
// left"), the words for each failure, and the note left behind before the app quits to install, so the copy that opens
// next can say "Updated to 1.0.3 (925)" (or that it didn't take).

import Foundation

enum MacAppUpdateStepID: String, CaseIterable, Sendable {
    case download, unpack, install, reopen
}

enum MacAppUpdateStepState: Equatable, Sendable {
    case waiting, active, done, failed
}

/// What's New, out of an appcast item's plain-text description.
struct MacAppUpdateNotes: Equatable, Sendable {
    /// A sentence ahead of the list that isn't just "What's new since the last Mac update:".
    var intro: String?
    var items: [String]

    static let empty = MacAppUpdateNotes(intro: nil, items: [])

    /// `ship.py appcast` writes the notes' "- " lines on lines of their own; the feeds before it ran each paragraph into
    /// one line ("What's new since the last Mac update: - Math in replies … - Command-Delete is now …"), so a " - "
    /// after a sentence's end and before a capital starts an item too.
    init(_ text: String?) {
        var intro: [String] = []
        var items: [String] = []
        let text = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
        for paragraph in text.components(separatedBy: "\n") {
            for (index, piece) in Self.pieces(paragraph).enumerated() {
                let bullet = piece.hasPrefix("- ") || piece.hasPrefix("• ") || piece.hasPrefix("* ")
                let words = (bullet ? String(piece.dropFirst(2)) : piece).trimmingCharacters(in: .whitespaces)
                guard !words.isEmpty else { continue }
                if bullet || index > 0 || !items.isEmpty { items.append(words) } else { intro.append(words) }
            }
        }
        let lead = intro.joined(separator: " ")
        self.intro = lead.isEmpty || Self.isBareHeading(lead) ? nil : lead
        self.items = items
    }

    init(intro: String?, items: [String]) {
        self.intro = intro
        self.items = items
    }

    /// One line cut at each run-in item: a " - " after . : ! ? or ) and before a capital letter or a digit.
    private static func pieces(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        var out: [String] = []
        var from = trimmed.startIndex
        for match in runIn.matches(in: trimmed, range: range) {
            guard let cut = Range(match.range, in: trimmed) else { continue }
            out.append(String(trimmed[from..<cut.lowerBound]))
            from = cut.upperBound
        }
        out.append(String(trimmed[from...]))
        // Only the first piece can be a lead-in; the rest were items.
        return out.enumerated().map { $0.offset == 0 ? $0.element : "- " + $0.element }
    }

    /// Swift's Regex has no lookbehind; Foundation's does.
    private static let runIn = try! NSRegularExpression(pattern: #"(?<=[.:!?)])\s+-\s+(?=[\p{Lu}0-9⌘⌥⌃⇧])"#)

    private static func isBareHeading(_ text: String) -> Bool {
        let lower = text.lowercased()
        return text.hasSuffix(":") && (lower.hasPrefix("what’s new") || lower.hasPrefix("what's new") || lower.hasPrefix("new in"))
    }
}

/// The download's bytes, for its line and the bar.
struct MacAppUpdateTransfer: Equatable, Sendable {
    var expected: UInt64 = 0
    var received: UInt64 = 0
    var started: Date?
    /// Recent (time, total received) points: the speed is read over the last few seconds, not since the start.
    private var samples: [Sample] = []

    private struct Sample: Equatable, Sendable { var at: Date; var total: UInt64 }

    init(expected: UInt64 = 0) { self.expected = expected }

    mutating func begin(at now: Date) {
        received = 0
        started = now
        samples = [Sample(at: now, total: 0)]
    }

    mutating func add(_ bytes: UInt64, at now: Date) {
        if started == nil { begin(at: now) }
        received += bytes
        if expected > 0, received > expected { expected = received }
        samples.append(Sample(at: now, total: received))
        samples.removeAll { now.timeIntervalSince($0.at) > 4 }
        if samples.count > 400 { samples.removeFirst(samples.count - 400) }
    }

    /// 0…1, once the size is known.
    var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    /// Bytes a second over the recent samples (nil until there's a second's worth).
    func speed(at now: Date) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 0.75, last.total > first.total else { return nil }
        return Double(last.total - first.total) / span
    }

    func secondsLeft(at now: Date) -> Int? {
        guard expected > received, let speed = speed(at: now), speed > 0 else { return nil }
        return Int((Double(expected - received) / speed).rounded(.up))
    }

    /// "21.4 of 52.8 MB · About 6 s left", "21.4 MB" before the size is known.
    func words(at now: Date) -> String {
        guard expected > 0 else { return received > 0 ? MacAppUpdateWords.size(received) : "Starting…" }
        var line = "\(MacAppUpdateWords.size(received, unit: false, like: expected)) of \(MacAppUpdateWords.size(expected))"
        if let left = secondsLeft(at: now) { line += " · " + MacAppUpdateWords.timeLeft(left) }
        return line
    }
}

enum MacAppUpdateWords {
    /// "52.8 MB" (Finder's thousands), "820 KB", "1.2 GB". `like`: the unit of another size, so "21.4 of 52.8 MB"
    /// keeps one unit; `unit` false leaves it off.
    static func size(_ bytes: UInt64, unit: Bool = true, like other: UInt64? = nil) -> String {
        let scale = other ?? bytes
        let (divisor, name): (Double, String) = scale >= 1_000_000_000 ? (1e9, "GB") : scale >= 1_000_000 ? (1e6, "MB") : (1e3, "KB")
        let value = Double(bytes) / divisor
        let number = name == "KB" ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return unit ? "\(number) \(name)" : number
    }

    /// "1.0.3 (925)"; the build alone when the version is missing or the same text.
    static func version(_ display: String?, build: String?) -> String {
        let display = display?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = build?.trimmingCharacters(in: .whitespaces) ?? ""
        if display.isEmpty { return build.isEmpty ? "?" : "build \(build)" }
        if build.isEmpty || build == display { return display }
        return "\(display) (\(build))"
    }

    /// "About 6 s left", "About 2 min left", "Less than a second left".
    static func timeLeft(_ seconds: Int) -> String {
        if seconds <= 1 { return "Almost done" }
        if seconds < 60 { return "About \(seconds) s left" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return "About \(minutes) min left"
    }

    /// "6 s", "1 min 4 s".
    static func took(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 60 { return "\(max(1, whole)) s" }
        return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s"
    }

    /// Sparkle's SPUNoUpdateFoundReason (SUErrors.h), as the up-to-date line.
    static func upToDate(reason: Int?, current: String, latest: String?) -> String {
        switch reason {
        case 2: "This copy (\(current)) is newer than the website’s\(latest.map { " (\($0))" } ?? "")."
        case 3: "\(latest.map { "Hermes HQ \($0)" } ?? "The newest Hermes HQ") needs a newer version of macOS."
        case 4: "\(latest.map { "Hermes HQ \($0)" } ?? "The newest Hermes HQ") doesn’t run on this version of macOS yet."
        case 5: "The newest Hermes HQ needs a Mac with Apple silicon."
        default: "\(current) is the newest version."
        }
    }

    /// A failure's headline and line, from Sparkle's error (SUSparkleErrorDomain codes, SUErrors.h) or the network's.
    static func failure(domain: String, code: Int, description: String) -> (headline: String, line: String) {
        if domain == NSURLErrorDomain {
            return ("Couldn’t Reach the Update Server", code == NSURLErrorNotConnectedToInternet
                    ? "This Mac isn’t connected to the internet. Connect, then try again."
                    : "gethermeshq.com didn’t answer. Check the connection, then try again.")
        }
        guard domain == "SUSparkleErrorDomain" else {
            return ("The Update Didn’t Finish", description.isEmpty ? "Something went wrong. Try again in a moment." : description)
        }
        switch code {
        case 1000, 1002, 1004:
            return ("Couldn’t Read the Update List", "The website’s list of updates couldn’t be read. Try again in a moment.")
        case 1003:
            return ("Move Hermes HQ to Applications First", "Hermes HQ is running from the disk image. Drag it to Applications, open it from there, then update.")
        case 1005:
            return ("Move Hermes HQ to Applications First", "macOS is running this copy from a temporary place. Move Hermes HQ to Applications, open it again, then update.")
        case 2001:
            return ("The Download Stopped", "The update didn’t download all the way. Check the connection, then try again.")
        case 3000:
            return ("Couldn’t Open the Update", "The download was damaged. Try again: it downloads fresh.")
        case 3001, 3002, 1, 2:
            return ("The Update Wasn’t Signed Right", "Hermes HQ didn’t install it, to keep this Mac safe. Download the newest copy from gethermeshq.com instead.")
        case 4000, 4005, 4012:
            return ("Couldn’t Install the Update", "macOS didn’t let the update replace Hermes HQ. Download the newest copy from gethermeshq.com and drag it to Applications.")
        case 4001:
            return ("Installing Needs Your Password", "The update was stopped when the password was asked for. Try again and enter your Mac’s password.")
        case 4004:
            return ("Hermes HQ Didn’t Reopen", "The update installed, but Hermes HQ didn’t open again by itself. Open it from Applications.")
        case 4007:
            return ("Update Cancelled", "Nothing changed. Hermes HQ stays on this version.")
        case 4008:
            return ("Update Waits for Your Password", "It installs the next time you quit Hermes HQ and enter your password.")
        case 4002, 4003, 4010:
            return ("The Installer Didn’t Start", "Try again. If it keeps happening, download the newest copy from gethermeshq.com.")
        default:
            return ("The Update Didn’t Finish", description.isEmpty ? "Something went wrong. Try again in a moment." : description)
        }
    }

    /// Codes that mean the person stopped it (no Try Again needed, no Copy Details).
    static func isCancel(domain: String, code: Int) -> Bool {
        domain == "SUSparkleErrorDomain" && code == 4007
    }

    /// Codes where the website's download is the way forward.
    static func wantsWebsite(domain: String, code: Int) -> Bool {
        domain == "SUSparkleErrorDomain" && [1003, 1005, 3001, 3002, 1, 2, 4000, 4005, 4012, 4002, 4003, 4010].contains(code)
    }
}

/// Left in UserDefaults just before the app quits to install (or chooses to install when it quits), so the next copy
/// that opens can say what happened.
struct MacAppUpdateRecord: Codable, Equatable, Sendable {
    var fromBuild: String
    var fromDisplay: String
    var toBuild: String
    var toDisplay: String
    var notes: String?
    var at: Date
    /// Later: Sparkle installs it when the app quits, whenever that is.
    var onQuit: Bool

    static let key = "HQMacAppUpdateRecord"

    enum Outcome: Equatable, Sendable {
        /// This copy is the new build.
        case updated
        /// Still the old build soon after a restart to update: the install didn't take.
        case didntFinish
        /// Nothing to say (an old note, or Later's install hasn't happened yet).
        case nothing
    }

    func outcome(runningBuild: String, now: Date) -> Outcome {
        let age = now.timeIntervalSince(at)
        if runningBuild == toBuild { return age < 14 * 86_400 ? .updated : .nothing }
        if runningBuild == fromBuild, !onQuit, age >= 0, age < 30 * 60 { return .didntFinish }
        return .nothing
    }

    /// Kept for a later launch: Later's install hasn't happened yet (the app is still the old build).
    func keepsWaiting(runningBuild: String, now: Date) -> Bool {
        onQuit && runningBuild == fromBuild && now.timeIntervalSince(at) < 14 * 86_400
    }

    static func load(_ defaults: UserDefaults = .standard) -> MacAppUpdateRecord? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(MacAppUpdateRecord.self, from: $0) }
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func clear(_ defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
