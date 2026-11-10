// Gateway settings unit tests: the schema renderer's mapping (which keys a page lists and how each is drawn), the record
// edits and save payloads (`diffConfig` sparse patches, Try Again, Reset to Default), env key rules, the export file's
// redaction and the import's placeholders, search, and the diagnostics timeline. Vectors from the web app's own rules
// (`config-settings.tsx`, `helpers.ts`, `settings-ios-list.tsx`, `settings-config-file.ts`).

import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

private func schemaFixture() -> [String: ConfigFieldSchema] {
    ConfigFieldSchema.fields([
        "fields": [
            "approvals.mode": ["type": "string"],
            "approvals.timeout": ["type": "number"],
            "approvals.mcp_reload_confirm": ["type": "boolean", "description": "Ask before reloading connectors"],
            "command_allowlist": ["type": "list"],
            "timezone": ["type": "select", "searchable": true, "clearable": true, "options": ["", "Europe/London", "Asia/Tokyo"]],
            "display.personality": ["type": "string"],
            "display.show_reasoning": ["type": "boolean"],
            "agent.tool_use_enforcement": ["type": "string"],
            "agent.max_turns": ["type": "number"],
            "memory.provider": ["type": "select", "options": ["", "honcho"]],
            "compression.enabled": ["type": "boolean"],
            "voice.gpt_live.instructions": ["type": "text"],
            "fallback_providers": ["type": "list"],
        ],
    ])
}

nonisolated private let record: JSONValue = [
    "approvals": ["mode": "smart", "timeout": 60, "mcp_reload_confirm": true],
    "command_allowlist": ["ls"],
    "timezone": "Asia/Tokyo",
    "display": ["personality": "concise", "show_reasoning": false],
    "personalities": ["Pirate Captain": ["prompt": "Arr"]],
    "agent": ["max_turns": 90, "tool_use_enforcement": "auto"],
    "memory": ["provider": ""],
    "compression": ["enabled": true, "protect_last_n": 20],
    "fallback_providers": [["provider": "openrouter", "model": "deepseek/deepseek-v3.2"]],
    "terminal": ["cwd": "~/work"],
]

nonisolated private let defaults: JSONValue = [
    "approvals": ["mode": "manual", "timeout": 60, "mcp_reload_confirm": true],
    "compression": ["enabled": true, "protect_last_n": 20],
]

// MARK: - Record paths

@Suite struct ConfigPathTests {
    /// Stress test 2026-10-28 #99: only the chosen backend's image row shows.
    @Test func terminalImagesFollowTheBackend() {
        let all: Set<String> = ["terminal.docker_image", "terminal.singularity_image", "terminal.modal_image", "terminal.daytona_image"]
        #expect(ConfigCatalog.hiddenNow(config: ["terminal": ["backend": "local"]]) == all)
        #expect(ConfigCatalog.hiddenNow(config: ["terminal": ["backend": "docker"]]) == all.subtracting(["terminal.docker_image"]))
        #expect(ConfigCatalog.hiddenNow(config: nil) == all)
    }

    @Test func getsAndSetsNestedPaths() {
        #expect(ConfigPath.get(record, "approvals.mode") == "smart")
        #expect(ConfigPath.get(record, "approvals.nope") == nil)
        #expect(ConfigPath.get(record, "timezone.inner") == nil)
        let next = ConfigPath.set(record, "approvals.mode", "off")
        #expect(ConfigPath.get(next, "approvals.mode") == "off")
        #expect(ConfigPath.get(next, "approvals.timeout") == 60, "siblings kept")
        let created = ConfigPath.set(.object([:]), "a.b.c", true)
        #expect(created == ["a": ["b": ["c": true]]])
        #expect(ConfigPath.get(record, "__proto__.x") == nil, "unsafe paths are refused")
    }

