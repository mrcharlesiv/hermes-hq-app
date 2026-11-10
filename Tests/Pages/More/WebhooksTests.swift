// More › Webhooks (docs/spec/3x-morepages.md §13 acceptance 1): the New Webhook form's payload (events and skills
// split on commas, trimmed, empties dropped; absent keys not sent), the deliver labels, the row's words, the calls
// and the decoders fed bad data.

import Foundation
import Testing
@testable import HermesHQNative

nonisolated private func keys(_ value: JSONValue?) -> [String] { (value?.object ?? [:]).keys.sorted() }

struct WebhookFormTests {
    @Test func onlyANameSendsTheThreeKeysTheWebAlwaysSends() {
        var form = WebhookForm()
        form.name = "  github-push  "
        #expect(form.payload == .object(["name": "github-push", "deliver": "log", "deliver_only": false]))
        #expect(form.canCreate)
    }

    @Test func absentKeysAreNotSent() {
        var form = WebhookForm()
        form.name = "hook"
        form.description = "   "
        form.events = " , ,"
        form.skills = ""
        form.prompt = "\n"
        form.deliverChatId = "123"          // Log takes no chat: not sent.
        #expect(keys(form.payload) == ["deliver", "deliver_only", "name"])
    }

    @Test func aFullFormSendsEveryKey() {
        var form = WebhookForm()
        form.name = "github-push"
        form.description = " Runs the checks "
        form.events = "push, pull_request ,, release\nissue"
        form.skills = " release-checks,triage "
        form.deliver = "telegram"
        form.deliverChatId = " -1001234 "
        form.deliverOnly = true
        form.prompt = " Summarise it. "
        #expect(form.payload == .object([
            "name": "github-push", "description": "Runs the checks", "events": ["push", "pull_request", "release", "issue"],
            "skills": ["release-checks", "triage"], "deliver": "telegram", "deliver_chat_id": "-1001234", "deliver_only": true,
            "prompt": "Summarise it.",
        ]))
        #expect(keys(form.payload) == ["deliver", "deliver_chat_id", "deliver_only", "description", "events", "name", "prompt", "skills"])
    }

    @Test func splittingLists() {
        #expect(WebhookForm.list("") == [])
        #expect(WebhookForm.list(" a ,b,, c ,") == ["a", "b", "c"])
        #expect(WebhookForm.list("push") == ["push"])
        #expect(WebhookForm.list(",,,") == [])
    }

    @Test func payloadOnlyNeedsARealTarget() {
        var form = WebhookForm()
        form.name = "hook"
        form.deliverOnly = true
        #expect(!form.canDeliverOnly)
        #expect(form.payload["deliver_only"] == false)       // the gateway refuses payload-only with Log
        form.deliver = "email"
        #expect(form.canDeliverOnly && form.payload["deliver_only"] == true)
        #expect(form.payload["deliver_chat_id"] == nil)       // Email is not a chat platform
    }

    @Test func nameRule() {
        func valid(_ name: String) -> Bool { var form = WebhookForm(); form.name = name; return form.canCreate }
        #expect(valid("github-push") && valid("a") && valid("9_lives") && valid("  GitHub Push  "))
        #expect(!valid("") && !valid("   ") && !valid("-leading") && !valid("_x") && !valid("naïve") && !valid("a/b") && !valid("a.b"))
        var form = WebhookForm()
        form.name = " GitHub Push "
        #expect(form.normalizedName == "github-push")
    }

    @Test func deliverLabels() {
        #expect(WebhookDeliver.options == ["log", "telegram", "discord", "slack", "email", "github_comment"])
        #expect(WebhookDeliver.options.map(WebhookDeliver.label) == ["Log Only", "Telegram", "Discord", "Slack", "Email", "GitHub Comment"])
        #expect(WebhookDeliver.label("matrix") == "matrix" && WebhookDeliver.label("") == "Log Only")
        #expect(WebhookDeliver.options.filter(WebhookDeliver.isChat) == ["telegram", "discord", "slack"])
    }

    @Test func rowWords() {
        #expect(WebhookRoute(name: "a").summary == "All Events → Log Only")
        #expect(WebhookRoute(name: "a", events: ["push", "pull_request"], deliver: "github_comment").summary == "push, pull_request → GitHub Comment")
        #expect(WebhookRoute(name: "a", events: ["push"], deliver: "github_comment").spokenSummary == "push to GitHub Comment")
        #expect(WebhookRoute(name: "github-push", description: "Release checks", events: ["push"], deliver: "telegram").matches("TELE"))
        #expect(WebhookRoute(name: "github-push").matches("  ") && !WebhookRoute(name: "github-push").matches("slack"))
        #expect(WebhookWords.toggleFailure("a", on: true) == "Couldn’t turn “a” on" && WebhookWords.toggleFailure("a", on: false) == "Couldn’t turn “a” off")
    }

    @Test func createFailureWords() {
        #expect(WebhookWords.createFailure(HTTPError(status: 409, body: "{\"detail\":\"Subscription changed.\"}")) == "A webhook with that name already exists.")
        #expect(WebhookWords.createFailure(HTTPError(status: 400, body: "{\"detail\":\"Invalid name.\"}")) == "Invalid name.")
        #expect(WebhookWords.createFailure(HTTPError(status: 500, body: nil)) == "The gateway couldn’t do that.")
    }
}

