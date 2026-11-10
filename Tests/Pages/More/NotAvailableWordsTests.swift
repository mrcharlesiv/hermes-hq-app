// Mac UX stress test #10: a page or action this Hermes doesn't have reads "Not available on this Hermes", not as a
// failure ("The gateway's answer couldn't be read.").

import Foundation
import Testing
@testable import HermesHQNative

@Suite struct NotAvailableWordsTests {
    /// FastAPI's own 404/405 for a route it doesn't know (or no reason at all) is "not available".
    @Test func unknownRouteReadsAsNotAvailable() {
        #expect(PagesREST.reason(HTTPError(status: 404, body: #"{"detail":"Not Found"}"#)) == MoreWire.olderHermes)
        #expect(PagesREST.reason(HTTPError(status: 405, body: #"{"detail":"Method Not Allowed"}"#)) == MoreWire.olderHermes)
        #expect(PagesREST.reason(HTTPError(status: 404, body: nil)) == MoreWire.olderHermes)
        #expect(PagesREST.reason(HTTPError(status: 404, body: "<html>404</html>")) == MoreWire.olderHermes)
        #expect(MoreWire.olderHermes == "Not available on this Hermes. Updating Hermes may add it.")
    }

    /// A 404 that names what is gone keeps its own words; other statuses are unchanged.
    @Test func namedNotFoundKeepsItsWords() {
        #expect(PagesREST.reason(HTTPError(status: 404, body: #"{"detail":"Session not found"}"#)) == "Session not found")
        #expect(PagesREST.reason(HTTPError(status: 500, body: #"{"detail":"Not Found"}"#)) == "Not Found")
        #expect(PagesREST.reason(HTTPError(status: 500, body: nil)) == "The gateway couldn’t do that.")
    }

    /// An empty answer is a Hermes without the route; a wrong shape still couldn't be read.
    @Test func emptyAnswerIsNotAvailable() {
        #expect(PagesREST.unreadable(.object([:])).message == MoreWire.olderHermes)
        #expect(PagesREST.unreadable(.null).message == MoreWire.olderHermes)
        #expect(PagesREST.unreadable(.array([])).message == MoreWire.olderHermes)
        #expect(PagesREST.unreadable(.object(["x": .number(1)])).message == "The gateway’s answer couldn’t be read.")
        #expect(PagesREST.reason(StarMapGraphError()) == MoreWire.olderHermes)
    }

    @Test func titleSwitchesOnlyForNotAvailable() {
        #expect(MoreWire.failureTitle("Couldn’t Load Webhooks", reason: MoreWire.olderHermes) == "Not Available on This Hermes")
        #expect(MoreWire.failureTitle("Couldn’t Load Webhooks", reason: "Busy") == "Couldn’t Load Webhooks")
    }

    /// [mac] Stress test 2026-10-28 #10: the line under the title names the page instead of repeating the title.
    @Test func notAvailableBodyNamesThePage() {
        #expect(MoreWire.notAvailableBody("Messaging") == "This Hermes doesn’t have Messaging. Updating Hermes may add it.")
        #expect(MoreWire.notAvailableBody(nil) == MoreWire.olderHermes)
        #expect(MoreWire.pageName(fromFailureTitle: "Couldn’t Load Star Map") == "Star Map")
        #expect(MoreWire.pageName(fromFailureTitle: "Couldn’t Load the Board") == "Board")
        #expect(MoreWire.pageName(fromFailureTitle: "Preview Unavailable") == nil)
    }
}

/// The Star Map graph of an empty answer, thrown.
private func StarMapGraphError() -> Error {
    do { _ = try StarMapGraph(json: .object([:])); return PagesMessageError("no throw") } catch { return error }
}
