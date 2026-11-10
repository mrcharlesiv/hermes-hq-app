// [diagnostics] Errors outlive the launch they explain (the web app's `src/diagnostics-errors.ts`): a crash, a
// force-quit or iOS ending the app used to start Diagnostics' list empty, so the errors that led up to it were gone.
// The last 20 of the installed build, with their time and screen (redacted when stored), stay in one small file, each
// tagged with the run it came from; Diagnostics shows the earlier runs' as "Before the last launch".

import Foundation

nonisolated final class KeptErrors: @unchecked Sendable {
    static let shared = KeptErrors()
    static let limit = 20

    struct Entry: Codable, Sendable, Equatable {
        var message: String
        var at: Date
        var route: String?
        var run: String
    }

    private struct Kept: Codable {
        var build: String
        var entries: [Entry]
    }

    let file: URL
    let build: String
    /// Made once per process: what tells this run's errors from an earlier run's.
    let run: String
    private let queue = DispatchQueue(label: "ai.hermes.hqnative.kepterrors", qos: .utility)

    init(file: URL = KeptErrors.defaultFile, build: String = StabilityCounts.build, run: String = UUID().uuidString) {
        self.file = file
        self.build = build
        self.run = run
    }

    static var defaultFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true).appendingPathComponent("errors.json")
    }

    private static func coders() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (encoder, decoder)
    }

    private func read() -> Kept {
        guard let data = try? Data(contentsOf: file), let kept = try? Self.coders().1.decode(Kept.self, from: data), kept.build == build else {
            return Kept(build: build, entries: [])
        }
        return Kept(build: build, entries: Array(kept.entries.suffix(Self.limit)))
    }

    /// One more error from this run; a disk that refuses only loses the copy.
    func keep(message: String, at date: Date = Date(), route: String? = nil) {
        queue.async { [self] in keepNow(message: message, at: date, route: route) }
    }

    func keepNow(message: String, at date: Date = Date(), route: String? = nil) {
        var kept = read()
        let screen = route.map { Self.cut(DiagnosticRedactor.redact(String($0.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")), 120) }
        kept.entries.append(Entry(message: Self.cut(DiagnosticRedactor.redact(message), 1000), at: date,
                                  route: screen?.isEmpty == false ? screen : nil, run: run))
        kept.entries = Array(kept.entries.suffix(Self.limit))
        guard let data = try? Self.coders().0.encode(kept) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The errors earlier runs of this build kept, oldest first, each with " · on <screen>" when it had one.
    func earlier() -> [(message: String, at: Date?)] {
        queue.sync {
            read().entries.filter { $0.run != run }.map { entry in
                (entry.route.map { "\(entry.message) · on \($0)" } ?? entry.message, Optional(entry.at))
            }
        }
    }

    /// Waits for writes already asked for (tests).
    func settle() { queue.sync {} }

    private static func cut(_ text: String, _ limit: Int) -> String {
        text.utf16.count > limit ? String(decoding: Array(text.utf16.prefix(limit)), as: UTF16.self) : text
    }
}
