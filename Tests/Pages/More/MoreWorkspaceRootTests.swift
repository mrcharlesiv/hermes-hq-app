// More › Files and Review (docs/spec/3x-morepages.md §11, acceptance 1): the root's precedence and its persistence per
// account and bot, the web's folder-error words (`S/fe-pages-r4.test.ts`, titles in Title Case), paths in words, the
// large-file notice, and the lenient reads through the chat's workspace calls.

import Foundation
import Testing
@testable import HermesHQNative

struct MoreWorkspaceRootTests {
    private func defaults() -> UserDefaults {
        let name = "more-workspace-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func precedenceIsChosenThenChatThenGateway() {
        typealias R = MoreWorkspaceRoot
        #expect(R.resolve(chosen: "/a", chatFolder: "/b", gatewayDefault: "/c") == .init(path: "/a", source: .chosen))
        #expect(R.resolve(chosen: nil, chatFolder: "/b", gatewayDefault: "/c") == .init(path: "/b", source: .chat))
        #expect(R.resolve(chosen: nil, chatFolder: nil, gatewayDefault: "/c") == .init(path: "/c", source: .gateway))
        #expect(R.resolve(chosen: nil, chatFolder: nil, gatewayDefault: nil) == nil)
        // A value that is not an absolute path never wins.
        #expect(R.resolve(chosen: "relative/path", chatFolder: "  ", gatewayDefault: "/c/") == .init(path: "/c", source: .gateway))
        #expect(R.resolve(chosen: "", chatFolder: " /b/ ", gatewayDefault: nil) == .init(path: "/b", source: .chat))
        #expect(R.resolve(chosen: "/", chatFolder: "/b", gatewayDefault: nil) == .init(path: "/", source: .chosen))
        #expect(R.needsGatewayDefault(chosen: nil, chatFolder: nil))
        #expect(R.needsGatewayDefault(chosen: "x", chatFolder: ""))
        #expect(!R.needsGatewayDefault(chosen: nil, chatFolder: "/b"))
        #expect(!R.needsGatewayDefault(chosen: "/a", chatFolder: nil))
    }

    @Test func chosenFolderIsKeptPerAccountAndBot() {
        let store = defaults()
        typealias R = MoreWorkspaceRoot
        #expect(R.key(account: "gw|me", profile: "inbox") == "pages.filesRoot.gw|me.inbox")
        #expect(R.key(account: "gw|me", profile: "") == "pages.filesRoot.gw|me.default")
        #expect(R.chosen(account: "gw|me", profile: "default", defaults: store) == nil)
        R.setChosen("/home/hermes/projects/notes/", account: "gw|me", profile: "default", defaults: store)
        R.setChosen("/srv/inbox", account: "gw|me", profile: "inbox", defaults: store)
        R.setChosen("/other", account: "gw2|me", profile: "default", defaults: store)
        #expect(R.chosen(account: "gw|me", profile: "default", defaults: store) == "/home/hermes/projects/notes")
        #expect(R.chosen(account: "gw|me", profile: "inbox", defaults: store) == "/srv/inbox")
        #expect(R.chosen(account: "gw2|me", profile: "default", defaults: store) == "/other")
        #expect(R.chosen(account: "gw|me", profile: "deploys", defaults: store) == nil)
        // Use Chat's Folder forgets only that bot's choice.
        R.setChosen(nil, account: "gw|me", profile: "default", defaults: store)
        #expect(R.chosen(account: "gw|me", profile: "default", defaults: store) == nil)
        #expect(R.chosen(account: "gw|me", profile: "inbox", defaults: store) == "/srv/inbox")
        // A path that is not absolute is never stored, and a stored one that is not absolute is never read.
        R.setChosen("notes", account: "gw|me", profile: "inbox", defaults: store)
        #expect(R.chosen(account: "gw|me", profile: "inbox", defaults: store) == nil)
        store.set("~/x", forKey: R.key(account: "gw|me", profile: "inbox"))
        #expect(R.chosen(account: "gw|me", profile: "inbox", defaults: store) == nil)
        R.forget(account: "gw2|me", defaults: store)
        #expect(R.chosen(account: "gw2|me", profile: "default", defaults: store) == nil)
    }

