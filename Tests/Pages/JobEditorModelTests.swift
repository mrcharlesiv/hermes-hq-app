// [jobs] The New Job / Edit Job form's model and the store's editor calls (docs/spec/3x-jobs.md §3, §4, §6): what is
// sent on create, that an edit sends only what changed (D-J1), completeness, the reasons a refusal shows, one write
// per save, the list cache's cap (D-J10), a long list's cost (§6.1) and the shared run-history read (§6.4).

import Foundation
import Synchronization
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
struct JobEditorModelTests {
    static let bots: [(id: String, name: String)] = [("default", "Hermes"), ("research", "Research")]

    nonisolated static func job(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var base: [String: JSONValue] = ["id": "j1", "name": "Morning mail", "prompt": "Summarize my unread mail", "profile": "research",
                                         "schedule": ["kind": "cron", "expr": "0 9 * * 1-5", "display": "0 9 * * 1-5"],
                                         "schedule_display": "0 9 * * 1-5", "deliver": "local,telegram", "enabled": true, "state": "scheduled"]
        for (key, value) in extra { base[key] = value }
        return .object(base)
    }

    nonisolated static let targets: JSONValue = ["targets": [["id": "local", "name": "Local"], ["id": "telegram", "name": "Telegram"],
                                                           ["id": "discord", "name": "Discord", "home_target_set": false]]]
    nonisolated static let models: JSONValue = ["providers": [
        ["slug": "anthropic", "name": "Anthropic", "models": ["claude-sonnet-5", "claude-opus-5"], "authenticated": true],
        ["slug": "openai", "name": "OpenAI", "models": ["gpt-5"], "authenticated": false],
        ["slug": "xai", "name": "xAI", "models": [], "authenticated": true],
        ["slug": "nous", "name": "Nous Portal", "models": ["hermes-4", "hermes-4", ""]],
        ["slug": "null", "name": "Null", "models": .null],
    ]]

    /// A gateway that answers the editor's reads and echoes writes.
    nonisolated static func gateway(job: JSONValue = JobEditorModelTests.job(), write: (@Sendable (PagesFakeClient.Request) async throws -> JSONValue)? = nil)
        -> PagesFakeClient {
        PagesFakeClient { request in
            if request.method != "GET" {
                if let write { return try await write(request) }
                return ["id": "made", "name": "Made", "profile": .string(request.query["profile"] ?? "")]
            }
            switch request.path {
            case "/api/cron/delivery-targets": return targets
            case "/api/model/options": return models
            case "/api/cron/blueprints": return JobBlueprintTests.catalog
            case "/api/cron/jobs": return .array([job])
            default: return job
            }
        }
    }

    func editor(_ json: JSONValue = JobEditorModelTests.job(), client: PagesFakeClient? = nil) -> (JobEditorModel, PagesFakeClient) {
        let client = client ?? Self.gateway(job: json)
        let store = JobsStore(client: client, account: client.account, directory: nil)
        var job = CronJob(json: json)!
        if job.profile == nil { job.profile = "research" }
        return (JobEditorModel(store: store, mode: .edit(job), bots: Self.bots, profile: job.owner), client)
    }

    func creator(client: PagesFakeClient? = nil, profile: String = "default", blueprint: Blueprint? = nil) -> (JobEditorModel, PagesFakeClient) {
        let client = client ?? Self.gateway()
        let store = JobsStore(client: client, account: client.account, directory: nil)
        return (JobEditorModel(store: store, mode: .create, bots: Self.bots, profile: profile, blueprint: blueprint), client)
    }

    // MARK: Create

    @Test func aNewJobStartsDailyLocalDefaultModelAndIncomplete() {
        let (model, _) = creator()
        #expect(model.title == "New Job" && model.actionTitle == "Create")
        #expect(model.form.frequency == .daily && model.form.schedule == "0 9 * * *" && model.form.deliver == "local" && model.form.model == nil)
        #expect(!model.isDirty && !model.isComplete && !model.canSave)
        #expect(model.validate() == "Prompt is required.")
        model.form.prompt = "  \n "
        #expect(model.validate() == "Prompt is required.", "only whitespace is no prompt")
        model.setFrequency(.custom)
        model.setCustomSchedule("  ")
        #expect(model.validate() == "Prompt and schedule are required.")
        model.form.prompt = "Do it"
        #expect(model.validate() == "Schedule is required.")
        model.setCustomSchedule("every 2h")
        #expect(model.isComplete && model.canSave && model.isDirty)
        #expect(model.showsBotRow && model.showsModelRow)
    }

