import UIKit
import Testing
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct NewChatProjectSubtitleTests {
    @Test func titleViewDrawsFolderGlyphOrEmojiAndRevertsCleanly() {
        let title = ChatTitleView()
        title.title = "New Chat"
        title.subtitleProject = ChatProjectBadge(name: "acme-api")
        #expect(title.subtitleHasAttachment, "default project look draws folder.fill inline")
        #expect(title.shownSubtitleText?.contains("acme-api") == true)
        #expect(title.accessibilityLabel == "New Chat, Project: acme-api")

        // Project with custom emoji uses the emoji directly instead of folder.fill.
        title.subtitleProject = ChatProjectBadge(name: "acme-api", emoji: "🚀", color: .systemCyan)
        #expect(!title.subtitleHasAttachment)
        #expect(title.shownSubtitleText == "🚀\u{2009}acme-api")
        #expect(title.accessibilityLabel == "New Chat, Project: acme-api")

        // Trailing subtitle (Mac model/status suffix) joins with a middle dot.
        title.subtitle = "Claude Opus"
        #expect(title.shownSubtitleText == "🚀\u{2009}acme-api · Claude Opus")
        #expect(title.accessibilityLabel == "New Chat, Project: acme-api, Claude Opus")

        // Clearing the project restores the plain bot subtitle with no leftover attachment.
        title.subtitleProject = nil
        title.subtitle = "Otto"
        #expect(!title.subtitleHasAttachment)
        #expect(title.shownSubtitleText == "Otto")
        #expect(title.accessibilityLabel == "New Chat, Otto")
    }

    @Test func projectChatKeepsProjectSubtitleAfterFirstMessage() async throws {
        let session = StubProjectChatSession(title: "New Chat", botName: "Otto", messages: [])
        let vc = ChatViewController(session: session)
        vc.sessionProject = ChatProjectBadge(name: "acme-api")
        vc.loadViewIfNeeded()

        let title = try #require(vc.navigationItem.titleView as? ChatTitleView)
        #expect(title.title == "New Chat")
        #expect(title.subtitleProject == ChatProjectBadge(name: "acme-api"))
        #expect(title.subtitleHasAttachment)
        #expect(title.shownSubtitleText?.contains("acme-api") == true)

        // First message arrives and chat is titled: header keeps showing the project instead of duplicating the bot name.
        session.title = "Check build failure"
        session.appendUserMessage("Check the build failure")
        try await Task.sleep(for: .milliseconds(80))

        #expect(title.title == "Check build failure")
        #expect(title.subtitleProject == ChatProjectBadge(name: "acme-api"))
        #expect(title.subtitleHasAttachment)
        #expect(title.shownSubtitleText?.contains("acme-api") == true)
        #expect(title.shownSubtitleText != "Otto")
    }

    @Test func existingProjectChatShowsProjectSubtitleWhileNonProjectAndTaskKeepPreviousBehavior() throws {
        let existing = StubProjectChatSession(title: "Fix build", botName: "Otto", messages: [
            ChatMessage(id: "m1", role: .user, parts: [.text("Hello")], timestamp: Date(), rowId: 1),
        ])
        let existingVC = ChatViewController(session: existing)
        existingVC.sessionProject = ChatProjectBadge(name: "acme-api")
        existingVC.loadViewIfNeeded()
        let existingTitle = try #require(existingVC.navigationItem.titleView as? ChatTitleView)
        #expect(existingTitle.subtitleProject == ChatProjectBadge(name: "acme-api"))
        #expect(existingTitle.subtitleHasAttachment)
        #expect(existingTitle.shownSubtitleText?.contains("acme-api") == true)

        // Clearing the project (e.g. moved out to Home) reverts to the bot's name.
        existingVC.sessionProject = nil
        #expect(existingTitle.subtitleProject == nil)
        #expect(!existingTitle.subtitleHasAttachment)
        #expect(existingTitle.shownSubtitleText == "Otto")

        let home = StubProjectChatSession(title: "New Chat", botName: "Otto", messages: [])
        let homeVC = ChatViewController(session: home)
        homeVC.loadViewIfNeeded()
        let homeTitle = try #require(homeVC.navigationItem.titleView as? ChatTitleView)
        #expect(homeTitle.subtitleProject == nil)
        #expect(homeTitle.shownSubtitleText == "Otto")

        // Task pages override the title and keep their own standalone header.
        let taskVC = ChatViewController(session: home)
        taskVC.sessionProject = ChatProjectBadge(name: "acme-api")
        taskVC.titleOverride = "Today"
        taskVC.loadViewIfNeeded()
        let taskTitle = try #require(taskVC.navigationItem.titleView as? ChatTitleView)
        #expect(taskTitle.subtitleProject == nil)
        #expect(taskTitle.shownSubtitleText == nil)
    }
}

@MainActor private final class StubProjectChatSession: ChatSessionModel, ChatSessionDetails {
    var title: String
    var botName: String
    let profile = "otto"
    let head: JSONValue? = nil
    let layoutScope = "test|otto|new-chat"
    let modelName: String? = "Claude Opus"
    let seenThrough: Date? = nil
    private(set) var messages: [ChatMessage]
    let isRunning = false
    let hasOlder = false
    let isLoadingOlder = false
    let connection: ConnectionState = .ready
    let statusText: String? = nil
    var onChange: ((ChatChange) -> Void)?

    init(title: String, botName: String, messages: [ChatMessage]) {
        self.title = title
        self.botName = botName
        self.messages = messages
    }

    func appendUserMessage(_ text: String) {
        let m = ChatMessage(id: "u-\(messages.count + 1)", role: .user, parts: [.text(text)], timestamp: Date(), rowId: nil)
        messages.append(m)
        onChange?(.appended(ids: [m.id]))
    }

    func start() {}
    func stopObserving() {}
    func loadOlder() {}
    func send(_ text: String) { appendUserMessage(text) }
    func stop() {}
}