    @Test func lastChatFolderBelongsToItsBot() {
        let store = defaults()
        let sessions = [SessionSummary(id: "s1", profile: "inbox", title: "Triage", preview: nil, lastActive: nil, source: nil,
                                       unread: false, isRunning: false, cwd: "/home/hermes/inbox")]
        MoreChatFolderRecord(profile: "inbox", sessionId: "s1", cwd: nil, title: "Triage").write(account: "a", defaults: store)
        let saved = MoreChatFolderRecord.read(account: "a", defaults: store)
        #expect(saved?.title == "Triage")
        // The chat said no folder: its row on the Sessions list has one.
        #expect(saved?.folder(for: "inbox", sessions: sessions) == "/home/hermes/inbox")
        #expect(saved?.folder(for: "inbox", sessions: []) == nil)
        // Another bot's Files never follows this chat.
        #expect(saved?.folder(for: "default", sessions: sessions) == nil)
        // The chat's own folder wins over the row's.
        let own = MoreChatFolderRecord(profile: "", sessionId: "s1", cwd: "/work/", title: nil)
        #expect(own.folder(for: "default", sessions: sessions) == "/work")
        #expect(own.folder(for: "", sessions: sessions) == "/work")
        #expect(MoreChatFolderRecord.read(account: "b", defaults: store) == nil)
        store.set(Data("not json".utf8), forKey: MoreChatFolderRecord.key("b"))
        #expect(MoreChatFolderRecord.read(account: "b", defaults: store) == nil)
        MoreChatFolderRecord.forget(account: "a", defaults: store)
        #expect(MoreChatFolderRecord.read(account: "a", defaults: store) == nil)
    }

