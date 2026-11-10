// More › Import Sessions (docs/spec/3x-morepages.md §14, acceptance 1): the param builders send only the keys Hermes
// lists, paging merges without duplicates, the row's words, decoders with bad data, the scan-help words
// (`S/import-scan-help.ts`), and the list's paging state against a scripted client.

import Foundation
import Testing
@testable import HermesHQNative

struct ForeignSessionsWireTests {
    private func keys(_ value: JSONValue) -> [String] { (value.object ?? [:]).keys.sorted() }

    @Test func listParamsSendOnlyTheAllowedKeys() {
        typealias API = ForeignSessionsAPI
        // The first page of All for the default bot: only the page size.
        #expect(API.listParams(profile: nil, source: nil, offset: 0) == ["limit": 50])
        #expect(API.listParams(profile: "default", source: nil, offset: 0) == ["limit": 50])
        #expect(API.listParams(profile: "", source: "", offset: 0) == ["limit": 50])
        #expect(API.listParams(profile: "inbox", source: "codex", offset: 50) == ["profile": "inbox", "source": "codex", "offset": 50, "limit": 50])
        #expect(API.listParams(profile: nil, source: "claude", offset: 0) == ["source": "claude", "limit": 50])
        // "all" (or anything that is not a source Hermes knows) is never sent.
        #expect(keys(API.listParams(profile: nil, source: "all", offset: 100)) == ["limit", "offset"])
        let allowed: Set<String> = ["profile", "source", "offset", "limit"]
        for profile in [nil, "default", "inbox"] as [String?] {
            for source in [nil, "claude", "codex", "all", "gemini"] as [String?] {
                for offset in [0, 50, 1950] {
                    #expect(Set(keys(API.listParams(profile: profile, source: source, offset: offset))).isSubset(of: allowed))
                }
            }
        }
    }

    @Test func previewAndImportParamsAreTheIdAndTheBot() {
        typealias API = ForeignSessionsAPI
        #expect(API.idParams(profile: nil, id: "fs-0001") == ["id": "fs-0001"])
        #expect(API.idParams(profile: "default", id: "fs-0001") == ["id": "fs-0001"])
        #expect(API.idParams(profile: "inbox", id: "fs-0001") == ["id": "fs-0001", "profile": "inbox"])
    }

    @Test func callsUseTheThreeMethodsWithExactlyThoseParams() async throws {
        let client = MoreFakeClient { request in
            switch request.path {
            case "session.foreign.list": return ["sessions": [], "next_offset": .null, "host": "h", "unreadable": 0]
            case "session.foreign.preview": return ["messages": [["role": "user", "content": "hi"]], "total": 1, "truncated": false]
            default: return ["session_id": "new-1", "already_imported": false]
            }
        }
        let api = ForeignSessionsAPI(client: client)
        _ = try await api.list(profile: "inbox", source: "codex", offset: 50)
        _ = try await api.preview(profile: "inbox", id: "fs-0009")
        let made = try await api.importSession(profile: nil, id: "fs-0009")
        #expect(made.sessionId == "new-1" && !made.alreadyImported)
        #expect(client.logLines == ["RPC session.foreign.list", "RPC session.foreign.preview", "RPC session.foreign.import"])
        #expect(client.log[0].body == ["profile": "inbox", "source": "codex", "offset": 50, "limit": 50])
        #expect(client.log[1].body == ["profile": "inbox", "id": "fs-0009"])
        #expect(client.log[2].body == ["id": "fs-0009"])
    }

