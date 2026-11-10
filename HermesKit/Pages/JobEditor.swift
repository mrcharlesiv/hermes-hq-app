// [jobs] The New Job / Edit Job form's state (docs/spec/3x-jobs.md §4, §6.5-§6.10): one model for both, so the two
// read as one page. It holds what was typed, what the gateway offers (delivery targets, models, blueprints), whether
// the form is complete or changed, and builds exactly what is sent: the create body (§3.2), the blueprint values
// (§3.4) and, for an edit, only the keys that changed (D-J1: a key the person did not touch is never rewritten).

import Foundation
import Observation

@MainActor @Observable
final class JobEditorModel {
    enum Mode: Equatable { case create, edit(CronJob) }
    enum LoadState: Equatable { case loading, loaded, failed }
    enum Outcome: Equatable {
        /// The new job's key, when the gateway's answer named it.
        case created(String?)
        case saved
        case failed
    }

    /// Everything the person can change, for "is the form as it was opened".
    struct Form: Equatable {
        var profile: String
        var name = ""
        var prompt = ""
        var frequency = JobFrequency.daily
        var schedule = JobFrequency.daily.presetExpr ?? ""
        var deliver = JobDelivery.fallback
        var model: JobModelChoice?
        var blueprintKey: String?
        var slots: [String: String] = [:]
        /// Create only: run the new job once as soon as it exists (`JobsStore.runNow`), so its result can be checked.
        var runNow = false
    }

    let store: JobsStore
    private(set) var mode: Mode
    /// Profile → display name, in the order the Bot row offers them.
    let bots: [(id: String, name: String)]

    var form: Form
    private(set) var baseline: Form

    private(set) var targets: [DeliveryTarget] = []
    private(set) var targetsState = LoadState.loading
    private(set) var providers: [JobModelProvider] = []
    private(set) var modelsState = LoadState.loading
    private(set) var saving = false
    /// The reason of the last failed save (shown on top of the form).
    var failure: String?
    /// The blueprint field the last refusal named.
    private(set) var failedField: String?
    /// The gateway refused the Custom schedule as typed.
    private(set) var scheduleRejected = false
    /// Bumped when a failure appears: the form scrolls it into view.
    private(set) var failureTick = 0

    @ObservationIgnored private var loadGeneration = 0
    /// Counts live editor models (the stress plan's leak check).
    nonisolated(unsafe) static var liveCount = 0

    init(store: JobsStore, mode: Mode, bots: [(id: String, name: String)], profile: String, blueprint: Blueprint? = nil) {
        self.store = store
        self.mode = mode
        self.bots = bots
        var form = Form(profile: profile)
        if case .edit(let job) = mode { form = Self.form(for: job) }
        if case .create = mode, let blueprint {
            form.blueprintKey = blueprint.key
            form.slots = Self.seededSlots(blueprint)
            if store.blueprintsByProfile[profile]?.contains(where: { $0.key == blueprint.key }) != true {
                store.blueprintsByProfile[profile, default: []].append(blueprint)
            }
        }
        self.form = form
        baseline = form
        Self.liveCount += 1
    }

    isolated deinit { Self.liveCount -= 1 }

    /// The form a stored job opens with (vendor app/cron/index.tsx:1139-1148).
    static func form(for job: CronJob) -> Form {
        var form = Form(profile: job.owner)
        form.name = (job.name ?? "").pgTrim
        form.prompt = job.prompt ?? ""
        form.schedule = JobWords.scheduleExpr(job)
        form.frequency = JobSchedule.frequency(for: form.schedule)
        let deliver = (job.deliver ?? "").pgTrim
        form.deliver = deliver.isEmpty ? JobDelivery.fallback : deliver
        let model = (job.model ?? "").pgTrim
        form.model = model.isEmpty ? nil : JobModelChoice(provider: (job.provider ?? "").pgTrim, model: model)
        return form
    }

