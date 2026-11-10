// [directory] Hermes' app catalog as `GET /api/mcp/catalog` answers it: parsing, names, Popular order, logo sources.

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct McpCatalogTests {
    private func parse(_ text: String) throws -> [McpCatalogEntry] {
        McpCatalog.entries(try JSONValue.parse(Data(text.utf8)))
    }

    @Test func parsesTheGatewayShape() throws {
        let entries = try parse("""
        {"entries": [
          {"name": "n8n-official", "description": "Connect n8n.", "connector_slug": null, "source": "https://docs.n8n.io/connect/",
           "transport": "http", "auth_type": "oauth", "required_env": [{"name": "N8N_MCP_SERVER_URL", "prompt": "Server URL", "required": true}],
           "command": null, "args": [], "url": "${N8N_MCP_SERVER_URL}", "install_url": null, "post_install": "Run it.", "installed": false, "enabled": false},
          {"name": "stripe", "description": "Payments.", "connector_slug": "stripe_mcp", "source": "https://docs.stripe.com/mcp",
           "transport": "http", "auth_type": "oauth", "required_env": [], "url": "https://mcp.stripe.com", "installed": true, "enabled": true},
          {"description": "no name, skipped"}
        ], "diagnostics": []}
        """)
        #expect(entries.count == 2)
        #expect(entries[0].requiredEnv == [.init(name: "N8N_MCP_SERVER_URL", prompt: "Server URL", required: true)])
        #expect(entries[0].needsSignIn && !entries[0].needsBuild)
        #expect(entries[0].title == "n8n")
        #expect(entries[1].title == "Stripe")
        #expect(entries[1].installed)
    }

    @Test func titlesFollowTheDesktop() {
        #expect(McpCatalog.title(connectorSlug: nil, name: "prisma-postgres") == "Prisma Postgres")
        #expect(McpCatalog.title(connectorSlug: nil, name: "github") == "GitHub")
        #expect(McpCatalog.title(connectorSlug: nil, name: "some_thing-mcp") == "Some Thing MCP")
    }

    @Test func popularLeadsWithTheBestKnownThenAToZ() {
        func entry(_ name: String) -> McpCatalogEntry {
            McpCatalogEntry(name: name, description: "", source: "", transport: "http", authType: "none", requiredEnv: [], args: [],
                            postInstall: "", installed: false, enabled: false)
        }
        let ordered = McpCatalog.ordered(["zapier", "linear", "apple", "notion"].map(entry)).map(\.name)
        #expect(ordered == ["notion", "linear", "apple", "zapier"])
    }

    @Test func logoSourcesTrySlugsThenTheProductSite() {
        let stripe = McpCatalogEntry(name: "stripe", description: "", connectorSlug: "stripe_mcp", source: "https://docs.stripe.com/mcp",
                                     transport: "http", authType: "oauth", requiredEnv: [], args: [], postInstall: "", installed: false, enabled: false)
        #expect(McpCatalog.logoSlugs(stripe) == ["stripe_mcp", "stripe"])
        #expect(McpCatalog.site(stripe)?.absoluteString == "https://stripe.com")
        let local = McpCatalogEntry(name: "unreal-engine", description: "", source: "https://github.com/x/y", transport: "http", authType: "none",
                                    requiredEnv: [], args: [], url: "http://127.0.0.1:8000/mcp", postInstall: "", installed: false, enabled: false)
        #expect(McpCatalog.logoSlugs(local) == ["unreal-engine", "unrealengine", "unreal_engine"])
        #expect(McpCatalog.site(local) == nil, "never a code host or a private address")
    }

    @Test func addressesAreTypedInTheOpen() {
        #expect(McpCatalog.isAddress(.init(name: "N8N_MCP_SERVER_URL", prompt: "", required: true)))
        #expect(!McpCatalog.isAddress(.init(name: "TWELVE_DATA_API_KEY", prompt: "", required: true)))
        #expect(!McpCatalog.isAddress(.init(name: "CURLY_TOKEN", prompt: "", required: true)))
    }
}
