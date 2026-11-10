// Sends the diagnostic log home by itself: to the owner's own computer through the gateway's hermes-hq-push plugin
// (POST /api/plugins/hermes-hq-push/logs, the route the web app's performance log already uses), which writes
// ~/.hermes/hq-logs/HQN_<model>-<id>/<day>.jsonl. Nothing goes anywhere else.
//
// The plugin keeps only short fields (strings ≤ 120 characters, ≤ 16 fields, names like "message", "name", "url",
// "token" dropped), so each log line and each crash-stack frame is its own small event:
//   note.<category> {m, m2…}                       a log line (split into 120-character parts)
//   crash.exc {rec, nm, why, why2…}                 an Objective-C exception (written as it happened, sent next launch)
//   crash.sig {rec}                                 a fatal signal
//   crash.mk {rec, ver, exc, code, sig, cls, why…}  iOS's own crash report (MetricKit)
//   crash.frame {rec, i, f}                         one stack line of an exception / signal record
//   crash.why {rec, lib, why…}                      the message a library left for the crash report ("Fatal error: …")
//   crash.mk.frame {rec, i, b, o, u}                MetricKit frame: binary, offset into its text, UUID prefix
//   frames {kd, scr, n, …} / frames.bad {…}        hitches while things move (FrameMeter.swift); mk.day {day, bld, sh…}
//   mem.high {scr, fp, fpk}                         the footprint passed 250 MB / another 50 MB (MemoryFootprint.swift);
//                                                   fp / fpk (MB now, this run's peak) also on mem.trim, main.hang,
//                                                   frames.bad and mk.day (with hi / hiOn, the day's sampled high)
//   hang.mk {rec, dur, ver, bld}                    iOS's own hang report (MetricKit)
//   hang.mk.frame {rec, i, b, o, u, s}              its main thread's innermost frames; `s` the symbol when the
//                                                   binary is a system one loaded now (the app's own: atos, hqn-logs.py)
//   main.hang {ms, screen, rec, bld, did…}          a stall HangWatch saw; `rec` when its stack was sampled, then
//   main.hang.frame {rec, n, i, b, o, s}            the main thread's frames at sample `n` (MainStack.swift)
//   note.system {m}                                 [mac] an error or fault the system logged for the app (SystemLog.swift)
// Unsent events wait in Logs/outbox-<account>.jsonl (at most 16 MB), one per gateway account: lines logged while
// signed in to one gateway (or after leaving it, until the next sign-in) go to that gateway only; a failed send waits 30 s, doubling to 30 min, and a gateway
// without the route (404) is asked again after 6 h. A batch the plugin refuses for good (400, 413, 422), or one that
// failed 8 times in a row, is let go (the next batch says `lost`) so it cannot hold every later line back.
//
// [perf] Right after the link comes back the uploads hold off for 15 s (`hold`), so the lists' refresh has the
// connection to itself; leaving the app, a janky-moment mark and crash records still send at once.
//
// Settings › About › Send Performance Logs to Your Computer (on by default, `perf-log.ts` setPerfLogEnabled) turns it
// off: nothing is queued or sent then, and what was waiting is deleted. Mark a Janky Moment queues a `mark {by, id}`
// event and sends at once.

import Foundation
import UIKit

