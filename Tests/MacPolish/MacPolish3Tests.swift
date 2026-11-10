// Mac polish (2026-11-06 audit), batch 3 "Settings pages": the rules behind the fixes that are pure logic or words.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct MacPolish3Tests {
    // MARK: #98 Rows that only matter while a switch is on

    @Test func repositoryFoldersAreHeldWhileDiscoveryIsOff() {
        let off: JSONValue = ["desktop": ["repo_scan_enabled": false, "repo_scan_roots": ["~/src"]]]
        #expect(ConfigCatalog.heldNow(config: off) == ["desktop.repo_scan_roots", "desktop.repo_scan_exclude_paths"])
        let on: JSONValue = ["desktop": ["repo_scan_enabled": true]]
        #expect(ConfigCatalog.heldNow(config: on).isEmpty)
    }

    @Test func checkpointLimitIsHeldWhileCheckpointsAreOff() {
        let off: JSONValue = ["checkpoints": ["enabled": false, "max_snapshots": 50]]
        #expect(ConfigCatalog.heldNow(config: off) == ["checkpoints.max_snapshots"])
    }

    @Test func aHeldRowWhoseSwitchIsElsewhereSaysWhere() {
        #expect(ConfigCatalog.heldHelp["checkpoints.max_snapshots"] == "Turn on File Checkpoints in Safety to change it.")
        #expect(Set(ConfigCatalog.heldHelp.keys).isSubset(of: ConfigCatalog.parentSwitch.keys))
        #expect(ConfigCatalog.heldHelp["desktop.repo_scan_roots"] == nil)   // its switch is on the same card
    }

    @Test func aRecordWithoutTheSwitchHoldsNothing() {
        #expect(ConfigCatalog.heldNow(config: ["desktop": ["repo_scan_roots": ["~/src"]]]).isEmpty)
        #expect(ConfigCatalog.heldNow(config: nil).isEmpty)
    }

    @Test func apiServerKeysDependOnTheAPIServerSwitch() {
        #expect(EnvKeys.parentSwitch("API_SERVER_PORT") == "API_SERVER_ENABLED")
        #expect(EnvKeys.parentSwitch("API_SERVER_KEY") == "API_SERVER_ENABLED")
        #expect(EnvKeys.parentSwitch("API_SERVER_ENABLED") == nil)
        #expect(EnvKeys.parentSwitch("OPENAI_API_KEY") == nil)
    }

    @Test func apiServerPortIsHeldOnlyWhileTheSwitchIsKnownOff() {
        let model = EnvKeysModel(api: nil, readOnly: false)
        model.vars = [EnvVarInfo(key: "API_SERVER_ENABLED", description: "Run the API server (default: false)"),
                      EnvVarInfo(key: "API_SERVER_PORT", category: "setting")]
        #expect(model.heldOff("API_SERVER_PORT"), "unset with default false: off")
        model.vars[0] = EnvVarInfo(key: "API_SERVER_ENABLED", description: "Run the API server (default: true)")
        #expect(!model.heldOff("API_SERVER_PORT"))
        model.vars = [EnvVarInfo(key: "API_SERVER_PORT", category: "setting")]
        #expect(!model.heldOff("API_SERVER_PORT"), "no switch listed: nothing to hold it")
    }

    // MARK: #132 Settings help text

    private func list(_ key: String, _ items: [JSONValue]) -> ConfigFieldModel {
        ConfigFieldModel(key: key, label: key, description: nil, control: .list, value: .array(items), defaultValue: nil)
    }

    @Test func listCountsSayWhatTheyHoldInLowerCase() {
        #expect(ConfigRenderer.summary(list("toolsets", ["web", "terminal", "memory"])) == "3 toolsets")
        #expect(ConfigRenderer.summary(list("command_allowlist", ["ls"])) == "1 command")
        #expect(ConfigRenderer.summary(list("terminal.env_passthrough", ["PATH", "HOME"])) == "2 variables")
        #expect(ConfigRenderer.summary(list("desktop.repo_scan_roots", ["~/src"])) == "1 folder")
        #expect(ConfigRenderer.summary(list("some.other_list", ["a", "b"])) == "2 items", "a list not named: items")
        #expect(ConfigRenderer.summary(list("toolsets", [])) == "None")
    }

    @Test func helpSaysChatsBotsAndSystemDefault() {
        #expect(ConfigCopy.descriptions["display.personality"] == "Default assistant style for new chats.")
        #expect(ConfigCopy.descriptions["memory.memory_enabled"]?.hasSuffix("future chats.") == true)
        let zone = ConfigCopy.descriptions["timezone"] ?? ""
        #expect(zone.contains("Choose System Default") && !zone.contains("blank"))
        #expect(ConfigRenderer.optionLabel(key: "timezone", "") == "System Default", "the help names the list's own choice")
        #expect(AttachmentLimit.macFooter().hasSuffix("Set on this Mac for every bot."))
        #expect(!AttachmentLimit.footer().contains("profile"))
    }

    // MARK: #133 One setting, one name

    @Test func serviceTierIsFastModeOnAgentLimitsToo() {
        #expect(ConfigCopy.labels["agent.service_tier"] == "Fast Mode")
        #expect(ConfigRenderer.optionLabel(key: "agent.service_tier", "fast") == "On")
        #expect(ConfigRenderer.optionLabel(key: "agent.service_tier", "normal") == "Off")
        #expect(ConfigCatalog.page(forField: "agent.service_tier", in: "advanced")?.title == "Agent Limits")
    }

    // MARK: #90 One icon for Connectors

    @Test func connectorsWearThePlugInCapabilities() {
        #expect(CapabilitiesTab.connectors.symbol == "powerplug", "as in More and Settings › Tabs; the dotted triangle is Spawn Tree's")
        #expect(SettingsRowLabel.tiles["powerplug"] != nil, "the iOS look's tile for it")
    }
}