    /// A blueprint's first values, with a time the catalog left blank (or wrote badly) set to what the wheel shows,
    /// so what is on screen is what is sent.
    static func seededSlots(_ blueprint: Blueprint) -> [String: String] {
        var slots = JobBlueprints.initialValues(blueprint)
        for field in blueprint.fields where JobBlueprints.control(field) == .time {
            if let time = JobBlueprints.time(slots[field.name] ?? "") {
                slots[field.name] = JobBlueprints.timeValue(hour: time.hour, minute: time.minute)
            } else if !field.optional {
                slots[field.name] = JobBlueprints.timeValue(hour: 9, minute: 0)
            }
        }
        return slots
    }

    // MARK: What the form is

    var isEdit: Bool { if case .edit = mode { return true }; return false }
    var job: CronJob? { if case .edit(let job) = mode { return job }; return nil }
    var scriptOnly: Bool { job.map(JobWords.jobIsScriptOnly) ?? false }
    var title: String { isEdit ? "Edit Job" : "New Job" }
    var actionTitle: String { isEdit ? "Save" : "Create" }
    var intro: String {
        isEdit ? "Update the schedule, prompt, or delivery target. Changes apply on next run."
               : "Schedule a prompt to run automatically. Choose how often it runs."
    }

    /// The profile's blueprints (create only).
    var blueprints: [Blueprint] { isEdit ? [] : (store.blueprintsByProfile[form.profile] ?? []) }
    var blueprint: Blueprint? { form.blueprintKey.flatMap { key in blueprints.first { $0.key == key } } }
    var showsBotRow: Bool { !isEdit && bots.count >= 2 }
    var showsModelRow: Bool { !scriptOnly && blueprint == nil }

    var fields: JobTimeFields { JobSchedule.fields(form.schedule) }

    func setFrequency(_ next: JobFrequency) {
        guard next != form.frequency else { return }
        form.schedule = JobSchedule.expression(for: next, keeping: form.schedule)
        form.frequency = next
        scheduleRejected = false
    }

    /// A time or day control changed: the cron line is composed again.
    func setFields(_ next: JobTimeFields) {
        guard form.frequency.isTimed, next != fields else { return }
        form.schedule = JobSchedule.compose(form.frequency, next)
    }

    /// Weekly's day buttons: turns a day on or off. False when nothing changed (the last day stays on).
    @discardableResult
    func toggleWeekday(_ day: Int) -> Bool {
        guard form.frequency == .weekly else { return false }
        var next = fields
        var days = Set(next.weekdays)
        if days.contains(day) {
            guard days.count > 1 else { return false }
            days.remove(day)
        } else {
            days.insert(day)
        }
        next.weekdays = JobTimeFields.cleanDays(Array(days))
        setFields(next)
        return true
    }

    func setCustomSchedule(_ text: String) {
        // The field writes its own text back when it gets focus: that is not a change, so the red note stays.
        guard text != form.schedule else { return }
        form.schedule = text
        scheduleRejected = false
    }

    /// The schedule as it is sent.
    var scheduleToSend: String { JobSchedule.cleanCustom(form.schedule) }

