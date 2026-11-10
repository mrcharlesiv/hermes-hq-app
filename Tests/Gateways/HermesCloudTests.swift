// Hermes Cloud (App/Gateways/CloudGatewayFlow.swift, HermesKit/Cloud): reading Portal's agent rows and tool schemas,
// the MCP answer in either body shape, the token answer, and a whole list/create run against a URLProtocol stub that
// plays Portal's OAuth and MCP endpoints (no network).

import Foundation
import Testing
@testable import HermesHQNative

/// Answers Portal's endpoints from a script; records each JSON-RPC method seen.
nonisolated final class PortalStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var methods: [String] = []
    nonisolated(unsafe) static var authorizations: [String] = []
    nonisolated(unsafe) static var calls: [JSONValue] = []
    nonisolated(unsafe) static var answer: @Sendable (String, JSONValue) -> (Int, [String: String], String) = { _, _ in (500, [:], "") }
    static let lock = NSLock()

    static func reset(_ answer: @escaping @Sendable (String, JSONValue) -> (Int, [String: String], String)) {
        lock.lock(); methods = []; authorizations = []; calls = []; self.answer = answer; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        let body = (try? JSONValue.parse(data)) ?? .string(String(decoding: data, as: UTF8.self))
        Self.lock.lock()
        if let method = body["method"]?.string { Self.methods.append(method) }
        if body["method"]?.string == "tools/call" { Self.calls.append(body["params"] ?? .null) }
        Self.authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let answer = Self.answer
        Self.lock.unlock()
        let (status, headers, text) = answer(request.url?.path ?? "", body)
        // Status 0: the answer never comes (the phone's wait runs out).
        if status == 0 { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct HermesCloudTests {
    // Portal's own `agent` and `agents` input schemas as `tools/list` sent them on 2026-10-30.
    nonisolated static let realAgentSchema = try! JSONValue.parse(Data(#"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"action":{"type":"string","enum":["start","stop","restart","create","destroy","update_env","update_image","rename","set_feature","resize","grow_disk","reassign"]},"agent_id":{"type":"string","minLength":1,"description":"The Hermes Cloud agent instance id (from agents(action='list'))."},"name":{"description":"Instance name (action='create' or action='rename').","type":"string","minLength":1,"maxLength":64},"region":{"description":"Fly region for a new instance (action='create'). Defaults to iad. Other backends choose their own placement; the response's region is where it landed.","type":"string","enum":["iad","sjc","lhr","nrt","syd","gru"]},"compute_provider":{"description":"Compute backend for a new instance (action='create'). Omit for the default a sys admin picks. Outside production, Azure, Kubernetes and Sprites require staff access and Fly needs none; production refuses any choice except DigitalOcean. DigitalOcean requires your account's OHR flag. The backend must be enabled and configured in this environment.","type":"string","enum":["fly","azure","digitalocean","kubernetes","sprites"]},"model":{"description":"LLM model id for a new instance (action='create').","type":"string"},"size":{"description":"Instance size profile key (action='create' or action='resize'), e.g. 'standard' (default, 2 GB) or 'pro' (4 GB). Resolved against the instance's own backend.","type":"string","minLength":1,"maxLength":64},"disk_gb":{"description":"Target data-volume size in GB (action='grow_disk'); one of the offered disk sizes, larger than the current one.","type":"integer","exclusiveMinimum":0,"maximum":9007199254740991},"env":{"description":"Environment variables to set (action='update_env' or action='create').","type":"object","propertyNames":{"type":"string"},"additionalProperties":{"type":"string"}},"deleted_keys":{"description":"Environment variable names to remove (action='update_env').","type":"array","items":{"type":"string"}},"feature_key":{"description":"Feature key (action='set_feature'), e.g. 'relay' (Team Gateway; the instance then also suspends while idle and wakes on inbound activity).","type":"string","minLength":1,"maxLength":64},"enabled":{"description":"Whether to enable the feature (action='set_feature').","type":"boolean"},"assign_to":{"description":"New owner (action='reassign'): 'team' (the team's own agent identity), 'group' (the group's agent identity), or 'me'. Access is unchanged.","type":"string","enum":["team","group","me"]},"group":{"description":"Group id or exact group name (action='reassign' with assign_to='group').","type":"string","minLength":1,"maxLength":200}},"required":["action"]}"#.utf8))
    nonisolated static let realAgentsSchema = try! JSONValue.parse(Data(#"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"action":{"type":"string","enum":["list","get","status","cost_estimate"]},"agent_id":{"type":"string","minLength":1,"description":"The Hermes Cloud agent instance id (from agents(action='list'))."}},"required":["action"]}"#.utf8))

    // The shapes the real server could send: a flat schema with an action enum and per-action notes.
    nonisolated static let agentSchema: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["create", "start", "stop", "restart", "destroy", "update_env", "update_image"]],
            "id": ["type": "string", "description": "Agent id (start/stop/restart/destroy/update_env/update_image)."],
            "name": ["type": "string", "description": "Name for the new agent (create)."],
            "size": ["type": "string", "enum": ["small", "medium", "large"], "default": "small", "description": "Server size (create)."],
            "model": ["type": "string", "description": "Model the agent uses."],
            "env": ["type": "object", "description": "Environment variables (create/update_env)."],
            "image": ["type": "string", "description": "Image tag (update_image)."],
        ],
        "required": ["action"],
    ]
    @Test func agentRowsReadInEveryShape() {
        let camel: JSONValue = ["agents": [["id": "a1", "name": "ares", "status": "running",
                                            "dashboardUrl": "https://atlas-1000.agents.nousresearch.com", "dashboardGatewayState": "active"]]]
        let snake: JSONValue = ["agent": ["agent_id": "a2", "name": "lab", "state": "provisioning", "dashboard_url": nil]]
        let bare: JSONValue = [["id": "a3", "status": "stopped", "url": "http://insecure.example"]]
        let ares = CloudAgent.readAll(camel).first
        #expect(ares?.dashboardURL?.host == "atlas-1000.agents.nousresearch.com")
        #expect(ares?.isReady == true)
        let lab = CloudAgent.readAll(snake).first
        #expect(lab?.id == "a2" && lab?.status == "provisioning")
        #expect(lab?.dashboardURL == nil && lab?.isReady == false)
        let stopped = CloudAgent.readAll(bare).first
        #expect(stopped?.isStopped == true)
        #expect(stopped?.dashboardURL == nil)   // only https addresses are kept
        #expect(stopped?.name == "a3")
        let asleep = CloudAgent.read(["id": "a4", "name": "relay", "status": "suspended", "isSleeping": true,
                                      "dashboardUrl": "https://relay.agents.nousresearch.com", "dashboardGatewayState": "down"])
        #expect(asleep?.isSleeping == true && asleep?.isReady == true)   // the sign-in wakes it; no start first
    }

    @Test func portalsRealCreateFormIsSizeThenRegion() throws {
        let schema = CloudToolSchema.read(Self.realAgentSchema)
        let fields = schema.fields(for: "create")
        // compute_provider (production refuses all but DigitalOcean) and model (set in HQ) aren't asked; disk_gb,
        // feature_key, assign_to … belong to other actions; env is an object.
        #expect(fields.map(\.name) == ["size", "region"])
        let size = try #require(fields.first)
        #expect(size.kind == .choice && size.choices == ["standard", "pro", "max"] && size.defaultValue == "standard")
        #expect(size.title(of: "standard") == "Standard · 2 GB" && size.title(of: "pro") == "Pro · 4 GB")
        let region = try #require(fields.last)
        #expect(region.choices == ["iad", "sjc", "lhr", "nrt", "syd", "gru"] && region.defaultValue == "iad")
        #expect(region.title(of: "gru") == "São Paulo" && region.title(of: "iad") == "Virginia, US")
        #expect(schema.idKey(for: "start") == "agent_id")
        #expect(CloudToolSchema.read(Self.realAgentsSchema).idKey(for: "get") == "agent_id")
    }

    @Test func choicesAndDefaultsReadFromDescriptions() {
        #expect(CloudToolSchema.describedChoices("e.g. 'one' (only)") == nil)   // one value isn't a list
        #expect(CloudToolSchema.describedChoices("'a' (default) or 'b' (big, 8 GB)")?.map(\.title) == ["A", "B · big, 8 GB"])
        #expect(CloudToolSchema.statedDefault("Fly region. Defaults to iad. Other backends …") == "iad")
        #expect(CloudToolSchema.statedDefault("No default here.") == nil)
    }

    @Test func createFormComesFromTheSchema() {
        let schema = CloudToolSchema.read(Self.agentSchema)
        #expect(schema.actionKey == "action")
        let fields = schema.fields(for: "create")
        // name is the form's own field; id is for other actions; env is an object; image is update_image only; model is
        // set in HQ once connected.
        #expect(fields.map(\.name) == ["size"])
        let size = fields.first { $0.name == "size" }
        #expect(size?.kind == .choice && size?.choices == ["small", "medium", "large"] && size?.defaultValue == "small")
        #expect(schema.idKey(for: "start") == "id")
    }

    @Test func oneOfBranchesGiveEachActionItsFields() {
        let schema = CloudToolSchema.read([
            "type": "object",
            "oneOf": [
                ["properties": ["action": ["const": "create"], "name": ["type": "string"], "tier": ["enum": ["s", "m"]]], "required": ["name", "tier"]],
                ["properties": ["action": ["const": "stop"], "agent_id": ["type": "string"]], "required": ["agent_id"]],
            ],
        ])
        #expect(schema.actions == ["create", "stop"])
        let create = schema.fields(for: "create")
        #expect(create.map(\.name) == ["tier"])
        #expect(create.first?.required == true)
        #expect(schema.idKey(for: "stop") == "agent_id")
    }

    @Test func titlesReadAsWords() {
        #expect(CloudToolSchema.title("server_size") == "Server Size")
        #expect(CloudToolSchema.title("cpuKind") == "Cpu Kind")
        #expect(CloudToolSchema.title("medium") == "Medium")
    }

    @Test func eventStreamAnswerIsTheLastResult() throws {
        let stream = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"ok\":true}}\n\n"
        let value = try HermesCloudClient.answer(Data(stream.utf8), eventStream: true)
        #expect(value["result"]?["ok"]?.bool == true)
        let plain = try HermesCloudClient.answer(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), eventStream: false)
        #expect(plain["id"]?.int == 1)
    }

    @Test func tokenAnswerKeepsTheOldRefreshWhenNoneComes() throws {
        let first = try #require(PortalCredentials.read(["access_token": "a1", "refresh_token": "r1", "expires_in": 3600], clientId: "c", now: 1000))
        #expect(first.expiresAt == 4600 && first.refreshToken == "r1")
        #expect(!first.needsRenewal(now: 4000) && first.needsRenewal(now: 4550))
        let renewed = try #require(PortalCredentials.read(["access_token": "a2"], clientId: "c", previous: first, now: 5000))
        #expect(renewed.refreshToken == "r1" && renewed.expiresAt == 0 && !renewed.needsRenewal(now: 1e12))
        #expect(PortalCredentials.read(["error": "invalid_grant"], clientId: "c") == nil)
    }

    @Test func authorizeURLCarriesPKCEScopeAndResource() throws {
        let url = try #require(PortalAuth().authorizeURL(clientId: "mcp:abc", redirect: "http://127.0.0.1:5000/callback", challenge: "ch", state: "st"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "portal.nousresearch.com" && url.path == "/oauth/authorize")
        #expect(items["client_id"] == "mcp:abc" && items["code_challenge_method"] == "S256" && items["scope"] == "mcp:manage_agents")
        #expect(items["resource"] == "https://portal.nousresearch.com/mcp" && items["redirect_uri"] == "http://127.0.0.1:5000/callback")
    }

    // MARK: A run against the stub

    static func client(keychain: PortalKeychain) -> (HermesCloudClient, PortalLogin) {
        let session = PortalAuth.makeSession(protocols: [PortalStub.self])
        let login = PortalLogin(keychain: keychain, auth: PortalAuth(session: session))
        return (HermesCloudClient(login: login, session: session), login)
    }

    nonisolated static func mcp(_ id: JSONValue?, _ result: JSONValue) -> String {
        String(decoding: (try? JSONValue.object(["jsonrpc": "2.0", "id": id ?? .null, "result": result]).encoded()) ?? Data(), as: UTF8.self)
    }

    nonisolated static func toolText(_ value: JSONValue) -> JSONValue {
        let text = String(decoding: (try? value.encoded()) ?? Data(), as: UTF8.self)
        return ["content": [["type": "text", "text": .string(text)]]]
    }

    @Test func listCreateAndPollRunAsThePortalLogin() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok-1", refreshToken: "ref-1", expiresAt: 0, obtainedAt: 0))
        nonisolated(unsafe) var polls = 0
        PortalStub.reset { path, body in
            let id = body["id"]
            switch body["method"]?.string {
            case "initialize": return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s1"], Self.mcp(id, ["protocolVersion": "2025-06-18"]))
            case "notifications/initialized": return (202, [:], "")
            case "tools/list":
                return (200, ["Content-Type": "text/event-stream"], "data: " + Self.mcp(id, ["tools": [
                    ["name": "agents", "inputSchema": Self.realAgentsSchema], ["name": "agent", "inputSchema": Self.realAgentSchema]]]) + "\n\n")
            case "tools/call":
                let args = body["params"]?["arguments"]
                switch (body["params"]?["name"]?.string, args?["action"]?.string) {
                case ("agents", "list"): return (200, ["Content-Type": "application/json"], Self.mcp(id, Self.toolText(["agents": []])))
                case ("agent", "create"):
                    return (200, ["Content-Type": "application/json"], Self.mcp(id, Self.toolText(["agent": ["id": "ag_1", "name": args?["name"] ?? "", "status": "provisioning"]])))
                case ("agents", "get"):
                    polls += 1
                    let row: JSONValue = polls < 2 ? ["id": "ag_1", "name": "scratch", "status": "provisioning"]
                        : ["id": "ag_1", "name": "scratch", "status": "running", "dashboardUrl": "https://scratch.agents.nousresearch.com", "dashboardGatewayState": "active"]
                    return (200, ["Content-Type": "application/json"], Self.mcp(id, ["structuredContent": row, "content": []]))
                default: return (200, ["Content-Type": "application/json"], Self.mcp(id, ["isError": true, "content": [["type": "text", "text": "nope"]]]))
                }
            default: return (400, [:], "")
            }
        }
        let (client, _) = Self.client(keychain: keychain)
        #expect(try await client.listAgents().isEmpty)
        #expect(try await client.createFields().map(\.name) == ["size", "region"])
        #expect(await client.nameLimit() == 64)
        let made = try #require(try await client.create(name: "scratch", values: ["size": "pro"]))
        #expect(made.id == "ag_1" && !made.isReady)
        #expect(try await client.agent("ag_1")?.isReady == false)
        let ready = try #require(try await client.agent("ag_1"))
        #expect(ready.isReady && ready.dashboardURL?.host == "scratch.agents.nousresearch.com")
        let create = PortalStub.calls.first { $0["name"]?.string == "agent" }
        #expect(create?["arguments"]?["name"]?.string == "scratch" && create?["arguments"]?["size"]?.string == "pro")
        #expect(PortalStub.calls.first { $0["arguments"]?["action"]?.string == "get" }?["arguments"]?["agent_id"]?.string == "ag_1")
        #expect(PortalStub.methods.filter { $0 == "initialize" }.count == 1)
        #expect(PortalStub.authorizations.allSatisfy { $0 == "Bearer tok-1" })
    }

    @Test func aCreateWithNoAnswerIsNeverSentTwice() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        PortalStub.reset { _, body in
            let id = body["id"]
            switch body["method"]?.string {
            case "initialize": return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s1"], Self.mcp(id, [:]))
            case "notifications/initialized": return (202, [:], "")
            case "tools/list": return (200, ["Content-Type": "application/json"], Self.mcp(id, ["tools": [["name": "agent", "inputSchema": Self.realAgentSchema]]]))
            default: return (0, [:], "")   // the create's answer never comes
            }
        }
        let (client, _) = Self.client(keychain: keychain)
        do {
            _ = try await client.create(name: "scratch", values: [:])
            Issue.record("create should have failed")
        } catch let error as PortalError {
            #expect(error.kind == .network && error.mayHaveRun)
        }
        #expect(PortalStub.calls.count == 1)   // one create went out; the failure wasn't retried to read it
    }

    @Test func a401RenewsOnceThenSignsOut() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "old", refreshToken: "ref-1", expiresAt: 0, obtainedAt: 0))
        PortalStub.reset { path, body in
            if path == "/api/oauth/token" { return (200, ["Content-Type": "application/json"], #"{"access_token":"new","refresh_token":"ref-2","expires_in":3600}"#) }
            return (401, [:], "")
        }
        let (client, login) = Self.client(keychain: keychain)
        await #expect(throws: PortalError.signedOut) { try await client.listAgents() }
        // Renewed once (old → new), then the second 401 signed the phone out of Portal.
        #expect(PortalStub.authorizations.contains("Bearer old") && PortalStub.authorizations.contains("Bearer new"))
        #expect(await login.isSignedIn == false)
    }

    @Test func pricesReadAsDollars() {
        #expect(CloudPrices.dollars(0.56) == "$0.56")
        #expect(CloudPrices.dollars(2) == "$2")
        #expect(CloudPrices.dollars(32.7) == "$33")
        #expect(CloudPrices.dollars(0.5) == "$0.50")
        #expect(CloudPrices.size("Pro")?.perDay == 1.08)
        #expect(CloudPrices.size("max")?.stoppedPerDay == 0.50)
        #expect(CloudPrices.size("ultra") == nil)
        #expect(CloudPrices.lowestPerDay == 0.60)
    }

    @Test func closestRegionFollowsTheTimeZone() throws {
        let all = ["iad", "sjc", "lhr", "nrt", "syd", "gru"]
        func near(_ id: String) throws -> String? { CloudRegions.closest(among: all, zone: try #require(TimeZone(identifier: id))) }
        #expect(try near("America/Chicago") == "iad")
        #expect(try near("America/New_York") == "iad")
        #expect(try near("America/Los_Angeles") == "sjc")
        #expect(try near("America/Sao_Paulo") == "gru")
        #expect(try near("Europe/Paris") == "lhr")
        #expect(try near("Asia/Tokyo") == "nrt")
        #expect(try near("Australia/Sydney") == "syd")
        // A region Portal doesn't offer falls through to the next nearest.
        #expect(CloudRegions.closest(among: ["iad", "lhr"], zone: try #require(TimeZone(identifier: "Asia/Tokyo"))) == "lhr")
    }

    @Test func spendReadsLooseShapes() throws {
        let flat = try JSONValue.parse(Data(#"{"agent_id":"a1","cost_to_date_usd":3.24,"projected_monthly_usd":32.7,"hourly_rate":0.045}"#.utf8))
        #expect(CloudSpend.read(flat) == CloudSpend(toDate: 3.24, monthly: 32.7))
        let nested = try JSONValue.parse(Data(#"{"estimate":{"spent":"$1,204.50","per_month":"$40.00"}}"#.utf8))
        #expect(CloudSpend.read(nested) == CloudSpend(toDate: 1204.5, monthly: 40))
        let monthOnly = try JSONValue.parse(Data(#"{"monthly":12}"#.utf8))
        #expect(CloudSpend.read(monthOnly) == CloudSpend(toDate: nil, monthly: 12))
        #expect(CloudSpend.read(try JSONValue.parse(Data(#"{"status":"running","cpus":4}"#.utf8))) == nil)
    }

    @Test func pendingAgentIsFoundByIdOrByName() {
        let agent = CloudAgent(id: "a9", name: "Hermes Cloud", status: "provisioning", dashboardURL: nil, gatewayState: "unknown")
        #expect(CloudPending(id: nil, name: "hermes cloud", size: "pro", made: Date()).matches(agent))
        #expect(CloudPending(id: "a9", name: "Other", size: nil, made: Date()).matches(agent))
        #expect(!CloudPending(id: "a1", name: "Hermes Cloud", size: nil, made: Date()).matches(agent))
        let defaults = UserDefaults(suiteName: "tests.cloud.pending.\(UUID().uuidString)")!
        let saved = CloudPending(id: "a9", name: "Hermes Cloud", size: "pro", made: Date(timeIntervalSince1970: 1_800_000_000))
        saved.save(defaults)
        #expect(CloudPending.load(defaults) == saved)
        CloudPending.clear(defaults)
        #expect(CloudPending.load(defaults) == nil)
    }

    @MainActor @Test func portalStatusReadsAsWords() {
        func words(_ status: String, url: Bool = false, gateway: String = "unknown") -> String {
            CloudCopy.live(CloudAgent(id: "a", name: "A", status: status, dashboardURL: url ? URL(string: "https://a.agents.nousresearch.com") : nil,
                                      gatewayState: gateway))
        }
        #expect(words("provisioning") == "Nous is getting a machine ready")
        #expect(words("deploying") == "Installing Hermes")
        #expect(words("starting") == "Starting Hermes")
        #expect(words("running") == "Running. Waiting for its address")
        #expect(words("running", url: true, gateway: "down") == "Running. Waiting for it to answer")
        #expect(words("running", url: true, gateway: "active") == "It’s up. Opening the door…")
        #expect(words("migrating") == "Nous says: Migrating")
    }

    // MARK: Managing an agent that exists

    @Test func everyAgentActionIsOneThePortalOffers() {
        let schema = CloudToolSchema.read(Self.realAgentSchema)
        #expect(Set(CloudAction.allCases.map(\.rawValue)).isSubset(of: Set(schema.actions)))
        #expect(schema.fields(for: "resize").first { $0.name == "size" }?.choices == ["standard", "pro", "max"])
        #expect(schema.idKey(for: "rename") == "agent_id")
        #expect(CloudAction.restart.restarts && CloudAction.resize.restarts && !CloudAction.stop.restarts && !CloudAction.rename.restarts)
    }

    @Test func agentRowExtrasReadLoosely() throws {
        let camel = try #require(CloudAgent.read(["id": "a", "name": "A", "status": "running", "diskGb": 10, "diskOptions": [10, 20, 50],
                                                  "envKeys": ["TZ", "OPENAI_API_KEY"], "features": ["relay"], "imageVersion": "v0.22.5",
                                                  "updateAvailable": true]))
        #expect(camel.diskGB == 10 && camel.diskChoices == [10, 20, 50] && camel.envNames == ["TZ", "OPENAI_API_KEY"])
        #expect(camel.relay == true && camel.version == "v0.22.5" && camel.updateAvailable == true)
        let snake = try #require(CloudAgent.read(["id": "b", "status": "stopped", "disk_gb": 20, "env": ["B": "x", "A": "y"],
                                                  "features": ["relay": false]]))
        #expect(snake.diskGB == 20 && snake.envNames == ["A", "B"] && snake.relay == false && snake.updateAvailable == nil)
        let bare = try #require(CloudAgent.read(["id": "c", "status": "restarting"]))
        #expect(bare.diskGB == nil && bare.envNames.isEmpty && bare.relay == nil && bare.version.isEmpty && bare.isChanging)
    }

    @Test func teamGatewayReadsOnOffAndLinks() {
        #expect(CloudTeamGateway.read(["enabled": true, "platforms": ["Discord", ["platform": "telegram"]]])
                == CloudTeamGateway(enabled: true, platforms: ["discord", "telegram"]))
        #expect(CloudTeamGateway.read(["teamGateway": ["relay": false]]) == CloudTeamGateway(enabled: false))
        #expect(CloudTeamGateway.read(["agent_id": "a"]) == nil)
    }

    @Test func diskSizesReadFromARefusal() {
        #expect(CloudGatewayModel.diskSizes(in: "disk_gb must be one of the offered disk sizes: 10, 20, 50 GB") == [10, 20, 50])
        #expect(CloudGatewayModel.diskSizes(in: "Nous Portal refused that.") == nil)
        #expect(CloudGatewayModel.diskSizes(in: "Disk must be larger than 10 GB") == nil)
    }

    @Test func variableNamesAreShellNamesAndOnlyNamesAreKept() throws {
        #expect(CloudEnvNames.isValid("OPENAI_API_KEY") && CloudEnvNames.isValid("_x1"))
        #expect(!CloudEnvNames.isValid("1ABC") && !CloudEnvNames.isValid("A-B") && !CloudEnvNames.isValid("") && !CloudEnvNames.isValid("ÄB"))
        let defaults = try #require(UserDefaults(suiteName: "tests.cloud.env.\(UUID().uuidString)"))
        CloudEnvNames.save(["TZ", "A", "TZ"], for: "ag_1", defaults)
        #expect(CloudEnvNames.load("ag_1", defaults) == ["A", "TZ"])
        CloudEnvNames.save([], for: "ag_1", defaults)
        #expect(defaults.object(forKey: CloudEnvNames.key("ag_1")) == nil)
    }

    /// Audit 06-21: the "so far" clock of the update, add-on and Nous sheets counts hours past an hour.
    @MainActor @Test func elapsedCountsHours() {
        #expect(CloudCopy.elapsed(0) == "0:00")
        #expect(CloudCopy.elapsed(245) == "4:05")
        #expect(CloudCopy.elapsed(3599) == "59:59")
        #expect(CloudCopy.elapsed(3600) == "1:00:00")
        #expect(CloudCopy.elapsed(4503) == "1:15:03")
        #expect(CloudCopy.elapsed(-5) == "0:00")
    }

    @MainActor @Test func pricesShowWhatAChangeCostsOrSaves() {
        #expect(CloudCopy.priceChange(from: CloudPrices.size("standard"), to: CloudPrices.size("pro")) == "About $0.48 more a day: $1.08 instead of $0.60.")
        #expect(CloudCopy.priceChange(from: CloudPrices.size("pro"), to: CloudPrices.size("standard")) == "Saves about $0.48 a day: $0.60 instead of $1.08.")
        #expect(CloudCopy.priceChange(from: nil, to: CloudPrices.size("pro")) == nil)
        #expect(CloudCopy.stopDetail(CloudPrices.size("pro")) == "Saves about $0.95 a day. Everything on it is kept.")
        #expect(CloudCopy.stopMessage("A", size: CloudPrices.size("pro"), current: true).contains("HQ is using it now"))
        #expect(CloudCopy.spendLine(CloudSpend(toDate: 3.24, monthly: 32.7)) == "$3.24 so far · about $33 a month")
        #expect(CloudCopy.spendLine(nil) == nil)
        let stopped = CloudAgent(id: "a", name: "Night Shift", status: "stopped", dashboardURL: nil, gatewayState: "down")
        #expect(CloudCopy.connectTitle(stopped, saved: false) == "Start and Connect")
        #expect(CloudCopy.connectTitle(stopped, saved: true) == "Open Night Shift")
    }

    /// A Portal whose agent is `state` (the stub moves it along), for the action tests below.
    nonisolated static func managedPortal(_ state: @escaping @Sendable (_ action: String?, _ args: JSONValue?) -> JSONValue?) -> @Sendable (String, JSONValue) -> (Int, [String: String], String) {
        { _, body in
            let id = body["id"]
            switch body["method"]?.string {
            case "initialize": return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s1"], Self.mcp(id, [:]))
            case "notifications/initialized": return (202, [:], "")
            case "tools/list":
                return (200, ["Content-Type": "application/json"], Self.mcp(id, ["tools": [
                    ["name": "agents", "inputSchema": Self.realAgentsSchema], ["name": "agent", "inputSchema": Self.realAgentSchema],
                    ["name": "team_gateway", "inputSchema": ["type": "object", "properties": [
                        "action": ["type": "string", "enum": ["enable", "disable", "status"]], "agent_id": ["type": "string"]]]]]]))
            case "tools/call":
                let args = body["params"]?["arguments"]
                guard let answer = state(args?["action"]?.string.map { "\(body["params"]?["name"]?.string ?? ""):\($0)" }, args) else {
                    return (200, ["Content-Type": "application/json"], Self.mcp(id, ["isError": true, "content": [["type": "text", "text": "Agent not found"]]]))
                }
                return (200, ["Content-Type": "application/json"], Self.mcp(id, Self.toolText(answer)))
            default: return (400, [:], "")
            }
        }
    }

    @Test func actionsSendTheAgentIdAndTheirFields() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        PortalStub.reset(Self.managedPortal { action, _ in
            switch action {
            case "team_gateway:status": return ["enabled": true, "platforms": ["discord"]]
            default: return ["ok": true, "agent": ["id": "ag_1", "name": "Renamed", "status": "running"]]
            }
        })
        let (client, _) = Self.client(keychain: keychain)
        #expect(await client.offered() == Set(CloudAction.allCases))
        #expect(await client.sizeChoices() == ["standard", "pro", "max"])
        #expect(try await client.act(.stop, on: "ag_1")?.id == "ag_1")
        try await client.act(.rename, on: "ag_1", ["name": "Renamed"])
        try await client.act(.updateEnv, on: "ag_1", ["env": ["TZ": "Europe/London"], "deleted_keys": ["OLD"]])
        try await client.act(.setFeature, on: "ag_1", ["feature_key": "relay", "enabled": true])
        #expect(await client.teamGateway("ag_1") == CloudTeamGateway(enabled: true, platforms: ["discord"]))
        let sent = PortalStub.calls.compactMap { $0["arguments"] }
        #expect(sent.map { $0["action"]?.string ?? "" } == ["stop", "rename", "update_env", "set_feature", "status"])
        #expect(sent.allSatisfy { $0["agent_id"]?.string == "ag_1" })
        #expect(sent[1]["name"]?.string == "Renamed")
        #expect(sent[2]["env"]?["TZ"]?.string == "Europe/London" && sent[2]["deleted_keys"]?[0]?.string == "OLD")
        #expect(sent[3]["feature_key"]?.string == "relay" && sent[3]["enabled"]?.bool == true)
    }

    @Test func aStopWithNoAnswerIsNeverSentTwice() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        PortalStub.reset { _, body in
            let id = body["id"]
            switch body["method"]?.string {
            case "initialize": return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "s1"], Self.mcp(id, [:]))
            case "notifications/initialized": return (202, [:], "")
            case "tools/list": return (200, ["Content-Type": "application/json"], Self.mcp(id, ["tools": [["name": "agent", "inputSchema": Self.realAgentSchema]]]))
            default: return (0, [:], "")
            }
        }
        let (client, _) = Self.client(keychain: keychain)
        do {
            try await client.act(.stop, on: "ag_1")
            Issue.record("stop should have failed")
        } catch let error as PortalError {
            #expect(error.kind == .network && error.mayHaveRun)
        }
        #expect(PortalStub.calls.count == 1)
    }

    @MainActor static func model(_ client: HermesCloudClient, _ login: PortalLogin, agents: [CloudAgent]) -> CloudGatewayModel {
        let driver = SignInServiceDriver(service: SignInService(store: AccountStore(vault: Fixtures.testVault("cloud-manage"))))
        let model = CloudGatewayModel(driver: driver, savedHosts: [], client: client, login: login)
        model.debugSetAgents(agents)
        return model
    }

    /// 2026-11-04: a resize to Max came back fine on Nous's side, but one status read dropped while the machine moved
    /// and HQ gave up with "The connection to Nous Portal dropped" over a half-done "Stopping · Pro".
    @MainActor @Test func resizeKeepsWatchingThroughADroppedStatusRead() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        nonisolated(unsafe) var polls = 0
        let portal = Self.managedPortal { action, _ in
            switch action {
            case "agent:resize": return ["ok": true]
            case "agents:status", "agents:get":
                return ["id": "ag_1", "name": "Hermes", "status": polls < 3 ? "stopping" : "running", "dashboardGatewayState": polls < 3 ? "down" : "active",
                        "size": ["key": polls < 3 ? "pro" : "max", "cpus": 4, "memoryMb": polls < 3 ? 4096 : 8192, "diskGb": polls < 3 ? 25 : 100]]
            default: return ["ok": true]
            }
        }
        PortalStub.reset { path, body in
            if body["params"]?["arguments"]?["action"]?.string == "status" {
                polls += 1
                if polls == 2 { return (0, [:], "") }   // this read never answers
            }
            return portal(path, body)
        }
        let (client, login) = Self.client(keychain: keychain)
        let running = CloudAgent(id: "ag_1", name: "Hermes", status: "running", dashboardURL: URL(string: "https://hermes.agents.nousresearch.com"),
                                 gatewayState: "active", size: "pro")
        let model = Self.model(client, login, agents: [running])
        model.perform(.resize, on: running, ["size": "max"])
        for _ in 0..<150 where model.busy["ag_1"] != nil { try await Task.sleep(for: .milliseconds(200)) }
        #expect(model.actionFailure["ag_1"] == nil)
        #expect(model.agent("ag_1")?.size == "max" && model.agent("ag_1")?.memoryMB == 8192)
        #expect(polls >= 3)
    }

    @MainActor @Test func stopIsWatchedUntilNousSaysStopped() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        nonisolated(unsafe) var polls = 0
        PortalStub.reset(Self.managedPortal { action, _ in
            switch action {
            case "agent:stop": return ["ok": true]
            case "agents:status", "agents:get":
                polls += 1
                return ["id": "ag_1", "name": "Night Shift", "status": polls < 2 ? "stopping" : "stopped", "dashboardGatewayState": "down"]
            default: return ["ok": true]
            }
        })
        let (client, login) = Self.client(keychain: keychain)
        let running = CloudAgent(id: "ag_1", name: "Night Shift", status: "running", dashboardURL: URL(string: "https://night.agents.nousresearch.com"),
                                 gatewayState: "active", size: "pro")
        let model = Self.model(client, login, agents: [running])
        model.stop(running)
        #expect(model.busy["ag_1"]?.action == .stop)
        model.stop(running)   // a second tap while it runs does nothing
        for _ in 0..<100 where model.busy["ag_1"] != nil { try await Task.sleep(for: .milliseconds(200)) }
        #expect(model.busy["ag_1"] == nil && model.actionFailure["ag_1"] == nil)
        #expect(model.agent("ag_1")?.isStopped == true)
        #expect(model.agent("ag_1")?.size == "pro")   // the poll's row had no size: the known one stays
        #expect(PortalStub.calls.filter { $0["arguments"]?["action"]?.string == "stop" }.count == 1)
    }

    @MainActor @Test func deleteDropsTheAgentOnceNousNoLongerListsIt() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        nonisolated(unsafe) var lists = 0
        PortalStub.reset(Self.managedPortal { action, _ in
            switch action {
            case "agent:destroy": return ["ok": true]
            case "agents:list":
                lists += 1
                return ["agents": lists < 2 ? [["id": "ag_1", "name": "Old", "status": "destroying"]] : []]
            default: return ["ok": true]
            }
        })
        let (client, login) = Self.client(keychain: keychain)
        let agent = CloudAgent(id: "ag_1", name: "Old", status: "stopped", dashboardURL: nil, gatewayState: "down")
        let model = Self.model(client, login, agents: [agent])
        var routes: [CloudGatewayModel.Route] = []
        model.onRoute = { routes.append($0) }
        model.destroy(agent)
        for _ in 0..<100 where model.busy["ag_1"] != nil { try await Task.sleep(for: .milliseconds(200)) }
        #expect(model.agents.isEmpty && model.actionFailure["ag_1"] == nil)
        #expect(routes == [.root])
    }

    @MainActor @Test func onlyNousAddressesAreCloudGateways() {
        #expect(CloudGatewayFlow.isCloud(URL(string: "https://hermes-cloud-1234.agents.nousresearch.com")))
        #expect(CloudGatewayFlow.isCloud(URL(string: "https://X.Agents.NousResearch.com:443/")))
        #expect(!CloudGatewayFlow.isCloud(URL(string: "https://agents.nousresearch.com.evil.example")))
        #expect(!CloudGatewayFlow.isCloud(URL(string: "http://127.0.0.1:9119")))
        #expect(!CloudGatewayFlow.isCloud(nil))
    }

    /// A row as Portal really sends it (keys from the owner's phone, 2026-10-31).
    @Test func realAgentRowReadsHealthLimitsAndErrors() throws {
        let row: JSONValue = ["id": "ag_1", "name": "Hermes", "status": "running", "health": "healthy", "healthDetail": "",
                              "dashboardUrl": "https://hermes-5678.agents.nousresearch.com", "size": "standard", "region": "iad",
                              "volumeGb": 10, "changeSizeAvailable": false, "diskExpansionAvailable": true, "lastError": "",
                              "scheduledDeletionAt": "", "model": "Hermes-4-405B", "isSleeping": false, "computeProvider": "digitalocean"]
        let agent = try #require(CloudAgent.read(row))
        #expect(agent.gatewayState == "active" && agent.isReady)
        #expect(agent.diskGB == 10 && agent.canResize == false && agent.canGrowDisk == true && agent.model == "Hermes-4-405B")
        let sick = try #require(CloudAgent.read(["id": "ag_2", "status": "failed", "health": "unhealthy", "healthDetail": "no answer on 8642",
                                                 "lastError": "image pull failed", "scheduledDeletionAt": "2026-11-07"]))
        #expect(sick.gatewayState == "down" && sick.healthDetail == "no answer on 8642" && sick.lastError == "image pull failed")
        #expect(sick.deletesAt == "2026-11-07" && sick.canResize == nil)
        #expect(CloudAgent.gatewayWord("Degraded") == "degraded" && CloudAgent.gatewayWord("starting") == "unknown")
    }

    @MainActor @Test func gatewayRowsSayStateSizeAndDailyPrice() {
        let url = URL(string: "https://hermes-5678.agents.nousresearch.com")
        let running = CloudAgent(id: "a", name: "Hermes", status: "running", dashboardURL: url, gatewayState: "active", size: "standard")
        #expect(CloudCopy.gatewayRowLine(running) == "Running · Standard · $0.60 a day")
        let stopped = CloudAgent(id: "a", name: "Hermes", status: "stopped", dashboardURL: url, gatewayState: "down", size: "pro")
        #expect(CloudCopy.gatewayRowLine(stopped) == "Stopped · Pro · $0.13 a day")
    }

    @MainActor @Test func aGatewayFindsItsAgentByHost() throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        let (client, login) = Self.client(keychain: keychain)
        let model = Self.model(client, login, agents: [
            CloudAgent(id: "a1", name: "Hermes", status: "running", dashboardURL: URL(string: "https://hermes-5678.agents.nousresearch.com"), gatewayState: "active"),
            CloudAgent(id: "a2", name: "Hermes Cloud", status: "running", dashboardURL: URL(string: "https://hermes-cloud-1234.agents.nousresearch.com"), gatewayState: "active")])
        #expect(model.agent(atHost: try #require(URL(string: "https://Hermes-Cloud-1234.agents.nousresearch.com/")))?.id == "a2")
        #expect(model.agent(atHost: try #require(URL(string: "https://other-1.agents.nousresearch.com")) ) == nil)
        #expect(model.agent(atHost: try #require(URL(string: "https://hermes-5678.agents.nousresearch.com:443")))?.id == "a1")
    }

    @MainActor @Test func openedFromAGatewayGoesStraightToItsAgent() async throws {
        let keychain = PortalKeychain(service: "tests.portal.\(UUID().uuidString)")
        defer { keychain.clear() }
        keychain.save(PortalCredentials(clientId: "mcp:c", accessToken: "tok", refreshToken: "ref", expiresAt: 0, obtainedAt: 0))
        PortalStub.reset(Self.managedPortal { action, _ in
            switch action {
            case "agents:list": return ["agents": [
                ["id": "ag_1", "name": "Research Bot", "status": "running", "dashboardUrl": "https://research-1.agents.nousresearch.com"],
                ["id": "ag_2", "name": "Hermes Cloud", "status": "running", "dashboardUrl": "https://hermes-cloud-1234.agents.nousresearch.com"]]]
            default: return ["ok": true]
            }
        })
        let (client, login) = Self.client(keychain: keychain)
        let model = Self.model(client, login, agents: [])
        var routes: [CloudGatewayModel.Route] = []
        model.onRoute = { routes.append($0) }
        model.openHost = "hermes-cloud-1234.agents.nousresearch.com"
        model.load()
        for _ in 0..<50 where routes.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(routes == [.agent("ag_2")])
        #expect(model.openHost == nil)
    }

    /// Portal's MCP row as it really came on 2026-11-04: `size` is an object, not a word.
    @Test func sizeObjectGivesKeyMemoryAndScreen() throws {
        let row = try JSONValue.parse(Data(#"""
        {"id":"ag_1","name":"Hermes","status":"RUNNING","region":"sjc","health":"HEALTHY","computeProvider":"fly",
         "size":{"key":"standard","cpus":2,"memoryMb":2048,"diskGb":25},"volumeGb":25,"isSleeping":false,
         "capabilities":{"canUpdateImage":true},"changeSizeAvailable":true}
        """#.utf8))
        let agent = try #require(CloudAgent.read(row))
        #expect(agent.size == "standard")
        #expect(agent.memoryMB == 2048)
        #expect(agent.cpus == 2)
        #expect(agent.diskGB == 25)
        #expect(CloudPrices.size(agent.size) != nil)
        #expect(CloudScreen.included(memoryMB: agent.memoryMB) == false)
        #expect(CloudScreen.included(memoryMB: 8192) == true)
        #expect(CloudScreen.included(memoryMB: nil) == nil)
        #expect(CloudScreen.size(in: ["standard", "pro", "max"]) == "max")
        #expect(CloudScreen.size(in: ["standard", "pro"]) == nil)
        // The web's plain-word shape still reads.
        let plain = try #require(CloudAgent.read(try JSONValue.parse(Data(#"{"id":"ag_2","status":"running","size":"pro"}"#.utf8))))
        #expect(plain.size == "pro")
        #expect(plain.memoryMB == nil)
    }
}
