// The app's own diagnostic log, so a crash on the owner's phone can be read afterwards: a small rolling text log of
// what the app did (launch, screens, connection, errors — never message text, tokens or passwords), plus a record of
// every crash it can see: an Objective-C exception's name, reason and stack (written as it happens), a fatal signal's
// raw backtrace, and MetricKit's crash reports from iOS (delivered on a later launch, with the exception reason).
// Everything lives in Documents/Logs, which the Files app shows (On My iPhone › HQ Native › Logs) and Settings ›
// About › Share Logs sends as one zip.
//
// Two levels: `AppLog.note` always (launch, screens, connection, errors), `AppLog.trace` only with Settings › About ›
// Detailed Logging on (default on): every request, call, stream step, send step and list load, so a problem can be
// followed afterwards without reproducing it. Ids never appear raw: `AppLog.tag` turns a chat or message id into a short
// stable tag (the same id gives the same tag on every phone and on the gateway's computer, `hqn-logs.py --tag`).

import CryptoKit
import Foundation
import MetricKit
import os

nonisolated final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()

    /// Documents/Logs (created on first use).
    let directory: URL
    private let queue = DispatchQueue(label: "ai.hermes.hqnative.diagnostics", qos: .utility)
    /// Marks `queue`, so a wait for it from its own thread (the crash handler, for an exception raised there) is skipped.
    private static let onQueue = DispatchSpecificKey<Bool>()
    private let oslog = Logger(subsystem: "ai.hermes.hqnative", category: "app")
    private var handle: FileHandle?
    private let formatter: DateFormatter
    static let maxBytes = 4 << 20          // app.log rolls to app.1.log past 4 MB

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        queue.setSpecific(key: Self.onQueue, value: true)
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
    }

    var logURL: URL { directory.appendingPathComponent("app.log") }

    /// One line in the log (and the system log). `category` is a short word: launch, screen, net, chat, error…
    /// `code`: the line names code (a stack's frames), so its words aren't taken for ids (`AppLog.logged`).
    func note(_ category: String, _ message: String, code: Bool = false) {
        let now = Date()
        let thread = Thread.isMainThread ? "main" : "bg"
        DiagnosticsTimeline.shared.record(category: category, message: message, at: now)   // Settings › About › Diagnostics
        queue.async { [self] in
            let message = AppLog.logged(message, code: code)   // a gateway's words may quote a raw chat id or URL
            // [13-11] The system log gets the same redacted line as the file (it went there raw, marked public, so
            // Console or a sysdiagnose showed hostnames and chat ids).
            oslog.log("[\(category, privacy: .public)] \(message, privacy: .public)")
            write("\(formatter.string(from: now)) [\(category)] (\(thread)) \(message)\n")
            LogUploader.shared.noteLine(category: category, message: message, at: now)   // home to the owner's computer
        }
    }

    /// Waits for queued lines to land (before a crash record, and in tests).
    /// [13-20] On the queue itself there is nothing to wait for: waiting would hang the crash handler for good instead of
    /// writing its record.
    func flush() {
        guard DispatchQueue.getSpecific(key: Self.onQueue) != true else { return }
        queue.sync {}
    }

    #if DEBUG
    /// Tests: runs `body` on the log's own queue.
    func onLogQueue<T>(_ body: () -> T) -> T { queue.sync(execute: body) }
    #endif

    private func write(_ line: String) {
        if handle == nil {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
        }
        guard let handle, let data = line.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        if let size = try? handle.offset(), size > UInt64(Self.maxBytes) { roll() }
    }

    private func roll() {
        try? handle?.close()
        handle = nil
        let old = directory.appendingPathComponent("app.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: logURL, to: old)
    }

    /// The last `bytes` of the log, for crash records and the About page.
    func tail(bytes: Int = 16 << 10) -> String {
        flush()
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        return String(decoding: data.suffix(bytes), as: UTF8.self)
    }

    /// A one-off file in the Logs folder (crash records, MetricKit payloads). Old ones beyond 30 are removed.
    /// Returns where it went.
    @discardableResult
    func writeRecord(prefix: String, ext: String, _ data: Data) -> URL {
        let stamp = Self.fileStamp(Date())
        // [13-8] iOS can hand over several MetricKit payloads at once (after days away): each keeps its own file
        // instead of overwriting the one written the same second.
        var url = directory.appendingPathComponent("\(prefix)-\(stamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(prefix)-\(stamp)-\(n).\(ext)")
            n += 1
        }
        try? data.write(to: url, options: .atomic)
        prune(prefix: prefix, keep: 30)
        return url
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func prune(prefix: String, keep: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(keep) { try? FileManager.default.removeItem(at: file) }
    }

    /// Crash records (newest first): exception-, signal- and metrickit- files.
    func crashRecords() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["exception-", "signal-", "metrickit-"].contains(where: $0.lastPathComponent.hasPrefix) }
            .filter { !$0.lastPathComponent.hasSuffix("-pending.txt") }   // this run's open signal file
            .sorted { Self.modified($0) > Self.modified($1) }
    }
}