    @Test func diffSendsOnlyTheChangedBranches() {
        let next = ConfigPath.set(ConfigPath.set(record, "approvals.mode", "off"), "memory.provider", "honcho")
        #expect(ConfigPath.diff(record, next) == ["approvals": ["mode": "off"], "memory": ["provider": "honcho"]])
        #expect(ConfigPath.diff(record, record) == .object([:]))
        // Arrays go whole.
        let list = ConfigPath.set(record, "command_allowlist", ["ls", "pwd"])
        #expect(ConfigPath.diff(record, list) == ["command_allowlist": ["ls", "pwd"]])
        // A new key goes; a new null doesn't.
        #expect(ConfigPath.diff(record, ConfigPath.set(record, "sessions.auto_archive", true)) == ["sessions": ["auto_archive": true]])
        #expect(ConfigPath.diff(record, ConfigPath.set(record, "nothing", .null)) == .object([:]))
    }

    @Test func mergeLaysAPatchOverTheRecord() {
        let merged = ConfigPath.merge(record, ["approvals": ["mode": "off"], "new": 1])
        #expect(ConfigPath.get(merged, "approvals.mode") == "off")
        #expect(ConfigPath.get(merged, "approvals.timeout") == 60)
        #expect(ConfigPath.get(merged, "new") == 1)
    }

    @Test func clearingEnabledToolsetsIsCaught() {
        #expect(ConfigPath.clearsEnabledToolsets(["toolsets": ["web"]], ["toolsets": []]))
        #expect(!ConfigPath.clearsEnabledToolsets(["toolsets": ["web"]], ["other": 1]), "a missing key keeps them")
        #expect(!ConfigPath.clearsEnabledToolsets(["toolsets": []], ["toolsets": []]))
    }
}

// MARK: - The renderer

@Suite struct ConfigRendererTests {
    @Test func approvalsPageListsItsFieldsInOrderWithTheirControls() throws {
        let page = try #require(ConfigCatalog.page("safety.approvals"))
        let fields = ConfigRenderer.fields(page: page, schema: schemaFixture(), config: record, defaults: defaults)
        #expect(fields.map(\.key) == ["approvals.mode", "approvals.timeout", "approvals.mcp_reload_confirm", "command_allowlist"])
        #expect(fields[0].control == .choice(options: ["manual", "smart", "off"], free: false, searchable: false))
        #expect(fields[0].label == "Approval Mode")
        #expect(fields[0].description == "How Hermes handles commands that need your approval.")
        #expect(fields[1].control == .number)
        #expect(fields[2].control == .toggle)
        #expect(fields[2].description == nil, "round 2: the label now says what the schema's description said, so it isn't repeated")
        #expect(fields[3].control == .list)
        #expect(fields[0].canReset, "smart differs from the default manual")
        #expect(!fields[1].canReset, "60 is the default")
        #expect(fields[3].defaultValue == nil && !fields[3].canReset, "no default, no reset")
    }

    @Test func keysTheSchemaOmitsAreInferredFromTheRecord() throws {
        let page = try #require(ConfigCatalog.page("memory.context"))
        let fields = ConfigRenderer.fields(page: page, schema: schemaFixture(), config: record)
        let protect = try #require(fields.first { $0.key == "compression.protect_last_n" })
        #expect(protect.control == .number, "a number in the record draws a number field")
        #expect(protect.label == "Protected Recent Messages")
        #expect(!fields.contains { $0.key == "compression.threshold" }, "neither in the schema nor the record: not shown")
    }

    @Test func timezoneIsASearchableChoiceKeepingTheCurrentValue() {
        var field = ConfigRenderer.model(key: "timezone", schema: schemaFixture()["timezone"]!, value: "Mars/Olympus", config: record, defaults: nil)
        #expect(field.control == .choice(options: ["", "Europe/London", "Asia/Tokyo", "Mars/Olympus"], free: false, searchable: true))
        field.value = ""
        #expect(ConfigRenderer.optionLabel(key: "timezone", "") == "System Default")
        #expect(ConfigRenderer.optionLabel(key: "timezone", "Asia/Tokyo") == "Tokyo (Asia)", "zone ids read as words (Mac UX stress test #59)")
        #expect(ConfigRenderer.optionLabel(key: "timezone", "America/New_York") == "New York (America)")
        #expect(ConfigRenderer.optionLabel(key: "timezone", "Etc/UTC") == "UTC")
    }

