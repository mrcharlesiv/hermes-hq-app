// Review round 1 of the pages: hosted images only from public https hosts (r1-10), page reads parsed off the main
// thread, Artifacts never reading off screen and ids unique across profiles, archive's silence, sign-out forgetting the
// pages' choices, and the details scrub.

import Darwin
import Foundation
import Synchronization
import Testing
@testable import HermesHQNative

/// A synchronous probe (`pthread_main_np` is not an async-unsafe API).
nonisolated private func onMainThread() -> Bool { pthread_main_np() != 0 }

/// Records whether each answered request ran on the main thread.
nonisolated private final class ThreadLog: Sendable {
    private let state = Mutex<[String: Bool]>([:])
    func note(_ path: String) { let main = onMainThread(); state.withLock { $0[path] = main } }
    var all: [String: Bool] { state.withLock { $0 } }
}

struct PublicHostPolicyTests {
    private let lan = PublicHostPolicy.PublicHosts { _ in [[192, 168, 1, 20]] }
    private let tailnet = PublicHostPolicy.PublicHosts { _ in [[100, 101, 102, 103]] }
    private let loopback6 = PublicHostPolicy.PublicHosts { _ in [Array(repeating: 0, count: 15) + [1]] }
    private let internet = PublicHostPolicy.PublicHosts { _ in [[93, 184, 216, 34]] }
    private let mixed = PublicHostPolicy.PublicHosts { _ in [[93, 184, 216, 34], [10, 0, 0, 7]] }
    private let unknown = PublicHostPolicy.PublicHosts { _ in [] }

    @Test func onlyPublicHTTPSSpellingsPass() {
        func ok(_ s: String) -> Bool { PublicHostPolicy.publicHTTPS(URL(string: s)) }
        #expect(ok("https://images.example.com/a.png"))
        #expect(ok("https://93.184.216.34/a.png"))
        #expect(!ok("http://images.example.com/a.png"), "cleartext http")
        #expect(!ok("https://192.168.1.5/a.png"))
        #expect(!ok("https://10.0.0.8/a.png"))
        #expect(!ok("https://172.20.1.1/a.png"))
        #expect(!ok("https://100.64.0.1/a.png"), "CGNAT / Tailscale")
        #expect(!ok("https://100.101.102.104/a.png"), "a Tailscale address")
        #expect(!ok("https://127.0.0.1/a.png"))
        #expect(!ok("https://127.1/a.png"), "a short numeric form is an address")
        #expect(!ok("https://0x7f.0.0.1/a.png"))
        #expect(!ok("https://169.254.169.254/latest/meta-data"))
        #expect(!ok("https://my-mac.tail1234.ts.net/a.png"))
        #expect(!ok("https://printer.local/a.png"))
        #expect(!ok("https://localhost/a.png"))
        #expect(!ok("https://[::1]/a.png"))
        #expect(!ok("https://user:pw@images.example.com/a.png"))
    }