    @Test func createBodyHasNoEmptyNameAndNoModelKeysByDefault() {
        let (model, _) = creator()
        model.form.prompt = "  Summarize my unread mail \n"
        #expect(model.createBody() == ["prompt": "Summarize my unread mail", "schedule": "0 9 * * *", "deliver": "local"])
        model.form.name = "  Morning mail "
        model.toggleDelivery("telegram")
        model.form.model = JobModelChoice(provider: "anthropic", model: "claude-sonnet-5")
        model.setFrequency(.weekly)
        var fields = model.fields
        fields.weekday = 3; fields.hour = 18; fields.minute = 30
        model.setFields(fields)
        #expect(model.createBody() == ["prompt": "Summarize my unread mail", "schedule": "30 18 * * 3", "name": "Morning mail",
                                       "deliver": "telegram", "model": "claude-sonnet-5", "provider": "anthropic"])
    }

    @Test func everyPresetSendsItsExpressionAndASwitchKeepsTheTime() {
        let (model, _) = creator()
        var sent: [String] = []
        for frequency in JobFrequency.allCases where frequency != .custom {
            model.setFrequency(frequency)
            sent.append(model.scheduleToSend)
        }
        #expect(sent == ["0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *", "0 * * * *", "*/15 * * * *"])
        model.setFrequency(.daily)
        model.setFields(JobTimeFields(hour: 7, minute: 15))
        model.setFrequency(.weekly)
        #expect(model.form.schedule == "15 7 * * 1")
        model.setFrequency(.custom)
        #expect(model.form.schedule == "15 7 * * 1", "Custom starts from the current expression")
        model.setCustomSchedule("0 9 * * 1\u{2013}5\n")
        #expect(model.scheduleToSend == "0 9 * * 1-5")
    }

    @Test func createPostsOnceToTheChosenBotAndAnswersTheNewKey() async {
        let (model, client) = creator(profile: "research")
        model.form.prompt = "Read the feeds"
        async let first = model.save()
        async let second = model.save()
        let outcomes = await [first, second]
        #expect(outcomes.contains(.created("research|made")))
        #expect(outcomes.contains(.failed), "a second save while one is on its way does nothing")
        let posts = client.log.filter { $0.method == "POST" }
        #expect(posts.count == 1)
        #expect(posts.first?.description == "POST /api/cron/jobs?profile=research")
        #expect(posts.first?.body == ["prompt": "Read the feeds", "schedule": "0 9 * * *", "deliver": "local"])
        #expect(!model.isDirty && !model.saving)
    }

    @Test func aRefusedCreateKeepsTheFormAndShowsTheFirstLine() async {
        let usage = "Invalid schedule 'banana'. Use:\n  - Interval: '30m', 'every 30m', 'every 2h' (recurring)\n  - Cron: '0 9 * * *'"
        let client = Self.gateway { _ in throw httpError(400, usage) }
        let (model, _) = creator(client: client)
        model.form.prompt = "Do it"
        model.setFrequency(.custom)
        model.setCustomSchedule("banana")
        #expect(await model.save() == .failed)
        #expect(model.failure == "Invalid schedule 'banana'. Use:")
        #expect(model.scheduleRejected && model.failureTick == 1)
        #expect(model.form.prompt == "Do it" && model.form.schedule == "banana" && model.canSave)
        model.setCustomSchedule("banana")
        #expect(model.scheduleRejected, "the same text again (a tap into the field) keeps the red note")
        model.setCustomSchedule("every 2h")
        #expect(!model.scheduleRejected)
    }

    @Test func refusalsArePlainWords() {
        #expect(JobsStore.editReason(httpError(400, "")) == "The gateway did not say why.")
        #expect(JobsStore.editReason(HTTPError(status: 500, body: "<html><body>Bad Gateway</body></html>")) == "The gateway did not say why.")
        #expect(JobsStore.editReason(HTTPError(status: 503, body: "")) == "The gateway did not say why.")
        #expect(JobsStore.editReason(HTTPError(status: 502, body: "")) == JobsStore.slowAnswer, "an edge timeout: the write may have landed")
        #expect(JobsStore.editReason(HTTPError(status: 422, body: #"{"detail":[{"type":"missing","loc":["body","schedule"]}]}"#)) == "The gateway did not say why.")
        #expect(JobsStore.editReason(HTTPError(status: 400, body: #"{"detail":{"code":7}}"#)) == "The gateway did not say why.")
        let long = JobsStore.editReason(httpError(400, String(repeating: "word ", count: 80)))
        #expect(long.count <= 200 && long.hasSuffix("…"))
        #expect(JobsStore.editReason(GatewayFailure.timeout) == JobsStore.slowAnswer)
        #expect(!JobsStore.editReason(URLError(.networkConnectionLost)).isEmpty)
        #expect(!JobsStore.editReason(URLError(.networkConnectionLost)).contains("NSURL"))
    }

    @Test func aReadOnlyGatewaySendsNothing() async {
        let (model, client) = creator()
        model.store.readOnlyGateway = true
        model.form.prompt = "Do it"
        #expect(await model.save() == .failed)
        #expect(model.failure == JobsStore.readOnlyNotice)
        #expect(client.log.allSatisfy { $0.method == "GET" })
    }

    @Test func theBotRowReReadsWhatThatBotOffers() async throws {
        let (model, client) = creator()
        await model.load()
        #expect(model.targetsState == .loaded && model.modelsState == .loaded)
        #expect(model.providers.map(\.slug) == ["anthropic", "nous"], "signed in, with models")
        #expect(model.providers[1].models == ["hermes-4"])
        model.chooseProfile("research")
        #expect(!model.isDirty, "choosing the bot of an untouched form is not a change to discard")
        try await Task.sleep(for: .milliseconds(150))
        let reads = client.logLines.filter { $0.contains("delivery-targets") }
        #expect(reads == ["GET /api/cron/delivery-targets?profile=default", "GET /api/cron/delivery-targets?profile=research"])
        #expect(client.logLines.contains("GET /api/model/options?explicit_only=1&profile=research"))
        #expect(client.logLines.contains("GET /api/cron/blueprints?profile=research"))
    }

    @Test func eachEditorReadMayFailAloneAndTheFormStillSaves() async {
        let client = PagesFakeClient { request in
            if request.method == "GET" && request.path != "/api/cron/jobs" { throw GatewayFailure.offline }
            return request.method == "GET" ? .array([]) : ["id": "made", "profile": "default"]
        }
        let (model, _) = creator(client: client)
        await model.load()
        #expect(model.targetsState == .failed && model.modelsState == .failed && model.blueprints.isEmpty)
        #expect(model.deliveryRows.map(\.title) == ["Run History Only"])
        model.form.prompt = "Do it"
        #expect(await model.save() == .created("default|made"))
    }

    // MARK: Blueprints

    @Test func aBlueprintSendsItsValuesAndNoModel() async {
        let brief = Blueprint.list(JobBlueprintTests.catalog)[0]
        let (model, client) = creator(blueprint: brief)
        #expect(model.blueprint?.key == "morning-brief" && !model.showsModelRow && !model.isDirty)
        #expect(model.isComplete)
        #expect(model.blueprintValues() == ["time": "08:00", "deliver": "local"])
        model.setSlot("time", "07:30")
        #expect(await model.save() == .created("default|made"))
        let post = client.log.first { $0.method == "POST" }
        #expect(post?.description == "POST /api/cron/blueprints/instantiate?profile=default")
        #expect(post?.body == ["blueprint": "morning-brief", "values": ["time": "07:30", "deliver": "local"]])
    }

    @Test func aBlueprintWaitsForItsRequiredFieldsAndLeavesOutABlankOptionalOne() {
        let watch = Blueprint.list(JobBlueprintTests.catalog)[1]
        let (model, _) = creator(blueprint: watch)
        #expect(!model.isComplete && model.validate() == "Fill in every field.")
        model.setSlot("item", "PS5 at example.com")
        #expect(model.isComplete)
        #expect(model.blueprintValues() == ["item": "PS5 at example.com", "condition": "the all-in price drops below my target", "interval_h": "6"])
    }

    @Test func backToCustomRestoresWhatWasTypedAndAnotherBlueprintStartsFromItsOwnValues() async {
        let (model, _) = creator()
        await model.store.loadBlueprints(profile: "default")
        model.form.prompt = "My own prompt"
        model.chooseBlueprint("morning-brief")
        model.setSlot("time", "06:00")
        model.chooseBlueprint("price-watch")
        #expect(model.form.slots["interval_h"] == "6" && model.form.slots["time"] == nil)
        model.chooseBlueprint("morning-brief")
        #expect(model.form.slots["time"] == "08:00")
        model.chooseBlueprint(nil)
        #expect(model.blueprint == nil && model.form.prompt == "My own prompt" && model.isComplete)
    }

    @Test func aFieldErrorIsCleanedAndNamesItsField() async {
        let client = Self.gateway { _ in throw httpError(422, "422: invalid time '25:00' — use HH:MM (24h)") }
        let (model, _) = creator(client: client, blueprint: Blueprint.list(JobBlueprintTests.catalog)[0])
        #expect(await model.save() == .failed)
        #expect(model.failure == "invalid time '25:00' — use HH:MM (24h)")
        #expect(model.failedField == "time")
        model.setSlot("time", "09:00")
        #expect(model.failedField == nil)
    }

    @Test func anUnknownBlueprintSaysSoAndTheCatalogIsReadAgain() async throws {
        let client = Self.gateway { _ in throw httpError(404, "Unknown blueprint: morning-brief") }
        let (model, _) = creator(client: client, blueprint: Blueprint.list(JobBlueprintTests.catalog)[0])
        #expect(await model.save() == .failed)
        #expect(model.failure == "This blueprint is no longer available.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.logLines.contains("GET /api/cron/blueprints?profile=default"))
    }

    @Test func aBlankTimeDefaultIsSetToWhatTheWheelShows() {
        let odd = Blueprint(key: "odd", title: "Odd", fields: [BlueprintField(name: "time", type: "time", defaultValue: ""),
                                                               BlueprintField(name: "later", type: "time", defaultValue: "7:5x", optional: true)])
        #expect(JobEditorModel.seededSlots(odd) == ["time": "09:00", "later": "7:5x"])
    }

    // MARK: Edit

    @Test func anOpenedJobIsNotDirtyAndSaveWaitsForAChange() {
        let (model, _) = editor()
        #expect(model.title == "Edit Job" && model.actionTitle == "Save")
        #expect(model.form.name == "Morning mail" && model.form.frequency == .weekdays && model.form.deliver == "local,telegram")
        #expect(!model.isDirty && model.isComplete && !model.canSave && model.updates() == nil)
        #expect(!model.showsBotRow, "a job cannot move between bots")
    }

    @Test func anEditSendsOnlyTheKeysThatChanged() {
        let (model, _) = editor()
        model.form.name = "Morning mail  "
        #expect(model.updates() == nil, "spaces around a name are not a change")
        model.form.name = "Mail"
        #expect(model.updates() == ["name": "Mail"])
        model.form.prompt = "Summarize everything"
        #expect(model.updates() == ["name": "Mail", "prompt": "Summarize everything"])
        model.form.name = "Morning mail"; model.form.prompt = "Summarize my unread mail"
        model.setFields(JobTimeFields(hour: 8, minute: 30))
        #expect(model.updates() == ["schedule": "30 8 * * 1-5"])
        model.setFields(JobTimeFields(hour: 9, minute: 0))
        #expect(model.updates() == nil, "back to the stored time: nothing to send")
        model.toggleDelivery("telegram")
        #expect(model.updates() == ["deliver": "local"])
        model.toggleDelivery("telegram")
        #expect(model.updates() == ["deliver": "telegram"], "Run History Only is its own choice: local is not put back beside Telegram")
        model.form.deliver = "local,telegram"
        #expect(model.updates() == nil)
    }

    @Test func modelAndProviderTravelTogetherAndNullClearsThePin() {
        let (pinned, _) = editor(Self.job(["model": "claude-sonnet-5", "provider": "anthropic"]))
        #expect(pinned.form.model == JobModelChoice(provider: "anthropic", model: "claude-sonnet-5"))
        pinned.form.model = nil
        #expect(pinned.updates() == ["model": .null, "provider": .null])
        pinned.form.model = JobModelChoice(provider: "anthropic", model: "claude-opus-5")
        #expect(pinned.updates() == ["model": "claude-opus-5", "provider": "anthropic"])
        let (bare, _) = editor(Self.job(["model": "local-model", "provider": .null]))
        bare.form.name = "Renamed"
        #expect(bare.updates() == ["name": "Renamed"], "a pin without a provider is left as it is")
    }

    @Test func aPinTheGatewayNoLongerListsIsKeptAsAChoice() async {
        let (model, _) = editor(Self.job(["model": "retired-model-1", "provider": "oldco"]))
        await model.load()
        #expect(model.unlistedModel == JobModelChoice(provider: "oldco", model: "retired-model-1"))
        model.form.model = JobModelChoice(provider: "anthropic", model: "claude-opus-5")
        #expect(model.unlistedModel == nil)
    }

    @Test func aScheduleThatIsNotAPresetOpensAsCustomAndIsNotResent() {
        let (interval, _) = editor(Self.job(["schedule": ["kind": "interval", "minutes": 30, "display": "every 30m"], "schedule_display": "every 30m"]))
        #expect(interval.form.frequency == .custom && interval.form.schedule == "every 30m")
        interval.form.name = "Renamed"
        #expect(interval.updates() == ["name": "Renamed"])
        let (range, _) = editor(Self.job(["schedule": ["kind": "cron", "expr": "0 9 * * 1-3"], "schedule_display": "0 9 * * 1-3"]))
        #expect(range.form.frequency == .custom && range.form.schedule == "0 9 * * 1-3")
        // A list of days is Weekly's own line (redesign 2026-10-31), opened as written and not resent.
        let (list, _) = editor(Self.job(["schedule": ["kind": "cron", "expr": "0 9 * * 3,1"], "schedule_display": "0 9 * * 3,1"]))
        #expect(list.form.frequency == .weekly && list.fields.weekdays == [1, 3] && list.form.schedule == "0 9 * * 3,1" && !list.isDirty)
        list.form.name = "Renamed"
        #expect(list.updates() == ["name": "Renamed"])
        let (sunday, _) = editor(Self.job(["schedule": ["kind": "cron", "expr": "0 9 * * 7"], "schedule_display": "0 9 * * 7"]))
        #expect(sunday.form.frequency == .weekly && sunday.fields.weekday == 0 && !sunday.isDirty)
        sunday.form.name = "Renamed"
        #expect(sunday.updates() == ["name": "Renamed"], "opening a job never rewrites its schedule")
    }

    @Test func aScriptOnlyJobNeverSendsAPromptOrAModel() {
        let (model, _) = editor(Self.job(["prompt": "", "script": "df -h", "no_agent": true, "model": "x", "provider": "y"]))
        #expect(model.scriptOnly && !model.showsModelRow && model.isComplete)
        model.form.prompt = "typed somehow"
        model.form.model = nil
        model.setFrequency(.hourly)
        #expect(model.updates() == ["schedule": "0 * * * *"])
    }

    @Test func oddStoredJobsOpenWithoutACrash() {
        let (empty, _) = editor(["id": "odd", "profile": "research", "schedule": .null, "deliver": "", "prompt": "   "])
        #expect(empty.form.deliver == "local" && empty.form.frequency == .custom && !empty.isComplete && !empty.isDirty)
        let (repeated, _) = editor(Self.job(["deliver": "local,local,,telegram"]))
        #expect(repeated.deliveryRows.filter(\.checked).map(\.id) == ["local", "telegram"])
        repeated.form.name = "x"
        #expect(repeated.updates() == ["name": "x"], "the same places in other words are not a change")
        let (six, _) = editor(Self.job(["schedule": ["kind": "cron", "expr": "0 0 9 * * *"], "schedule_display": "0 0 9 * * *"]))
        #expect(six.form.frequency == .custom)
        let (long, _) = editor(Self.job(["name": .string(String(repeating: "n", count: 500))]))
        #expect(long.form.name.count == 500 && !long.isDirty)
    }

    @Test func savePutsOnlyTheChangesOnTheJobsOwnBot() async {
        let (model, client) = editor()
        model.form.name = "Mail"
        #expect(await model.save() == .saved)
        let put = client.log.first { $0.method == "PUT" }
        #expect(put?.description == "PUT /api/cron/jobs/j1?profile=research")
        #expect(put?.body == ["updates": ["name": "Mail"]])
        #expect(client.log.filter { $0.method == "PUT" }.count == 1)
    }

    @Test func aJobDeletedElsewhereSaysSoAndLeavesTheList() async {
        let client = Self.gateway { _ in throw httpError(404, "Job not found") }
        let (model, _) = editor(client: client)
        await model.store.refresh()
        #expect(model.store.jobs.count == 1)
        let removed = Mutex<[String]>([])
        model.store.onJobRemoved = { key in removed.withLock { $0.append(key) } }
        model.form.name = "Mail"
        #expect(await model.save() == .failed)
        #expect(model.failure == "This job no longer exists.")
        #expect(removed.withLock { $0 } == ["research|j1"])
    }

    @Test func aChangeElsewhereReachesAPristineFormButNeverADirtyOne() {
        let (model, _) = editor()
        var fresh = model.job!
        fresh.name = "Renamed elsewhere"
        model.absorb(fresh)
        #expect(model.form.name == "Renamed elsewhere" && !model.isDirty)
        model.form.prompt = "My typing"
        fresh.name = "Renamed again"
        fresh.deliver = "local"
        model.absorb(fresh)
        #expect(model.form.name == "Renamed elsewhere" && model.form.prompt == "My typing", "the person's typing wins")
        #expect(model.updates() == ["prompt": "My typing"], "only their own change is sent")
    }

    @Test func aSlowAnswerSaysSoAndTheListIsReadAgain() async throws {
        let client = Self.gateway { _ in throw GatewayFailure.timeout }
        let (model, _) = creator(client: client)
        model.form.prompt = "Do it"
        #expect(await model.save() == .failed)
        #expect(model.failure == "The gateway is taking a while. Check the list before trying again.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.logLines.contains { $0.hasPrefix("GET /api/cron/jobs?") }, "it may have landed: the list shows the truth")
        #expect(client.log.filter { $0.method == "POST" }.count == 1, "never retried by itself")
    }

    @Test func editorModelsAreReleased() async {
        let before = JobEditorModel.liveCount
        for _ in 0..<50 {
            let (model, _) = creator()
            await model.load()
            model.form.prompt = "x"
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(JobEditorModel.liveCount == before)
    }

    // MARK: Redesign 2026-10-31

    @Test func theNameHermesWouldGiveIsTheMostOfThePromptsFirstLine() {
        let (model, _) = creator()
        #expect(model.suggestedName == nil)
        model.form.prompt = "  Summarize my unread Slack threads\nand email me the top five, every single morning please  "
        #expect(model.suggestedName == "Summarize my unread Slack threads and email me the")
        #expect(model.suggestedName?.count ?? 0 <= 50)
    }

    @Test func weeklyDaysTurnOnAndOffButNeverAllOff() {
        let (model, _) = creator()
        #expect(!model.toggleWeekday(3), "only Weekly has day buttons")
        model.setFrequency(.weekly)
        #expect(model.form.schedule == "0 9 * * 1")
        #expect(model.toggleWeekday(3) && model.toggleWeekday(5))
        #expect(model.form.schedule == "0 9 * * 1,3,5" && model.form.frequency == .weekly)
        #expect(model.toggleWeekday(1) && model.toggleWeekday(3))
        #expect(model.form.schedule == "0 9 * * 5")
        #expect(!model.toggleWeekday(5), "the last day stays on")
        #expect(model.form.schedule == "0 9 * * 5")
    }

    @Test func runOnceNowStartsOffAndIsNotSent() {
        let (model, _) = creator()
        #expect(!model.form.runNow)
        model.form.prompt = "Do it"
        model.form.runNow = true
        #expect(model.isDirty)
        #expect(model.createBody() == ["prompt": "Do it", "schedule": "0 9 * * *", "deliver": "local"])
    }

    @Test func theGatewaysClockComesFromItsJobs() async {
        let zone = TimeZone(identifier: "America/Chicago")!
        let now = PagesDate.parse("2026-10-31T04:50:00-05:00")!
        let (model, _) = creator(client: Self.gateway(job: Self.job(["next_run_at": "2026-11-02T07:00:00-06:00"])))
        #expect(model.hostClock(now: now, zone: zone) == .unknown)
        await model.store.refresh()
        guard var job = model.store.jobs.first else { Issue.record("no job"); return }
        #expect(model.hostClock(now: now, zone: zone) == .shared)
        job.nextRunAt = "2026-11-02T07:00:00-05:00"   // written before the change, still today's offset
        model.store.replace(job)
        #expect(model.hostClock(now: now, zone: zone) == .shared)
        job.nextRunAt = "2026-11-02T07:00:00+00:00"
        model.store.replace(job)
        #expect(model.hostClock(now: now, zone: zone) == .offset(0))
    }
}