/// Short form for call sites: `AppLog.note("screen", "Artifacts")`.
nonisolated enum AppLog {
    static func note(_ category: String, _ message: String) { DiagnosticLog.shared.note(category, message) }
    static func error(_ where: String, _ error: Error) {
        DiagnosticLog.shared.note("error", "\(`where`): \(scrub(String(describing: error)))")
    }

    /// A detailed line: written only while Detailed Logging is on, and the message is not even built otherwise.
    static func trace(_ category: String, _ message: @autoclosure () -> String) {
        guard detailed else { return }
        DiagnosticLog.shared.note(category, message())
    }

    /// A detailed line that names code: a stack's frames ("UIKitCore -[UIView layoutSubviews] ← Hermes HQ +0x1a2b3c").
    /// Mac polish #49: run through `tagIds`, the app's own function names and offsets read "$#d36a6c", and none of a
    /// round's 165 hang lines could be traced to app code. Frames hold no one's data, so only hosts are tagged.
    static func traceCode(_ category: String, _ message: @autoclosure () -> String) {
        guard detailed else { return }
        DiagnosticLog.shared.note(category, message(), code: true)
    }

    /// A line as the log keeps it: every URL's host tagged and, unless it names code, every id-like word.
    static func logged(_ message: String, code: Bool) -> String {
        code ? tagHosts(message) : tagIds(tagHosts(message))
    }

    /// An error worth knowing about that the code then carries on from (a `try?` that failed): detailed level, with the
    /// error's own words, run through the redactor.
    static func swallowed(_ category: String, _ where: @autoclosure () -> String, _ error: Error) {
        guard detailed else { return }
        DiagnosticLog.shared.note(category, "\(`where`()) failed: \(scrub(String(describing: error)))")
    }

    /// Gateway or error words made safe for the log: the redactor, then every URL's host swapped for its tag (a URLError
    /// carries the whole failing URL: "NSErrorFailingURLKey=https://my-mac.tail1234.ts.net/…" reads "https://#20f234/…"),
    /// then every id-like word (a session or message id quoted in a refusal, "session 20251027_101010_ab12cd opened by
    /// cli") swapped for its tag.
    static func scrub(_ text: String) -> String { tagIds(tagHosts(DiagnosticRedactor.redact(text))) }

    private static let urlHost = try! NSRegularExpression(
        pattern: #"\b([a-z][a-z0-9+.-]{0,31}://)(?:[^\s/?#@"'<>]*@)?(\[[0-9a-f:.]+\]|[^\s/?#:"'<>,;)\]}]+)(:\d+)?"#,
        options: [.caseInsensitive])

    /// Every `scheme://host[:port]` written `scheme://#tag`, port dropped: the gateway's address never reaches the log
    /// (the tag is the one the gateway lines use, `AppLog.tag(url.host())`, so a failure still matches its gateway).
    static func tagHosts(_ text: String) -> String {
        guard text.contains("://") else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for match in urlHost.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let host = ns.substring(with: match.range(at: 2))
            guard !host.hasPrefix("#") else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                + ns.substring(with: match.range(at: 1)) + tag(host.lowercased())
            last = match.range.location + match.range.length
        }
        return last == 0 ? text : out + ns.substring(from: last)
    }

    private static let idWord = try! NSRegularExpression(
        pattern: #"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b|(?<![#\w])[A-Za-z0-9_]{8,}"#, options: [.caseInsensitive])

    /// Every id-like word (a UUID, or 8+ letters/digits/underscores with 3+ digits: "20251027_101010_ab12cd") swapped
    /// for its tag. Applied to every line as it is written; model names ("gpt-4o-2024-08-06") and counts survive.
    static func tagIds(_ text: String) -> String {
        guard text.utf8.count >= 8 else { return text }
        let ns = text as NSString
        var out = "", last = 0
        for match in idWord.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: match.range)
            let digits = word.filter(\.isNumber).count
            guard word.contains("-") || digits >= 3 && (word.contains(where: \.isLetter) || word.count >= 14) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + tag(word)
            last = match.range.location + match.range.length
        }
        return last == 0 ? text : out + ns.substring(from: last)
    }

    static let detailedKey = "hqn.log.detailed"
    /// Settings › About › Detailed Logging (default on). Read once, then kept here: `trace` runs on hot paths.
    nonisolated(unsafe) private(set) static var detailed: Bool = UserDefaults.standard.object(forKey: detailedKey) as? Bool ?? true

    static func setDetailed(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: detailedKey)
        detailed = on
        note("settings", "detailed logging \(on ? "on" : "off")")
    }

    /// A short stable tag for an id (chat, session, message, job): `#` + 6 hex of its SHA-256, never the id itself.
    /// nil or empty reads `#-`.
    static func tag(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "#-" }
        let digest = SHA256.hash(data: Data(id.utf8))
        return "#" + digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// A chat cache scope ("<account>|<profile>|<stored id>") tagged by its stored id, as the chat engine tags it.
    static func tag(scope: String) -> String {
        tag(scope.split(separator: "|", omittingEmptySubsequences: false).last.map(String.init) ?? scope)
    }

    /// Milliseconds since `start`, for "took N ms" in trace lines.
    static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = start.duration(to: .now).components
        return Int(d.seconds * 1000 + d.attoseconds / 1_000_000_000_000_000)
    }

    /// A URL path with ids swapped for tags and the query dropped: `/api/sessions/#3fa9b2/messages`.
    static func path(_ url: URL?) -> String {
        guard let url else { return "?" }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
            let s = String(part)
            return looksLikeId(s) ? tag(s.removingPercentEncoding ?? s) : s
        }
        return parts.joined(separator: "/") + (url.query == nil ? "" : "?…")
    }

    /// A path part that is an id or a user-chosen name rather than a fixed route word.
    static func looksLikeId(_ s: String) -> Bool {
        if s.isEmpty || s.count > 40 { return !s.isEmpty }
        if s.contains("%") || s.contains(".") && s.count > 12 { return true }
        let digits = s.filter(\.isNumber).count
        if digits >= 3 { return true }
        if s.count >= 16, digits > 0 || s.contains("_") { return true }   // not a long route word ("hermes-hq-browser")
        return s.contains(where: { $0.isUppercase }) && s.count >= 8
    }
}

