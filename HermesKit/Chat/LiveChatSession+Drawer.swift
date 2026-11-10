// [composer-drawers] The gateway side of the slash and @ drawers (docs/spec/3x-composer.md §9.3, §10.3): `complete.slash`
// and `complete.path`, scoped to this chat. Strict params: `complete.slash {text, session_id?, profile?}`,
// `complete.path {word, cwd?, session_id?, profile?}`. `cwd` is this chat's own folder, never another chat's.

import Foundation

/// What the composer's drawers ask of a live chat.
@MainActor protocol ChatCompleting: AnyObject {
    /// The socket is up (offline, the drawers use what they have locally).
    var completionsOnline: Bool { get }
    /// The chat's own folder as the gateway last reported it (nil: unknown).
    var completionFolder: String? { get }
    func completeSlash(_ text: String) async throws -> ComposerDrawerModel.Answer
    func completePath(_ word: String) async throws -> ComposerDrawerModel.Answer
    /// Whether the chat's folder can be listed on the gateway computer (`GET /api/fs/list`); a failure that says
    /// nothing about the folder (no network) counts as readable.
    func completionFolderReadable(_ folder: String) async -> Bool
}

extension LiveChatSession: ChatCompleting {
    static let completionTimeout: Duration = .seconds(5)

    var completionsOnline: Bool { connection == .ready }
    var completionFolder: String? { menus.cwd }

    func completeSlash(_ text: String) async throws -> ComposerDrawerModel.Answer {
        let result = try await sessionCall("complete.slash", timeout: Self.completionTimeout, runtime: .optional) { _ in
            ["text": .string(text)]
        }
        return ComposerDrawerModel.answer(result, asked: text)
    }

    func completePath(_ word: String) async throws -> ComposerDrawerModel.Answer {
        let folder = menus.cwd
        let result = try await sessionCall("complete.path", timeout: Self.completionTimeout, runtime: .optional) { _ in
            var params: [String: JSONValue] = ["word": .string(word)]
            if let folder { params["cwd"] = .string(folder) }
            return params
        }
        return ComposerDrawerModel.answer(result, asked: word)
    }

    func completionFolderReadable(_ folder: String) async -> Bool {
        do {
            _ = try await workspace.list(folder)
            return true
        } catch is MenusError {
            // The gateway answered with the folder's own error (ENOENT, EACCES): it isn't there for this chat.
            return false
        } catch let error as HTTPError {
            return !(error.status == 403 || error.status == 404)
        } catch {
            return true
        }
    }
}