/// §6.1 (R1): a very long list is bounded by the list itself, not by paging.
@MainActor
struct JobsLongListTests {
    nonisolated static func many(_ count: Int) -> JSONValue {
        .array((0..<count).map { n in
            ["id": .string(String(format: "g%05d", n)), "name": .string("Generated job \(n)"), "profile": n % 2 == 0 ? "default" : "research",
             "prompt": .string(String(repeating: "Generated job \(n): do the thing and say what changed. ", count: 3)),
             "schedule": ["kind": "cron", "expr": "0 9 * * *", "display": "0 9 * * *"], "enabled": true, "state": "scheduled",
             "next_run_at": "2026-10-14T09:00:00+00:00"]
        })
    }

    @Test func theCacheKeepsAtMost500JobsAndStaysUnderTheLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jobs-long-\(UUID().uuidString)")
        let client = PagesFakeClient { request in request.path == "/api/cron/jobs" ? Self.many(1000) : .object([:]) }
        let store = JobsStore(client: client, account: client.account, directory: dir)
        await store.refresh()
        #expect(store.jobs.count == 1000, "the page shows every job")
        PagesCache.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        #expect((sizes.max() ?? 0) <= JobsStore.cacheLimit, "cache file sizes: \(sizes)")
        let again = JobsStore(client: PagesFakeClient { _ in throw GatewayFailure.offline }, account: client.account, directory: dir)
        #expect(again.hasList && again.jobs.count == JobsStore.cachedJobsLimit, "a relaunch paints the first 500 before the network")
        try? FileManager.default.removeItem(at: dir)
    }

    /// D-J21: long prompts make 500 jobs too large; the cache keeps the longest prefix that fits instead of nothing.
    @Test func longPromptsKeepAShorterPrefixRatherThanNoCache() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jobs-long-prompts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list: JSONValue = .array((0..<1000).map { n in
            ["id": .string(String(format: "p%05d", n)), "name": .string("Long job \(n)"), "profile": "default",
             "prompt": .string(String(repeating: "x", count: 1000)), "enabled": true, "state": "scheduled"]
        })
        let client = PagesFakeClient { request in request.path == "/api/cron/jobs" ? list : .object([:]) }
        let store = JobsStore(client: client, account: client.account, directory: dir)
        await store.refresh()
        #expect(store.jobs.count == 1000)
        PagesCache.flush()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        let sizes = try files.map { try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
        #expect((sizes.max() ?? 0) <= JobsStore.cacheLimit, "cache file sizes: \(sizes)")
        let again = JobsStore(client: PagesFakeClient { _ in throw GatewayFailure.offline }, account: client.account, directory: dir)
        #expect(again.hasList && again.jobs.count == 250, "kept \(again.jobs.count)")
    }

    @Test func thePrefixHalvesUntilItFitsAndGivesUpBelow31() throws {
        func jobs(_ count: Int, prompt: Int) -> [CronJob] {
            (0..<count).compactMap { CronJob(json: ["id": .string("h\($0)"), "name": "Job", "profile": "default",
                                                    "prompt": .string(String(repeating: "y", count: prompt)), "enabled": true]) }
        }
        func kept(_ list: [CronJob]) -> Int? {
            PagesCache.fittingJobs(list, at: 1, maxBytes: JobsStore.cacheLimit)
                .flatMap { try? JSONDecoder().decode(PagesCached<[CronJob]>.self, from: $0) }?.value.count
        }
        #expect(kept(jobs(40, prompt: 10)) == 40, "a short list is kept whole")
        #expect(kept(jobs(600, prompt: 10)) == 500)
        #expect(kept(jobs(600, prompt: 2_000)) == 125)
        #expect(kept(jobs(600, prompt: 4_000)) == 62)
        #expect(kept(jobs(600, prompt: 9_000)) == 31)
        #expect(kept(jobs(600, prompt: 12_000)) == nil, "even 31 do not fit: nothing is kept")
        #expect(kept(jobs(20, prompt: 20_000)) == nil, "a short list over the limit is not kept in part")
        #expect(kept([]) == 0)
    }

    /// §11.4: an edit, a pause or a delete made while an older list read is in flight is not undone when that read lands.
    @Test func aWriteIsNotUndoneByAListReadThatBeganBeforeIt() async throws {
        let reads = Mutex(0)
        let renamed = Mutex(false)
        let deleted = Mutex(false)
        let old = JobEditorModelTests.job(), other = JobEditorModelTests.job(["id": "j2", "name": "Other"])
        let client = PagesFakeClient { request in
            if request.method == "PUT" { renamed.withLock { $0 = true }; return JobEditorModelTests.job(["name": "Renamed"]) }
            if request.method == "DELETE" { deleted.withLock { $0 = true }; return .object([:]) }
            guard request.path == "/api/cron/jobs" else { return .object([:]) }
            let n = reads.withLock { $0 += 1; return $0 }
            // The answer is what the gateway had when the read began; reads 2 and 4 are slow.
            let first: JSONValue = renamed.withLock { $0 } ? JobEditorModelTests.job(["name": "Renamed"]) : old
            let answer: JSONValue = deleted.withLock { $0 } ? .array([first]) : .array([first, other])
            if n == 2 || n == 4 { try await Task.sleep(for: .milliseconds(400)) }
            return answer
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        #expect(store.jobs.compactMap(\.name).sorted() == ["Morning mail", "Other"])
        var seen: [[String]] = []
        store.onChange = { seen.append(store.jobs.compactMap(\.name).sorted()) }

        let slow = Task { await store.refresh() }          // read 2: began before the edit, lands after it
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.loading)
        let job = try #require(store.jobs.first { $0.id == "j1" })
        _ = await store.update(job, updates: ["name": "Renamed"])
        seen = []                                          // from here on: what the page is told after the write
        #expect(store.jobs.contains { $0.name == "Renamed" })
        await slow.value
        try await Task.sleep(for: .milliseconds(700))      // read 2 has landed, and the read asked by the write
        #expect(!seen.contains { $0.contains("Morning mail") }, "the old name came back: \(seen)")
        #expect(store.jobs.compactMap(\.name).sorted() == ["Other", "Renamed"])
        #expect(!store.loading)

        let slowAgain = Task { await store.refresh() }     // read 4: began before the delete
        try await Task.sleep(for: .milliseconds(80))
        let gone = try #require(store.jobs.first { $0.id == "j2" })
        _ = await store.delete(gone)
        seen = []
        await slowAgain.value
        try await Task.sleep(for: .milliseconds(700))
        #expect(!seen.contains { $0.contains("Other") }, "the deleted row came back: \(seen)")
        #expect(store.jobs.compactMap(\.name) == ["Renamed"])
        #expect(!store.loading)
    }

    @Test func applyingAThousandJobsIsFastOnTheMainThread() async {
        let client = PagesFakeClient { request in request.path == "/api/cron/jobs" ? Self.many(1000) : .object([:]) }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        let jobs = store.jobs
        let clock = ContinuousClock()
        // What the list does for a refresh or a keystroke: section and words for every job, then the search filter.
        let now = Date()
        let grouping = clock.measure {
            for job in jobs { _ = JobWords.section(job, now: now); _ = store.title(job); _ = JobWords.rowSubtitle(job, now: now) }
        }
        let search = clock.measure {
            _ = jobs.filter { job in [JobWords.jobTitle(job), job.prompt ?? "", job.scheduleDisplay ?? ""].contains { $0.lowercased().contains("job 99") } }
        }
        print("[measure] 1000 jobs: rows \(grouping), search \(search)")
        #expect(grouping < .milliseconds(100), "rows for 1000 jobs took \(grouping)")
        #expect(search < .milliseconds(100), "a search over 1000 jobs took \(search)")
    }
}

