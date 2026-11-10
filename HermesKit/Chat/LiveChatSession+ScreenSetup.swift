// [screen] "Set up with Hermes" (docs/spec/3x-screen.md §5.13): hands the installer the app carries to this chat's
// gateway and queues the setup request through the chat's normal send (queued behind a running reply, sent at once
// when idle, drafts untouched). The app never unpacks or runs the installer.

import Foundation

extension LiveChatSession {
    /// True while this chat still has the setup request waiting in its queue (a second tap must not attach again).
    var hasQueuedScreenSetup: Bool { queuedMessages.contains { $0.text.hasPrefix(ScreenSetupPrompt.text) } }

    /// Waits up to `limit` for this chat's runtime id (resuming it when there is none).
    func screenSetupRuntime(limit: Duration = .seconds(4)) async throws(ScreenSetupError) -> String {
        if let rid = runtimeSessionId { return rid }
        let resume = Task { [weak self] in _ = try? await self?.resumeNow() }
        defer { resume.cancel() }
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if let rid = runtimeSessionId { return rid }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let rid = runtimeSessionId else { throw .notReady }
        return rid
    }

    /// `file.attach {session_id, profile, name, data_url}` (120 s: the frame is about 734 KB). A stale runtime id
    /// (4001) resumes once and attaches again. Returns the gateway's `ref_text` and the runtime id it was attached to.
    func attachScreenSetup(name: String, dataURL: String) async throws(ScreenSetupError) -> (refText: String, runtime: String) {
        var resumed = false
        while true {
            let rid = try await screenSetupRuntime()
            var params: [String: JSONValue] = ["session_id": .string(rid), "name": .string(name), "data_url": .string(dataURL)]
            if let profileParam { params["profile"] = .string(profileParam) }
            do {
                let answer = try await client.call("file.attach", .object(params), timeout: .seconds(120))
                return (try ScreenSetupAttach.refText(answer), rid)
            } catch let error as RPCError where error.code == 4001 && !resumed {
                resumed = true
                runtimeSessionId = nil
            } catch let error as ScreenSetupError {
                throw error
            } catch let error as RPCError {
                AppLog.note("screen", "setup attach refused \(error.code)")
                throw .installer(error.isTimeout || error.isConnectionLost || error.isNotConnected ? nil : error.message)
            } catch {
                throw .installer(nil)
            }
        }
    }

    /// Queues the request (or sends it at once when the chat is idle). Throws when it is in neither the transcript
    /// nor the queue afterwards.
    func sendScreenSetup(refText: String, bundle: ScreenSetupBundle) throws(ScreenSetupError) {
        let text = ScreenSetupPrompt.message(refText: refText, sha256: bundle.sha256, helperAppPath: bundle.helperAppPath)
        let before = messages.count
        send(text, display: ScreenSetupPrompt.queueTitle)
        let queued = queuedMessages.contains { $0.text == text }
        let sent = messages.count > before && messages.suffix(messages.count - before).contains { $0.role == .user }
        guard queued || sent else { throw .notQueued }
    }
}