    var botNames: [String: String] { Dictionary(bots.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }

    var deliveryRows: [DeliveryRow] {
        JobDelivery.rows(targets: targets, value: form.deliver, origin: job?.origin,
                         chatNames: JobWords.knownChatNames(store.jobs), botNames: botNames)
    }

    /// "Send Results To" as the editor draws it: places, the bots' chats, and the platforms still without a home channel.
    var deliveryGroups: (places: [DeliveryRow], bots: [DeliveryRow], needsHome: [String]) {
        JobDelivery.groups(JobDelivery.historyOnlyBeside(deliveryRows))
    }

    /// What Hermes calls a job saved without a name: its prompt's first 50 characters (cron/jobs.py `create_job`),
    /// on one line. nil while there is no prompt.
    var suggestedName: String? {
        let line = form.prompt.split(whereSeparator: \.isNewline).joined(separator: " ").pgTrim
        guard !line.isEmpty else { return nil }
        return String(line.prefix(50)).pgTrim
    }

    /// The gateway's clock as its jobs' next runs are written (this bot's first, then any): `shared` when a written
    /// offset is the phone's own, at that moment or now (the same zone, written before or after a daylight-saving
    /// change: the phone's calendar then reads the schedule, and follows the change), else the first job's offset,
    /// minutes east of UTC; unknown when no job says.
    enum HostClock: Equatable { case unknown, shared, offset(Int) }

    func hostClock(now: Date = Date(), zone: TimeZone = .current) -> HostClock {
        let mine = store.jobs.filter { $0.owner == form.profile }
        var foreign: Int?
        for job in (mine + store.jobs).prefix(40) {
            guard let offset = JobWords.writtenOffset(job.nextRunAt), let at = PagesDate.parse(job.nextRunAt) else { continue }
            if [zone.secondsFromGMT(for: at), zone.secondsFromGMT(for: now)].contains(offset * 60) { return .shared }
            foreign = foreign ?? offset
        }
        return foreign.map { .offset($0) } ?? .unknown
    }

    /// The fixed offset to read a schedule on: nil while the gateway keeps the phone's zone (or none is known).
    var hostOffset: Int? { if case .offset(let offset) = hostClock() { return offset }; return nil }

    /// "First run: Tomorrow at 9:00 AM" (create) / "Next run: …" (edit), in the phone's words; nil when the schedule
    /// is not a line the app can read (Custom phrases) or never fires.
    func nextRunWords(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard blueprint == nil, let next = JobSchedule.nextRun(scheduleToSend, hostOffset: hostOffset, now: now, calendar: calendar) else { return nil }
        return (isEdit ? "Next run: " : "First run: ") + JobWords.relativeDateTime(next, now: now, calendar: calendar)
    }

    /// The rows of a blueprint's deliver slot: one choice, a job's origin is not offered.
    func slotDeliveryRows(_ value: String) -> [DeliveryRow] {
        JobDelivery.rows(targets: targets, value: value.isEmpty || value == "origin" ? JobDelivery.fallback : value,
                         chatNames: JobWords.knownChatNames(store.jobs), botNames: botNames)
    }

    /// A tap on a "Send Results To" row (`JobDelivery.pick`). False when nothing changed (Run History Only tapped again).
    @discardableResult
    func toggleDelivery(_ id: String) -> Bool {
        let next = JobDelivery.pick(form.deliver, id)
        guard !JobDelivery.same(next, form.deliver) else { return false }
        form.deliver = next
        return true
    }

    func setSlot(_ name: String, _ value: String) {
        form.slots[name] = value
        if failedField == name { failedField = nil }
    }

    /// "Start from": nil is Custom (what was typed in the normal form is kept); a blueprint starts from its own values.
    func chooseBlueprint(_ key: String?) {
        guard key != form.blueprintKey else { return }
        form.blueprintKey = key
        form.slots = key.flatMap { key in blueprints.first { $0.key == key } }.map(Self.seededSlots) ?? [:]
        failure = nil
        failedField = nil
    }

    /// The Bot row (create): the job's bot, and what that bot offers.
    func chooseProfile(_ profile: String) {
        guard !isEdit, profile != form.profile else { return }
        let moved = baseline.profile == form.profile && form == baseline
        form.profile = profile
        if moved { baseline = form }
        Task { await load() }
    }

    /// The model the job is pinned to that the gateway no longer lists (kept as a choice so a save never changes it).
    var unlistedModel: JobModelChoice? {
        guard let model = form.model else { return nil }
        let listed = providers.contains { $0.slug == model.provider && $0.models.contains(model.model) }
        return listed ? nil : model
    }

    var modelWords: String { form.model.map { ModelNames.displayModelName($0.model, provider: $0.provider) } ?? "Default (global model)" }

    // MARK: Complete, changed

    /// The validation sentence (vendor cron-job-model.ts:23-40); nil when the form can be sent.
    func validate() -> String? {
        if let blueprint {
            return JobBlueprints.isIncomplete(blueprint, form.slots) ? "Fill in every field." : nil
        }
        let prompt = form.prompt.pgTrim, schedule = scheduleToSend
        if schedule.isEmpty && prompt.isEmpty && !scriptOnly { return "Prompt and schedule are required." }
        if schedule.isEmpty { return "Schedule is required." }
        if !scriptOnly && prompt.isEmpty { return "Prompt is required." }
        return nil
    }

    var isComplete: Bool { validate() == nil }
    /// The form differs from how it opened (closing asks first).
    var isDirty: Bool { form != baseline }
    /// Create: complete. Save: complete and something to send.
    var canSave: Bool { !saving && isComplete && (isEdit ? updates() != nil : true) }

    // MARK: What is sent

    /// `POST /api/cron/jobs` (§3.2): no empty name, no model keys for the default model.
    func createBody() -> JSONValue {
        var body: [String: JSONValue] = [
            "prompt": .string(form.prompt.pgTrim),
            "schedule": .string(scheduleToSend),
            "deliver": .string(JobDelivery.parse(form.deliver).joined(separator: ",")),
        ]
        let name = form.name.pgTrim
        if !name.isEmpty { body["name"] = .string(name) }
        if let model = form.model, !model.model.isEmpty {
            body["model"] = .string(model.model)
            body["provider"] = .string(model.provider)
        }
        return .object(body)
    }

    /// The blueprint's values (§3.4): every field, an optional one left blank left out.
    func blueprintValues() -> [String: String] {
        guard let blueprint else { return [:] }
        var values: [String: String] = [:]
        for field in blueprint.fields {
            var value = (form.slots[field.name] ?? "").pgTrim
            if field.name == JobBlueprints.deliverField && (value.isEmpty || value == "origin") { value = JobDelivery.fallback }
            if value.isEmpty && field.optional { continue }
            values[field.name] = value
        }
        return values
    }

    /// `PUT …` `updates` (§3.3, D-J1): only the keys whose value differs from the job as loaded; `model` and `provider`
    /// always together (`null` for both clears the pin); a script-only job never sends a prompt or a model. nil when
    /// nothing changed.
    func updates() -> JSONValue? {
        guard isEdit else { return nil }
        var out: [String: JSONValue] = [:]
        if form.name.pgTrim != baseline.name.pgTrim { out["name"] = .string(form.name.pgTrim) }
        if !scriptOnly, form.prompt.pgTrim != baseline.prompt.pgTrim { out["prompt"] = .string(form.prompt.pgTrim) }
        if scheduleToSend != JobSchedule.cleanCustom(baseline.schedule) { out["schedule"] = .string(scheduleToSend) }
        if !JobDelivery.same(form.deliver, baseline.deliver) {
            out["deliver"] = .string(JobDelivery.parse(form.deliver).joined(separator: ","))
        }
        if !scriptOnly, form.model != baseline.model {
            out["model"] = form.model.map { .string($0.model) } ?? .null
            out["provider"] = form.model.flatMap { $0.provider.isEmpty ? nil : .string($0.provider) } ?? .null
        }
        return out.isEmpty ? nil : .object(out)
    }

    // MARK: Reads

    /// What the editor reads when it opens (and again when the Bot row changes). Nothing here blocks the form.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration, profile = form.profile
        targetsState = targets.isEmpty ? .loading : targetsState
        async let targetsRead: [DeliveryTarget]? = try? store.deliveryTargets(profile: profile)
        async let modelsRead: [JobModelProvider]? = scriptOnly ? [] : (try? store.modelProviders(profile: profile))
        if !isEdit { Task { await store.loadBlueprints(profile: profile); self.blueprintsArrived(profile) } }
        if case .edit(let job) = mode { Task { await self.refreshJob(job) } }
        let (gotTargets, gotModels) = await (targetsRead, modelsRead)
        guard generation == loadGeneration else { return }
        if let gotTargets { targets = gotTargets; targetsState = .loaded } else { targets = []; targetsState = .failed }
        // [provider-manager] The owner's provider and model names, hidden models left out.
        if let gotModels { providers = gotModels.map { $0.applying(ProviderPrefs.active) }; modelsState = .loaded } else { providers = []; modelsState = .failed }
    }