nonisolated final class LogUploader: @unchecked Sendable {
    static let shared = LogUploader()
    static let route = "/api/plugins/hermes-hq-push/logs"
    static let maxOutboxBytes = 16 << 20
    static let batchLines = 800
    /// A request also ends at this many bytes of lines, well under any gateway or tunnel body limit.
    static let batchBytes = 256 << 10
    /// Sends of one batch that may fail in a row before it is let go.
    static let maxBatchFailures = 8
    static let maxString = 120

    private let queue = DispatchQueue(label: "ai.hermes.hqnative.logupload", qos: .utility)
    private let lock = NSLock()
    /// Sends one request body; set by the app once it has a gateway client (nil while signed out).
    private var sender: (@Sendable (Data) async throws -> Void)?
    private var inFlight = false
    private var failures = 0
    private var notBefore = Date.distantPast
    private var lastKick = Date.distantPast
    /// No send that is not forced before this (`hold`).
    private var quietUntil = Date.distantPast
    /// Failed sends of the batch in `sending.jsonl`.
    private var batchFailures = 0
    private let customDirectory: URL?
    private var lostLines = false
    private(set) var lastUploadAt: Date?
    private(set) var lastStatus: Int?

    /// [13-9] Whose gateway the waiting lines go to (a short hash of the account id): the one signed in when they were
    /// logged, or the last one while signed out. "" before any sign-in that named its account: the shared outbox.jsonl,
    /// which the first account named takes over.
    private var owner = ""

    /// `directory`: where the outbox lives (tests); the diagnostic log's own folder otherwise.
    init(directory: URL? = nil) {
        customDirectory = directory
        owner = ((try? String(contentsOf: ownerFile, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let enabledKey = "hqn.perfLog.enabled"

    /// Send Performance Logs to Your Computer (default on).
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The Settings switch. Off deletes what was waiting to be sent; on sends the next batch soon.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            kick("enabled")
        } else {
            queue.async { [self] in
                lock.lock(); defer { lock.unlock() }
                // Every account's outbox (and every batch not on its way).
                let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
                for name in names where name.hasSuffix(".jsonl") && (name.hasPrefix("outbox") || name.hasPrefix("sending")) {
                    let url = directory.appendingPathComponent(name)
                    if inFlight, url == sending { continue }
                    try? FileManager.default.removeItem(at: url)
                }
                lostLines = false
            }
        }
    }

    /// "That was janky just now": a marker in the log on the owner's computer, sent straight away. Returns its id.
    @discardableResult
    func markMoment(by: String = "user") -> String {
        let id = (0..<12).map { _ in String(Int.random(in: 0..<16), radix: 16) }.joined()
        guard Self.isEnabled else { return id }
        queue.async { [self] in
            if let line = Self.event("mark", [("by", by), ("id", id)]) { append([line]) }
            lock.lock(); notBefore = .distantPast; lock.unlock()
        }
        kick("mark", force: true)
        return id
    }

    /// Bytes waiting to be sent (Diagnostics).
    var pendingBytes: Int {
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        lock.lock(); let urls = (outbox, sending); lock.unlock()
        return size(urls.0) + size(urls.1)
    }

    private var directory: URL { customDirectory ?? DiagnosticLog.shared.directory }
    /// This owner's (read under `lock`).
    private var outbox: URL { outbox(owner) }
    private var sending: URL { sending(owner) }
    private func outbox(_ owner: String) -> URL { directory.appendingPathComponent(owner.isEmpty ? "outbox.jsonl" : "outbox-\(owner).jsonl") }
    private func sending(_ owner: String) -> URL { directory.appendingPathComponent(owner.isEmpty ? "sending.jsonl" : "sending-\(owner).jsonl") }
    private var ownerFile: URL { directory.appendingPathComponent("outbox-owner.txt") }

    static func ownerKey(_ accountId: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325          // FNV-1a: stable across launches, no ids in file names
        for byte in accountId.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
    private var sentList: URL { directory.appendingPathComponent("sent-records.txt") }

    static var device: String {
        let key = "hqn.log.device"
        var id = UserDefaults.standard.string(forKey: key) ?? ""
        if id.range(of: "^[0-9a-f]{8}$", options: .regularExpression) == nil {
            id = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
            UserDefaults.standard.set(id, forKey: key)
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let label = String(("HQN_" + machine).map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(24))
        return "\(label)-\(id)"
    }

    static var appLabel: String {
        let info = Bundle.main.infoDictionary
        return "HQN \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    // MARK: Events

    /// A field set with long strings split into 120-character parts (`why`, `why2`, `why3`…).
    static func event(_ kind: String, at date: Date = Date(), _ fields: [(String, Any)]) -> String? {
        var out: [String: Any] = ["t": Int(date.timeIntervalSince1970 * 1000), "k": kind, "s": "n"]
        for (key, value) in fields {
            guard out.count - 3 < 16 else { break }
            if let text = value as? String {
                var rest = Substring(text.replacingOccurrences(of: "\n", with: " ⏎ "))
                var part = 1
                repeat {
                    out[part == 1 ? key : "\(key)\(part)"] = String(rest.prefix(maxString))
                    rest = rest.dropFirst(maxString)
                    part += 1
                } while !rest.isEmpty && out.count - 3 < 16
            } else {
                out[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              data.count <= 2000 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Called on the log's queue for every log line.
    func noteLine(category: String, message: String, at date: Date) {
        guard Self.isEnabled else { return }
        let kind = "note." + String(category.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(30))
        if let line = Self.event(kind, at: date, [("m", message)]) { append([line]) }
        lock.lock(); let due = Date().timeIntervalSince(lastKick) > 60 && Date() >= quietUntil; lock.unlock()
        if due { kick("periodic") }
    }

    /// [diagnostics] One named event with short, content-free fields ("power", "mem.trim"): queued like a log line.
    func record(_ kind: String, _ fields: [(String, Any)], at date: Date = Date()) {
        guard Self.isEnabled else { return }
        guard let line = Self.event(kind, at: date, fields) else { return }
        queue.async { [self] in append([line]) }
    }

    private func append(_ lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        let size = (try? outbox.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size < Self.maxOutboxBytes else { lostLines = true; return }
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        if let handle = try? FileHandle(forWritingTo: outbox) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: outbox)
        }
    }

    // MARK: Crash records → events (once each)

    /// Turns every crash record not sent yet into events. Run at launch, after `CrashCapture.install()`.
    func collectCrashRecords() {
        guard Self.isEnabled else { return }
        queue.async { [self] in
            let sent = Set(((try? String(contentsOf: sentList, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
            var done: [String] = []
            for file in DiagnosticLog.shared.crashRecords().reversed() where !sent.contains(file.lastPathComponent) {
                if file.lastPathComponent.hasSuffix("-pending.txt") { continue }   // this run's open signal file
                let rec = String(file.deletingPathExtension().lastPathComponent.suffix(15))
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                var lines: [String] = []
                if file.lastPathComponent.hasPrefix("metrickit-") {
                    lines = Self.metricKitEvents((try? Data(contentsOf: file)) ?? Data(), rec: rec, date: date)
                } else if let text = try? String(contentsOf: file, encoding: .utf8) {
                    lines = Self.recordEvents(text, exception: file.lastPathComponent.hasPrefix("exception-"), rec: rec, date: date)
                }
                append(lines)
                done.append(file.lastPathComponent)
            }
            if !done.isEmpty {
                let all = (sent.union(done)).sorted().suffix(200).joined(separator: "\n")
                try? all.write(to: sentList, atomically: true, encoding: .utf8)
                kick("crash", force: true)   // a crash record does not wait out a hold
            }
        }
    }

    static func recordEvents(_ text: String, exception: Bool, rec: String, date: Date) -> [String] {
        var lines: [String] = []
        let rows = text.components(separatedBy: "\n")
        func value(_ prefix: String) -> String { rows.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? "" }
        // The build, for the dSYM that names the app's frames: "Build: 454" (exception), "Fatal signal in … (454)".
        var build = value("Build: ")
        if !exception, let header = rows.first, header.hasSuffix(")"), let open = header.lastIndex(of: "(") {
            build = String(header[header.index(after: open)..<header.index(before: header.endIndex)])
        }
        if exception {
            lines += [event("crash.exc", at: date, [("rec", rec), ("bld", build), ("nm", value("Name: ")), ("thr", value("Thread: ")),
                                                     ("why", value("Reason: "))])].compactMap { $0 }
        } else {
            lines += [event("crash.sig", at: date, [("rec", rec), ("bld", build)])].compactMap { $0 }
        }
        if let image = rows.first(where: { $0.hasPrefix("App image header") }) {
            lines += [event("crash.img", at: date, [("rec", rec), ("img", image)])].compactMap { $0 }
        }
        // Why it stopped, in the words a library left for the crash report (CrashMessages): "Fatal error: …".
        for row in rows where row.hasPrefix("Crash message (") {
            guard let close = row.range(of: "): ") else { continue }
            let library = String(row[row.index(row.startIndex, offsetBy: 15)..<close.lowerBound])
            let text = String(row[close.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " |"))
            lines += [event("crash.why", at: date, [("rec", rec), ("lib", library), ("why", AppLog.scrub(text))])].compactMap { $0 }
        }
        // Stack lines: "N  Binary  0xADDR symbol + off" (exception) or backtrace_symbols_fd lines (signal). [mac] The
        // binary's name may have a space in it ("Hermes HQ"): the app's own frames were dropped from every Mac record.
        let stack = rows.filter { $0.range(of: #"^\d+\s+\S.*?\s+0x[0-9a-f]{8,}\b"#, options: .regularExpression) != nil }
        for (i, row) in stack.prefix(80).enumerated() {
            let compact = row.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            lines += [event("crash.frame", at: date, [("rec", rec), ("i", i), ("f", String(compact.prefix(maxString)))])].compactMap { $0 }
        }
        return lines
    }

    static func metricKitEvents(_ data: Data, rec: String, date: Date) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var lines: [String] = []
        for crash in (root["crashDiagnostics"] as? [[String: Any]]) ?? [] {
            let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
            let reason = meta["objectiveCexceptionReason"] as? [String: Any] ?? [:]
            var fields: [(String, Any)] = [("rec", rec)]
            for (key, name) in [("appVersion", "ver"), ("appBuildVersion", "bld"), ("exceptionType", "exc"), ("exceptionCode", "code"),
                                ("signal", "sig"), ("osVersion", "os")] {
                if let v = meta[key] { fields.append((name, "\(v)")) }
            }
            if let v = reason["className"] { fields.append(("cls", "\(v)")) }
            if let v = reason["exceptionName"] { fields.append(("nm", "\(v)")) }
            if let v = meta["terminationReason"] { fields.append(("term", "\(v)")) }
            if let v = reason["composedMessage"] { fields.append(("why", "\(v)")) }
            lines += [event("crash.mk", at: date, fields)].compactMap { $0 }
            // The crashed thread's frames, outermost call last.
            let tree = crash["callStackTree"] as? [String: Any] ?? [:]
            let stacks = tree["callStacks"] as? [[String: Any]] ?? []
            let crashed = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
            var frames: [[String: Any]] = []
            func walk(_ list: [[String: Any]]) {
                for frame in list {
                    frames.append(frame)
                    walk(frame["subFrames"] as? [[String: Any]] ?? [])
                }
            }
            walk(crashed?["callStackRootFrames"] as? [[String: Any]] ?? [])
            for (i, frame) in frames.prefix(80).enumerated() {
                lines += [event("crash.mk.frame", at: date, [("rec", rec), ("i", i), ("b", "\(frame["binaryName"] ?? "?")"),
                                                            ("o", (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? -1),
                                                            ("u", String("\(frame["binaryUUID"] ?? "")".prefix(8)))])].compactMap { $0 }
            }
        }
        for (n, hang) in ((root["hangDiagnostics"] as? [[String: Any]]) ?? []).enumerated() {
            let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
            // [diagnostics] build 292: several hangs in one payload each keep their own record.
            let hangRec = n == 0 ? rec : "\(rec)-\(n)"
            lines += [event("hang.mk", at: date, [("rec", hangRec), ("dur", "\(meta["hangDuration"] ?? "?")"),
                                                  ("ver", "\(meta["appVersion"] ?? "?")"),
                                                  ("bld", "\(meta["appBuildVersion"] ?? "?")")])].compactMap { $0 }
            // The main thread's stack (the one the hang is attributed to), innermost first: what it was stuck in.
            for frame in hangFrames(hang) {
                lines += [event("hang.mk.frame", at: date, [("rec", hangRec), ("i", frame.i), ("b", frame.binary), ("o", frame.offset),
                                                           ("u", frame.uuid), ("s", frame.symbol ?? "")])].compactMap { $0 }
            }
        }
        return lines
    }

    struct HangFrame: Equatable { var i: Int; var binary: String; var offset: Int64; var uuid: String; var symbol: String? }
    static let hangFrameLimit = 24

    /// A MetricKit hang's attributed thread, innermost frame first (a root frame is the innermost; its `subFrames` are
    /// its callers), at most `hangFrameLimit`. Symbols only for system binaries loaded in this process now (same UUID).
    static func hangFrames(_ hang: [String: Any], symbolize: (String, Int64) -> String? = LoadedImages.symbol) -> [HangFrame] {
        let tree = hang["callStackTree"] as? [String: Any] ?? [:]
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        guard let main = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first else { return [] }
        var out: [HangFrame] = []
        // Among siblings (a sampled stack), the one most samples went through.
        func heaviest(_ list: Any?) -> [String: Any]? {
            (list as? [[String: Any]])?.max { ($0["sampleCount"] as? Int ?? 0) < ($1["sampleCount"] as? Int ?? 0) }
        }
        var frame = heaviest(main["callStackRootFrames"])
        while let f = frame, out.count < hangFrameLimit {
            let uuid = "\(f["binaryUUID"] ?? "")"
            let offset = (f["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? -1
            let binary = "\(f["binaryName"] ?? "?")"
            let symbol = LoadedImages.isApp(binary) || offset < 0 ? nil : symbolize(uuid, offset)   // Mac polish #49
            out.append(HangFrame(i: out.count, binary: binary, offset: offset, uuid: String(uuid.prefix(8)),
                                 symbol: symbol.map { String($0.prefix(maxString)) }))
            frame = heaviest(f["subFrames"])
        }
        return out
    }

    // MARK: Sending

    /// `account`: the gateway account it sends to; lines logged from now on wait for that account's sends.
    func setSender(_ sender: (@Sendable (Data) async throws -> Void)?, account: String? = nil) {
        lock.lock()
        self.sender = sender
        if let account { use(owner: Self.ownerKey(account)) }
        lock.unlock()
        if sender != nil { kick("signed-in") }
    }

    /// Under `lock`.
    private func use(owner next: String) {
        guard next != owner else { return }
        let fm = FileManager.default
        if owner.isEmpty {
            // Lines from before outboxes were per account go with the first account named.
            for (from, to) in [(outbox(""), outbox(next)), (sending(""), sending(next))]
            where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        owner = next
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? next.write(to: ownerFile, atomically: true, encoding: .utf8)
        // The other gateway's back-off and failed tries are not this one's.
        failures = 0
        batchFailures = 0
        notBefore = .distantPast
    }

    /// Remove Gateway: what waited for that account goes (it is never sent anywhere else).
    func forget(account: String) {
        let key = Self.ownerKey(account)
        queue.async { [self] in
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.removeItem(at: outbox(key))
            if !(inFlight && key == owner) { try? FileManager.default.removeItem(at: sending(key)) }
        }
    }

    /// Waits for work already queued (tests).
    func settle() { queue.sync {} }

    /// Tests: the next kick does not wait out a back-off.
    func clearBackOff() {
        lock.lock(); notBefore = .distantPast; lock.unlock()
    }

    /// No upload before `date` unless forced: what waits stays in the outbox (and the periodic kick stays quiet).
    func hold(until date: Date) {
        lock.lock(); quietUntil = date; lock.unlock()
    }

    /// Sends what is waiting (when there is a gateway, nothing is in flight and no back-off holds it). `force` ignores
    /// a `hold` (leaving the app, a mark, crash records). `done` runs once, when this kick's upload has ended or when
    /// there was nothing to send.
    func kick(_ reason: String, force: Bool = false, done: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            lock.lock()
            guard force || Date() >= quietUntil else { lock.unlock(); done?(); return }
            lastKick = Date()
            guard Self.isEnabled, let sender, !inFlight, Date() >= notBefore else { lock.unlock(); done?(); return }
            if !FileManager.default.fileExists(atPath: sending.path) {
                guard FileManager.default.fileExists(atPath: outbox.path) else { lock.unlock(); done?(); return }
                try? FileManager.default.moveItem(at: outbox, to: sending)
            }
            let lost = lostLines
            lostLines = false
            inFlight = true
            let batch = sending
            lock.unlock()
            let lines = ((try? String(contentsOf: batch, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            let device = Self.device, app = Self.appLabel
            Task.detached(priority: .utility) { [self] in
                var status = 0
                var start = 0
                do {
                    repeat {
                        var end = start, bytes = 0
                        while end < lines.count, end - start < Self.batchLines,
                              end == start || bytes + lines[end].utf8.count <= Self.batchBytes {
                            bytes += lines[end].utf8.count
                            end += 1
                        }
                        let chunk = Array(lines[start..<end])
                        let body = try JSONSerialization.data(withJSONObject: ["device": device, "lines": chunk, "app": app,
                                                                               "reason": reason, "lost": lost && start == 0])
                        try await sender(body)
                        start = end
                    } while start < lines.count
                } catch let error as HTTPError {
                    status = error.status
                } catch {
                    status = -1
                }
                finish(status: status, batch: batch, rest: status == 0 || start == 0 ? nil : Array(lines[start...]))
                done?()
            }
        }
    }

    /// `batch`: the file that was sent (its owner may have changed since). `rest`: the lines a send that failed partway
    /// had not sent yet.
    private func finish(status: Int, batch: URL, rest: [String]?) {
        queue.async { [self] in
            lock.lock(); defer { lock.unlock() }
            inFlight = false
            lastUploadAt = Date()
            lastStatus = status
            if let rest, Self.isEnabled, ![400, 413, 422].contains(status) {
                // [13-10] Part of it arrived: only what didn't goes again (it was all sent again, twice in the log).
                try? Data(rest.map { $0 + "\n" }.joined().utf8).write(to: batch, options: .atomic)
            }
            guard batch == sending else {
                // Signed in elsewhere meanwhile: that account's batch waits for its own sign-in, and this gateway's
                // back-off is not touched.
                if status == 0 { try? FileManager.default.removeItem(at: batch) }
                return
            }
            if status == 0 {
                try? FileManager.default.removeItem(at: sending)
                failures = 0
                batchFailures = 0
                notBefore = .distantPast
            } else if [400, 413, 422].contains(status) {
                // Refused for good: sending it again can only fail again, and the outbox would fill up behind it.
                try? FileManager.default.removeItem(at: sending)
                failures = 0
                batchFailures = 0
                lostLines = true
            } else {
                failures += 1
                batchFailures = rest == nil ? batchFailures + 1 : 1   // what is left after some went is a new batch
                notBefore = Date().addingTimeInterval(status == 404 ? 6 * 3600 : min(1800, 30 * pow(2, Double(failures - 1))))
                if batchFailures >= Self.maxBatchFailures {
                    try? FileManager.default.removeItem(at: sending)   // the back-off stays; the next batch is a new one
                    batchFailures = 0
                    lostLines = true
                }
            }
        }
    }
}
