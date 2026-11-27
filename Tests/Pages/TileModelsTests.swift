// [tile-models] Which model updates the tiles: Settings › Tile Model (a default and a fallback, each "each bot's own"
// until picked), a tile's own model, and the one write each job needs (owner 2026-11-18).

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct TileModelsTests {
    private let sonnet = TileModelPick(provider: "anthropic", model: "claude-sonnet-5")
    private let opus = TileModelPick(provider: "anthropic", model: "claude-opus-5-5")
    private let astra = TileModelPick(provider: "openai", model: "gpt-6.2-astra")
    private let haiku = TileModelPick(provider: "anthropic", model: "claude-haiku-5-5")

    private func job(_ id: String = "j1", model: String? = nil, provider: String? = nil, prompt: String? = "Update ~/dashboards/x.html",
                     script: String? = nil, noAgent: Bool = false, fallback: [TileModelPick]? = nil) -> CronJob {
        var job = CronJob(id: id)
        job.profile = "otto"
        job.prompt = prompt
        job.script = script
        job.noAgent = noAgent
        job.model = model
        job.provider = provider
        job.fallbackProviders = fallback
        return job
    }

    private func pinned(_ pick: TileModelPick, fallback: [TileModelPick]? = nil) -> CronJob {
        job(model: pick.model, provider: pick.provider, fallback: fallback)
    }

    // MARK: Apply rules

    @Test func scriptJobsAreNeverTouched() {
        let noAgent = job(noAgent: true)
        let scriptOnly = job(prompt: "  ", script: "~/dashboards/x.refresh.py")
        for script in [noAgent, scriptOnly] {
            #expect(TileModels.isScriptOnly(script))
            #expect(TileModels.desired(script, override: astra, default: sonnet, fallback: opus, applied: nil) == nil)
        }
        // A prompt with a script ahead of it is a model's run.
        #expect(!TileModels.isScriptOnly(job(script: "~/collect.py")))
    }

    @Test func nothingPickedLeavesEveryJobAlone() {
        #expect(TileModels.desired(job(), override: nil, default: nil, fallback: nil, applied: nil) == nil)
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: nil, fallback: nil, applied: nil) == nil)
        // A fallback alone pins nothing: an unpinned job walks its bot's own chain.
        #expect(TileModels.desired(job(), override: nil, default: nil, fallback: opus, applied: nil) == nil)
    }

    @Test func aDefaultPinsAnUnpinnedJob() throws {
        let plan = try #require(TileModels.desired(job(), override: nil, default: sonnet, fallback: nil, applied: nil))
        #expect(plan.pin == sonnet)
        #expect(plan.fallback == .leave)
        #expect(plan.record == TileModelApplied(pin: sonnet, fallback: nil))
        #expect(plan.updates == ["model": "claude-sonnet-5", "provider": "anthropic"])
        #expect(plan.updates["fallback_providers"] == nil)
    }

    @Test func aPickedFallbackGoesWithThePin() throws {
        let plan = try #require(TileModels.desired(job(), override: nil, default: sonnet, fallback: opus, applied: nil))
        #expect(plan.fallback == .set(opus))
        #expect(plan.record == TileModelApplied(pin: sonnet, fallback: opus))
        #expect(plan.updates["fallback_providers"] == .array([["provider": "anthropic", "model": "claude-opus-5-5"]]))
    }

    @Test func aJobAlreadyRightGetsNoWrite() {
        let applied = TileModelApplied(pin: sonnet, fallback: nil)
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: sonnet, fallback: nil, applied: applied) == nil)
        // With the fallback it carries, as Hermes lists it.
        let withFallback = pinned(sonnet, fallback: [opus])
        let both = TileModelApplied(pin: sonnet, fallback: opus)
        #expect(TileModels.desired(withFallback, override: nil, default: sonnet, fallback: opus, applied: both) == nil)
        // A Hermes that doesn't list the field: the app's own record says it was sent.
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: sonnet, fallback: opus, applied: both) == nil)
    }

    @Test func aNewFallbackIsSentOnce() throws {
        let applied = TileModelApplied(pin: sonnet, fallback: nil)
        let plan = try #require(TileModels.desired(pinned(sonnet), override: nil, default: sonnet, fallback: opus, applied: applied))
        #expect(plan.pin == sonnet)
        #expect(plan.fallback == .set(opus))
        // Once written (the job lists it, or the record has it), nothing more.
        #expect(TileModels.desired(pinned(sonnet, fallback: [opus]), override: nil, default: sonnet, fallback: opus, applied: plan.record) == nil)
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: sonnet, fallback: opus, applied: plan.record) == nil)
        // Another fallback on the job than the one asked for: sent again.
        let other = try #require(TileModels.desired(pinned(sonnet, fallback: [haiku]), override: nil, default: sonnet, fallback: opus,
                                                    applied: plan.record))
        #expect(other.fallback == .set(opus))
    }

    @Test func aChangedDefaultMovesTheAppsPins() throws {
        let applied = TileModelApplied(pin: sonnet, fallback: nil)
        let plan = try #require(TileModels.desired(pinned(sonnet), override: nil, default: astra, fallback: nil, applied: applied))
        #expect(plan.pin == astra)
        #expect(plan.updates == ["model": "gpt-6.2-astra", "provider": "openai"])
    }

    @Test func backToEachBotsOwnTakesOnlyTheAppsPin() throws {
        let applied = TileModelApplied(pin: sonnet, fallback: nil)
        let plan = try #require(TileModels.desired(pinned(sonnet), override: nil, default: nil, fallback: nil, applied: applied))
        #expect(plan.pin == nil)
        #expect(plan.record == nil)
        #expect(plan.updates == ["model": .null, "provider": .null])
        // A pin with no record (set by hand, or by the bot) stays.
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: nil, fallback: nil, applied: nil) == nil)
    }

    @Test func unpinningTakesTheAppsFallbackToo() throws {
        let applied = TileModelApplied(pin: sonnet, fallback: opus)
        let plan = try #require(TileModels.desired(pinned(sonnet, fallback: [opus]), override: nil, default: nil, fallback: nil, applied: applied))
        #expect(plan.pin == nil)
        #expect(plan.fallback == .clear)
        #expect(plan.updates == ["model": .null, "provider": .null, "fallback_providers": .null])
    }

    @Test func eachBotsOwnFallbackTakesBackTheAppsOne() throws {
        let applied = TileModelApplied(pin: sonnet, fallback: opus)
        let plan = try #require(TileModels.desired(pinned(sonnet, fallback: [opus]), override: nil, default: sonnet, fallback: nil, applied: applied))
        #expect(plan.pin == sonnet)
        #expect(plan.fallback == .clear)
        #expect(plan.record == TileModelApplied(pin: sonnet, fallback: nil))
        // Then it's settled.
        #expect(TileModels.desired(pinned(sonnet), override: nil, default: sonnet, fallback: nil, applied: plan.record) == nil)
        // A fallback someone else put on the job (not the app's) isn't touched.
        #expect(TileModels.desired(pinned(sonnet, fallback: [haiku]), override: nil, default: sonnet, fallback: nil, applied: applied) == nil)
    }

    @Test func aHandPinIsKept() {
        // Pinned by hand before any setting: the default doesn't overwrite it.
        #expect(TileModels.desired(pinned(opus), override: nil, default: sonnet, fallback: opus, applied: nil) == nil)
        // Changed elsewhere since the app pinned it: kept too, and not taken back.
        let applied = TileModelApplied(pin: sonnet, fallback: nil)
        #expect(TileModels.desired(pinned(haiku), override: nil, default: sonnet, fallback: nil, applied: applied) == nil)
        #expect(TileModels.desired(pinned(haiku), override: nil, default: nil, fallback: nil, applied: applied) == nil)
        #expect(!TileModels.isAppPin(pinned(haiku), applied: applied))
    }

    @Test func aTilesOwnModelWins() throws {
        // Over the default, on an unpinned job.
        let plan = try #require(TileModels.desired(job(), override: astra, default: sonnet, fallback: nil, applied: nil))
        #expect(plan.pin == astra)
        // Over a hand pin: the owner chose for this tile.
        let over = try #require(TileModels.desired(pinned(opus), override: astra, default: nil, fallback: nil, applied: nil))
        #expect(over.pin == astra)
        #expect(over.record == TileModelApplied(pin: astra, fallback: nil))
        // Already on it: no write.
        #expect(TileModels.desired(pinned(astra), override: astra, default: sonnet, fallback: nil,
                                   applied: TileModelApplied(pin: astra, fallback: nil)) == nil)
        // With the account's fallback.
        let withFallback = try #require(TileModels.desired(job(), override: astra, default: nil, fallback: opus, applied: nil))
        #expect(withFallback.fallback == .set(opus))
    }

    @Test func aTileBackOnTheDefault() throws {
        // Its own model (the app's pin) goes back to the default…
        let applied = TileModelApplied(pin: astra, fallback: nil)
        let toDefault = try #require(TileModels.desired(pinned(astra), override: nil, default: sonnet, fallback: nil, applied: applied))
        #expect(toDefault.pin == sonnet)
        // …or to the bot's own when there's none.
        let toBot = try #require(TileModels.desired(pinned(astra), override: nil, default: nil, fallback: nil, applied: applied))
        #expect(toBot.pin == nil)
    }

    @Test func aPinWithoutItsProviderMatches() {
        // Hermes keeps a pin that names only the model; the provider-less side matches any.
        let bare = job(model: "claude-sonnet-5", provider: nil)
        #expect(TileModels.desired(bare, override: nil, default: sonnet, fallback: nil, applied: TileModelApplied(pin: sonnet, fallback: nil)) == nil)
        #expect(TileModelPick(provider: "", model: "x").same(TileModelPick(provider: "openai", model: "x")))
        #expect(TileModelPick(provider: "OpenAI", model: "x").same(TileModelPick(provider: "openai", model: "x")))
        #expect(!TileModelPick(provider: "anthropic", model: "x").same(TileModelPick(provider: "openai", model: "x")))
        #expect(!TileModelPick(provider: "openai", model: "x").same(TileModelPick(provider: "openai", model: "y")))
    }

    @Test func aPickWithoutAProviderSendsNull() {
        let plan = TileModels.Plan(pin: TileModelPick(provider: "", model: "local-model"), fallback: .leave, record: nil)
        #expect(plan.updates == ["model": "local-model", "provider": .null])
    }

    // MARK: The wire

    @Test func jobsReadTheirFallback() throws {
        let listed: JSONValue = ["id": "j1", "prompt": "x", "model": "gpt-6.2-astra", "provider": "openai",
                                 "fallback_providers": [["provider": "anthropic", "model": "claude-opus-5-5"], "openrouter:qwen-4"]]
        let job = try #require(CronJob(json: listed))
        #expect(job.fallbackProviders == [opus, TileModelPick(provider: "openrouter", model: "qwen-4")])
        #expect(TileModels.pin(of: job) == astra)
        #expect(CronJob(json: ["id": "j2"])?.fallbackProviders == nil)
        #expect(CronJob(json: ["id": "j3", "fallback_providers": .null])?.fallbackProviders == nil)
        #expect(CronJob(json: ["id": "j4", "fallback_providers": []])?.fallbackProviders == [])
        #expect(CronJob(json: ["id": "j5", "model": "  "]).map(TileModels.pin(of:)) == .some(nil))
        // Kept in the Jobs page's disk cache.
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(CronJob.self, from: data).fallbackProviders == job.fallbackProviders)
    }

    // MARK: Words

    @Test func theUpdatesLineNamesTheModel() {
        var hourly = job(model: astra.model, provider: astra.provider)
        hourly.schedule = CronSchedule(json: ["kind": "cron", "expr": "0 * * * *"])
        let words = TileModels.updatesSubtitle(hourly, botModel: "Opus 5.5")
        #expect(words == TileJobs.status(hourly) + " · " + TileModels.name(astra))
        #expect(words.hasSuffix(" · hourly · " + TileModels.name(astra)))
        // Unpinned: the bot's model by name.
        var bots = job()
        bots.schedule = hourly.schedule
        #expect(TileModels.updatesSubtitle(bots, botModel: "Opus 5.5").hasSuffix(" · hourly · Opus 5.5"))
        // Unknown, or a script: the status alone.
        #expect(TileModels.updatesSubtitle(bots, botModel: nil) == TileJobs.status(bots))
        var script = job(noAgent: true)
        script.schedule = hourly.schedule
        #expect(TileModels.updatesSubtitle(script, botModel: "Opus 5.5") == TileJobs.status(script))
    }

    @Test func theModelMenusWords() {
        #expect(TileModels.modelSubtitle(pinned(astra), botName: "Otto", botModel: "Opus 5.5") == TileModels.name(astra))
        #expect(TileModels.modelSubtitle(job(), botName: "Otto", botModel: "Opus 5.5") == "Opus 5.5 · Otto’s model")
        #expect(TileModels.modelSubtitle(job(), botName: "Otto", botModel: nil) == "Otto’s own model")
        #expect(TileModels.modelSubtitle(job(noAgent: true), botName: "Otto", botModel: "Opus 5.5") == "A script, no model")
        #expect(TileModels.useDefaultTitle(default: sonnet, botName: "Otto", botModel: "Opus 5.5") == "Use Tile Default (\(TileModels.name(sonnet)))")
        #expect(TileModels.useDefaultTitle(default: nil, botName: "Otto", botModel: "Opus 5.5") == "Use Tile Default (Opus 5.5)")
        #expect(TileModels.useDefaultTitle(default: nil, botName: "Otto", botModel: nil) == "Use Tile Default (Otto’s Model)")
        #expect(TileModels.runningName(job(), botModel: "  ") == nil)
    }

    @Test func theShortList() {
        let favorites = ["anthropic::claude-opus-5-5", "bad-key", "openai::gpt-6.2-astra"]
        let recents = [astra, haiku]
        let list = TileModels.shortList(favorites: favorites, recents: recents, catalog: [sonnet], keep: nil)
        // Starred first, then recents, each once; the catalog only when there are neither.
        #expect(list == [opus, astra, haiku])
        #expect(TileModels.shortList(favorites: [], recents: [], catalog: [sonnet, opus], keep: nil) == [sonnet, opus])
        // The tile's own pick is listed first, even when it's neither.
        let own = TileModelPick(provider: "openrouter", model: "qwen-4")
        #expect(TileModels.shortList(favorites: favorites, recents: [], catalog: [], keep: own) == [own, opus, astra])
        #expect(TileModels.shortList(favorites: [], recents: [], catalog: [sonnet], keep: own) == [own, sonnet])
        // At most the limit.
        let many = (1...10).map { TileModelPick(provider: "p", model: "m\($0)") }
        #expect(TileModels.shortList(favorites: [], recents: many, catalog: [], keep: nil, limit: 4).count == 4)
    }

    @Test func theSettingsWords() {
        #expect(TileModels.defaultValue(nil) == "Each Bot’s Own Model")
        #expect(TileModels.fallbackValue(nil) == "Each Bot’s Own Fallback")
        #expect(TileModels.defaultValue(sonnet) == TileModels.name(sonnet))
        // Honest about a Hermes that can't carry a fallback per job yet.
        #expect(TileModels.footer(default: sonnet, fallback: opus).contains("won’t fall back"))
        #expect(TileModels.footer(default: sonnet, fallback: nil).contains("doesn’t use its bot’s fallbacks"))
        #expect(!TileModels.footer(default: nil, fallback: nil).contains("fall back:"))
        #expect(TileModels.appliedWords(changed: 0, failed: []) == "No tile’s job needed a change.")
        #expect(TileModels.appliedWords(changed: 1, failed: []) == "1 tile’s job changed.")
        #expect(TileModels.appliedWords(changed: 3, failed: []) == "3 tiles’ jobs changed.")
        #expect(TileModels.appliedWords(changed: 2, failed: ["The gateway did not say why."])
                == "Couldn’t change 1 tile: The gateway did not say why. 2 other tiles were changed.")
        #expect(TileModels.appliedWords(changed: 0, failed: ["a", "b"]) == "Couldn’t change 2 tiles: a")
    }

    // MARK: Settings round trip

    private func freshDefaults() -> UserDefaults {
        let name = "tile-models-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func settingsRoundTrip() {
        let defaults = freshDefaults()
        let settings = TileModelSettings(accountId: "acct-1", defaults: defaults)
        #expect(settings.defaultModel == nil)
        #expect(settings.fallbackModel == nil)
        settings.defaultModel = sonnet
        settings.fallbackModel = opus
        settings.setOverride(astra, for: "otto|j1")
        settings.setApplied(TileModelApplied(pin: sonnet, fallback: opus), for: "otto|j2")
        // Read back from a new value over the same defaults (as the next launch does).
        let again = TileModelSettings(accountId: "acct-1", defaults: defaults)
        #expect(again.defaultModel == sonnet)
        #expect(again.fallbackModel == opus)
        #expect(again.override("otto|j1") == astra)
        #expect(again.override("otto|j2") == nil)
        #expect(again.applied("otto|j2") == TileModelApplied(pin: sonnet, fallback: opus))
        // Another account sees none of it.
        let other = TileModelSettings(accountId: "acct-2", defaults: defaults)
        #expect(other.defaultModel == nil && other.override("otto|j1") == nil && other.applied("otto|j2") == nil)
        // Cleared: the keys go.
        again.defaultModel = nil
        again.fallbackModel = nil
        again.setOverride(nil, for: "otto|j1")
        again.setApplied(nil, for: "otto|j2")
        #expect(again.defaultModel == nil && again.fallbackModel == nil)
        #expect(defaults.object(forKey: TileModelSettings.key("overrides", accountId: "acct-1")) == nil)
        #expect(defaults.object(forKey: TileModelSettings.key("applied", accountId: "acct-1")) == nil)
    }

    @Test func settingsDriveThePlanAndRememberTheWrite() throws {
        let defaults = freshDefaults()
        let settings = TileModelSettings(accountId: "acct-1", defaults: defaults)
        let unpinned = job("j1")
        #expect(settings.plan(unpinned) == nil)
        settings.defaultModel = sonnet
        let plan = try #require(settings.plan(unpinned))
        settings.wrote(plan, to: unpinned.key)
        #expect(settings.applied(unpinned.key) == TileModelApplied(pin: sonnet, fallback: nil))
        // The job as Hermes now lists it: settled.
        #expect(settings.plan(pinned(sonnet)) == nil)
        // Back to each bot's own: the app's pin is taken back, and forgotten once that's written.
        settings.defaultModel = nil
        let unpin = try #require(settings.plan(pinned(sonnet)))
        #expect(unpin.pin == nil)
        settings.wrote(unpin, to: unpinned.key)
        #expect(settings.applied(unpinned.key) == nil)
        // A tile's own model, by its job's key.
        settings.setOverride(astra, for: unpinned.key)
        #expect(settings.plan(unpinned)?.pin == astra)
    }

    @Test func tileModelsTravelWithTheAccountsSettings() throws {
        let key = TileModelSettings.key("default", accountId: "acct-1")
        #expect(key == "hq.tileModels.default|acct-1")
        let synced = try #require(SyncedSettingKeys.synced(key, accountId: "acct-1", library: false))
        #expect(synced == "hq.tileModels.default|{account}")
        #expect(SyncedSettingKeys.local(synced, accountId: "acct-9") == "hq.tileModels.default|acct-9")
        #expect(SyncedSettingKeys.synced(TileModelSettings.key("applied", accountId: "acct-1"), accountId: "acct-1", library: false) != nil)
        // Not another account's, and not in the library document.
        #expect(SyncedSettingKeys.synced(key, accountId: "acct-2", library: false) == nil)
        #expect(SyncedSettingKeys.synced(key, accountId: "acct-1", library: true) == nil)
        // The stored values survive the trip as the same kind of value.
        let record = TileModelApplied(pin: sonnet, fallback: opus).stored
        let encoded = try #require(SyncedDefaultsValue.encode(["otto|j1": record]))
        let decoded = SyncedDefaultsValue.decode(encoded) as? [String: Any]
        #expect(TileModelApplied(stored: decoded?["otto|j1"]) == TileModelApplied(pin: sonnet, fallback: opus))
        let pick = try #require(SyncedDefaultsValue.encode(sonnet.stored))
        #expect(TileModelPick(stored: SyncedDefaultsValue.decode(pick)) == sonnet)
    }

    @Test func tileModelIsFoundInSettingsSearch() {
        #expect(SettingsSearch.rootPages.contains { $0.target == .root("tile-model") && $0.label == "Tile Model" })
        #expect(SettingsNavigator.category(of: "tile-model") == .gateway)
    }
}