    @Test func decodersSurviveBadData() throws {
        let page = ForeignPage(["sessions": [.null, "text", ["source": "claude"], ["id": 7, "title": 9], [], ["id": "  "],
                                             ["id": "ok", "source": "codex", "title": .null, "cwd": "", "mtime": "1760000000", "turn_count": "12",
                                              "excerpt": 4, "label": ""],
                                             ["id": "neg", "turn_count": -3, "mtime": "soon"]],
                                "next_offset": "50", "host": "", "unreadable": "3"])
        #expect(page.sessions.map(\.id) == ["ok", "neg"])
        let ok = page.sessions[0]
        #expect(ok.label == "Codex" && ok.title == "" && ok.cwd == nil && ok.turnCount == 12 && ok.excerpt == "")
        #expect(ok.modified == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(page.sessions[1].turnCount == 0 && page.sessions[1].modified == nil)
        #expect(page.nextOffset == 50 && page.host == nil && page.unreadable == 3)
        // An empty object, an array where an object was expected, a next offset that does not move.
        #expect(ForeignPage([:]).sessions.isEmpty && ForeignPage([:]).nextOffset == nil)
        #expect(ForeignPage(["sessions": ["a": 1], "next_offset": 0, "unreadable": -2]) == ForeignPage([:]))
        #expect(ForeignPage([1, 2, 3]).sessions.isEmpty)

        let preview = try ForeignPreview(["messages": [["role": "user", "content": "hi"], ["content": "no role"], ["role": "assistant"], 5, .null,
                                                       ["role": "assistant", "content": ""]],
                                          "total": "90", "truncated": true, "already_imported": "", "cwd": .null])
        #expect(preview.messages == [ForeignTurn(role: "user", content: "hi"), ForeignTurn(role: "assistant", content: "no role")])
        #expect(preview.total == 90 && preview.truncated && preview.alreadyImported == nil && preview.cwd == nil)
        #expect(try ForeignPreview(["already_imported": "s-9"]).alreadyImported == "s-9")
        #expect(try ForeignPreview([:]).messages.isEmpty)
        #expect(throws: (any Error).self) { try ForeignPreview("nope") }
        #expect(throws: (any Error).self) { try ForeignPreview([1]) }
        #expect(throws: (any Error).self) { try ForeignImportResult([:]) }
        #expect(throws: (any Error).self) { try ForeignImportResult(["session_id": ""]) }
        #expect(throws: (any Error).self) { try ForeignImportResult(.null) }
        #expect(try ForeignImportResult(["session_id": "s", "already_imported": "yes"]).alreadyImported == false)
    }
}

struct ForeignSessionsRulesTests {
    private func row(_ id: String, title: String = "T", source: String = "claude", cwd: String? = "/home/hermes/projects/site",
                     turns: Int = 12, excerpt: String = "", modified: Date? = nil) -> ForeignSession {
        ForeignSession(id: id, source: source, label: ForeignSessions.sourceName(source), title: title, cwd: cwd, modified: modified,
                       turnCount: turns, excerpt: excerpt)
    }

    @Test func pagesMergeWithoutDuplicates() {
        let first = (0..<50).map { row("fs-\($0)") }
        // The second page overlaps the first by one row and repeats one of its own.
        var second = (49..<100).map { row("fs-\($0)", title: "newer") }
        second.append(row("fs-99", title: "again"))
        let merged = ForeignSessions.merge(first, second)
        #expect(merged.count == 100)
        #expect(Set(merged.map(\.id)).count == 100)
        #expect(merged.map(\.id) == (0..<100).map { "fs-\($0)" })
        // A row seen again keeps its place and takes the newer copy.
        #expect(merged[49].title == "newer" && merged[99].title == "again")
        #expect(ForeignSessions.merge([], []).isEmpty)
        #expect(ForeignSessions.merge([row("a"), row("a"), row("b")], [row("b"), row("c")]).map(\.id) == ["a", "b", "c"])
        // 2,000 rows in 40 pages stay unique and in order.
        var all: [ForeignSession] = []
        for page in 0..<40 { all = ForeignSessions.merge(all, (max(0, page * 50 - 1)..<(page + 1) * 50).map { row("r\($0)") }) }
        #expect(all.count == 2000 && all.last?.id == "r1999")
    }