    @Test func personalityChoicesIncludeTheRecordsOwn() {
        let options = ConfigRenderer.options(key: "display.personality", schema: ConfigFieldSchema(kind: .string), value: "concise", config: record)
        #expect(options?.first == "")
        #expect(options?.contains("pirate captain") == true, "a custom personality, folded as the runtime folds it")
        #expect(ConfigRenderer.optionLabel(key: "display.personality", "") == "None")
    }

    @Test func toolUseEnforcementWritesBooleansForEveryModelAndNever() {
        let field = ConfigRenderer.model(key: "agent.tool_use_enforcement", schema: schemaFixture()["agent.tool_use_enforcement"]!,
                                         value: "auto", config: record, defaults: nil)
        #expect(field.control == .choice(options: ["auto", "true", "false"], free: false, searchable: false))
        #expect(ConfigRenderer.choiceValue(key: field.key, "true", current: field.value) == .bool(true))
        #expect(ConfigRenderer.choiceValue(key: field.key, "auto", current: field.value) == "auto")
        #expect(ConfigRenderer.optionLabel(key: field.key, "true") == "Every Model")
    }

    /// Stress test 2026-10-28 #100: Service Tier is a Normal/Fast choice; a value the app doesn't know stays a choice.
    @Test func serviceTierIsAChoice() {
        let plain = ConfigFieldSchema(kind: .string, description: "Provider service tier (normal or fast)")
        #expect(ConfigRenderer.control(key: "agent.service_tier", schema: plain, value: "normal", config: record)
                == .choice(options: ["normal", "fast"], free: false, searchable: false))
        #expect(ConfigRenderer.control(key: "agent.service_tier", schema: plain, value: "priority", config: record)
                == .choice(options: ["normal", "fast", "priority"], free: false, searchable: false))
        #expect(ConfigRenderer.description(key: "agent.service_tier", schema: plain, label: "Service Tier")?.contains("normal or fast") == false)
        #expect(ConfigCopy.labels["memory.memory_enabled"] != "Persistent Memory", "the switch isn't named like its page")
    }

    @Test func controlsForTheOtherKinds() {
        let schema = schemaFixture()
        #expect(ConfigRenderer.control(key: "voice.gpt_live.instructions", schema: schema["voice.gpt_live.instructions"]!, value: "x", config: record) == .longText)
        #expect(ConfigRenderer.control(key: "providers", schema: ConfigFieldSchema(kind: .string), value: ["a": 1], config: record) == .json)
        #expect(ConfigRenderer.control(key: "terminal.cwd", schema: ConfigFieldSchema(kind: .string), value: "~/work", config: record) == .text)
        #expect(ConfigRenderer.control(key: "terminal.cwd", schema: ConfigFieldSchema(kind: .string), value: .string(String(repeating: "a", count: 101)),
                                       config: record) == .longText, "a long string gets the big editor")
        #expect(ConfigRenderer.control(key: "fallback_providers", schema: schema["fallback_providers"]!, value: nil, config: record) == .fallbackModels)
        #expect(ConfigRenderer.control(key: "memory.provider", schema: schema["memory.provider"]!, value: "", config: record)
                == .choice(options: ["", "honcho"], free: false, searchable: false), "the schema's own options")
        // [talk] Settings › Voice now knows the OpenAI voices (docs/spec/3x-talk.md §9.3); DeepInfra's stay open text.
        #expect(ConfigRenderer.control(key: "tts.deepinfra.voice", schema: ConfigFieldSchema(kind: .string), value: "nova", config: record) == .text,
                "no options known: a text field")
    }

    @Test func numbersAndListsParseAsTheWebsFieldsDo() {
        #expect(ConfigRenderer.numberValue("") == .number(0), "empty means 0")
        #expect(ConfigRenderer.numberValue("1,500") == .number(1500))
        #expect(ConfigRenderer.numberValue("abc") == nil)
        #expect(ConfigRenderer.listValue(" ls, git status ,,pwd") == ["ls", "git status", "pwd"])
    }

    @Test func everyCatalogPageResolvesItsKeys() {
        for section in ConfigCatalog.sections {
            for key in section.keys {
                #expect(ConfigCatalog.page(forField: key, in: section.id) != nil, "\(key) has a page in \(section.id)")
            }
        }
        #expect(ConfigCatalog.page(forField: "agent.service_tier", in: "advanced")?.id == "runtime")
        #expect(ConfigCatalog.page(forField: "checkpoints.max_snapshots", in: "advanced")?.id == "output")
        #expect(ConfigCatalog.page(forField: "checkpoints.enabled", in: "safety")?.id == "checkpoints")
    }

    @Test func fallbackModelsReadBothShapesAndWriteObjects() {
        let list = FallbackModel.list([["provider": "openrouter", "model": "a"], "anthropic:claude"])
        #expect(list == [FallbackModel(provider: "openrouter", model: "a"), FallbackModel(provider: "anthropic", model: "claude")])
        #expect(FallbackModel.value(list) == [["provider": "openrouter", "model": "a"], ["provider": "anthropic", "model": "claude"]])
    }

    @Test func gatewayDefaultsReadAsTheWebReadsThem() {
        #expect(ConfigCopy.resumeLastSession(.object([:])), "on unless the record says false")
        #expect(!ConfigCopy.resumeLastSession(["display": ["resume_last_session": false]]))
        #expect(ConfigCopy.isFastTier("priority") && ConfigCopy.isFastTier("FAST") && !ConfigCopy.isFastTier("normal"))
        #expect(ConfigCopy.reasoningEffort(false) == "none" && ConfigCopy.reasoningEffort(nil) == "medium")
    }
}