    @Test func addressesAreJudgedByTheirRoutableSpace() {
        #expect(PublicHostPolicy.publicAddress([8, 8, 8, 8]))
        #expect(!PublicHostPolicy.publicAddress([100, 64, 0, 1]))
        #expect(!PublicHostPolicy.publicAddress([192, 168, 0, 1]))
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 0, 1]
        #expect(!PublicHostPolicy.publicAddress(mapped), "IPv4-mapped LAN")
        let ula: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + Array(repeating: 0, count: 10)
        #expect(!PublicHostPolicy.publicAddress(ula), "Tailscale's IPv6 ULA")
        let global: [UInt8] = [0x26, 0x06, 0x47, 0x00] + Array(repeating: 0, count: 11) + [1]
        #expect(PublicHostPolicy.publicAddress(global))
    }

    @Test func aNameMustResolveOnlyToPublicAddresses() async {
        let url = URL(string: "https://cdn.example.com/a.png")
        #expect(await PublicHostPolicy.allowed(url, hosts: internet))
        #expect(!(await PublicHostPolicy.allowed(url, hosts: lan)), "split horizon to the LAN")
        #expect(!(await PublicHostPolicy.allowed(url, hosts: tailnet)))
        #expect(!(await PublicHostPolicy.allowed(url, hosts: loopback6)))
        #expect(!(await PublicHostPolicy.allowed(url, hosts: mixed)), "every address must be public")
        #expect(!(await PublicHostPolicy.allowed(url, hosts: unknown)), "a name that doesn't resolve")
    }

    @Test func redirectsGoOnlyToPublicHTTPSHostsAndAtMostFive() async {
        func admit(_ hop: Int, _ s: String, _ hosts: PublicHostPolicy.PublicHosts) async -> Bool {
            await RemoteImageFetch.admitRedirect(hops: hop, to: URL(string: s), hosts: hosts)
        }
        #expect(await admit(1, "https://cdn.example.com/b.png", internet))
        #expect(!(await admit(1, "https://192.168.1.1/admin", internet)), "a redirect to a LAN address")
        #expect(!(await admit(1, "https://router.example.com/", lan)), "a redirect to a name on the LAN")
        #expect(!(await admit(1, "https://nas.local/x.png", internet)))
        #expect(!(await admit(1, "http://cdn.example.com/b.png", internet)), "a downgrade to http")
        #expect(await admit(5, "https://cdn.example.com/b.png", internet))
        #expect(!(await admit(6, "https://cdn.example.com/b.png", internet)), "a sixth hop")
    }

    @Test func theTaskDelegateRefusesARedirectToTheLAN() async throws {
        let load = RemoteImageLoad(ceiling: 1024) { hop, url in
            await RemoteImageFetch.admitRedirect(hops: hop, to: url, hosts: PublicHostPolicy.PublicHosts { host in
                host == "cdn.example.com" ? [[93, 184, 216, 34]] : [[192, 168, 1, 1]]
            })
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://cdn.example.com/a.png")!)
        let response = HTTPURLResponse(url: URL(string: "https://cdn.example.com/a.png")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        func follow(_ target: String) async -> URLRequest? {
            await withCheckedContinuation { continuation in
                load.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: target)!)) {
                    continuation.resume(returning: $0)
                }
            }
        }
        #expect(await follow("https://cdn.example.com/b.png") != nil)
        #expect(await follow("https://intranet.example.com/x.png") == nil, "the name resolves to the LAN")
        task.cancel()
        session.invalidateAndCancel()
    }

    @Test func anHTTPImageIsNeverFetchedAndSaysItIsHostedElsewhere() async {
        let client = PagesFakeClient()
        let record = ArtifactRecord(id: "x", kind: .image, value: "http://192.168.1.20/cam.jpg", href: "http://192.168.1.20/cam.jpg",
                                    label: "cam.jpg", sessionId: "s", profile: nil, sessionTitle: "t", timestamp: 0)
        await #expect(throws: RemoteImageFetch.Refused.self) { try await ArtifactFiles.imageData(client, record) }
        #expect(client.log.isEmpty, "nothing goes to the gateway either")
        let refused = RemoteImageFetch.Refused(reason: "x")
        #expect(ArtifactFiles.isHostedElsewhere(refused))
        #expect(ArtifactFiles.failureText(refused, image: true) == "This image is on another site and couldn’t be shown here. Tap Open to view it.")
        let lan = ArtifactRecord(id: "y", kind: .image, value: "https://192.168.1.20/cam.jpg", href: "", label: "cam.jpg",
                                 sessionId: "s", profile: nil, sessionTitle: "t", timestamp: 0)
        await #expect(throws: RemoteImageFetch.Refused.self) { try await ArtifactFiles.imageData(client, lan) }
    }
}