    func reloadTargets() async {
        let profile = form.profile
        guard let got = try? await store.deliveryTargets(profile: profile), profile == form.profile else { return }
        targets = got
        targetsState = .loaded
    }

    func reloadModels() async {
        let profile = form.profile
        modelsState = .loading
        let got = try? await store.modelProviders(profile: profile)
        guard profile == form.profile else { return }
        if let got { providers = got.map { $0.applying(ProviderPrefs.active) }; modelsState = .loaded } else { modelsState = .failed }
    }

    private func blueprintsArrived(_ profile: String) {
        // A blueprint the new bot does not have goes back to Custom.
        guard profile == form.profile, let key = form.blueprintKey, !blueprints.contains(where: { $0.key == key }) else { return }
        let pristine = form == baseline
        form.blueprintKey = nil
        form.slots = [:]
        if pristine { baseline = form }
    }

    /// Edit opens on the list's copy, then takes the gateway's fresh one (a failed read changes nothing).
    private func refreshJob(_ job: CronJob) async {
        if case .some(.some(let fresh)) = await store.reload(job) { absorb(fresh) }
    }

    /// The job changed elsewhere. A pristine form takes the new values; a changed one is left alone and keeps its
    /// own baseline, so only what the person changed is sent (D-J12).
    func absorb(_ fresh: CronJob) {
        guard case .edit(let job) = mode, fresh.key == job.key, !saving else { return }
        guard form == baseline else { return }
        mode = .edit(fresh)
        form = Self.form(for: fresh)
        baseline = form
    }