// MARK: - The store's save payloads

@MainActor @Suite(.serialized) struct GatewayConfigStoreTests {
    private func makeStore(_ client: PagesFakeClient, readOnly: Bool = false) -> GatewayConfigStore {
        let store = GatewayConfigStore(api: GatewaySettingsAPI(client: client), readOnly: readOnly)
        store.debounce = .milliseconds(20)
        return store
    }

    nonisolated private static func answer(_ request: PagesFakeClient.Request) -> JSONValue {
        switch (request.method, request.path) {
        case ("GET", "/api/config"): record
        case ("GET", "/api/config/schema"): ["fields": ["approvals.mode": ["type": "string"]]]
        case ("GET", "/api/config/defaults"): defaults
        default: ["ok": true]
        }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func editsAreDebouncedIntoOneSparsePut() async {
        let client = PagesFakeClient { Self.answer($0) }
        let store = makeStore(client)
        await store.load()
        #expect(store.phase == .loaded)
        store.set("approvals.mode", "off")
        store.set("approvals.timeout", 30)
        store.set("display.show_reasoning", true)
        await waitFor { client.log.contains { $0.method == "PUT" } }
        try? await Task.sleep(for: .milliseconds(60))
        let puts = client.log.filter { $0.method == "PUT" }
        #expect(puts.count == 1, "one save for three quick edits: \(client.logLines)")
        #expect(puts.first?.path == "/api/config")
        #expect(puts.first?.body == ["config": ["approvals": ["mode": "off", "timeout": 30], "display": ["show_reasoning": true]]],
                "only what changed, under `config`")
        // The next edit diffs against what was saved.
        store.set("approvals.mode", "manual")
        await waitFor { client.log.filter { $0.method == "PUT" }.count == 2 }
        #expect(client.log.filter { $0.method == "PUT" }.last?.body == ["config": ["approvals": ["mode": "manual"]]])
    }

    @Test func aRefusedSaveShowsTheSavedValueAndTryAgainResends() async {
        let fail = Mutex(true)
        let client = PagesFakeClient { request in
            if request.method == "PUT", fail.withLock({ $0 }) { throw httpError(500, "disk full") }
            return Self.answer(request)
        }
        let store = makeStore(client)
        await store.load()
        store.set("approvals.mode", "off")
        await waitFor { store.failure != nil }
        #expect(store.failure?.text == "disk full", "the gateway's own words")
        #expect(store.value("approvals.mode") == "smart", "the page shows the saved value again")
        #expect(store.failure?.patch == ["approvals": ["mode": "off"]])
        fail.withLock { $0 = false }
        store.retry()
        #expect(store.value("approvals.mode") == "off")
        await waitFor { client.log.filter { $0.method == "PUT" }.count == 2 && store.saving == 0 }
        #expect(store.failure == nil)
        #expect(client.log.filter { $0.method == "PUT" }.last?.body == ["config": ["approvals": ["mode": "off"]]])
    }