// MARK: - Crash capture

/// Installed once, first thing at launch.
nonisolated enum CrashCapture {
    nonisolated(unsafe) private static var signalFD: Int32 = -1
    nonisolated(unsafe) private static var installed = false
    private static let metrics = MetricsReceiver()

    static func install() {
        guard !installed else { return }
        installed = true
        let log = DiagnosticLog.shared
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        log.note("launch", "\(AppIdentity.current.displayName) \(version), \(DeviceWord.system) \(ProcessInfo.processInfo.operatingSystemVersionString), \(Self.model())")
        // Whether this log is whole: with Detailed Logging off the trace lines are missing, with sending off none of it
        // reaches the owner's computer. [mac] Where the app runs from: a translocated or disk-image copy can't update.
        var setup = "logging: detailed \(AppLog.detailed ? "on" : "off"), sending \(LogUploader.isEnabled ? "on" : "off")"
        #if targetEnvironment(macCatalyst)
        setup += ", running \(Self.location(Bundle.main.bundlePath))"
        #endif
        log.note("launch", setup)

        // An Objective-C exception anywhere (also one raised inside Swift async code, which `try?` does not catch).
        NSSetUncaughtExceptionHandler { exception in
            var text = "Uncaught exception\n"
            text += "Name: \(exception.name.rawValue)\nReason: \(exception.reason ?? "(none)")\n"
            text += "Thread: \(Thread.isMainThread ? "main" : "background")\n"
            text += "Build: \(StabilityCounts.build)\n"
            if let info = exception.userInfo, !info.isEmpty { text += "UserInfo keys: \(info.keys.map { "\($0)" }.sorted())\n" }
            text += "\nStack:\n" + exception.callStackSymbols.joined(separator: "\n")
            text += "\n\nStack addresses (for symbolication):\n" + exception.callStackReturnAddresses.map { String(format: "0x%llx", $0.uint64Value) }.joined(separator: "\n")
            text += "\n\n" + CrashCapture.binaryImageNote()
            let messages = CrashMessages.current()
            if !messages.isEmpty { text += "\n" + messages.map { "Crash message (\($0.library)): \($0.text)" }.joined(separator: "\n") }
            text += "\n\nRecent log:\n" + DiagnosticLog.shared.tail()
            DiagnosticLog.shared.writeRecord(prefix: "exception", ext: "txt", Data(text.utf8))
        }

        // Fatal signals: the raw backtrace of the thread that died, written with async-signal-safe calls only, then the
        // message a library left for the system's crash report (Swift's "Fatal error: …"), which the backtrace lacks.
        CrashMessages.install()
        let path = log.directory.appendingPathComponent("signal-\(DiagnosticLog.fileStamp(Date()))-pending.txt").path
        signalFD = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if signalFD >= 0 {
            let header = "Fatal signal in Hermes HQ \(version)\n\(binaryImageNote())\nBacktrace of the thread that died:\n"
            _ = header.withCString { write(signalFD, $0, strlen($0)) }
            for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
                signal(sig) { sig in
                    let fd = CrashCapture.signalFD
                    if fd >= 0 {
                        var buffer = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
                        let count = backtrace(&buffer, 128)
                        let label: StaticString = "signal\n"
                        _ = write(fd, label.utf8Start, label.utf8CodeUnitCount)
                        backtrace_symbols_fd(&buffer, count, fd)
                        CrashMessages.write(to: fd)
                        fsync(fd)
                    }
                    signal(sig, SIG_DFL)
                    raise(sig)
                }
            }
        }
        // An earlier launch's empty signal file means that launch did not die of a signal.
        cleanEmptySignalFiles(except: path)
        StabilityCounts.countCaughtCrashes(log.crashRecords())   // [diagnostics] "Crashes caught by Hermes HQ"
        if let last = log.crashRecords().first {
            let defaults = UserDefaults.standard
            if let line = crashRecordNote(name: last.lastPathComponent, modified: DiagnosticLog.modified(last),
                                          lastNoted: defaults.string(forKey: lastNotedCrashKey), now: Date()) {
                log.note("launch", line)
                defaults.set(last.lastPathComponent, forKey: lastNotedCrashKey)
            }
        }

        MXMetricManager.shared.add(metrics)
    }

    static let lastNotedCrashKey = "hq.diagnostics.lastNotedCrashRecord"

    /// The launch line for the newest crash record, only the first launch that sees it (with its age), so an old
    /// record doesn't read like a fresh crash on every launch. Nil when this record was already noted.
    static func crashRecordNote(name: String, modified: Date, lastNoted: String?, now: Date) -> String? {
        guard name != lastNoted else { return nil }
        let minutes = max(0, Int(now.timeIntervalSince(modified) / 60))
        let age = minutes < 60 ? "\(minutes) min" : minutes < 48 * 60 ? "\(minutes / 60) h" : "\(minutes / 1440) days"
        return "new crash record: \(name) (written \(age) ago)"
    }

    private static func cleanEmptySignalFiles(except current: String) {
        let dir = DiagnosticLog.shared.directory
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("signal-") && file.path != current {
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !text.contains("\nsignal\n") {
                try? FileManager.default.removeItem(at: file)
            } else if file.lastPathComponent.hasSuffix("-pending.txt") {
                let kept = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: "-pending", with: ""))
                try? FileManager.default.moveItem(at: file, to: kept)
                DiagnosticLog.shared.note("launch", "the previous run died of a fatal signal: \(kept.lastPathComponent)")
            }
        }
    }

    /// Where the app's own code sits in memory, so raw addresses can be matched to the build's dSYM.
    static func binaryImageNote() -> String {
        guard let header = _dyld_get_image_header(0) else { return "" }
        let slide = _dyld_get_image_vmaddr_slide(0)
        return String(format: "App image header 0x%llx, slide 0x%llx", UInt64(UInt(bitPattern: header)), Int64(slide))
    }

    private static func model() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if targetEnvironment(macCatalyst)
        // [mac] uname says only "arm64"; the Mac's model ("Mac16,10") is hw.model.
        var size = 0
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [UInt8](repeating: 0, count: size)
            if sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 {
                return "\(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)) \(machine)"
            }
        }
        #endif
        return machine
    }

    /// [mac] Where the app's bundle sits, in words that name no folder of the person's: Gatekeeper's translocated
    /// copy (the app was opened where it was downloaded) and a mounted disk image can't install an update.
    static func location(_ bundlePath: String) -> String {
        if bundlePath.contains("/AppTranslocation/") { return "translocated (opened where it was downloaded)" }
        if bundlePath.hasPrefix("/Volumes/") { return "from a disk image" }
        if bundlePath.hasPrefix("/Applications/") { return "from Applications" }
        if bundlePath.contains("/DerivedData/") || bundlePath.contains("/.build/") || bundlePath.contains("/build/") { return "a development build" }
        if bundlePath.contains("/Applications/") { return "from your own Applications folder" }
        return "from another folder"
    }
}

