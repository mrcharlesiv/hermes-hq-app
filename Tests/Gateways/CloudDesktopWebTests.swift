// [cloud-desktop] A Hermes Cloud agent's own Hermes Desktop in the app (App/Gateways/CloudDesktopWeb.swift): which
// gateways have it, its address, which pages stay in the view, and a login store per agent.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct CloudDesktopWebTests {
    @Test func onlyNousHostedGatewaysHaveIt() {
        let cloud = URL(string: "https://hermes-5678.agents.nousresearch.com/some/path")!
        #expect(CloudDesktopWeb.address(cloud)?.absoluteString == "https://hermes-5678.agents.nousresearch.com/")
        #expect(CloudDesktopWeb.address(URL(string: "http://studio.local:9119")!) == nil)
        #expect(CloudDesktopWeb.address(nil) == nil)
    }

    @Test func signInStaysInsideAndTheAgentsLinksLeave() {
        let agent = "hermes-5678.agents.nousresearch.com"
        let page = URL(string: "https://\(agent)/chat")!
        // The agent itself and Nous's sign-in.
        #expect(CloudDesktopWeb.staysInside(URL(string: "https://\(agent)/auth/login?provider=nous")!, agentHost: agent, from: page))
        #expect(CloudDesktopWeb.staysInside(URL(string: "https://portal.nousresearch.com/oauth/authorize")!, agentHost: agent, from: page))
        // A link in a chat leaves for Safari.
        #expect(!CloudDesktopWeb.staysInside(URL(string: "https://example.com/")!, agentHost: agent, from: page))
        // An identity provider reached from Portal's sign-in page stays (the login comes back here).
        #expect(CloudDesktopWeb.staysInside(URL(string: "https://accounts.google.com/o/oauth2")!, agentHost: agent,
                                            from: URL(string: "https://portal.nousresearch.com/login")!))
        // Not a web page: the system opens it.
        #expect(!CloudDesktopWeb.staysInside(URL(string: "mailto:a@b.c")!, agentHost: agent, from: page))
    }

    @Test func eachAgentKeepsItsOwnLogin() {
        let one = CloudDesktopWeb.storeID("hermes-5678.agents.nousresearch.com")
        #expect(one == CloudDesktopWeb.storeID("HERMES-5678.agents.nousresearch.com"))
        #expect(one != CloudDesktopWeb.storeID("atlas-1000.agents.nousresearch.com"))
    }
}
