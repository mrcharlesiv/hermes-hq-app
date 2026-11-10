// Owner 2026-11-02 ("You have a TON of artifacts saved from email footers and other BS. Remove them."): Remove hides
// an artifact on this device, per account, in every chat that names it, and unpins it.

import Foundation
import Testing
@testable import HermesHQNative

@MainActor
struct ArtifactHiddenTests {
    private func record(_ value: String, session: String = "s1", profile: String? = nil,
                        kind: ArtifactRecord.Kind = .link) -> ArtifactRecord {
        ArtifactRecord(id: "\(session):\(value)", kind: kind, value: value, href: ArtifactCollector.href(value),
                       label: ArtifactCollector.label(value, kind: kind), sessionId: session, profile: profile,
                       sessionTitle: "Mail", timestamp: 1000)
    }

    @Test func hidesTheValueInEveryChatForThatBotOnly() {
        let hidden = ArtifactHidden(fileURL: nil)
        hidden.hide(record("https://example.com/footer", session: "a"))
        #expect(hidden.isHidden(record("https://example.com/footer", session: "b")), "the same link in another chat")
        #expect(hidden.isHidden(record("https://example.com/footer", profile: "default")), "no profile is the default bot")
        #expect(!hidden.isHidden(record("https://example.com/footer", profile: "finance")), "another bot's")
        let list = [record("https://example.com/footer", session: "c"), record("/tmp/report.pdf", kind: .file),
                    record("https://example.com/footer", profile: "finance")]
        #expect(hidden.visible(list).map(\.value) == ["/tmp/report.pdf", "https://example.com/footer"])
    }

    @Test func removingAPinnedOneUnpinsIt() {
        let hidden = ArtifactHidden(fileURL: nil), pins = ArtifactPins(fileURL: nil)
        let dash = record("/x/dash.html", kind: .file), notes = record("/x/notes.md", kind: .file)
        pins.pin(ArtifactPin(dash))
        pins.pin(ArtifactPin(notes))
        hidden.hide(ArtifactPin(dash).record, pins: pins)
        #expect(pins.pins.map(\.value) == ["/x/notes.md"])
        #expect(hidden.visible([ArtifactPin(dash), ArtifactPin(notes)]).map(\.value) == ["/x/notes.md"], "a pin made again stays out")
    }

    @Test func persistsPerAccount() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hidden-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = ArtifactHidden.fileURL(accountId: "acct-1", root: root)
        #expect(url != ArtifactHidden.fileURL(accountId: "acct-2", root: root))
        #expect(url.deletingLastPathComponent().lastPathComponent == "hidden")
        let hidden = ArtifactHidden(fileURL: url)
        hidden.hide(record("https://instagram.com/somebrand", profile: "mail"))
        hidden.hide(record("https://instagram.com/somebrand", profile: "mail"))   // once
        PagesCache.flush()
        let again = ArtifactHidden(fileURL: url)
        #expect(again.keys == ["mail\u{1F}https://instagram.com/somebrand"])
        #expect(again.visible([record("https://instagram.com/somebrand", session: "z", profile: "mail")]).isEmpty)
        #expect(ArtifactHidden(fileURL: ArtifactHidden.fileURL(accountId: "acct-2", root: root)).isEmpty)
    }

    @Test func theStoreListsNothingRemoved() {
        let client = PagesFakeClient { _ in ["sessions": []] }
        let hidden = ArtifactHidden(fileURL: nil)
        let store = ArtifactsStore(client: client, account: client.account, directory: nil, hidden: hidden)
        let entry = ArtifactIndexEntry(stamp: "1|1|x", at: 1, artifacts: [record("https://example.com/a"), record("/tmp/b.pdf", kind: .file)])
        store.index.seed([ArtifactIndex.key(profile: nil, id: "s1"): entry])
        store.prepare()
        #expect(store.artifacts.count == 2)
        hidden.hide(record("https://example.com/a"))
        #expect(store.artifacts.map(\.value) == ["/tmp/b.pdf"], "gone at once")
    }
}