    @Test func rowTextNamesTheFolderTheCountAndTheAge() {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let us = Locale(identifier: "en_US")
        let session = row("a", title: "  Fix the\nflaky   login test ", turns: 12, excerpt: " Let’s look\n\n at it.  ", modified: now.addingTimeInterval(-7200))
        #expect(ForeignSessions.title(session) == "Fix the flaky login test")
        #expect(ForeignSessions.detail(session, now: now, locale: us) == "site · 12 messages · 2 hours ago")
        #expect(ForeignSessions.excerpt(session) == "Let’s look at it.")
        // No folder, one message, no time.
        #expect(ForeignSessions.detail(row("b", cwd: nil, turns: 1), now: now, locale: us) == "1 message")
        #expect(ForeignSessions.detail(row("c", cwd: "/", turns: 0, modified: now.addingTimeInterval(-5)), now: now, locale: us) == "0 messages · just now")
        // A clock ahead of the phone's never reads as the future.
        #expect(ForeignSessions.detail(row("d", turns: 2, modified: now.addingTimeInterval(900)), now: now, locale: us) == "site · 2 messages · just now")
        // No title: the app it came from names it.
        #expect(ForeignSessions.title(row("e", title: " \n ", source: "codex")) == "Codex Conversation")
        #expect(ForeignSessions.title(ForeignSession(id: "f", source: "", label: "", title: "", cwd: nil, modified: nil, turnCount: 0, excerpt: "")) == "Untitled Conversation")
        #expect(ForeignSessions.excerpt(row("g")) == nil)
        #expect(ForeignSessions.excerpt(row("h", excerpt: String(repeating: "x", count: 5000)))?.count == 400)
        #expect(ForeignSessions.spoken(session, now: now).hasPrefix("Fix the flaky login test, Claude Code, site · 12 messages"))
        #expect(ForeignSessions.sourceName("claude") == "Claude Code" && ForeignSessions.sourceName("codex") == "Codex")
        #expect(ForeignSessionsStore.Source.allCases.map(\.title) == ["All", "Claude Code", "Codex"])
        #expect(ForeignSessionsStore.Source.allCases.map(\.wire) == [nil, "claude", "codex"])
    }

    @Test func searchLooksAtTitleFolderAndExcerpt() {
        let rows = [row("a", title: "Pricing page", cwd: "/w/site"), row("b", title: "Other", cwd: "/w/Billing"),
                    row("c", title: "Third", cwd: nil, excerpt: "about PRICING tiers")]
        #expect(ForeignSessions.filter(rows, query: "pricing").map(\.id) == ["a", "c"])
        #expect(ForeignSessions.filter(rows, query: " billing ").map(\.id) == ["b"])
        #expect(ForeignSessions.filter(rows, query: "   ").count == 3)
        #expect(ForeignSessions.filter(rows, query: "nothing").isEmpty)
    }

    /// `S/import-scan-help.ts`.
    @Test func scanHelpComesFromTheErrorItself() {
        typealias F = ForeignSessions
        let signIn = "Your sign-in to Hermes has expired or was rejected. Sign in again, then try again."
        let slow = "Reading the Claude Code and Codex logs on the computer running Hermes took too long. Try again in a moment."
        let unreachable = "Hermes HQ can’t reach the computer running Hermes. Check the connection, then try again."
        #expect(F.scanHelp(message: "HTTP 401") == signIn)
        #expect(F.scanHelp(message: "Authentication expired") == signIn)
        #expect(F.scanHelp(message: "404 Not Found") == "This Hermes doesn’t offer importing sessions yet. Update Hermes on the computer running Hermes to use it.")
        #expect(F.scanHelp(message: "request timed out") == slow)
        #expect(F.scanHelp(message: "504") == slow)
        #expect(F.scanHelp(message: "Load failed") == unreachable)
        #expect(F.scanHelp(message: "The network connection was lost.") == unreachable)
        #expect(F.scanHelp(message: "disk  is\nfull") == "\(F.scanHelpText) (disk is full)")
        #expect(F.scanHelp(message: String(repeating: "x", count: 200)) == F.scanHelpText)
        #expect(F.scanHelp(message: "") == F.scanHelpText)
        #expect(F.scanHelp(HTTPError(status: 403, body: nil)) == signIn)
        #expect(F.scanHelp(GatewayFailure.timeout) == slow)
        #expect(F.scanHelp(URLError(.notConnectedToInternet)) == unreachable)
        // A gateway without the method: the "older Hermes" words (the More row goes next time).
        #expect(F.scanHelp(RPCError(code: -32601, message: "Method not found: session.foreign.list")) == MoreWire.olderHermes)
        #expect(F.scanHelp(RPCError(code: -32000, message: "the scan broke")) == "\(F.scanHelpText) (the scan broke)")
    }