struct WebhookWireTests {
    @Test func theListDecodesLeniently() throws {
        let json = try JSONValue.parse(Data("""
        {"enabled":true,"base_url":"http://127.0.0.1:1","subscriptions":[
          {"name":"github-push","description":"d","events":["push",7,null,""," pr "],"skills":"none","deliver":"telegram",
           "deliver_only":true,"prompt":"p","enabled":false,"secret_set":true,"url":"http://127.0.0.1:1/webhooks/github-push",
           "created_at":"2026-10-01T08:30:00Z"},
          {"name":"github-push","description":"a repeat"},
          {"name":"bare"}, {"description":"no name"}, null, 3, "x", [], {"name":""}, {"name":42,"enabled":"no","deliver":null,"created_at":"never"}
        ]}
        """.utf8))
        let answer = try #require(WebhooksAnswer(json: json))
        #expect(answer.enabled && answer.baseURL == "http://127.0.0.1:1")
        #expect(answer.subscriptions.map(\.name) == ["github-push", "bare", "42"])
        let first = answer.subscriptions[0]
        #expect(first.events == ["push", "7", "pr"] && first.skills.isEmpty && first.deliverOnly && !first.enabled && first.secretSet)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_790_843_400))
        // Default-on, default Log.
        #expect(answer.subscriptions[1].enabled && answer.subscriptions[1].deliver == "log" && answer.subscriptions[1].createdAt == nil)
        #expect(answer.subscriptions[2].enabled && answer.subscriptions[2].deliver == "log")
        #expect(WebhooksAnswer(json: ["enabled": false])?.subscriptions.isEmpty == true)
        #expect(WebhooksAnswer(json: ["subscriptions": .object([:])])?.enabled == false)
        for bad in ["{}", "[]", "null", "7", "\"x\"", "{\"other\":1}"] {
            #expect(WebhooksAnswer(json: try JSONValue.parse(Data(bad.utf8))) == nil, "\(bad)")
        }
    }

    @Test func enableAnswer() {
        #expect(WebhookEnableResult(json: ["ok": true, "needs_restart": true, "restart_started": false]).showsRestartNotice)
        #expect(!WebhookEnableResult(json: ["needs_restart": false, "restart_started": true]).showsRestartNotice)
        #expect(!WebhookEnableResult(json: ["needs_restart": true, "restart_started": true]).showsRestartNotice)
        #expect(!WebhookEnableResult(json: .null).showsRestartNotice)
        #expect(WebhookEnableResult(json: ["needs_restart": true, "restart_error": "no service"]).restartError == "no service")
    }

    @Test func callsGoWhereTheSpecSays() async throws {
        let client = MoreFakeClient { request in
            switch (request.method, request.path) {
            case ("GET", "/api/webhooks"): return ["enabled": true, "subscriptions": []]
            case ("POST", "/api/webhooks"): return ["name": "github-push", "url": "http://x/webhooks/github-push", "secret": "s3cr3t-value"]
            default: return ["ok": true, "needs_restart": true]
            }
        }
        let api = WebhooksAPI(client: client)
        _ = try await api.list()
        #expect(try await api.enable().needsRestart)
        var form = WebhookForm()
        form.name = "github-push"
        let created = try await api.create(form)
        #expect(created.secret == "s3cr3t-value" && created.url.hasSuffix("/webhooks/github-push"))
        try await api.setEnabled("git hub/push", false)
        try await api.delete("git hub/push")
        #expect(client.logLines == [
            "GET /api/webhooks", "POST /api/webhooks/enable", "POST /api/webhooks",
            "PUT /api/webhooks/git%20hub%2Fpush/enabled", "DELETE /api/webhooks/git%20hub%2Fpush",
        ])
        #expect(client.log[1].body == nil)
        #expect(client.log[2].body == .object(["name": "github-push", "deliver": "log", "deliver_only": false]))
        #expect(client.log[3].body == .object(["enabled": false]))
        #expect(client.log[4].body == nil)
    }

    @Test func anUnreadableAnswerIsAnError() async {
        let client = MoreFakeClient { _ in [1, 2, 3] }
        await #expect(throws: PagesMessageError.self) { _ = try await WebhooksAPI(client: client).list() }
        var form = WebhookForm()
        form.name = "x"
        await #expect(throws: PagesMessageError.self) { _ = try await WebhooksAPI(client: client).create(form) }
    }
}
