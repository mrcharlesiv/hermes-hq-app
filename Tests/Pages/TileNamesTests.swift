// [tiles] A tile's name in words, and the job that keeps it up to date (owner 2026-11-03).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct TileNamesTests {
    @Test func fileNamesReadAsWords() {
        #expect(TileNames.pretty("revenue-week.html") == "Revenue Week")
        #expect(TileNames.pretty("/home/hermes/dashboards/weather_of_the_week.html") == "Weather of the Week")
        #expect(TileNames.pretty("tasksByStage.html") == "Tasks By Stage")
        #expect(TileNames.pretty("Otto-q3-goals.htm") == "Otto q3 Goals")
        #expect(TileNames.pretty("tile.html") == "Tile")
    }

    @Test func titlesAreTidied() {
        #expect(TileNames.cleanTitle("  Revenue\n  this   week ") == "Revenue this week")
        #expect(TileNames.cleanTitle("revenue-week.html") == "Revenue Week")
        #expect(TileNames.cleanTitle("   ") == nil)
        #expect(TileNames.cleanTitle(nil) == nil)
        let long = TileNames.cleanTitle("Open pull requests by repository and reviewer, oldest first")
        #expect(long == "Open pull requests by repository and…")
        #expect((long?.count ?? 99) <= TileNames.longest + 1)
    }

    @Test func headGivesTitleAndJob() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <title>Sales &amp; Calls</title>
        <meta content="job_42" name="hq-tile-job">
        </head><body>…</body></html>
        """
        #expect(TileNames.head(html) == TileNames.Head(title: "Sales & Calls", jobId: "job_42"))
        #expect(TileNames.head("<html><body>no head</body></html>") == TileNames.Head())
    }

    @Test func pinNameOrder() {
        var pin = ArtifactPin(kind: .file, value: "/home/h/dashboards/revenue-week.html", label: "", profile: "otto",
                              sessionId: "s", sessionTitle: "t")
        #expect(pin.name == "Revenue Week")
        pin.pageTitle = "Revenue This Week"
        #expect(pin.name == "Revenue This Week")
        pin.title = "Money"
        #expect(pin.name == "Money")
    }

    @Test func renameAndHeadAreKept() {
        let pins = ArtifactPins(fileURL: nil)
        let pin = ArtifactPin(kind: .file, value: "/d/a.html", label: "", profile: nil, sessionId: "s", sessionTitle: "t")
        pins.pin(pin)
        pins.notePage(id: pin.id, head: TileNames.Head(title: "Alpha", jobId: "j1"))
        #expect(pins.pins.first?.name == "Alpha")
        #expect(pins.pins.first?.jobId == "j1")
        pins.rename(id: pin.id, to: "  My   Tile ")
        #expect(pins.pins.first?.name == "My Tile")
        pins.rename(id: pin.id, to: "")
        #expect(pins.pins.first?.name == "Alpha")
    }

    private func job(_ id: String, prompt: String? = nil, script: String? = nil, profile: String = "otto", expr: String? = nil,
                     enabled: Bool = true) -> CronJob {
        var job = CronJob(id: id)
        job.prompt = prompt
        job.script = script
        job.profile = profile
        job.enabled = enabled
        if let expr { job.schedule = CronSchedule(kind: "cron", expr: expr) }
        return job
    }

    @Test func theJobThatWritesTheFile() {
        let path = "/home/hermes/dashboards/revenue.html"
        let jobs = [
            job("other", prompt: "Summarise the inbox"),
            job("byName", prompt: "Make revenue.html look nicer"),
            job("byPath", prompt: "Update the Dashboard tile ~/dashboards/revenue.html with the dashboard-tile skill"),
            job("otherBot", prompt: "Update /home/hermes/dashboards/revenue.html", profile: "finance"),
        ]
        #expect(TileJobs.match(path: path, profile: "otto", jobId: nil, jobs: jobs)?.id == "byPath")
        #expect(TileJobs.match(path: path, profile: "otto", jobId: "other", jobs: jobs)?.id == "other")
        let scripts = [job("script", script: "~/dashboards/revenue.refresh.py")]
        #expect(TileJobs.match(path: path, profile: "otto", jobId: nil, jobs: scripts)?.id == "script")
        #expect(TileJobs.match(path: path, profile: "ops", jobId: nil, jobs: jobs) == nil)
        // A running job wins a tie with a paused one.
        let tie = [job("paused", prompt: path, enabled: false), job("runs", prompt: path)]
        #expect(TileJobs.match(path: path, profile: "otto", jobId: nil, jobs: tie)?.id == "runs")
    }

    @Test func howOftenAndStatus() {
        #expect(TileJobs.frequency(of: job("a", expr: "0 * * * *"))?.title == "Every Hour")
        #expect(TileJobs.frequency(of: job("a", expr: "0 9 * * 1-5")) == nil)
        var interval = job("b")
        interval.scheduleDisplay = "every 15m"
        #expect(TileJobs.howOften(interval) == "every 15 min")
        var ran = job("c", expr: "*/30 * * * *")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ran.lastRunAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-300))
        #expect(TileJobs.status(ran, now: now) == "Updated 5 min ago · every 30 min")
        ran.enabled = false
        #expect(TileJobs.status(ran, now: now) == "Updates paused")
        #expect(TileJobs.status(job("d", expr: "0 8 * * *"), now: now) == "Not updated yet · daily")
    }

    @Test func healthMarks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        #expect(TileJobs.health(nil, now: now) == .none)
        var hourly = job("h", expr: "0 * * * *")
        hourly.lastRunAt = iso.string(from: now.addingTimeInterval(-20 * 60))
        hourly.nextRunAt = iso.string(from: now.addingTimeInterval(40 * 60))
        hourly.lastStatus = "ok"
        #expect(TileJobs.health(hourly, now: now) == .fine)
        var failed = hourly
        failed.lastStatus = "error"
        failed.lastError = "Stripe timed out\nTraceback…"
        #expect(TileJobs.health(failed, now: now) == .failed("Stripe timed out"))
        var late = hourly
        late.nextRunAt = iso.string(from: now.addingTimeInterval(-45 * 60))
        #expect(TileJobs.health(late, now: now) == .late)
        var old = hourly
        old.nextRunAt = nil
        old.lastRunAt = iso.string(from: now.addingTimeInterval(-3 * 3600))
        #expect(TileJobs.health(old, now: now) == .late)
        var paused = failed
        paused.enabled = false
        #expect(TileJobs.health(paused, now: now) == .paused)
        var running = hourly
        running.latestRunStatus = "running"
        running.latestRunClaimedAt = iso.string(from: now.addingTimeInterval(-30))
        #expect(TileJobs.health(running, now: now) == .updating)
    }

    @Test func whoUpdatesIt() {
        var own = job("a", prompt: "Update ~/dashboards/x.html")
        own.model = "claude-sonnet-5"
        #expect(TileJobs.modelWords(own, botName: "Otto", botModel: "Opus 5.5") == ModelNames.displayModelName("claude-sonnet-5"))
        let bots = job("b", prompt: "Update ~/dashboards/x.html")
        #expect(TileJobs.modelWords(bots, botName: "Otto", botModel: "Opus 5.5") == "Opus 5.5 (Otto’s model)")
        #expect(TileJobs.modelWords(bots, botName: "Otto", botModel: nil) == "Otto’s own model")
        let script = job("c", script: "~/dashboards/x.refresh.py")
        #expect(TileJobs.modelWords(script, botName: "Otto", botModel: "Opus 5.5") == "A script, no model")
    }

    // Owner 2026-11-10: a New Tile's bot ended with "Hold the card → Pin as Tile", though the app pins it.
    @Test func aNewTileIsPinnedByTheApp() {
        let prompt = TileMaker.prompt("Revenue this week")
        #expect(prompt.contains("MEDIA:/absolute/path/to/the/tile.html (the app pins it to my Dashboard by itself, so don't tell me how to pin it)"))
        let reply = "**Ready.** Updates every 15 minutes.\n\nHold the card → **Pin as Tile**.\n\nMEDIA:/Users/me/dashboards/today.html"
        #expect(TileMaker.pagePath(in: reply) == "/Users/me/dashboards/today.html")
    }

    @Test func aChangeKeepsTheTile() {
        let prompt = TileMaker.changePrompt(path: "/home/h/dashboards/revenue.html", what: "make it a bar chart")
        #expect(prompt.hasPrefix("Change my Hermes HQ Dashboard tile /home/h/dashboards/revenue.html: make it a bar chart"))
        #expect(prompt.contains("hq-tile-job"))
        #expect(TileMaker.pagePath(in: prompt) == "/home/h/dashboards/revenue.html")
    }

    // [tiles] Change Tile's quick changes (owner 2026-11-10): a tap adds one to the words, a second tap takes it out.
    @Test func quickChangesAddAndComeOut() {
        let bar = "Make it a bar chart", month = "Compare with last month"
        #expect(TileChangeWords.adding(bar, to: "") == bar)
        #expect(TileChangeWords.adding(bar, to: "  ") == bar)
        #expect(TileChangeWords.adding(month, to: bar) == "Make it a bar chart, compare with last month")
        #expect(TileChangeWords.adding(month, to: "Use green.") == "Use green. Compare with last month")
        #expect(TileChangeWords.adding(bar, to: "make it a BAR chart") == "make it a BAR chart", "already there")
        let both = TileChangeWords.toggling(month, in: bar)
        #expect(TileChangeWords.contains(both, month))
        #expect(TileChangeWords.toggling(month, in: both) == bar)
        #expect(TileChangeWords.toggling(bar, in: both) == "Compare with last month")
        #expect(TileChangeWords.removing(bar, from: bar) == "")
        #expect(TileChangeWords.removing(month, from: "Use green, compare with last month, bigger") == "Use green, bigger")
    }

    // [tiles] A change that stopped with a problem says its first line.
    @Test func aProblemIsSaidInALine() {
        #expect(TileMaker.firstLine("Stripe timed out\nTraceback (most recent call last)") == "Stripe timed out.")
        #expect(TileMaker.firstLine("The model is overloaded.") == "The model is overloaded.")
        #expect(TileMaker.firstLine(String(repeating: "x", count: 300)).count == 160)
    }

    @Test func aChangeAsksForItsQuestionsAndSaysWhatChanged() {
        let prompt = TileMaker.changePrompt(path: "/home/h/dashboards/revenue.html", what: "bigger numbers")
        #expect(prompt.contains("leave out the MEDIA line"))
        #expect(prompt.contains("say in a line or two what you changed"))
        #expect(prompt.hasSuffix("MEDIA:/home/h/dashboards/revenue.html"))
    }

    // [live-tiles] A page that asks to run live: a refresh tag, its own buttons, or a plain "live" tag.
    @Test func livePagesAreReadFromTheirHead() {
        let refresh = TileNames.head(#"<head><meta name="hq-tile-refresh" content="120"></head>"#)
        #expect(refresh.live && refresh.refreshSeconds == 120)
        #expect(TileNames.head(#"<meta name="hq-tile-refresh" content="5">"#).refreshSeconds == TileNames.shortestRefresh)
        #expect(TileNames.head(#"<button data-hermes-send="Check the build">Check</button>"#).live)
        #expect(TileNames.head("<script>hermes.send('more')</script>").live)
        #expect(TileNames.head(#"<meta name="hq-tile" content="live">"#).live)
        let still = TileNames.head("<title>Sales</title><p>numbers</p>")
        #expect(!still.live && still.refreshSeconds == nil)
    }
}
