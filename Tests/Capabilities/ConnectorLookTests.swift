// [connectors-ux] The words and marks every Connectors row shares: descriptions without the name they repeat, a symbol
// (never a letter) for a connector with no logo, and a plugin's status line kept to one short line.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor @Suite struct ConnectorLookTests {
    private func entry(_ name: String, _ description: String) -> McpCatalogEntry {
        McpCatalogEntry(name: name, description: description, source: "", transport: "http", authType: "none", requiredEnv: [], args: [],
                        postInstall: "", installed: false, enabled: false)
    }

    @Test func descriptionsDropTheNameTheyStartWith() {
        #expect(entry("gitlab", "GitLab: issues, merge requests, pipelines.").shortDescription == "Issues, merge requests, pipelines.")
        #expect(entry("algolia", "Algolia search: indices.").shortDescription == "Algolia search: indices.", "only the name itself is cut")
        #expect(entry("figma", "Official Figma remote MCP — design context").shortDescription == "Official Figma remote MCP — design context")
        #expect(entry("betterstack", "Better Stack — logs and uptime.").shortDescription == "Logs and uptime.")
        #expect(entry("asana", "Tasks, projects, and goals.").shortDescription == "Tasks, projects, and goals.")
        #expect(entry("todoist", "").shortDescription == "")
    }

    @Test func aConnectorWithoutALogoGetsASymbolNotALetter() {
        #expect(ConnectorSymbol.of("browser") == "globe")
        #expect(ConnectorSymbol.of("Files") == "folder")
        #expect(ConnectorSymbol.of("sqlite-db") == "cylinder")
        #expect(ConnectorSymbol.of("server-287") == "powerplug")
        #expect(ConnectorSymbol.of("github") == "arrow.triangle.branch")
        #expect(ConnectorSymbol.of("mysql") == "cylinder")
        #expect(ConnectorSymbol.of("Google Drive") == "folder")
        #expect(ConnectorSymbol.of("digital-ocean") == "powerplug", "a short word inside another word doesn't count")
        #expect(ConnectorSymbol.of("feedback") == "powerplug")
    }

    @Test func aPluginsRowSaysPluginNotWhoAddedIt() {
        let browser = McpServer(name: "browser", transport: "stdio", enabled: true, source: "plugin", plugin: "hermes-hq-browser",
                                status: "connected", tools: 12)
        #expect(ConnectorRow.words(browser) == "Connected · 12 tools · Plugin")
        let github = McpServer(name: "github", transport: "http", enabled: true, source: "config", plugin: nil, status: "connected", tools: 5)
        #expect(ConnectorRow.words(github) == "Connected · 5 tools")
        var off = github
        off.enabled = false
        #expect(ConnectorRow.words(off) == "Off")
        #expect(ConnectorTone.of(off) == .quiet)
        #expect(ConnectorTone.of(github) == .good)
        var failed = github
        failed.status = "failed"
        #expect(ConnectorTone.of(failed).isTrouble)
    }
}