    /// `S/audit-c-format.ts` `friendlyHostName`, `importPreviewText`.
    @Test func hostAndPreviewWords() {
        typealias F = ForeignSessions
        #expect(F.friendlyHost("Robins-Mac-mini.local") == "Robin’s Mac mini")
        #expect(F.friendlyHost("studio.example.com") == "studio")
        #expect(F.friendlyHost("192.168.1.20") == "192.168.1.20")
        #expect(F.friendlyHost("build-box") == "build box")
        #expect(F.friendlyHost(nil) == "")
        #expect(F.readingFrom("Robins-Mac-mini.local") == "Reading from Robin’s Mac mini")
        #expect(F.readingFrom(" ") == "Reading from the computer running Hermes")
        #expect(F.previewText("Done.\n[ran tool: read_file]\n[ran tool: read_file]\n\n[ran tool: terminal]\nNext.")
                == "Done.\nUsed read_file (2×) and terminal\nNext.")
        #expect(F.previewText("plain [ran tool: x] inline") == "plain [ran tool: x] inline")
        #expect(F.speaker(ForeignTurn(role: "user", content: "x"), label: "Codex") == "You")
        #expect(F.speaker(ForeignTurn(role: "assistant", content: "x"), label: "Codex") == "Codex")
    }
}

@MainActor
struct ForeignSessionsStoreTests {
    /// A gateway with `total` sessions, paged as Hermes pages them.
    private func gateway(total: Int, overlap: Bool = false) -> MoreFakeClient {
        MoreFakeClient { request in
            let params = request.body?.object ?? [:]
            let source = params["source"]?.string
            let ids = (0..<total).filter { source == nil || (source == "claude") == ($0 % 2 == 0) }
            let offset = params["offset"]?.int ?? 0, limit = params["limit"]?.int ?? 50
            var page = Array(ids.dropFirst(offset).prefix(limit))
            if overlap, offset > 0, offset <= ids.count { page.insert(ids[offset - 1], at: 0) }
            let rows: [JSONValue] = page.map { ["id": .string("fs-\($0)"), "source": $0 % 2 == 0 ? "claude" : "codex", "title": .string("Session \($0)"),
                                                "turn_count": 4, "mtime": 1_760_000_000] }
            return ["sessions": .array(rows), "next_offset": offset + limit < ids.count ? .number(Double(offset + limit)) : .null,
                    "host": "my-mac.local", "unreadable": offset == 0 ? 3 : 0]
        }
    }

    @Test func firstPageThenLoadMoreReachesTheEndWithoutDuplicates() async {
        let client = gateway(total: 120, overlap: true)
        let store = ForeignSessionsStore(client: client, profile: "default")
        var firstReads: [Bool] = []
        store.onFirstRead = { firstReads.append($0 == nil) }
        #expect(store.phase == .loading)
        store.reload()
        await store.settle()
        #expect(store.phase == .loaded && store.rows.count == 50 && store.hasMore && store.unreadable == 3)
        #expect(store.host == "my-mac.local" && firstReads == [true])
        store.loadMore()
        // A second and third tap while the page is on its way ask nothing more.
        store.loadMore(); store.loadMore()
        #expect(store.loadingMore)
        await store.settle()
        #expect(store.rows.count == 100 && store.hasMore && !store.loadingMore)
        store.loadMore()
        await store.settle()
        #expect(store.rows.count == 120 && !store.hasMore)
        #expect(Set(store.rows.map(\.id)).count == 120)
        store.loadMore()
        await store.settle()
        #expect(client.log.count == 3)
        #expect(client.log.map { $0.body?["offset"]?.int ?? 0 } == [0, 50, 100])
        #expect(client.log.allSatisfy { Set(($0.body?.object ?? [:]).keys).isSubset(of: ["limit", "offset"]) })
    }

    @Test func aSourceOrBotChangeStartsOverAndSendsIt() async {
        let client = gateway(total: 120)
        let store = ForeignSessionsStore(client: client, profile: "default")
        store.reload()
        await store.settle()
        store.setSource(.codex)
        #expect(store.phase == .loading && store.rows.isEmpty)
        await store.settle()
        #expect(store.rows.count == 50 && store.rows.allSatisfy { $0.source == "codex" })
        #expect(client.log.last?.body == ["source": "codex", "limit": 50])
        store.loadMore()
        await store.settle()
        #expect(store.rows.count == 60 && !store.hasMore)
        #expect(client.log.last?.body == ["source": "codex", "offset": 50, "limit": 50])
        store.setSource(.codex)      // the same source again reads nothing
        #expect(client.log.count == 3)
        store.setProfile("inbox")
        await store.settle()
        #expect(client.log.last?.body == ["profile": "inbox", "source": "codex", "limit": 50])
        store.setSource(.all)
        await store.settle()
        #expect(client.log.last?.body == ["profile": "inbox", "limit": 50])
        store.query = "session 11"
        #expect(store.searching && store.visible.map(\.id) == ["fs-11"])
    }