    /// `S/fe-pages-r4.test.ts` "says why a folder could not be read, never the raw code".
    @Test func folderErrorsAreSaidInWords() {
        typealias R = MoreWorkspaceRoot
        #expect(R.folderErrorText("ENOENT", chatFolder: true)
                == .init(title: "Folder Not Found", body: "This chat’s folder no longer exists on the computer running Hermes."))
        #expect(R.folderErrorText("ENOENT", chatFolder: false).body == "This folder no longer exists on the computer running Hermes.")
        #expect(R.folderErrorText("EACCES", chatFolder: true).body == "The computer running Hermes doesn’t allow Hermes HQ to read this chat’s folder.")
        #expect(R.folderErrorText("EACCES", chatFolder: false).body == "The computer running Hermes doesn’t allow Hermes HQ to read this folder.")
        #expect(R.folderErrorText("EPERM", chatFolder: false).title == "Can’t Open This Folder")
        #expect(R.folderErrorText("ENOTDIR", chatFolder: false).title == "Not a Folder")
        #expect(R.folderErrorText("ENOTDIR", chatFolder: true).body == "This chat’s folder is a file on the computer running Hermes, not a folder.")
        #expect(R.folderErrorText("Gateway timed out", chatFolder: false) == .init(title: "Couldn’t Read This Folder", body: "Gateway timed out"))
        // The code with its own text after it still counts; a longer word that only starts like one does not.
        #expect(R.folderErrorText("  ENOENT: no such file or directory ", chatFolder: false).title == "Folder Not Found")
        #expect(R.folderErrorText("ENOENTISH", chatFolder: false).title == "Couldn’t Read This Folder")
        #expect(R.folderErrorText("", chatFolder: false).body == "The computer running Hermes did not say why.")
        for code in ["ENOENT", "EACCES", "EPERM", "ENOTDIR"] {
            let words = R.folderErrorText(code, chatFolder: true)
            #expect(!words.title.contains(code) && !words.body.contains(code))
        }
    }

    /// `S/fe-pages-r4.test.ts` `gatewayHome` / `gatewayPath`.
    @Test func pathsAreShortenedOnlyInsideTheGatewayHome() {
        typealias R = MoreWorkspaceRoot
        let home = R.gatewayHome(defaultProfilePath: "/Users/me/.hermes")
        #expect(home == "/Users/me")
        #expect(R.gatewayHome(defaultProfilePath: "/Users/me/.hermes/profiles/x") == "/Users/me")
        #expect(R.gatewayHome(defaultProfilePath: "/srv/hermes-home") == nil)
        #expect(R.gatewayHome(defaultProfilePath: "/Users/a/.hermesx") == nil)
        #expect(R.gatewayHome(defaultProfilePath: nil) == nil)
        #expect(R.display("/Users/me/Projects/hermes-ios-final", home: home) == "~/Projects/hermes-ios-final")
        #expect(R.display("/Users/me", home: home) == "~")
        #expect(R.display("/Users/bots/gbrain", home: home) == "/Users/bots/gbrain")
        #expect(R.display("/Users/mex/a", home: home) == "/Users/mex/a")
        #expect(R.display("/Users/bots/gbrain/", home: nil) == "/Users/bots/gbrain")
        let profiles: JSONValue = ["profiles": [["name": "inbox", "path": "/Users/me/.hermes/profiles/inbox"],
                                                ["name": "default", "path": "/Users/me/.hermes", "is_default": true]]]
        #expect(R.gatewayHome(profiles: profiles) == "/Users/me")
        #expect(R.gatewayHome(profiles: ["profiles": "nope"]) == nil)
        #expect(R.gatewayHome(profiles: .null) == nil)
        #expect(R.name("/home/hermes/projects/site") == "site")
        #expect(R.name("/") == "/")
        #expect(R.parent("/home/hermes/projects/site") == "/home/hermes/projects")
        #expect(R.parent("/home") == "/")
        #expect(R.parent("/") == nil)
        #expect(R.parent("relative") == nil)
        #expect(R.sourceLine(.chosen, chatTitle: "x") == "Folder you chose")
        #expect(R.sourceLine(.chat, chatTitle: " Release 2.4 ") == "The folder of “Release 2.4”")
        #expect(R.sourceLine(.chat, chatTitle: nil) == "The folder of your last chat")
        #expect(R.sourceLine(.gateway, chatTitle: nil) == "The default folder on the computer running Hermes")
    }

    /// `S/fe-pages-r5.ts` `truncatedNotice`.
    @Test func largeFileNoticeSaysHowMuchOfHowMuch() {
        typealias R = MoreWorkspaceRoot
        #expect(R.truncatedNotice(byteSize: 2_621_440) == "Showing the first 512 KB of 2.5 MB.")
        #expect(R.truncatedNotice(byteSize: 3_145_748) == "Showing the first 512 KB of 3 MB.")
        #expect(R.truncatedNotice(byteSize: 700 * 1024) == "Showing the first 512 KB of 700 KB.")
        #expect(R.truncatedNotice(byteSize: nil) == "Showing the first 512 KB.")
        #expect(R.truncatedNotice(byteSize: 100) == "Showing the first 512 KB.")
        #expect(R.fileSize(1_048_576) == "1 MB")
    }

    @Test func reviewWordsAndFileOpening() {
        typealias R = MoreWorkspaceRoot
        #expect(R.noChanges == .init(title: "No Changes", body: "Nothing has changed in this folder since its last saved version."))
        #expect(R.notGit == .init(title: "Not a Git Folder", body: "Changes shows what changed in a project that uses Git."))
        #expect(R.isNotGit(reason: "fatal: not a git repository (or any of the parent directories): .git"))
        #expect(!R.isNotGit(reason: "Gateway timed out"))
        #expect(R.counts(added: 3, removed: 1) == "+3 −1")
        // Item 18: a zero side is left out ("New file · +5", not "New file · +5 −0").
        #expect(R.counts(added: 5, removed: 0) == "+5")
        #expect(R.counts(added: 0, removed: 3) == "−3")
        #expect(R.counts(added: -4, removed: 0) == "+0")
        #expect(R.statusLetter(" m ") == "M")
        #expect(R.statusLetter("?") == "?")
        #expect(R.statusLetter("weird") == "M")
        #expect(R.opening(name: "README.md") == .text)
        #expect(R.opening(name: "Makefile") == .text)
        #expect(R.opening(name: ".gitignore") == .text)
        #expect(R.opening(name: "index.html") == .text)
        #expect(R.opening(name: "reel.mov") == .download)
        #expect(R.opening(name: "report.PDF") == .download)
        let entries = [WorkspaceEntry(name: "a", path: "/a", isDirectory: true), WorkspaceEntry(name: "a", path: "/a", isDirectory: true),
                       WorkspaceEntry(name: "b", path: "/b", isDirectory: false)]
        #expect(R.deduped(entries).map(\.path) == ["/a", "/b"])
        let change = WorkspaceChange(path: "x.js", added: 1, removed: 0, status: "M", staged: false)
        var staged = change
        staged.staged = true
        #expect(R.deduped([change, change, staged]).count == 2)
    }

    // MARK: Reads (lenient, GET only)

    @Test func listingsAndTextAreReadLeniently() async throws {
        let client = MoreFakeClient { request in
            switch request.path {
            case "/api/fs/list":
                if request.query["path"] == "/gone" { return ["entries": [], "error": "ENOENT"] }
                if request.query["path"] == "/odd" { return ["entries": "nope"] }
                return ["entries": [["name": "b.txt", "path": "/r/b.txt", "isDirectory": false], ["name": 7], "junk", .null, [:],
                                    ["name": "src", "path": "/r/src", "isDirectory": true], ["name": "a.txt", "is_directory": false]]]
            case "/api/fs/read-text":
                return ["path": "/r/build.log", "text": "abc", "truncated": true, "byteSize": "3145748", "binary": .null]
            case "/api/git/review/list":
                return ["files": [["path": "src/app.js", "added": "3", "removed": 1, "status": "M", "staged": false], ["added": 1], 5,
                                  ["path": "node_modules/x/index.js", "added": 9, "removed": 9, "status": "M"]]]
            default:
                return [:]
            }
        }
        let workspace = ChatWorkspace(client: client, profile: nil)
        let entries = try await workspace.list("/r")
        #expect(entries.map(\.name) == ["src", "a.txt", "b.txt"])
        #expect(entries[1].path == "/r/a.txt")
        #expect(try await workspace.list("/odd").isEmpty)
        do {
            _ = try await workspace.list("/gone")
            Issue.record("a folder that is gone must throw its code")
        } catch let error as MenusError {
            #expect(MoreWorkspaceRoot.folderErrorText(error.message, chatFolder: false).title == "Folder Not Found")
        }
        let file = try await workspace.readText("/r/build.log")
        #expect(file.truncated && !file.binary && file.byteSize == 3_145_748)
        #expect(MoreWorkspaceRoot.truncatedNotice(byteSize: file.byteSize) == "Showing the first 512 KB of 3 MB.")
        let changes = try await workspace.changes(in: "/r")
        #expect(changes.map(\.path) == ["src/app.js"])
        #expect(changes.first?.added == 3)
        // Every request these pages make is a GET, and the default bot sends no profile.
        #expect(client.log.allSatisfy { $0.method == "GET" && $0.query["profile"] == nil })
        let scoped = ChatWorkspace(client: client, profile: "inbox")
        _ = try await scoped.list("/r")
        #expect(client.log.last?.query == ["path": "/r", "profile": "inbox"])
    }

    @Test func openFailureSaysTooLargeForA413() {
        #expect(MoreWorkspace.openFailure(HTTPError(status: 413, body: #"{"detail":"File too large"}"#)) == "This file is too large to open on this iPhone.")
        #expect(MoreWorkspace.openFailure(GatewayFailure.responseTooLarge) == "This file is too large to open on this iPhone.")
        #expect(MoreWorkspace.openFailure(HTTPError(status: 404, body: #"{"detail":"File not found"}"#)) == "File not found")
    }
}