@MainActor
struct PagesOffMainTests {
    @Test func pageReadsAreParsedOffTheMainThread() async throws {
        let threads = ThreadLog()
        let client = PagesFakeClient { request in
            threads.note(request.path)
            switch request.path {
            case "/api/plugins/kanban/board": return KanbanStoreTests.boardJSON([("t_a", "A", "todo")])
            case "/api/plugins/kanban/tasks/t_a": return ["task": ["id": "t_a", "title": "A", "status": "todo"], "comments": [], "events": []]
            case "/api/cron/jobs": return JobsStoreTests.jobs(["a"])
            case "/api/cron/jobs/a/runs": return ["runs": []]
            case "/api/fs/read-data-url": return ["dataUrl": "data:image/png;base64,YQ=="]
            default: return ["ok": true]
            }
        }
        #expect(onMainThread(), "the test itself runs on the main thread")
        let api = KanbanAPI(client: client)
        _ = try await api.board("")
        _ = try? await api.task("t_a", board: "")
        _ = try await api.boards()
        _ = try await api.profiles()
        let store = JobsStore(client: client, account: client.account, directory: nil)
        await store.refresh()
        _ = try await store.loadRuns(try #require(store.jobs.first))
        let image = ArtifactRecord(id: "i", kind: .image, value: "/home/hermes/a.png", href: "", label: "a.png", sessionId: "s",
                                   profile: "research", sessionTitle: "t", timestamp: 0)
        #expect(try await ArtifactFiles.imageData(client, image) == Data("a".utf8))
        let seen = threads.all
        for path in ["/api/plugins/kanban/board", "/api/plugins/kanban/tasks/t_a", "/api/plugins/kanban/boards",
                     "/api/plugins/kanban/profiles", "/api/cron/jobs", "/api/cron/jobs/a/runs", "/api/fs/read-data-url"] {
            #expect(seen[path] == false, "\(path) was read on the main thread (\(String(describing: seen[path])))")
        }
    }
}

@MainActor
struct ArtifactsStoreTests {
    @Test func aScopeChangeOffScreenReadsNothing() async throws {
        let client = PagesFakeClient { _ in ["sessions": []] }
        let store = ArtifactsStore(client: client, account: client.account, directory: nil)
        store.profilesProvider = { ["default", "finance"] }
        store.setScope("finance")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!client.log.contains { $0.path == ArtifactsStore.sessionsPath }, "no pass while the page isn't shown")
        store.pageShown()
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.log.filter { $0.path == ArtifactsStore.sessionsPath }.compactMap { $0.query["profile"] } == ["finance"])
    }

    @Test func theKeptIndexIsReadWhenThePageDrawsNotBefore() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pages-lazy-\(UUID().uuidString)")
        let url = dir.appending(path: "artifacts-index.json")
        let record = ArtifactRecord(id: ArtifactIndex.key(profile: "default", id: "a") + ":/x/a.png", kind: .image, value: "/x/a.png",
                                    href: "/x/a.png", label: "a.png", sessionId: "a", profile: "default", sessionTitle: "A", timestamp: 1)
        let file = ArtifactIndexFile(collector: ArtifactIndex.collectorVersion,
                                     entries: [ArtifactIndex.key(profile: "default", id: "a"): ArtifactIndexEntry(stamp: "1|1|", at: 1, artifacts: [record])])
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(file).write(to: url)
        let client = PagesFakeClient()
        let store = ArtifactsStore(client: client, account: client.account, directory: dir)
        #expect(!store.index.isLoaded && store.artifacts.isEmpty, "nothing is read at launch")
        store.prepare()
        #expect(store.index.isLoaded && store.artifacts.map(\.label) == ["a.png"], "a small index paints in the page's first frame")
        #expect(client.log.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func theSameSessionInTwoProfilesGivesDistinctIds() {
        let messages: [JSONValue] = [.object(["role": "assistant", "content": "Saved /home/hermes/out/chart.png", "timestamp": 2000])]
        let a = ArtifactCollector.collect(session: ArtifactSessionRow(id: "s-1", profile: "research", title: "A", preview: nil, messageCount: 1,
                                                                      lastActive: 1000, startedAt: 1000, cwd: nil, cwdPresent: false),
                                          messages: messages)
        let b = ArtifactCollector.collect(session: ArtifactSessionRow(id: "s-1", profile: "finance", title: "B", preview: nil, messageCount: 1,
                                                                      lastActive: 1000, startedAt: 1000, cwd: nil, cwdPresent: false),
                                          messages: messages)
        let all = ArtifactCollector.unique(a + b)
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)).count == 2, "ids are unique across profiles (\(all.map(\.id)))")
        #expect(ArtifactIndex.collectorVersion != "native-1", "indexes kept with the old ids are read again")
    }
}

@MainActor
struct PagesQuietAndForgetTests {
    @Test func archiveIsSilentAMoveIsNot() async throws {
        let client = PagesFakeClient { request in
            if request.path == "/api/plugins/kanban/board" { return KanbanStoreTests.boardJSON([("t_d", "D", "done"), ("t_b", "B", "blocked")]) }
            return ["ok": true]
        }
        let store = KanbanStore(api: KanbanAPI(client: client, nudger: KanbanNudger(client: client, delay: .seconds(60))),
                                account: client.account, directory: nil)
        await store.readBoard()
        let buzzes = Mutex(0)
        store.onWriteSucceeded = { buzzes.withLock { $0 += 1 } }
        #expect(await store.archive(try #require(store.board?.task("t_d"))) != nil)
        #expect(buzzes.withLock { $0 } == 0, "the Undo pill is archive's feedback")
        await store.move(try #require(store.board?.task("t_b")), to: "ready")
        #expect(buzzes.withLock { $0 } == 1)
    }

    @Test func signOutForgetsThePagesChoicesButNotTheKanbanSetting() {
        let account = GatewayAccount(id: "http://127.0.0.1:9735|forget-\(UUID().uuidString)", baseURL: URL(string: "http://127.0.0.1:9735")!,
                                     kind: .password, username: "pages", label: "t")
        let defaults = UserDefaults.standard
        let keys = [PagesTabs.tabKey(account), PagesTabs.availabilityKey(account), KanbanStore.slugKey(account),
                    PagesScope.defaultsKey(account), ArtifactsViewController.filterKey(account)]
        for key in keys { defaults.set("x", forKey: key) }
        defaults.set("on", forKey: PagesTabs.overrideKey(account))
        PagesTabs.forgetDefaults(account)
        for key in keys { #expect(defaults.object(forKey: key) == nil, "\(key)") }
        #expect(defaults.string(forKey: PagesTabs.overrideKey(account)) == "on")
        defaults.removeObject(forKey: PagesTabs.overrideKey(account))
    }

    @Test func detailsScrubKeyValueSecretsOnly() {
        #expect(PageStates.scrubbed("Session not found") == "Session not found")
        #expect(PageStates.scrubbed("token=abc123&x=1") == "token=…&x=1")
        #expect(PageStates.scrubbed("Authorization: Bearer abcdefghijkl") == "Authorization=…")
        #expect(PageStates.scrubbed("sent Bearer abcdefghijkl") == "sent Bearer …")
        #expect(PageStates.scrubbed("session_id=s-1 failed") == "session_id=… failed")
    }
}