/// §6.4 (R4): one run-history read for callers of the same moment, also when it fails.
@MainActor
struct JobRunsSharedReadTests {
    @Test func aFailedReadFailsEveryJoinedCallerOnceAndIsNotCached() async throws {
        let reads = SharedReads<[String]>()
        let count = Mutex(0)
        let load: @Sendable () async throws -> [String] = {
            let n = count.withLock { $0 += 1; return $0 }
            try await Task.sleep(for: .milliseconds(40))
            if n == 1 { throw GatewayFailure.offline }
            return ["run"]
        }
        let callers = (0..<3).map { _ in Task { try await reads.read("job", load) } }
        for caller in callers {
            await #expect(throws: GatewayFailure.self) { _ = try await caller.value }
        }
        #expect(count.withLock { $0 } == 1, "one request, one failure for all three")
        #expect(try await reads.read("job", load) == ["run"], "the failure is not kept")
        #expect(count.withLock { $0 } == 2)
    }

    @Test func theStoreMakesOneRunsRequestForSimultaneousCallers() async throws {
        let client = PagesFakeClient { request in
            if request.path.hasSuffix("/runs") {
                try await Task.sleep(for: .milliseconds(60))
                return ["runs": [["id": "r1", "status": "ok"]]]
            }
            return .array([JobEditorModelTests.job()])
        }
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        let job = store.jobs[0]
        async let a = store.loadRuns(job)
        async let b = store.loadRuns(job)
        async let c = store.loadRuns(job)
        _ = try await (a, b, c)
        #expect(client.logLines.filter { $0.contains("/runs") } == ["GET /api/cron/jobs/j1/runs?limit=20&profile=research"])
        _ = try await store.loadRuns(job)
        #expect(client.logLines.filter { $0.contains("/runs") }.count == 2, "a finished read is never reused")
    }

