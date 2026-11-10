// [hub] The Skills Hub search on the Skills tab (the desktop's HubSkillsSection): results decoded with where they come
// from and how far Hermes trusts that source, official ones left to "Available from Hermes", an older gateway
// without the route hiding the row, and Get installing the hub identifier for the bot.

import Foundation
import Testing
@testable import HermesHQNative

@Suite(.serialized) @MainActor struct SkillsHubTests {
    nonisolated static let hubJSON = #"""
    {"results":[
      {"name":"maps","description":"Maps","source":"official","identifier":"official/maps","trust_level":"builtin","repo":null,"tags":[]},
      {"name":"pdf-forms","description":"Fill PDF forms","source":"github","identifier":"anthropics/skills/pdf-forms","trust_level":"trusted","repo":"anthropics/skills","tags":[]},
      {"name":"pdf-redact","description":"Redact PDFs","source":"skills-sh","identifier":"skills-sh/pdf-redact","trust_level":"community","repo":null,"tags":[]},
      {"name":"notes","description":"Take notes","source":"clawhub","identifier":"clawhub/notes","trust_level":"community","repo":null,"tags":[]},
      {"name":"dupe","description":"","source":"github","identifier":"skills-sh/pdf-redact","trust_level":"community"}
    ],"source_counts":{},"timed_out":[],"installed":{"clawhub/notes":{"name":"notes"}}}
    """#

    func script(hub: Bool = true) -> BotsFakeGatewayClient {
        let client = BotsFakeGatewayClient()
        client.onREST { _, path, _, _ in
            switch path {
            case "/api/skills": return Data(CapabilitiesSpeedTests.skillsJSON.utf8)
            case "/api/skills/hub/official": return Data(CapabilitiesSpeedTests.officialJSON.utf8)
            case "/api/skills/hub/search" where hub: return Data(Self.hubJSON.utf8)
            default: throw HTTPError(status: 404, body: #"{"detail":"Not Found"}"#)
            }
        }
        return client
    }

    func model(_ client: BotsFakeGatewayClient) -> CapabilitiesModel {
        CapabilitiesModel(services: CapabilitiesFakeServices(CapabilitiesStore(client: client)), profile: "ivy", tab: .skills)
    }

    @Test func decodesTrustAndSource() throws {
        let found = try CapabilitiesStore.decodeHub(Data(Self.hubJSON.utf8))
        #expect(found.results.map(\.identifier) == ["official/maps", "anthropics/skills/pdf-forms", "skills-sh/pdf-redact", "clawhub/notes"])
        #expect(found.installed == ["clawhub/notes"])
        let forms = found.results[1], redact = found.results[2]
        #expect(!forms.isCommunity && forms.trustWord == "Trusted" && forms.provenance == "Trusted · GitHub · anthropics/skills")
        #expect(redact.isCommunity && redact.trustWord == "Community" && redact.provenance == "Community · skills.sh")
        #expect(found.results[0].trustWord == "Built-in" && found.results[0].sourceWord == "Official (Nous)")
    }

    @Test func searchShowsHubSkillsForWhatIsTyped() async {
        let client = script()
        let model = model(client)
        await model.reloadSkills()
        model.query = " pdf "
        #expect(model.shownHub == nil, "nothing searched yet")
        model.searchHub()
        #expect(await eventually { model.shownHub != nil })
        let call = client.restCalls.first { $0.path == "/api/skills/hub/search" }
        #expect(call?.query.contains(URLQueryItem(name: "q", value: "pdf")) == true)
        #expect(call?.query.contains(URLQueryItem(name: "profile", value: "ivy")) == true)
        // The official one is already under "Available from Hermes".
        #expect(model.shownHub?.map(\.name) == ["pdf-forms", "pdf-redact", "notes"])
        #expect(model.shownHub.map { $0.filter(model.hubIsInstalled).map(\.name) } == ["notes"])
        // Results belong to the words searched.
        model.query = "pdfs"
        #expect(model.shownHub == nil)
        model.query = "pdf"
        #expect(model.shownHub != nil)
        // Another bot: gone.
        model.profile = "kim"
        #expect(model.shownHub == nil && model.hubResults == nil)
    }

    @Test func anOlderGatewayHidesTheHub() async {
        let client = script(hub: false)
        let model = model(client)
        model.query = "pdf"
        model.searchHub()
        #expect(await eventually { model.hubUnsupported })
        #expect(model.hubError == nil && !model.hubSearching)
    }

    @Test func anotherBotIsNotMarkedUnsupportedByTheFirstOnesGateway() async {
        let client = script(hub: false)
        let model = model(client)
        model.query = "pdf"
        model.searchHub()
        #expect(await eventually { model.hubUnsupported })
        // Switch to a bot whose gateway does support hub search: the flag from the old bot must not stick.
        model.profile = "kim"
        #expect(!model.hubUnsupported)
    }

    @Test func getInstallsTheHubIdentifier() async {
        let client = script()
        client.onREST { method, path, _, _ in
            switch (method, path) {
            case ("GET", "/api/skills"): return Data(CapabilitiesSpeedTests.skillsJSON.utf8)
            case ("POST", "/api/skills/hub/install"): return Data(#"{"ok":true,"name":"skills-install-1"}"#.utf8)
            case ("GET", "/api/actions/skills-install-1/status"): return Data(#"{"name":"skills-install-1","running":false,"exit_code":0,"lines":[]}"#.utf8)
            default: throw HTTPError(status: 404, body: nil)
            }
        }
        let model = model(client)
        let skill = HubSkill(name: "pdf-redact", description: "", identifier: "skills-sh/pdf-redact", source: "skills-sh", trust: "community", repo: nil)
        model.runInstall(OfficialSkill(name: skill.name, description: "", identifier: skill.identifier, category: nil, installed: false)) {
            model.hubInstalled.insert(skill.identifier)
        }
        #expect(await eventually { model.hubIsInstalled(skill) })
        let body = client.restCalls.first { $0.path == "/api/skills/hub/install" }?.body
        #expect(body.flatMap { try? JSONValue.parse($0) } == ["identifier": "skills-sh/pdf-redact"])
    }
}
