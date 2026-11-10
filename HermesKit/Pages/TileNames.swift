// [tiles] A tile's name in plain words, and the job that keeps it up to date (owner 2026-11-03: "it's showing as like
// a .html … forced to have a pretty name that was formatted properly as just plain text"; "an easy way to control how
// frequently the tile is updated").
//
// The name is, in order: the one the owner gave it (Rename…), the page's own `<title>`, else its file name in words
// ("revenue-week.html" → "Revenue Week"). The file name still shows under the name when the tile opens.
//
// A tile is kept fresh by a scheduled job that rewrites its file (the add-on's dashboard-tile skill). That job is the
// one the page names (`<meta name="hq-tile-job" content="<job id>">`), else the bot's job whose prompt or script names
// the file.

import Foundation

nonisolated enum TileNames {
    /// The longest name kept from a page's title (a tile's name is a line under a small tile).
    static let longest = 40

    /// Small words that stay lower case inside a name ("Calls of the Week").
    private static let small: Set<String> = ["a", "an", "and", "as", "at", "by", "for", "in", "of", "on", "or", "the", "to", "vs", "with"]

    /// A file name as words: no extension, dashes, underscores and dots as spaces, camelCase split, each word capitalised
    /// (a word with capitals or digits of its own, "Otto" or "Q3", kept as it is).
    static func pretty(_ fileName: String) -> String {
        var base = fileName
        if let slash = base.lastIndex(where: { $0 == "/" || $0 == "\\" }) { base = String(base[base.index(after: slash)...]) }
        let ext = (base as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5 { base = (base as NSString).deletingPathExtension }
        var spaced = ""
        var previous: Character?
        for ch in base {
            if ch == "-" || ch == "_" || ch == "." || ch == "+" {
                spaced.append(" ")
            } else {
                // "revenueWeek" → "revenue Week"
                if let previous, previous.isLowercase, ch.isUppercase { spaced.append(" ") }
                spaced.append(ch)
            }
            previous = ch
        }
        let words = spaced.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return fileName }
        return words.enumerated().map { index, word in
            if word.contains(where: { $0.isUppercase || $0.isNumber }) { return word }
            if index > 0, small.contains(word) { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Mac polish #45: a file name in words with its extension kept ("index.md" → "Index.md"), for a name another tile's
    /// also reads as (`clashing`).
    static func pretty(_ fileName: String, keepsExtension: Bool) -> String {
        let words = pretty(fileName)
        let file = fileName.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? fileName
        let ext = (file as NSString).pathExtension
        guard keepsExtension, !ext.isEmpty, ext.count <= 5, words != fileName else { return words }
        return words + "." + ext.lowercased()
    }

    /// Mac polish #45: the tiles named only by their files (`byFile`) whose name another tile's reads as too, case aside
    /// (index.md and index.html both "Index"): those keep their extensions, so they can be told apart.
    static func clashing(_ names: [(id: String, name: String, byFile: Bool)]) -> Set<String> {
        var count: [String: Int] = [:]
        for entry in names { count[entry.name.lowercased(), default: 0] += 1 }
        return Set(names.filter { $0.byFile && count[$0.name.lowercased(), default: 0] > 1 }.map(\.id))
    }

    /// A page's `<title>` as a name: one line, no file extension, at most `longest` characters; nil when it has no
    /// words or is only a file name.
    static func cleanTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        var text = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for ext in [".html", ".htm"] where text.lowercased().hasSuffix(ext) {
            text = String(text.dropLast(ext.count)).trimmingCharacters(in: .whitespaces)
            // "revenue-week.html" as a title says no more than the file: tidy it as one.
            if !text.contains(" ") { text = pretty(text) }
        }
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if text.count > longest {
            let cut = text.prefix(longest)
            let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
            text = atWord.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:·|,")) + "…"
        }
        return text
    }

    /// What a page's head says about it: its title and the job that keeps it up to date.
    struct Head: Equatable, Sendable {
        var title: String?
        var jobId: String?
        /// [live-tiles] The page has buttons for its bot (`data-hermes-send`, `hermes.send(`) or asks to be read again on
        /// its own (`hq-tile-refresh`), or says so (`<meta name="hq-tile" content="live">`): its tile runs live.
        var live = false
        /// [live-tiles] `<meta name="hq-tile-refresh" content="300">`: read the file again this often while it shows.
        var refreshSeconds: Int?
    }

    /// [live-tiles] The shortest refresh a page may ask for (a file read over the gateway each time).
    static let shortestRefresh = 30

    /// Reads the `<title>` and `<meta name="hq-tile-job">` from a page's text (only its start is needed).
    static func head(_ html: String) -> Head {
        let text = String(html.prefix(64_000))
        var head = Head()
        if let match = text.range(of: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(text[match])
            if let open = tag.firstIndex(of: ">"), let close = tag.range(of: "</", options: .backwards) {
                head.title = cleanTitle(entities(String(tag[tag.index(after: open)..<close.lowerBound])))
            }
        }
        if let match = text.range(of: #"<meta[^>]*hq-tile-job[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            let tag = String(text[match])
            if let content = tag.range(of: #"content\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                let value = tag[content].split(whereSeparator: { $0 == "\"" || $0 == "'" }).dropFirst().first.map(String.init)
                let id = value?.trimmingCharacters(in: .whitespaces) ?? ""
                head.jobId = id.isEmpty ? nil : id
            }
        }
        if let match = text.range(of: #"<meta[^>]*hq-tile-refresh[^>]*>"#, options: [.regularExpression, .caseInsensitive]),
           let content = text[match].range(of: #"content\s*=\s*["']\s*\d+"#, options: .regularExpression),
           let seconds = Int(text[content].filter(\.isNumber)), seconds > 0 {
            head.refreshSeconds = max(shortestRefresh, seconds)
        }
        let liveMeta = text.range(of: #"<meta[^>]*name\s*=\s*["']hq-tile["'][^>]*content\s*=\s*["']live["']"#,
                                  options: [.regularExpression, .caseInsensitive]) != nil
        head.live = liveMeta || head.refreshSeconds != nil || text.contains("data-hermes-send") || text.contains("hermes.send(")
        return head
    }

    private static func entities(_ text: String) -> String {
        var out = text
        for (from, to) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                           ("&nbsp;", " "), ("&middot;", "·"), ("&mdash;", "—"), ("&ndash;", "–")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out
    }
}

/// [tiles] The job that keeps a tile up to date, and how often it runs.
nonisolated enum TileJobs {
    /// How often, as the tile's menu offers it.
    struct Frequency: Equatable, Sendable {
        var title: String
        /// Short, after "Updated 5 min ago · ".
        var short: String
        var cron: String
        var minutes: Int
    }

    static let frequencies: [Frequency] = [
        Frequency(title: "Every 15 Minutes", short: "every 15 min", cron: "*/15 * * * *", minutes: 15),
        Frequency(title: "Every 30 Minutes", short: "every 30 min", cron: "*/30 * * * *", minutes: 30),
        Frequency(title: "Every Hour", short: "hourly", cron: "0 * * * *", minutes: 60),
        Frequency(title: "Every 3 Hours", short: "every 3 hours", cron: "0 */3 * * *", minutes: 180),
        Frequency(title: "Every 6 Hours", short: "every 6 hours", cron: "0 */6 * * *", minutes: 360),
        Frequency(title: "Once a Day", short: "daily", cron: "0 8 * * *", minutes: 1440),
    ]

    /// The job keeping `path` (of bot `profile`) up to date: the one the page names, else the best of the bot's jobs
    /// naming the file (its whole path first, then its refresh script, then its file name alone).
    static func match(path: String, profile: String, jobId: String?, jobs: [CronJob]) -> CronJob? {
        let own = jobs.filter { $0.owner == profile }
        if let jobId, let named = own.first(where: { $0.id == jobId }) ?? jobs.first(where: { $0.id == jobId }) { return named }
        let file = (path as NSString).lastPathComponent
        guard !file.isEmpty else { return nil }
        let stem = (file as NSString).deletingPathExtension
        var paths = [path]
        // The same file as "~/…" or as a home-based path.
        if path.hasPrefix("~/") {
            paths.append(String(path.dropFirst(1)))
        } else if let home = path.range(of: #"^/(home|Users)/[^/]+/"#, options: .regularExpression) {
            paths.append("~/" + path[home.upperBound...])
        }
        var best: (job: CronJob, score: Int)?
        for job in own {
            let text = [job.prompt, job.script, job.name].compactMap { $0 }.joined(separator: "\n")
            var score = 0
            if paths.contains(where: { text.contains($0) }) { score = 3 }
            else if text.contains(stem + ".refresh") || text.contains(stem + "_refresh") { score = 2 }
            else if text.contains(file) { score = 1 }
            guard score > 0 else { continue }
            // A paused job loses a tie to one that runs.
            let rank = score * 2 + (isPaused(job) ? 0 : 1)
            if rank > (best?.score ?? 0) { best = (job, rank) }
        }
        return best?.job
    }

    static func isPaused(_ job: CronJob) -> Bool {
        job.enabled == false || job.state?.lowercased() == "paused"
    }

    /// The menu's choice the job runs at, nil when it runs at another time ("weekdays at 9").
    static func frequency(of job: CronJob) -> Frequency? {
        if let expr = job.schedule?.expr?.trimmingCharacters(in: .whitespaces), let hit = frequencies.first(where: { $0.cron == expr }) {
            return hit
        }
        if let minutes = job.schedule?.minutes, let hit = frequencies.first(where: { Double($0.minutes) == minutes }) { return hit }
        // "every 15m", "every 1h", as Hermes writes an interval.
        let display = (job.scheduleDisplay ?? job.schedule?.display ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let words: [String: Int] = ["every15m": 15, "every30m": 30, "every60m": 60, "every1h": 60, "every180m": 180, "every3h": 180,
                                    "every360m": 360, "every6h": 360, "every1440m": 1440, "every24h": 1440, "every1d": 1440]
        if let minutes = words[display] { return frequencies.first { $0.minutes == minutes } }
        return nil
    }

    /// How often, in a few lower-case words ("every 15 min", "weekdays at 9:00 AM").
    static func howOften(_ job: CronJob) -> String {
        if let hit = frequency(of: job) { return hit.short }
        let shown = (job.scheduleDisplay ?? job.schedule?.display ?? job.schedule?.expr ?? "").trimmingCharacters(in: .whitespaces)
        guard !shown.isEmpty else { return "on a schedule" }
        return shown.prefix(1).lowercased() + shown.dropFirst()
    }

    /// The tile's update line: "Updated 5 min ago · every 15 min", "Updates paused", "Not updated yet · hourly".
    static func status(_ job: CronJob, now: Date = Date()) -> String {
        if isPaused(job) { return "Updates paused" }
        let often = howOften(job)
        guard let last = PagesDate.parse(job.lastRunAt) else { return "Not updated yet · " + often }
        let failed = ["error", "failed"].contains(job.lastStatus?.lowercased() ?? "")
        return (failed ? "Update failed " : "Updated ") + ago(last, now: now) + " · " + often
    }

    /// The opened tile's line under its name, after the file name: "updated 5 min ago", "updates paused".
    static func shortStatus(_ job: CronJob, now: Date = Date()) -> String {
        if isPaused(job) { return "updates paused" }
        guard let last = PagesDate.parse(job.lastRunAt) else { return "not updated yet" }
        return "updated " + ago(last, now: now)
    }

    /// [tiles] How a tile's updates are going (owner 2026-11-03: "a tile that shows when it's stale or broken"):
    /// the tile wears a small mark for all but `fine` and `none`.
    enum Health: Equatable, Sendable {
        /// No job keeps it up to date.
        case none
        case fine
        /// Its job is running now (the picture is drawn again when it ends).
        case updating
        /// The last run failed (Hermes's words for why, when it gave them).
        case failed(String?)
        /// Its job should have run by now and hasn't (the computer was off, or the job is stuck).
        case late
        case paused
    }

    static func health(_ job: CronJob?, now: Date = Date()) -> Health {
        guard let job else { return .none }
        if isPaused(job) { return .paused }
        if JobWords.workIsOut(job) { return .updating }
        if ["error", "failed"].contains(job.lastStatus?.lowercased() ?? "") {
            let why = job.lastError?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            return .failed(why?.isEmpty == false ? why : nil)
        }
        // A run due over 15 minutes ago (or, for a long interval, half of it) that hasn't happened.
        let every = TimeInterval((frequency(of: job)?.minutes ?? 60) * 60)
        let grace = max(15 * 60, every / 2)
        if let next = PagesDate.parse(job.nextRunAt), now.timeIntervalSince(next) > grace { return .late }
        if let frequency = frequency(of: job), let last = PagesDate.parse(job.lastRunAt),
           now.timeIntervalSince(last) > TimeInterval(frequency.minutes * 60) * 2 + grace { return .late }
        return .fine
    }

    /// Who updates the tile, in words: "Sonnet 5", "Sonnet 5 (Otto's model)", "A script, no model".
    /// `botModel`: the bot's own model's name, for a job that names none.
    static func modelWords(_ job: CronJob, botName: String, botModel: String?) -> String {
        if job.noAgent || ((job.prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !(job.script ?? "").isEmpty) {
            return "A script, no model"
        }
        if let model = job.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { return ModelNames.displayModelName(model) }
        if let botModel, !botModel.isEmpty { return "\(botModel) (\(botName)’s model)" }
        return "\(botName)’s own model"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { let h = Int(seconds / 3600); return h == 1 ? "1 hour ago" : "\(h) hours ago" }
        let d = Int(seconds / 86_400)
        return d == 1 ? "yesterday" : "\(d) days ago"
    }

    static func date(_ text: String) -> Date? { PagesDate.parse(text) }
}
