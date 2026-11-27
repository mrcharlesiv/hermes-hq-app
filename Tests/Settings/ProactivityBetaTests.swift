import Foundation
import Testing
@testable import HermesHQNative

@Suite("Proactivity Beta")
struct ProactivityBetaTests {
    @Test func statusDecodesOffByDefaultPayload() throws {
        let json = """
        {
          "plugin": "hermes-hq-proactive",
          "version": "0.1.0-beta.1",
          "beta": true,
          "enabled": false,
          "autonomy_mode": "prep",
          "quiet_hours_active": false,
          "budgets": {"offers_used_24h": 0, "offers_limit_24h": 6, "interrupts_used_24h": 0, "interrupts_limit_24h": 2},
          "counts": {"pending_offers": 0, "open_loops": 0, "snoozed_loops": 0, "active_watches": 0},
          "settings": {
            "enabled": false,
            "autonomy_mode": "prep",
            "quiet_start": "22:00",
            "quiet_end": "08:00",
            "in_turn_enabled": true,
            "loop_radar_enabled": true,
            "idle_sweep_enabled": true,
            "daily_brief_enabled": true,
            "pattern_detection_enabled": true,
            "allow_llm_in_sweep": true
          }
        }
        """
        let status = try ProactivityBeta.Status.parse(Data(json.utf8))
        #expect(status.beta == true)
        #expect(status.enabled == false)
        #expect(status.autonomyMode == .prep)
        #expect(status.offersLimit24h == 6)
        #expect(status.quietStart == "22:00")
        #expect(status.quietEnd == "08:00")
    }

    @Test func statusDecodesActiveFullModeAndCounts() throws {
        let json = """
        {
          "version": "0.1.0-beta.1",
          "beta": true,
          "enabled": true,
          "autonomy_mode": "full",
          "quiet_hours_active": true,
          "budgets": {"offers_used_24h": 3, "offers_limit_24h": 8, "interrupts_used_24h": 1, "interrupts_limit_24h": 2},
          "counts": {"pending_offers": 2, "open_loops": 5, "snoozed_loops": 1, "active_watches": 3},
          "settings": {"in_turn_enabled": true, "loop_radar_enabled": false, "idle_sweep_enabled": true}
        }
        """
        let status = try ProactivityBeta.Status.parse(Data(json.utf8))
        #expect(status.enabled == true)
        #expect(status.autonomyMode == .full)
        #expect(status.quietHoursActive == true)
        #expect(status.offersUsed24h == 3)
        #expect(status.pendingOffers == 2)
        #expect(status.openLoops == 5)
        #expect(status.loopRadarEnabled == false)
    }

    @Test func routeMissingDetectsHermesPluginNotFoundAndFastAPI404() {
        #expect(ProactivityBetaAPI.isRouteMissing(HTTPError(status: 404, body: #"{"detail":"Plugin not found"}"#)) == true)
        #expect(ProactivityBetaAPI.isRouteMissing(HTTPError(status: 404, body: #"{"detail":"Not Found"}"#)) == true)
        #expect(ProactivityBetaAPI.isRouteMissing(HTTPError(status: 404, body: nil)) == true)
        #expect(ProactivityBetaAPI.isRouteMissing(HTTPError(status: 500, body: "boom")) == false)
    }

    @Test func errorWordsSurfacesHTTPDetailInsteadOfGenericUnreachable() {
        #expect(ProactivityBetaAPI.errorWords(HTTPError(status: 502, body: #"{"detail":"Plugin host restarting"}"#)) == "Plugin host restarting")
        #expect(ProactivityBetaAPI.errorWords(HTTPError(status: 503, body: "")) == "Hermes answered HTTP 503.")
    }

    @Test func profileQueryOmitsDefaultAndIncludesNamedBot() {
        #expect(ProactivityBetaAPI.profileQuery("default").isEmpty)
        #expect(ProactivityBetaAPI.profileQuery("otto") == [URLQueryItem(name: "profile", value: "otto")])
    }

    @Test func settingsSearchFindsProactivityBeta() {
        let entries = SettingsSearch.index(schema: [:])
        for query in ["proactive", "proactivity", "open loops", "daily brief"] {
            let hits = SettingsSearch.results(query, in: entries)
            #expect(hits.contains { $0.target == .root("proactivity-beta") && $0.label == "Proactivity (Beta)" })
        }
    }
}