    // MARK: Save

    private func fail(_ reason: String) {
        failure = reason
        failureTick += 1
    }

    /// The job made, as the gateway's answer named it (Run Once Now runs it even when the list read after it doesn't
    /// have it: another bot than the page shows, or a read that failed).
    private(set) var created: CronJob?

    /// Sends the form once: a second call while one is on its way does nothing.
    func save() async -> Outcome {
        guard !saving else { return .failed }
        if let invalid = validate() { fail(invalid); return .failed }
        failure = nil
        failedField = nil
        scheduleRejected = false
        saving = true
        defer { saving = false }
        let result: JobEditResult
        let usedBlueprint = blueprint
        switch mode {
        case .create:
            if let usedBlueprint {
                result = await store.instantiate(blueprint: usedBlueprint.key, values: blueprintValues(), profile: form.profile)
            } else {
                result = await store.create(body: createBody(), profile: form.profile)
            }
        case .edit(let job):
            guard let changes = updates() else { return .failed }
            result = await store.update(job, updates: changes)
        }
        switch result {
        case .done(let job):
            baseline = form
            if !isEdit { created = job }
            return isEdit ? .saved : .created(job?.key)
        case .refused:
            fail(JobsStore.readOnlyNotice)
            return .failed
        case .failed(let reason, let status, _):
            if let usedBlueprint {
                let cleaned = JobBlueprints.cleanFieldError(reason)
                failedField = JobBlueprints.fieldNamed(in: cleaned, of: usedBlueprint)
                fail(cleaned)
            } else {
                scheduleRejected = status == 400 && form.frequency == .custom && reason.lowercased().contains("invalid")
                fail(reason)
            }
            return .failed
        }
    }
}