    @Test func resetWritesTheDefault() async {
        let client = PagesFakeClient { Self.answer($0) }
        let store = makeStore(client)
        await store.load()
        #expect(store.field("approvals.mode")?.canReset == true)
        store.reset("approvals.mode")
        await waitFor { client.log.contains { $0.method == "PUT" } }
        #expect(client.log.first { $0.method == "PUT" }?.body == ["config": ["approvals": ["mode": "manual"]]])
    }

    // [13-2] Import Settings / Reset to Defaults: the read after the write used to be skipped (the write's own save was
    // still counted), so the pages kept the old values, and the next edit was diffed against the old record.
    @Test func importOrResetShowsTheNewRecordAtOnce() async {
        let server = Mutex(record)
        let client = PagesFakeClient { request in
            if request.method == "PUT", let patch = request.body?["config"] {
                server.withLock { $0 = ConfigPath.merge($0, patch) }
                return ["ok": true]
            }
            if request.method == "GET", request.path == "/api/config" { return server.withLock { $0 } }
            return Self.answer(request)
        }
        let store = makeStore(client)
        await store.load()
        #expect(store.value("approvals.mode") == "smart")
        let epoch = store.epoch
        try? await store.write(["approvals": ["mode": "manual"], "display": ["show_reasoning": true]])
        #expect(store.value("approvals.mode") == "manual", "the pages show what was written")
        #expect(store.value("display.show_reasoning") == true)
        #expect(store.epoch == epoch + 1)
        let reads = client.log.filter { $0.method == "GET" && $0.path == "/api/config" }.count
        #expect(reads == 2, "the record was read again after the write: \(client.logLines)")
        // The next edit is diffed against the new record: nothing old goes back.
        store.set("approvals.timeout", 45)
        await waitFor { client.log.filter { $0.method == "PUT" }.count == 2 }
        #expect(client.log.filter { $0.method == "PUT" }.last?.body == ["config": ["approvals": ["timeout": 45]]])
    }

    @Test func aReadOnlyGatewayRefusesWithoutSending() async {
        let client = PagesFakeClient { Self.answer($0) }
        let store = makeStore(client, readOnly: true)
        await store.load()
        store.set("approvals.mode", "off")
        await waitFor { store.failure != nil }
        #expect(store.failure?.text == BotWriteError.readOnlyReason)
        #expect(!client.log.contains { $0.method == "PUT" })
    }

    @Test func aFailedLoadSaysWhy() async {
        let client = PagesFakeClient { _ in throw httpError(404, "Not Found") }
        let store = makeStore(client)
        await store.load()
        #expect(store.phase == .failed(MoreWire.olderHermes))
    }

    @Test func defaultsAreAskedAlongsideTheRecord() async {
        // Each GET takes 150 ms: in a row the page would wait 300 ms, side by side the slower one.
        let client = PagesFakeClient { request in
            try await Task.sleep(for: .milliseconds(150))
            return Self.answer(request)
        }
        let store = makeStore(client)
        let clock = ContinuousClock()
        let took = await clock.measure { await store.load() }
        #expect(store.phase == .loaded)
        #expect(store.field("approvals.mode")?.canReset == true, "defaults are in when load returns")
        #expect(took < .milliseconds(280), "defaults overlapped the record: \(took)")
    }

