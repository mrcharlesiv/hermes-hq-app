// Connect Apps: apps the owner can't connect (docs/spec/3x-capabilities.md §10.13). Rows shaped as Composio's catalog
// answered live on 2026-10-27 (twitter, metaads, googledrive, perplexityai), the hiding rule, the two reads, and the
// plain words for "Composio does not manage auth for toolkit …".

import Foundation
import Testing
@testable import HermesHQNative

extension ComposioTests {
    nonisolated static func catalogRow(_ slug: String, schemes: [String], managed: [String], noAuth: Bool = false) -> JSONValue {
        ["slug": .string(slug), "name": .string(slug), "auth_schemes": .array(schemes.map(JSONValue.string)),
         "composio_managed_auth_schemes": .array(managed.map(JSONValue.string)), "no_auth": .bool(noAuth)]
    }

    @Test func onlyOAuthAppsWithoutAManagedSignInNeedTheOwnersApp() {
        #expect(ComposioSignIn.needsOwnApp(Self.catalogRow("twitter", schemes: ["OAUTH2"], managed: [])))
        #expect(ComposioSignIn.needsOwnApp(Self.catalogRow("oldone", schemes: ["OAUTH1", "oauth2"], managed: [])))
        // A key or token the owner types on Composio's page works.
        #expect(!ComposioSignIn.needsOwnApp(Self.catalogRow("metaads", schemes: ["OAUTH2", "API_KEY"], managed: [])))
        #expect(!ComposioSignIn.needsOwnApp(Self.catalogRow("perplexityai", schemes: ["API_KEY"], managed: [])))
        #expect(!ComposioSignIn.needsOwnApp(Self.catalogRow("googledrive", schemes: ["OAUTH2"], managed: ["OAUTH2"])))
        #expect(!ComposioSignIn.needsOwnApp(Self.catalogRow("hackernews", schemes: [], managed: [], noAuth: true)))
        #expect(!ComposioSignIn.needsOwnApp(Self.catalogRow("mystery", schemes: [], managed: [])), "unknown schemes show")
    }

    @Test func theListsLeaveOutOnlyAppsTheOwnerCantConnect() {
        func app(_ slug: String, account: String? = nil, noAuth: Bool = false, managed: [String] = []) -> ComposioToolkit {
            ComposioToolkit(slug: slug, name: slug, logo: "", description: "", noAuth: noAuth,
                            account: account.map { ComposioAccount(id: "ca_1", status: $0, reason: "", createdAt: "") }, managedSchemes: managed)
        }
        let needs: Set<String> = ["twitter", "shopify", "xero"]
        #expect(ComposioSignIn.hidden(app("twitter"), needsOwnApp: needs, configured: []))
        #expect(ComposioSignIn.hidden(app("Twitter"), needsOwnApp: needs, configured: []))
        #expect(!ComposioSignIn.hidden(app("twitter"), needsOwnApp: needs, configured: ["twitter"]), "the owner set up their own app")
        #expect(!ComposioSignIn.hidden(app("shopify", account: "ACTIVE"), needsOwnApp: needs, configured: []), "connected already")
        #expect(!ComposioSignIn.hidden(app("xero", account: "EXPIRED"), needsOwnApp: needs, configured: []), "needs a new sign-in: still listed")
        #expect(!ComposioSignIn.hidden(app("twitter", managed: ["OAUTH2"]), needsOwnApp: needs, configured: []), "its own row says managed")
        #expect(!ComposioSignIn.hidden(app("metaads"), needsOwnApp: needs, configured: []))
        #expect(!ComposioSignIn.hidden(app("googledrive"), needsOwnApp: [], configured: []), "nothing read: every app shows")
        // A session row's managed schemes are read.
        let row = ComposioToolkit.read(try! JSONValue.parse(Data(#"{"slug":"googledrive","name":"Google Drive","composio_managed_auth_schemes":["OAUTH2"],"is_no_auth":false}"#.utf8)))
        #expect(row?.managedSchemes == ["OAUTH2"])
    }

    @Test func theCatalogAndAuthConfigsAreReadPageByPage() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { request in
            let url = request.url!
            if url.path == "/api/v3/auth_configs" {
                return (200, #"{"items":[{"id":"ac_1","status":"ENABLED","toolkit":{"slug":"metaads"}},{"id":"ac_2","status":"DISABLED","toolkit":{"slug":"twitter"}},{"id":"ac_3","status":"ENABLED","toolkit":{"slug":"Shopify"}}]}"#)
            }
            if url.query?.contains("cursor=p2") == true {
                return (200, #"{"items":[{"slug":"shopify","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":[],"no_auth":false}],"next_cursor":null}"#)
            }
            return (200, #"{"items":[{"slug":"twitter","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":[],"no_auth":false},{"slug":"metaads","auth_schemes":["OAUTH2","API_KEY"],"composio_managed_auth_schemes":[],"no_auth":false},{"slug":"googledrive","auth_schemes":["OAUTH2"],"composio_managed_auth_schemes":["OAUTH2"],"no_auth":false}],"next_cursor":"p2"}"#)
        }
        let client = client(keys)
        #expect(try await client.appsNeedingOwnSignIn() == ["twitter", "shopify"])
        #expect(try await client.appsWithOwnAuthConfig() == ["metaads", "shopify"], "a disabled config doesn't count")
        let seen = ComposioStub.seen
        #expect(seen.map { $0.url?.path ?? "" } == ["/api/v3/toolkits", "/api/v3/toolkits", "/api/v3/auth_configs"])
        #expect(seen.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "x-api-key") == "ak_mock_dispatch" })
        #expect(seen[0].url?.query == "limit=1000" && seen[1].url?.query == "limit=1000&cursor=p2")
    }

    @Test func composiosNoSignInRefusalIsPutInPlainWords() async throws {
        let raw = "Composio does not manage auth for toolkit twitter and no auth config without required fields is available. Please create an auth config manually or specify one in auth_config_override."
        #expect(ComposioSignIn.isOwnAppRefusal(ComposioClient.error(status: 400, body: ["error": ["message": .string(raw)]])))
        #expect(!ComposioSignIn.isOwnAppRefusal(ComposioError(kind: .rejected, message: "Toolkit not found")))
        #expect(ComposioSignIn.ownAppMessage("Twitter")
                == "Composio doesn’t provide a sign-in for Twitter. To connect it, add your own Twitter developer app as an auth config in your Composio dashboard, then try again.")
        #expect(ComposioSignIn.dashboard.absoluteString == "https://platform.composio.dev")

        // The connect flow ends in its own outcome, not Composio's words.
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { _ in (400, #"{"error":{"message":"\#(raw)","status":400}}"#) }
        let connect = ComposioConnect()
        await connect.run(client: client(keys), session: "trs_1", slug: "twitter", window: nil)
        #expect(connect.outcome == .needsOwnApp)
    }
}