// MARK: - Crash messages

/// The message a library leaves for the system's crash report just before it stops the app (CrashReporterClient's
/// `__crash_info` section): Swift's "Fatal error: Index out of range" with its file and line, libdispatch's "BUG IN
/// CLIENT OF LIBDISPATCH: …", abort()'s reason. A signal's backtrace says where, not why; this says why. The sections
/// are found once at launch; the signal handler only reads them and writes (async-signal-safe).
nonisolated enum CrashMessages {
    /// `crashreporter_annotations_t`: version, message, signature_string, backtrace, message2, … (8-byte fields).
    private static let messageOffsets = [8, 32]
    private static let capacity = 64
    nonisolated(unsafe) private static var sections = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
    nonisolated(unsafe) private static var names = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: capacity)
    /// What each message pointed at when the app started: a standing note, not a reason (the simulator's
    /// libsystem_sim_platform holds "CoreSimulator 1171.7 - Device: …" all along). One a library sets later counts.
    nonisolated(unsafe) private static var standing = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity * 2)
    nonisolated(unsafe) private static var count = 0

    /// Finds every loaded image's crash-info section (the app's frameworks are all loaded by the time this runs).
    static func install() {
        guard count == 0 else { return }
        for index in 0..<_dyld_image_count() where count < capacity {
            guard let header = _dyld_get_image_header(index), header.pointee.magic == MH_MAGIC_64,
                  let path = _dyld_get_image_name(index) else { continue }
            let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
            for segment in ["__DATA", "__DATA_DIRTY", "__AUTH"] {
                var size: UInt = 0
                guard let section = getsectiondata(header64, segment, "__crash_info", &size), size >= 40 else { continue }
                sections[count] = UInt(bitPattern: section)
                for (slot, offset) in messageOffsets.enumerated() {
                    standing[count * 2 + slot] = UnsafeRawPointer(section).load(fromByteOffset: offset, as: UInt64.self)
                }
                names[count] = strrchr(path, 0x2F).map { UnsafePointer($0 + 1) } ?? path   // the file name after the last "/"
                count += 1
                break
            }
        }
    }

    /// The images that have a crash-info section (tests).
    static var libraries: [String] { (0..<count).compactMap { names[$0].map { String(cString: $0) } } }

    /// The messages set right now, as text (the exception record; tests).
    static func current() -> [(library: String, text: String)] {
        var out: [(String, String)] = []
        for index in 0..<count {
            for offset in messageOffsets {
                guard let text = message(index, offset) else { continue }
                out.append((names[index].map { String(cString: $0) } ?? "?", String(cString: text)))
            }
        }
        return out
    }

    private static func message(_ index: Int, _ offset: Int) -> UnsafePointer<CChar>? {
        guard let section = UnsafeRawPointer(bitPattern: sections[index]),
              section.load(as: UInt64.self) > 0,                        // version 0: never filled in
              case let address = section.load(fromByteOffset: offset, as: UInt64.self),
              address != standing[index * 2 + (offset == messageOffsets[0] ? 0 : 1)],
              let text = UnsafePointer<CChar>(bitPattern: UInt(address)),
              text.pointee != 0 else { return nil }
        return text
    }

    /// One "Crash message (<library>): <text>" line per message, newlines inside it written " | ". Signal handler.
    static func write(to fd: Int32) {
        for index in 0..<count {
            for offset in messageOffsets {
                guard let text = message(index, offset) else { continue }
                let head: StaticString = "Crash message ("
                _ = Darwin.write(fd, head.utf8Start, head.utf8CodeUnitCount)
                if let name = names[index] { _ = Darwin.write(fd, name, strlen(name)) }
                let colon: StaticString = "): "
                _ = Darwin.write(fd, colon.utf8Start, colon.utf8CodeUnitCount)
                let length = strnlen(text, 2000)
                var start = 0
                for position in 0..<length where text[position] == 0x0A {
                    _ = Darwin.write(fd, text + start, position - start)
                    let bar: StaticString = " | "
                    _ = Darwin.write(fd, bar.utf8Start, bar.utf8CodeUnitCount)
                    start = position + 1
                }
                _ = Darwin.write(fd, text + start, length - start)
                let end: StaticString = "\n"
                _ = Darwin.write(fd, end.utf8Start, end.utf8CodeUnitCount)
            }
        }
    }
}