    @Test func loadsAtTheSameTimeShareOneRead() async {
        let client = PagesFakeClient { request in
            try await Task.sleep(for: .milliseconds(50))
            return Self.answer(request)
        }
        let store = makeStore(client)
        await store.load()
        #expect(client.log.filter { $0.path == "/api/config" }.count == 1)
        // A stale reload keeps phase .loaded; three askers at once still send one read.
        async let a: Void = store.load(force: true)
        async let b: Void = store.load(force: true)
        async let c: Void = store.load(force: true)
        _ = await (a, b, c)
        #expect(client.log.filter { $0.path == "/api/config" }.count == 2, "\(client.logLines)")
        // Once it landed, the next forced load reads again.
        await store.load(force: true)
        #expect(client.log.filter { $0.path == "/api/config" }.count == 3)
    }

    @Test func missingDefaultsStillShowThePage() async {
        let client = PagesFakeClient { request in
            if request.path == "/api/config/defaults" { throw httpError(404, "Not Found") }
            return Self.answer(request)
        }
        let store = makeStore(client)
        await store.load()
        #expect(store.phase == .loaded)
        #expect(store.defaults == nil)
        #expect(store.config != nil)
    }
}

// MARK: - Keys

@Suite struct EnvKeysTests {
    @Test func platformAndToolLabels() {
        #expect(EnvKeys.keyLabel("TELEGRAM_ALLOW_ALL_USERS") == "Telegram: Allow All Users")
        #expect(EnvKeys.keyLabel("DISCORD_REQUIRE_MENTION") == "Discord: Require Mention")
        #expect(EnvKeys.keyLabel("SLACK_THREAD_REQUIRE_MENTION") == "Slack: Require Mention in Threads")
        #expect(EnvKeys.keyLabel("GOOGLE_CHAT_HOME_CHANNEL") == "Google Chat: Home Channel")
        #expect(EnvKeys.keyLabel("BRV_API_KEY") == "ByteRover")
        #expect(EnvKeys.keyLabel("HERMES_LANGFUSE_SECRET_KEY") == "Langfuse Secret Key")
        #expect(EnvKeys.keyLabel("SEARXNG_URL") == "SearXNG URL")
        #expect(EnvKeys.keyLabel("OPENAI_API_KEY") == nil)
        #expect(EnvKeys.title(EnvVarInfo(key: "FIRECRAWL_API_KEY")) == "Firecrawl API Key")
        // Mac UX stress test #59: provider keys read as the provider, not the variable.
        #expect(EnvKeys.title(EnvVarInfo(key: "OPENROUTER_API_KEY")) == "OpenRouter API Key")
        #expect(EnvKeys.title(EnvVarInfo(key: "OPENAI_BASE_URL")) == "OpenAI Base URL")
        #expect(EnvKeys.title(EnvVarInfo(key: "ANTHROPIC_API_KEY")) == "Anthropic API Key")
    }

    @Test func switchesAndTheirState() {
        let allow = EnvVarInfo(key: "TELEGRAM_ALLOW_ALL_USERS", description: "Let anyone message (true/false, default: false)")
        #expect(EnvKeys.isSwitch(allow))
        #expect(EnvKeys.switchState(allow, known: nil) == nil, "unset Allow All Users defers to config.yaml")
        let server = EnvVarInfo(key: "API_SERVER_ENABLED", description: "Run the API server (default: false)")
        #expect(EnvKeys.isSwitch(server))
        #expect(EnvKeys.switchState(server, known: nil) == false, "unset: its default")
        var set = server
        set.isSet = true
        #expect(EnvKeys.switchState(set, known: nil) == nil, "set but redacted: unknown until Show")
        #expect(EnvKeys.switchState(set, known: EnvKeys.bool("yes")) == true)
        #expect(EnvKeys.switchRemoves(server, to: false), "back to its default removes the key")
        #expect(!EnvKeys.switchRemoves(allow, to: false), "Allow All Users is always written")
        #expect(!EnvKeys.isSwitch(EnvVarInfo(key: "X_TOKEN", description: "true/false", isPassword: true)), "a password is never a switch")
        #expect(EnvKeys.switchDescription("Let anyone message (true/false, default: false)") == "Let anyone message (off by default)")
        #expect(EnvKeys.unknownNote(set, revealed: "maybe") == "Set to “maybe”.")
    }

