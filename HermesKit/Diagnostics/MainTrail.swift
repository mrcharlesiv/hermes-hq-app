// [diagnostics] What the main thread was doing when it stalled (build 292; docs/spec/3x-diagnostics.md §8.4). A 1.7 s
// `main.hang` on the owner's phone named only the screen. Named spans of main-thread work (a chat's rebuild and
// apply, a transcript merge, a full reload, a browser frame…) are kept here, the last few dozen plus the ones still
// open, and HangWatch writes the ones that overlapped the stall with its record, together with a few facts the app
// keeps current (the open chat's row count, a catch-up running). Each span is also an os_signpost interval (category
// "Main") for Instruments. Names are fixed words and facts are numbers or fixed words: no chat text ever.

import Foundation
import MachO
import os
import Synchronization

nonisolated enum MainTrail {
    struct Span: Equatable, Sendable {
        var name: String
        var begun: TimeInterval
        var ended: TimeInterval?
    }

    struct Token {
        fileprivate let id: Int
        fileprivate let name: StaticString
        fileprivate let signpost: OSSignpostIntervalState
    }

    private struct State {
        var open: [Int: Span] = [:]
        var done: [Span] = []
        var next = 0
        var facts: [String: (value: String, at: TimeInterval, aged: Bool)] = [:]
    }

    static let keep = 64
    private static let state = Mutex(State())
    private static let poster = OSSignposter(subsystem: Signposts.subsystem, category: "Main")

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func begin(_ name: StaticString, at time: TimeInterval = now()) -> Token {
        let signpost = poster.beginInterval(name, id: poster.makeSignpostID())
        let id = state.withLock { s in
            s.next &+= 1
            s.open[s.next] = Span(name: "\(name)", begun: time)
            return s.next
        }
        return Token(id: id, name: name, signpost: signpost)
    }

    static func end(_ token: Token, at time: TimeInterval = now()) {
        poster.endInterval(token.name, token.signpost)
        state.withLock { s in
            guard var span = s.open.removeValue(forKey: token.id) else { return }
            span.ended = time
            s.done.append(span)
            if s.done.count > keep { s.done.removeFirst(s.done.count - keep) }
        }
    }

    /// Runs `body` as one span.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        defer { end(token) }
        return try body()
    }

    /// A fact about what the app is doing ("rows" = "212", "catchUp" = "running"); nil removes it. An `aged` fact says
    /// how long ago it was set ("catchUp done 8s ago").
    static func set(_ key: String, _ value: String?, aged: Bool = true) {
        let at = now()
        state.withLock { $0.facts[key] = value.map { ($0, at, aged) } }
    }

    /// The spans that overlapped `from…to` (uptime seconds), the longest overlap first: "chat.apply 1650ms",
    /// "chat.flush×3 40ms", "browser.frame 1700ms open". Spans of one name are summed.
    static func during(from: TimeInterval, to: TimeInterval) -> String {
        let spans = state.withLock { s in s.done + s.open.values.sorted { $0.begun < $1.begun } }
        return summary(spans, from: from, to: to)
    }

    static func facts(at time: TimeInterval = now()) -> String {
        state.withLock { s in
            s.facts.sorted { $0.key < $1.key }.map { key, fact in
                let age = Int(time - fact.at)
                return "\(key) \(fact.value)" + (fact.aged && age >= 1 ? " \(age)s ago" : "")
            }.joined(separator: ", ")
        }
    }

    /// The pure part of `during` (tests).
    static func summary(_ spans: [Span], from: TimeInterval, to: TimeInterval) -> String {
        var byName: [String: (ms: Double, count: Int, open: Bool)] = [:]
        var order: [String] = []
        for span in spans {
            let end = span.ended ?? to
            let overlap = min(end, to) - max(span.begun, from)
            guard overlap > 0 || (span.ended == nil && span.begun <= to) else { continue }
            if byName[span.name] == nil { order.append(span.name) }
            var entry = byName[span.name] ?? (0, 0, false)
            entry.ms += max(0, overlap) * 1000
            entry.count += 1
            entry.open = entry.open || span.ended == nil
            byName[span.name] = entry
        }
        let ranked = order.sorted { (byName[$0]?.ms ?? 0) > (byName[$1]?.ms ?? 0) }
        return ranked.prefix(6).map { name in
            let e = byName[name]!
            return "\(name)\(e.count > 1 ? "×\(e.count)" : "") \(Int(e.ms.rounded()))ms\(e.open ? " open" : "")"
        }.joined(separator: ", ")
    }

    /// Tests start clean.
    static func reset() {
        state.withLock { $0 = State() }
    }
}

/// [diagnostics] Names for the frames of a MetricKit report: a binary loaded in this process with the report's UUID (a
/// system library on the same iOS) is looked up with `dladdr`. The app's own binary is left to atos and the build's
/// dSYM (`scripts/hqn-logs.py`): its symbols are stripped, so `dladdr` would name the wrong function.
nonisolated enum LoadedImages {
    static let appBinary = (Bundle.main.executableURL?.lastPathComponent) ?? ""

    /// The app's own code: its executable, or in a Debug build the `<app>.debug.dylib` beside it that Xcode puts the code
    /// in (Mac polish #49: taken for a system library, its frames were named by `dladdr`, the nearest exported symbol).
    static func isApp(_ binary: String) -> Bool { binary == appBinary || binary == appBinary + ".debug.dylib" }

    /// Load address of each image by UUID.
    private static let headers: [String: UInt] = {
        var map: [String: UInt] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let uuid = uuid(of: header) else { continue }
            map[uuid] = UInt(bitPattern: header)
        }
        return map
    }()

    static func symbol(uuid: String, offset: Int64) -> String? {
        guard offset >= 0, let header = headers[uuid.uppercased()] else { return nil }
        var info = Dl_info()
        guard let address = UnsafeRawPointer(bitPattern: header + UInt(offset)),
              dladdr(address, &info) != 0, let name = info.dli_sname else { return nil }
        return String(cString: name)
    }

    private static func uuid(of header: UnsafePointer<mach_header>) -> String? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == LC_UUID {
                let bytes = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                return UUID(uuid: bytes).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }
}
