// Connect Apps: who each account is (docs/spec/3x-capabilities.md §10.12). The who-am-I answers as the apps gave them
// live (addresses made up), the request the client makes, the row's title and address line, the name offered for an
// unnamed account, and the model asking for several accounts at once without an address reaching the log.

import Foundation
import Testing
@testable import HermesHQNative

extension ComposioTests {
    nonisolated static func answer(_ data: String, successful: Bool = true) -> JSONValue {
        try! JSONValue.parse(Data(#"{"successful":\#(successful),"error":null,"log_id":"log_1","data":\#(data)}"#.utf8))
    }

    @Test func whoAmIAnswersAreReadWhereEachAppPutsThem() throws {
        let table = ComposioWhoAmI.table
        // Google Drive (about.get, fields=user), as answered live.
        let drive = ComposioWhoAmI.read(Self.answer(#"{"user":{"displayName":"Jordan Lee","emailAddress":"jordan@work.example","kind":"drive#user","me":true,"permissionId":"155","photoLink":"https://lh3.googleusercontent.com/a"}}"#),
                                        entry: try #require(table["googledrive"]))
        #expect(drive == ComposioIdentity(email: "jordan@work.example", name: "Jordan Lee"))
        // Notion: the integration's own name sits at the top; the person is the bot's owner.
        let notion = ComposioWhoAmI.read(Self.answer(#"{"response_data":{"object":"user","type":"bot","name":"Hermes Integration","bot":{"owner":{"type":"user","user":{"object":"user","name":"Jordan Lee","person":{"email":"jordan.lee@gmail.com","email_verified":true},"type":"person"}},"workspace_name":"My Workspace"}}}"#),
                                         entry: try #require(table["notion"]))
        #expect(notion == ComposioIdentity(email: "jordan.lee@gmail.com", name: "Jordan Lee"))
        let clickup = ComposioWhoAmI.read(Self.answer(#"{"user":{"id":14,"email":"jordan@acme.example","username":"Jordan Lee","initials":"JL","color":"green"}}"#),
                                          entry: try #require(table["clickup"]))
        #expect(clickup == ComposioIdentity(email: "jordan@acme.example", name: "Jordan Lee"))
        let salesforce = ComposioWhoAmI.read(Self.answer(#"{"response_data":{"email":"jordan@acme.example","name":"Jordan Lee","nickname":"User1776","preferred_username":"jordan@acme.example"}}"#),
                                             entry: try #require(table["salesforce"]))
        #expect(salesforce == ComposioIdentity(email: "jordan@acme.example", name: "Jordan Lee"))
        // Gmail (not run live): the profile's emailAddress, and the search finds it when it sits elsewhere.
        let gmail = try #require(table["gmail"])
        #expect(ComposioWhoAmI.read(Self.answer(#"{"response_data":{"emailAddress":"jordan.lee@gmail.com","messagesTotal":3}}"#), entry: gmail)?.email == "jordan.lee@gmail.com")
        #expect(ComposioWhoAmI.read(Self.answer(#"{"profile":{"emailAddress":"jordan.lee@gmail.com"}}"#), entry: gmail)?.email == "jordan.lee@gmail.com")
        // GitHub with no public address: the name alone.
        #expect(ComposioWhoAmI.read(Self.answer(#"{"login":"jlee","name":null,"email":null}"#), entry: try #require(table["github"]))
                == ComposioIdentity(email: "", name: "jlee"))
    }

    @Test func whoAmIAnswersThatNameNobodyGiveNothing() throws {
        let drive = try #require(ComposioWhoAmI.entry("GoogleDrive"))
        #expect(ComposioWhoAmI.read(Self.answer(#"{"user":{"emailAddress":"jordan@work.example"}}"#, successful: false), entry: drive) == nil)
        #expect(ComposioWhoAmI.read(Self.answer(#"{}"#), entry: drive) == nil)
        #expect(ComposioWhoAmI.read(Self.answer(#""text""#), entry: drive) == nil)
        #expect(ComposioWhoAmI.read(try JSONValue.parse(Data(#"{"error":{"message":"expired"}}"#.utf8)), entry: drive) == nil)
        // Something that isn't an address at the address path is not shown as one.
        #expect(ComposioWhoAmI.read(Self.answer(#"{"user":{"emailAddress":"not an address","displayName":"Jordan"}}"#), entry: drive)
                == ComposioIdentity(email: "", name: "Jordan"))
        #expect(ComposioWhoAmI.entry("googlesheets") == nil && ComposioWhoAmI.entry("hackernews") == nil)
        #expect(ComposioWhoAmI.looksLikeEmail("a@b.co") && !ComposioWhoAmI.looksLikeEmail("a b@c.d") && !ComposioWhoAmI.looksLikeEmail("@b.co")
                && !ComposioWhoAmI.looksLikeEmail("a@b"))
    }

    @Test func theWhoAmIToolRunsAgainstOneAccountOnly() async throws {
        let keys = keychain()
        defer { keys.clear() }
        try keys.save("ak_mock_dispatch")
        ComposioStub.reset { request in
            (200, #"{"successful":true,"error":null,"data":{"user":{"displayName":"Jordan Lee","emailAddress":"jordan@work.example"}}}"#)
        }
        let client = client(keys)
        let identity = try await client.identity(account: "ca_1", toolkit: "googledrive", user: "dispatch-aabbcc")
        #expect(identity == ComposioIdentity(email: "jordan@work.example", name: "Jordan Lee"))
        // An app with no who-am-I tool asks nothing.
        #expect(try await client.identity(account: "ca_2", toolkit: "googlesheets", user: "dispatch-aabbcc") == nil)
        let seen = ComposioStub.seen
        #expect(seen.count == 1)
        #expect(seen[0].httpMethod == "POST" && seen[0].url?.path == "/api/v3/tools/execute/GOOGLEDRIVE_GET_ABOUT")
        #expect(seen[0].url?.host == "backend.composio.dev" && seen[0].value(forHTTPHeaderField: "x-api-key") == "ak_mock_dispatch")
        #expect(ComposioStub.bodies[0] == ["connected_account_id": "ca_1", "user_id": "dispatch-aabbcc", "arguments": ["fields": "user"]])

        // A refused run (an expired account answers 410) throws, so the caller keeps what it knew.
        ComposioStub.reset { _ in (410, #"{"error":{"message":"Connected account ca_1 for toolkit 'googledrive' is in EXPIRED state","status":410}}"#) }
        await #expect(throws: ComposioError.self) { try await client.identity(account: "ca_1", toolkit: "googledrive", user: "dispatch-aabbcc") }
    }

    @Test func rowsAreTitledByNameThenAddressThenNumber() {
        let me = ComposioIdentity(email: "jordan@work.example", name: "Jordan Lee")
        let unnamed = ComposioAccount(id: "ca_1", status: "ACTIVE", reason: "", createdAt: "")
        var named = unnamed; named.alias = "work-drive"
        #expect(unnamed.title(number: 2, identity: nil) == "Account 2")
        #expect(unnamed.title(number: 2, identity: ComposioIdentity(email: "", name: "Jordan Lee")) == "Account 2", "a name alone isn't a title")
        #expect(unnamed.title(number: 2, identity: me) == "jordan@work.example")
        #expect(unnamed.emailLine(identity: me) == nil, "the address is the title already")
        #expect(named.title(number: 2, identity: me) == "Work Drive")
        #expect(named.emailLine(identity: me) == "jordan@work.example")
        #expect(named.emailLine(identity: nil) == nil)
        #expect(unnamed.title(number: 1) == "Account 1", "the older words stay for callers without an address")
    }

    @Test func anUnnamedAccountIsOfferedANameFromItsAddress() {
        #expect(ComposioAlias.suggestion(email: "a.rivera@work.com") == "work")
        #expect(ComposioAlias.suggestion(email: "Jordan@Mail.Acme.co.uk") == "acme")
        #expect(ComposioAlias.suggestion(email: "jordan@northwind-traders.com") == "northwind-traders")
        #expect(ComposioAlias.suggestion(email: "jordan.lee@gmail.com") == "personal")
        #expect(ComposioAlias.suggestion(email: "jordan@icloud.com") == "personal")
        // "personal" taken by another account: the address's own name.
        #expect(ComposioAlias.suggestion(email: "jordan.lee+drive@gmail.com", taken: ["personal"]) == "jordan-lee")
        #expect(ComposioAlias.suggestion(email: "j@work.com", taken: ["work", "j"]) == nil)
        #expect(ComposioAlias.suggestion(email: "not an address") == nil)
        // Whatever is offered is already in Composio's shape.
        for email in ["Ünïcode@exämple.com", "x@a.b.c.d.e.example.com", "\(String(repeating: "a", count: 60))@\(String(repeating: "b", count: 60)).com"] {
            if let made = ComposioAlias.suggestion(email: email) { #expect(ComposioAlias.normalized(made) == made, "\(made)") }
        }
    }

    @Test func theModelAsksForEveryAccountAtOnceAndLogsNoAddress() async throws {
        let (model, _, _, done) = movingModel(configureFailures: 0)
        defer { done(); UserDefaults.standard.removeObject(forKey: "connectapps.identities.\(GatewayAccount.botsTestAccount.id)") }
        UserDefaults.standard.removeObject(forKey: "connectapps.identities.\(GatewayAccount.botsTestAccount.id)")
        #expect(model.userID == "dispatch-aabbcc")
        let marker = "zz\(UUID().uuidString.prefix(6).lowercased())"
        ComposioStub.reset { _ in
            // Called with the stub's lock held, after it read this request's body.
            let id = ComposioStub.bodies.last?["connected_account_id"]?.string ?? ""
            if id == "ca_bad" { return (500, "{}") }
            let who = id == "ca_1" ? "jordan.\(marker)@gmail.com" : "jordan@\(marker).example"
            return (200, #"{"successful":true,"data":{"user":{"displayName":"Jordan \#(marker)","emailAddress":"\#(who)"}}}"#)
        }
        let accounts = [ComposioAccount(id: "ca_1", status: "ACTIVE", reason: "", createdAt: ""),
                        ComposioAccount(id: "ca_2", status: "ACTIVE", reason: "", createdAt: "", alias: "work"),
                        ComposioAccount(id: "ca_bad", status: "ACTIVE", reason: "", createdAt: ""),
                        ComposioAccount(id: "ca_old", status: "EXPIRED", reason: "", createdAt: "")]
        model.setAccounts("googledrive", accounts)
        await model.loadIdentities("googledrive", accounts: accounts)
        #expect(model.identities["ca_1"]?.email == "jordan.\(marker)@gmail.com")
        #expect(model.identities["ca_2"]?.email == "jordan@\(marker).example")
        #expect(model.identities["ca_bad"] == nil && model.identities["ca_old"] == nil)
        #expect(ComposioStub.seen.count == 3, "an account that needs a new sign-in isn't asked")
        // Asked once per launch: a reload asks only the one that failed.
        await model.loadIdentities("googledrive", accounts: accounts)
        #expect(ComposioStub.seen.count == 4)
        // Kept on this device for the next launch; a gone account is forgotten.
        let saved = try #require(UserDefaults.standard.data(forKey: "connectapps.identities.\(GatewayAccount.botsTestAccount.id)"))
        #expect(try JSONDecoder().decode([String: ComposioIdentity].self, from: saved)["ca_2"]?.email == "jordan@\(marker).example")
        model.setAccounts("googledrive", Array(accounts.dropFirst()))
        #expect(model.identities["ca_1"] == nil)
        // The log names accounts by tag only.
        let log = DiagnosticLog.shared.tail(bytes: 64 << 10)
        #expect(!log.contains(marker))
        #expect(log.contains("account \(AppLog.tag("ca_bad")) who-am-I failed"))
    }
}