    @Test func pagesSortKeysAndHideTheWakeWord() {
        let vars = [EnvVarInfo(key: "FIRECRAWL_API_KEY", category: "tool"), EnvVarInfo(key: "PORCUPINE_ACCESS_KEY", category: "tool"),
                    EnvVarInfo(key: "TELEGRAM_BOT_TOKEN", category: "messaging", channelManaged: true),
                    EnvVarInfo(key: "API_SERVER_PORT", category: "setting"), EnvVarInfo(key: "ANTHROPIC_API_KEY", category: "provider"),
                    EnvVarInfo(key: "KIMI_CN_API_KEY", category: "provider")]
        #expect(EnvKeys.toolKeys(vars).map(\.key) == ["FIRECRAWL_API_KEY"])
        #expect(EnvKeys.otherKeys(vars).map(\.key) == ["API_SERVER_PORT"])
        #expect(EnvKeys.groupedProviders(vars).map(\.name) == ["Anthropic", "Kimi (China)"], "longest prefix wins")
        #expect(EnvKeys.preview("«redacted:sk-a...0000»") == "sk-a...0000")
        #expect(EnvKeys.preview("«redacted»") == "••••••••")
        // Stress test 2026-10-28 #84: a plain setting's clipped value ("86…") isn't shown; a secret keeps its preview.
        #expect(EnvKeys.rowPreview(EnvVarInfo(key: "API_SERVER_PORT", isSet: true, redactedValue: "«redacted:86…»")) == nil)
        #expect(EnvKeys.rowPreview(EnvVarInfo(key: "X_API_KEY", isPassword: true, isSet: true, redactedValue: "«redacted:sk-a...0000»")) == "sk-a...0000")
    }

    /// Stress test 2026-10-28 #84, round 2: set numbers and on/offs are read so their rows show the value; secrets and
    /// text never are.
    @Test func plainValuesAreReadOnOpen() {
        #expect(EnvKeys.readsValueItself(EnvVarInfo(key: "API_SERVER_PORT", isSet: true)))
        #expect(EnvKeys.readsValueItself(EnvVarInfo(key: "DISCORD_REQUIRE_MENTION", isSet: true)))
        #expect(!EnvKeys.readsValueItself(EnvVarInfo(key: "API_SERVER_PORT")), "not set: nothing to read")
        #expect(!EnvKeys.readsValueItself(EnvVarInfo(key: "GATEWAY_PROXY_URL", isSet: true)), "text can carry a password")
        #expect(!EnvKeys.readsValueItself(EnvVarInfo(key: "X_TIMEOUT", isPassword: true, isSet: true)))
        #expect(EnvKeys.title(EnvVarInfo(key: "API_SERVER_ENABLED")) == "API Server")
        #expect(EnvKeys.title(EnvVarInfo(key: "FAL_KEY")) == "FAL Key")
        #expect(EnvKeys.switchDescription("Run the OpenAI-compatible API server (default: false)")
                == "Let other apps use your bots the way they use OpenAI’s API (off by default)")
    }
}

// MARK: - Export / Import

@Suite struct SettingsFileTests {
    private let config: JSONValue = [
        "providers": ["openrouter": ["api_key": "sk-fixture-openrouter-not-real-0000", "api_key_env": "OPENROUTER_API_KEY"]],
        "mcp_servers": [
            "github": ["url": "https://api.example.invalid/mcp/?token=abc123&mode=x", "headers": ["Authorization": "Bearer fixture-1", "Accept": "application/json"]],
            "files": ["command": "npx", "args": ["files-mcp", "--api-key", "fixture-files-key", "--port", "3000"], "env": ["FILES_TOKEN": "${FILES_TOKEN}"]],
        ],
        "approvals": ["mode": "smart", "timeout": 60],
        "display": ["personality": "concise"],
    ]