    @Test func cronChangedBumpsTheTickTheJobPageWatches() {
        let client = PagesFakeClient()
        let store = JobsStore(client: client, account: client.account, directory: nil)
        let before = store.changeTick
        store.cronChanged()
        store.cronChanged()
        #expect(store.changeTick == before + 2)
    }
}

/// [jobs] Found by `testJE20_UnderADesktopLookSkin`: "Job Created" stopped the app with Desktop Look on, because the HUD
/// was tied to the system tab bar, which is hidden and outside the host's view tree then.
@MainActor
struct PagesHUDHostTests {
    @Test func theHUDShowsOverATabControllerWhoseSystemBarIsHidden() {
        let tabs = UITabBarController()
        tabs.viewControllers = [UINavigationController(rootViewController: UIViewController())]
        tabs.loadViewIfNeeded()
        tabs.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        tabs.setTabBarHidden(true, animated: false)
        tabs.tabBar.removeFromSuperview()   // what a hidden system bar amounts to for layout: not under the host
        let hud = PagesHUD.show("Job Created", symbol: "checkmark", from: tabs)
        #expect(hud?.superview === tabs.view)
        tabs.view.layoutIfNeeded()
        hud?.dismiss(animated: false)

        // With the docked bar of the Desktop Look in the tree, the HUD sits over it.
        let docked = DesktopTabBar(host: tabs)
        docked.frame = CGRect(x: 0, y: 794, width: 390, height: 50)
        tabs.view.addSubview(docked)
        let over = PagesHUD.show("Job Saved", symbol: "checkmark", from: tabs)
        tabs.view.layoutIfNeeded()
        #expect((over?.frame.maxY ?? 900) <= docked.frame.minY - 11, "over the docked bar: \(String(describing: over?.frame)) vs \(docked.frame)")
        over?.dismiss(animated: false)
    }

}