    @Test func aFailedFirstReadThenTryAgain() async {
        let client = MoreFakeClient { _ in throw RPCError(code: -32000, message: "the scan broke") }
        let store = ForeignSessionsStore(client: client, profile: "default")
        var errors: [Error?] = []
        store.onFirstRead = { errors.append($0) }
        store.reload()
        await store.settle()
        #expect(store.phase == .failed(help: "\(ForeignSessions.scanHelpText) (the scan broke)", reason: "the scan broke"))
        #expect(errors.count == 1 && errors[0] != nil)
        client.respond { _ in ["sessions": [["id": "a", "source": "claude"]], "next_offset": .null, "host": "h", "unreadable": 0] }
        store.reload()
        #expect(store.phase == .loading)
        await store.settle()
        #expect(store.phase == .loaded && store.rows.map(\.id) == ["a"] && !store.hasMore)
    }

    @Test func anOlderGatewayShowsTheOlderHermesWords() async {
        let client = MoreFakeClient { _ in throw RPCError(code: -32601, message: "Method not found: session.foreign.list") }
        let store = ForeignSessionsStore(client: client, profile: "default")
        var missing = false
        store.onFirstRead = { missing = $0.map(MoreWire.isMissingRoute) ?? false }
        store.reload()
        await store.settle()
        #expect(missing)
        if case .failed(let help, _) = store.phase { #expect(help == MoreWire.olderHermes) } else { Issue.record("expected the failed state") }
    }

    @Test func aFailedLoadMoreKeepsTheRowsAndCanBeTappedAgain() async {
        let client = gateway(total: 120)
        let store = ForeignSessionsStore(client: client, profile: "default")
        store.reload()
        await store.settle()
        let working = gateway(total: 120)
        client.respond { _ in throw HTTPError(status: 500, body: #"{"detail":"boom"}"#) }
        store.loadMore()
        await store.settle()
        #expect(store.rows.count == 50 && store.hasMore && store.moreError == "boom" && !store.loadingMore)
        client.respond { request in try await working.call(request.path, request.body ?? [:], timeout: .seconds(1)) }
        store.loadMore()
        await store.settle()
        #expect(store.rows.count == 100 && store.moreError == nil)
        // A refresh that fails keeps what is on screen.
        client.respond { _ in throw URLError(.timedOut) }
        store.reload(keeping: true)
        await store.settle()
        #expect(store.phase == .loaded && store.rows.count == 100)
    }

    @Test func aPagerThatNeverEndsIsStopped() async {
        // Every answer claims another page at the same offset and brings nothing new.
        let client = MoreFakeClient { request in
            let offset = request.body?["offset"]?.int ?? 0
            return ["sessions": offset == 0 ? [["id": "a"], ["id": "a"], ["id": "b"]] : [], "next_offset": 50, "host": "h"]
        }
        let store = ForeignSessionsStore(client: client, profile: "default")
        store.reload()
        await store.settle()
        #expect(store.rows.map(\.id) == ["a", "b"] && store.hasMore)
        store.loadMore()
        await store.settle()
        #expect(!store.hasMore && store.rows.count == 2)
    }

    @Test func twoThousandRowsPageInOrder() async {
        let store = ForeignSessionsStore(client: gateway(total: 2000, overlap: true), profile: "default")
        store.reload()
        await store.settle()
        var pages = 1
        while store.hasMore && pages < 60 {
            store.loadMore()
            await store.settle()
            pages += 1
        }
        #expect(pages == 40 && store.rows.count == 2000 && Set(store.rows.map(\.id)).count == 2000)
        #expect(store.rows.first?.id == "fs-0" && store.rows.last?.id == "fs-1999")
    }
}