    @Test func exportLeavesCredentialsOut() {
        let out = SettingsFile.redact(config)
        let p = SettingsFile.placeholder
        #expect(ConfigPath.get(out, "providers.openrouter.api_key") == .string(p))
        #expect(ConfigPath.get(out, "providers.openrouter.api_key_env") == "OPENROUTER_API_KEY", "a variable's name stays")
        #expect(ConfigPath.get(out, "mcp_servers.github.headers.Authorization") == .string(p))
        #expect(ConfigPath.get(out, "mcp_servers.github.headers.Accept") == "application/json")
        #expect(ConfigPath.get(out, "mcp_servers.github.url")?.string?.contains("token=\(p)") == true)
        #expect(ConfigPath.get(out, "mcp_servers.github.url")?.string?.contains("mode=x") == true)
        #expect(ConfigPath.get(out, "mcp_servers.files.args") == ["files-mcp", "--api-key", .string(p), "--port", "3000"])
        #expect(ConfigPath.get(out, "mcp_servers.files.env.FILES_TOKEN") == "${FILES_TOKEN}", "references stay")
        #expect(ConfigPath.get(out, "approvals") == ["mode": "smart", "timeout": 60], "settings untouched")
    }

    @Test func importKeepsTheGatewaysSecretsAndWritesOnlyChanges() {
        var file = SettingsFile.redact(config)
        file = ConfigPath.set(file, "approvals.mode", "off")
        let patch = SettingsFile.importPatch(file: file, current: config)
        #expect(patch == ["approvals": ["mode": "off"]], "placeholders never overwrite; only the change is sent: \(patch)")
    }

    @Test func fileNameSaysWhoAndWhen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_763_200)   // 2026-10-12
        #expect(SettingsFile.exportFileName(profile: "Hermes", now: date, calendar: calendar) == "Hermes settings 2026-10-12.json")
        #expect(SettingsFile.exportFileName(profile: "a/b:c", now: date, calendar: calendar) == "a b c settings 2026-10-12.json")
        #expect(SettingsFile.exportFileName(profile: "  ", now: date, calendar: calendar).hasPrefix("Hermes settings"))
    }
}

// MARK: - Search

@Suite struct SettingsSearchTests {
    @Test func everyWordMustMatchAndPagesComeFirst() {
        let index = SettingsSearch.index()
        let approval = SettingsSearch.results("approval", in: index)
        #expect(approval.first?.label == "Approvals", "the page before its fields: \(approval.map(\.label))")
        #expect(approval.contains { $0.label == "Approval Mode" })
        #expect(SettingsSearch.results("approval timeout", in: index).map(\.label) == ["Approval Timeout"])
        #expect(SettingsSearch.results("keychain", in: index).first?.label == "Saved Sign-In (iOS Keychain)")
        #expect(SettingsSearch.results("janky", in: index).first?.target == .root("about"))
        #expect(SettingsSearch.results("export", in: index).first?.target == .action("export"))
        #expect(SettingsSearch.results("   ", in: index).isEmpty)
        #expect(SettingsSearch.results("zzzz", in: index).isEmpty)
        #expect(SettingsSearch.results("reopen", in: index).first?.label == "Reopen Last Chat on Launch")
    }

    @Test func resultsAreUniquePerLabelAndPlace() {
        let entries = [SettingsSearchEntry(id: "a", label: "X", context: "Y", target: .root("a")),
                       SettingsSearchEntry(id: "b", label: "x", context: "y", target: .root("b"))]
        #expect(SettingsSearch.results("x", in: entries).count == 1)
    }
}

// MARK: - Diagnostics

@Suite struct DiagnosticsTimelineTests {
    @Test func errorsFoldAndRedact() {
        let timeline = DiagnosticsTimeline(processStart: Date(timeIntervalSince1970: 0))
        timeline.record(category: "error", message: "load: HTTP 500", at: Date(timeIntervalSince1970: 1))
        timeline.record(category: "error", message: "fetch https://host.example/x?token=abc failed", at: Date(timeIntervalSince1970: 2))
        timeline.record(category: "error", message: "load: HTTP 500", at: Date(timeIntervalSince1970: 3))
        let errors = timeline.recentErrors()
        #expect(errors.count == 2)
        #expect(errors[0].message == "load: HTTP 500" && errors[0].count == 2, "newest first, repeats folded")
        #expect(errors[1].message == "fetch https://host.example/x?[redacted] failed", "a URL keeps its path and loses its query: \(errors[1].message)")
    }
}