/// MetricKit hands over iOS's own crash and hang reports for this app (usually on the next launch). Each payload is
/// kept as JSON, and the crash's headline (exception reason, signal) goes into the log. [diagnostics] This build's
/// reports are also counted ("Stability, this build"), kept as short text (the last three, `CrashLog`) and added to
/// the day's kept numbers; each daily summary is folded to numbers and kept for a week (`FieldHistory`).
nonisolated final class MetricsReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private var build: String { StabilityCounts.build }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            DiagnosticLog.shared.writeRecord(prefix: "metrickit", ext: "json", payload.jsonRepresentation())
            for crash in payload.crashDiagnostics ?? [] {
                var parts = ["crash in \(crash.applicationVersion)"]
                if let reason = crash.exceptionReason {
                    parts.append("exception \(reason.exceptionName) (\(reason.className)): \(reason.composedMessage)")
                }
                if let type = crash.exceptionType { parts.append("type \(type)") }
                if let signal = crash.signal { parts.append("signal \(signal)") }
                if let reason = crash.terminationReason { parts.append(reason) }
                DiagnosticLog.shared.note("crash", parts.joined(separator: "; "))
            }
            for hang in payload.hangDiagnostics ?? [] {
                DiagnosticLog.shared.note("hang", "hang of \(hang.hangDuration) in \(hang.applicationVersion)")
            }
        }
        // iOS hands over a crash on a later launch; only this build's own are counted and kept.
        let build = self.build
        let crashes = payloads.flatMap { $0.crashDiagnostics ?? [] }.filter { $0.metaData.applicationBuildVersion == build }
        let hangs = payloads.flatMap { $0.hangDiagnostics ?? [] }.filter { $0.metaData.applicationBuildVersion == build }
        let cpu = payloads.flatMap { $0.cpuExceptionDiagnostics ?? [] }.filter { $0.metaData.applicationBuildVersion == build }
        let disk = payloads.flatMap { $0.diskWriteExceptionDiagnostics ?? [] }.filter { $0.metaData.applicationBuildVersion == build }
        StabilityCounts.count("crashes", by: crashes.count)
        StabilityCounts.count("cpuExceptions", by: cpu.count)
        StabilityCounts.count("diskWriteExceptions", by: disk.count)
        let now = Date()
        let reports: [(String, MXDiagnostic)] = crashes.map { ("Crash", $0) } + hangs.map { ("Hang", $0) } + cpu.map { ("CPU limit", $0) } + disk.map { ("Disk writes", $0) }
        CrashLog.keep(reports.map { CrashLog.summary(kind: $0.0, json: $0.1.jsonRepresentation(), at: now) }, build: build)
        guard !payloads.isEmpty else { return }
        FieldHistory.record(["diag.crashes": Double(crashes.count), "diag.hangs": Double(hangs.count),
                             "diag.hangSeconds": hangs.reduce(0) { $0 + $1.hangDuration.converted(to: .seconds).value },
                             "diag.cpuExceptions": Double(cpu.count), "diag.diskWriteExceptions": Double(disk.count)],
                            day: FieldHistory.day(now), build: build, at: now)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let values = Self.summary(payload), day = FieldHistory.day(payload.timeStampEnd)
            let build = payload.metaData?.applicationBuildVersion ?? build
            FieldHistory.record(values, day: day, build: build)
            // [diagnostics] build 293; the window spans two calendar days: the higher day's own sampled high and where.
            let highs = [FieldHistory.day(payload.timeStampBegin), day].map { MemoryFootprint.dayHighFields(day: $0) }
            let high = highs.max { ($0.first?.1 as? Int ?? 0) < ($1.first?.1 as? Int ?? 0) } ?? []
            LogUploader.shared.record("mk.day", Self.dayFields(values, day: day, build: build) + high + MemoryFootprint.fields())
        }
        DiagnosticLog.shared.note("metrics", "iOS daily summary received: \(payloads.count)")
    }

    /// One daily payload's numbers (`DiagnosticsReport.fieldSection` keys). Each metric is optional in the payload: a
    /// day the app never launched has no launch histogram, and iOS adds metrics over time.
    static func summary(_ payload: MXMetricPayload) -> [String: Double] {
        var values: [String: Double] = ["windowSeconds": payload.timeStampEnd.timeIntervalSince(payload.timeStampBegin)]
        if let cpu = payload.cpuMetrics { values["cpuSeconds"] = cpu.cumulativeCPUTime.converted(to: .seconds).value }
        if let memory = payload.memoryMetrics {
            values["peakMemoryBytes"] = memory.peakMemoryUsage.converted(to: .bytes).value
            values["suspendedMemoryBytes"] = memory.averageSuspendedMemory.averageMeasurement.converted(to: .bytes).value
        }
        if let responsiveness = payload.applicationResponsivenessMetrics {
            let hangs = FieldHistory.hangs(buckets(responsiveness.histogrammedApplicationHangTime))
            values["hangCount"] = hangs.count
            values["hangSeconds"] = hangs.seconds
        }
        if let exits = payload.applicationExitMetrics {
            let fg = exits.foregroundExitData, bg = exits.backgroundExitData
            values["exits.foreground.memoryLimit"] = Double(fg.cumulativeMemoryResourceLimitExitCount)
            values["exits.foreground.watchdog"] = Double(fg.cumulativeAppWatchdogExitCount)
            values["exits.foreground.abnormal"] = Double(fg.cumulativeAbnormalExitCount)
            values["exits.foreground.badAccess"] = Double(fg.cumulativeBadAccessExitCount)
            values["exits.foreground.illegalInstruction"] = Double(fg.cumulativeIllegalInstructionExitCount)
            values["exits.foreground.normal"] = Double(fg.cumulativeNormalAppExitCount)
            values["exits.background.memoryLimit"] = Double(bg.cumulativeMemoryResourceLimitExitCount)
            values["exits.background.memoryPressure"] = Double(bg.cumulativeMemoryPressureExitCount)
            values["exits.background.watchdog"] = Double(bg.cumulativeAppWatchdogExitCount)
            values["exits.background.abnormal"] = Double(bg.cumulativeAbnormalExitCount)
            values["exits.background.badAccess"] = Double(bg.cumulativeBadAccessExitCount)
            values["exits.background.illegalInstruction"] = Double(bg.cumulativeIllegalInstructionExitCount)
            values["exits.background.taskTimeout"] = Double(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)
            values["exits.background.lockedFile"] = Double(bg.cumulativeSuspendedWithLockedFileExitCount)
            values["exits.background.normal"] = Double(bg.cumulativeNormalAppExitCount)
        }
        if let launch = payload.applicationLaunchMetrics {
            values.merge(FieldHistory.launchBuckets("launch.firstDraw", buckets(launch.histogrammedTimeToFirstDraw))) { _, new in new }
            values.merge(FieldHistory.launchBuckets("launch.resume", buckets(launch.histogrammedApplicationResumeTime))) { _, new in new }
            values.merge(FieldHistory.launchBuckets("launch.extended", buckets(launch.histogrammedExtendedLaunch))) { _, new in new }
        }
        if let animation = payload.animationMetrics { values["scrollHitchMsPerSecond"] = animation.scrollHitchTimeRatio.value }
        return values
    }

    /// [diagnostics] A daily summary as one `mk.day` log event: scroll hitch ratio (ms/s), hangs (count, s), launches to
    /// first draw and resumes as five band counts ("under 0.5 s/0.5–1/1–2/2–4/over 4"), CPU seconds, peak MB, hours.
    static func dayFields(_ values: [String: Double], day: String, build: String) -> [(String, Any)] {
        var fields: [(String, Any)] = [("day", day), ("bld", build)]
        func bands(_ prefix: String) -> String? {
            let counts = FieldHistory.launchBands.map { Int(values["\(prefix).\($0.key)"] ?? 0) }
            return counts.contains { $0 > 0 } ? counts.map(String.init).joined(separator: "/") : nil
        }
        if let v = values["scrollHitchMsPerSecond"] { fields.append(("sh", FrameMath.decimal1(v))) }
        if let v = values["hangCount"] { fields.append(("hc", Int(v))) }
        if let v = values["hangSeconds"] { fields.append(("hs", FrameMath.decimal1(v))) }
        if let v = bands("launch.firstDraw") { fields.append(("fd", v)) }
        if let v = bands("launch.resume") { fields.append(("rsm", v)) }
        if let v = bands("launch.extended") { fields.append(("ext", v)) }
        if let v = values["cpuSeconds"] { fields.append(("cpu", Int(v.rounded()))) }
        if let v = values["peakMemoryBytes"] { fields.append(("pk", Int((v / 1_048_576).rounded()))) }
        if let v = values["windowSeconds"] { fields.append(("win", FrameMath.decimal1(v / 3600))) }
        return fields
    }

    private static func buckets(_ histogram: MXHistogram<UnitDuration>) -> [FieldHistory.Bucket] {
        let enumerator = histogram.bucketEnumerator
        var buckets: [FieldHistory.Bucket] = []
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            buckets.append(FieldHistory.Bucket(startMs: bucket.bucketStart.converted(to: .milliseconds).value,
                                               endMs: bucket.bucketEnd.converted(to: .milliseconds).value, count: bucket.bucketCount))
        }
        return buckets
    }
}
