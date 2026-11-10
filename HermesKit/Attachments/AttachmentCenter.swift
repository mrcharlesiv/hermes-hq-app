// One signed-in account's photos and files (docs/spec/1x-attachments.md §6): every chat's draft (text + tray), the
// live state of each attachment from pick to send, the upload queue (one at a time, oldest first, eager; spec §6.3),
// and the hand-over to a send's pipeline (`awaitUploaded`) and back (`returnToDraft`). Main actor; file and network
// work runs elsewhere. One center per account (`center(for:client:)`), dropped with its files on sign-out.

import Foundation
import UIKit

@MainActor final class AttachmentCenter {
    // MARK: Registry

    private static var centers: [String: AttachmentCenter] = [:]

    /// The center for `account`, made on first use (a new client for the same account replaces the old center's).
    static func center(for account: GatewayAccount, client: any GatewayClient) -> AttachmentCenter {
        if let known = centers[account.id] {
            if known.client === client { return known }
            known.rebind(client)
            return known
        }
        let made = AttachmentCenter(account: account, client: client)
        centers[account.id] = made
        return made
    }

    static func existing(_ accountId: String) -> AttachmentCenter? { centers[accountId] }

    /// Sign-out / account removal (spec §6.6): uploads and preparations stop; the account's phone copies, drafts file
    /// and media cache go. Gateway staging folders of unsent drafts stay (unreachable after sign-out).
    static func signedOut(accountId: String) {
        if let center = centers.removeValue(forKey: accountId) {
            center.shutdown()
        } else {
            AttachmentStaging(accountId: accountId).removeAll()
            DraftStore(accountId: accountId).remove()
        }
        MediaLoader.shared.purge(accountId: accountId)
    }

    // MARK: Parts

    let account: GatewayAccount
    private(set) var client: any GatewayClient
    let staging: AttachmentStaging
    private(set) var stager: AttachmentStager
    let store: DraftStore

    /// Every attachment this run knows (drafts, queued and in-flight sends), by id.
    private(set) var items: [String: DraftAttachment] = [:]
    private var profiles: [String: String] = [:]

    private struct Draft {
        var text: String = ""
        var ids: [String] = []
        var profile: String = ""
        var updatedAt: Double = 0
    }
    private var drafts: [String: Draft] = [:]

    // Uploads
    private var queue: [String] = []
    private var current: (id: String, task: Task<Void, Never>)?
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var autoRetried: Set<String> = []
    private var sendRetried: Set<String> = []
    private var urgent: Set<String> = []
    private var connectionReady = false
    /// The last state the socket reported. An upload can fail "offline" on a brief path blip while the socket stays
    /// ready, and then no new `ready` ever comes: a retry timer reopens the gate instead (`waitingRetry`).
    private var socketReady = false
    private var waitingRetry: Task<Void, Never>?
    private var waitingTries = 0
    /// The waits before each retry while the socket stays ready (tests shorten it).
    var waitingBackoff: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(30)]
    private var connectionTask: Task<Void, Never>?
    private var preparations: [String: Task<Void, Never>] = [:]
    private var shutDown = false
    /// iOS took the upload's background time back: nothing starts again until the app is in the foreground (a restart
    /// in the background would rebuild the body file and lose the time at once, over and over; spec §6.6).
    private var pausedForBackground = false
    private var foregroundObserver: NSObjectProtocol?
    /// Waits a Stop interrupted (`interruptWaits`): `awaitUploaded` answers "stopped" for them until the send ends.
    private var stopRequested: Set<String> = []

    // Observers
    private var itemObservers: [UUID: (String) -> Void] = [:]
    private var draftObservers: [String: [UUID: () -> Void]] = [:]

    /// Made through `center(for:client:)` in the app; tests make their own (with `base` for the files).
    init(account: GatewayAccount, client: any GatewayClient) {
        self.account = account
        self.client = client
        staging = AttachmentStaging(accountId: account.id)
        stager = AttachmentStager(client: client, tempDirectory: Self.uploadsDirectory(account.id))
        store = DraftStore(accountId: account.id)
        let staging = self.staging
        for (scope, saved) in store.load(exists: { staging.exists($0) }) {
            drafts[scope] = Draft(text: saved.text, ids: saved.attachments.map(\.id), profile: saved.profile, updatedAt: saved.updatedAt)
            for a in saved.attachments {
                items[a.id] = a
                profiles[a.id] = saved.profile
                if case .waiting = a.upload, !a.defersUpload { queue.append(a.id) }
            }
        }
        // Verify round 3: photos queued behind a reply when the app last went away (QueueStash) are known from the start
        // too, so the launch sweep keeps their phone copies and the chat's kept queue sends them.
        for stored in QueueStash.load(accountId: account.id).values {
            for a in stored.items.flatMap(\.attachments) where items[a.id] == nil && staging.exists(a) {
                var b = a
                switch b.upload {
                case .preparing, .uploading: b.upload = .waiting
                default: break
                }
                items[b.id] = b
                profiles[b.id] = stored.profile
                if case .waiting = b.upload, !b.defersUpload { queue.append(b.id) }
            }
        }
        if !items.isEmpty { AppLog.trace("offline", "attachment queue restored: \(items.count) known, \(queue.count) waiting to upload") }
        watchConnection()
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterBackground() }
        }
        sweepSoon()
    }

    isolated deinit {
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    /// Back in the foreground: an upload iOS stopped in the background starts again (spec §6.6).
    func resumeAfterBackground() {
        guard pausedForBackground else { return }
        pausedForBackground = false
        AppLog.trace("offline", "attachment upload resuming after background pause, \(queue.count) waiting")
        pump()
    }

    private func rebind(_ client: any GatewayClient) {
        self.client = client
        stager = AttachmentStager(client: client, tempDirectory: Self.uploadsDirectory(account.id))
        current?.task.cancel()
        waitingRetry?.cancel()
        watchConnection()
    }

    private func shutdown() {
        shutDown = true
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        connectionTask?.cancel()
        waitingRetry?.cancel()
        current?.task.cancel()
        current = nil
        for task in preparations.values { task.cancel() }
        preparations = [:]
        for list in waiters.values { list.forEach { $0.resume() } }
        waiters = [:]
        items = [:]
        drafts = [:]
        store.remove()
        let staging = self.staging
        DispatchQueue.global(qos: .utility).async { staging.removeAll() }
    }

    /// The upload failed "offline" but the socket is still ready: try again after a growing wait (2, 5, 10, 30 s).
    private func retryWhileSocketReady() {
        waitingRetry?.cancel()
        let delay = waitingBackoff[min(waitingTries, waitingBackoff.count - 1)]
        waitingTries += 1
        AppLog.trace("offline", "attachment upload retry armed: socket stayed ready, trying again in \(delay)")
        waitingRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.shutDown, self.socketReady, !self.connectionReady else { return }
            self.connectionReady = true
            self.pump()
        }
    }

    private func watchConnection() {
        connectionTask?.cancel()
        let states = client.connectionStates()
        connectionTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                let ready: Bool = { if case .ready = state { return true } else { return false } }()
                self.socketReady = ready
                if ready != self.connectionReady {
                    self.connectionReady = ready
                    if ready {
                        self.waitingRetry?.cancel()
                        self.waitingTries = 0
                        self.pump()
                    }
                }
            }
        }
    }

    // MARK: Observation

    final class Observation {
        fileprivate var cancelBlock: (() -> Void)?
        fileprivate init(_ cancel: @escaping () -> Void) { cancelBlock = cancel }
        func cancel() { cancelBlock?(); cancelBlock = nil }
        isolated deinit { cancelBlock?() }
    }

    /// Calls `handler` with an attachment's id whenever its state changes.
    func observeItems(_ handler: @escaping (String) -> Void) -> Observation {
        let id = UUID()
        itemObservers[id] = handler
        return Observation { [weak self] in self?.itemObservers[id] = nil }
    }

    /// Calls `handler` whenever the draft of `scope` changes (text from elsewhere, attachments added/removed/returned).
    func observeDraft(_ scope: String, _ handler: @escaping () -> Void) -> Observation {
        let id = UUID()
        draftObservers[scope, default: [:]][id] = handler
        // By id across scopes: a draft that moves (`moveDraft`) takes its observers along.
        return Observation { [weak self] in
            guard let self else { return }
            for key in self.draftObservers.keys { self.draftObservers[key]?[id] = nil }
        }
    }

    private func notifyItem(_ id: String) {
        for handler in itemObservers.values.map({ $0 }) { handler(id) }
    }

    private func notifyDraft(_ scope: String) {
        for handler in draftObservers[scope]?.values.map({ $0 }) ?? [] { handler() }
        onDraftChange?()
    }

    /// Verify round 3: some chat's draft changed outside typing (a send took it, words came back): the Bots rows' "Draft:"
    /// lines follow (typing itself is read when the chat is left).
    var onDraftChange: (() -> Void)?

    // MARK: Drafts

    /// The draft's text and attachments (current states), tray order.
    func draft(_ scope: String) -> (text: String, attachments: [DraftAttachment]) {
        guard let d = drafts[scope] else { return ("", []) }
        return (d.text, d.ids.compactMap { items[$0] })
    }

    /// A chat opened before its stored id was known (a bot whose chat the roster didn't name yet) kept its draft under
    /// `"<account>|<profile>|"`; once the id resolves the draft, and whoever watches it, move to the chat's real scope,
    /// so the next open finds it and a refused send returns to the tray on screen (spec A14). What was typed in this
    /// open wins over an older saved text; attachments go first, deduplicated. `keepTargetText`: the chat's own saved
    /// text wins instead (`adoptEarlierDraft`, a leftover that never moved).
    func moveDraft(from old: String, to new: String, keepTargetText: Bool = false) {
        guard old != new else { return }
        let watchers = draftObservers.removeValue(forKey: old)
        if let watchers { draftObservers[new, default: [:]].merge(watchers) { kept, _ in kept } }
        guard let moving = drafts.removeValue(forKey: old) else {
            if watchers != nil { notifyDraft(new) }
            return
        }
        var target = drafts[new] ?? Draft()
        target.ids = moving.ids + target.ids.filter { !moving.ids.contains($0) }
        if !moving.text.isEmpty, !(keepTargetText && !target.text.isEmpty) { target.text = moving.text }
        if !moving.profile.isEmpty { target.profile = moving.profile }
        target.updatedAt = max(target.updatedAt, moving.updatedAt)
        drafts[new] = target
        notifyDraft(new)
        save()
    }

    /// Typed text (the composer saves it as it changes).
    func setText(_ text: String, scope: String, profile: String) {
        var d = drafts[scope] ?? Draft()
        guard d.text != text else { return }
        d.text = text
        d.profile = profile
        d.updatedAt = Date().timeIntervalSince1970
        drafts[scope] = d
        save()
    }

    /// Adds an attachment to the end of the tray. A preparing one waits for `finishPreparing`.
    func add(_ attachment: DraftAttachment, scope: String, profile: String, preparation: Task<Void, Never>? = nil) {
        var d = drafts[scope] ?? Draft()
        d.ids.append(attachment.id)
        d.profile = profile
        d.updatedAt = Date().timeIntervalSince1970
        drafts[scope] = d
        items[attachment.id] = attachment
        profiles[attachment.id] = profile
        if let preparation { preparations[attachment.id] = preparation }
        if case .waiting = attachment.upload, !attachment.defersUpload { enqueue(attachment.id) }
        notifyDraft(scope)
        notifyItem(attachment.id)
        save()
    }

    /// The import finished: the prepared attachment replaces its placeholder and starts uploading.
    func finishPreparing(_ prepared: DraftAttachment) {
        preparations[prepared.id] = nil
        guard items[prepared.id] != nil else {
            // Removed while it was being prepared: its copy goes.
            staging.remove(prepared.id)
            return
        }
        var ready = prepared
        ready.upload = .waiting
        items[prepared.id] = ready
        if !ready.defersUpload { enqueue(ready.id) }
        notifyItem(ready.id)
        save()
    }

    /// The import failed: the placeholder goes (the caller shows "Couldn't Attach").
    func failPreparing(_ id: String) {
        preparations[id] = nil
        staging.remove(id)
        guard items.removeValue(forKey: id) != nil else { return }
        resumeWaiters(id)                    // a send waiting on it hears it is gone (and refuses) instead of hanging
        for scope in drafts.keys where drafts[scope]?.ids.contains(id) == true {
            drafts[scope]?.ids.removeAll { $0 == id }
            notifyDraft(scope)
        }
        save()
    }

    /// Progress of an iCloud download while preparing.
    func setPreparing(_ id: String, fraction: Double?) {
        guard var a = items[id], a.isPreparing else { return }
        a.upload = .preparing(fraction: fraction)
        items[id] = a
        notifyItem(id)
    }

    /// The tile's ✕ (spec §6.2): stops its preparation or upload, deletes the phone copy, and deletes the gateway
    /// staging folder when it was already uploaded.
    func remove(_ id: String, scope: String) {
        if let task = preparations.removeValue(forKey: id) { task.cancel() }
        if current?.id == id { current?.task.cancel() }
        queue.removeAll { $0 == id }
        let removed = items.removeValue(forKey: id)
        let profile = profiles.removeValue(forKey: id) ?? drafts[scope]?.profile ?? ""
        drafts[scope]?.ids.removeAll { $0 == id }
        drafts[scope]?.updatedAt = Date().timeIntervalSince1970
        TransferProgressCenter.finish(id)
        resumeWaiters(id)
        staging.remove(id)
        if let folder = removed?.stagingFolder, !folder.isEmpty {
            let stager = self.stager
            Task { await stager.release(folder: folder, profile: profile) }
        }
        notifyDraft(scope)
        save()
    }

    /// Try Again on a failed tile (spec §6.2): it gets its automatic retry back. A send's own retry
    /// (`resetAutoRetry: false`) is the one more try before refusing (spec §6.3).
    func retry(_ id: String, resetAutoRetry: Bool = true) {
        guard var a = items[id], a.failure != nil else { return }
        a.upload = .waiting
        items[id] = a
        if resetAutoRetry { autoRetried.remove(id) } else { autoRetried.insert(id) }
        notifyItem(id)
        enqueue(id)
        save()
    }

    /// Send takes the draft (spec §6.4 step 1): text and attachments leave the draft in the same frame; the attachments
    /// stay known (in flight) until the send ends or returns them.
    func takeForSend(_ scope: String) -> (text: String, attachments: [DraftAttachment]) {
        guard let d = drafts[scope] else { return ("", []) }
        let taken = (d.text, d.ids.compactMap { items[$0] })
        drafts[scope] = Draft(text: "", ids: [], profile: d.profile, updatedAt: Date().timeIntervalSince1970)
        notifyDraft(scope)
        save()
        return taken
    }

    /// A refused, stopped or unqueued send hands its attachments back (spec §6.4 step 8): in front of whatever the tray
    /// holds now (deduplicated by id), with their upload state (an uploaded one stays uploaded). `text` goes in only
    /// when the draft has none and `setTextIfEmpty`.
    func returnToDraft(_ scope: String, profile: String, text: String?, attachments: [DraftAttachment], setTextIfEmpty: Bool) {
        var d = drafts[scope] ?? Draft()
        d.profile = profile
        let incoming = attachments.map(\.id)
        d.ids = incoming + d.ids.filter { !incoming.contains($0) }
        for a in attachments {
            var b = items[a.id] ?? a
            if case .uploading = b.upload { b.upload = .waiting }
            items[a.id] = b
            profiles[a.id] = profile
            if case .waiting = b.upload, !b.defersUpload { enqueue(b.id) }
        }
        if setTextIfEmpty, let text, !text.isEmpty, d.text.isEmpty { d.text = text }
        d.updatedAt = Date().timeIntervalSince1970
        drafts[scope] = d
        notifyDraft(scope)
        save()
    }

    /// A sent message's attachments are done with (seeded or no longer needed): their phone copies go.
    func release(_ ids: [String]) {
        for id in ids {
            items[id] = nil
            profiles[id] = nil
            sendRetried.remove(id)
            autoRetried.remove(id)
            urgent.remove(id)
            staging.removeLater(id)
        }
        save()
    }

    // MARK: Uploads (spec §6.3)

    private func enqueue(_ id: String) {
        guard !queue.contains(id), current?.id != id else { return }
        queue.append(id)
        pump()
    }

    /// A send waits for this one: it goes first, at high priority.
    func prioritize(_ id: String) {
        urgent.insert(id)
        if let index = queue.firstIndex(of: id), index > 0 {
            queue.remove(at: index)
            queue.insert(id, at: 0)
        }
        if let a = items[id], a.defersUpload, case .waiting = a.upload { enqueue(id) }
        pump()
    }

    private func pump() {
        guard !shutDown, current == nil, connectionReady, !pausedForBackground else { return }
        queue.removeAll { items[$0] == nil }
        guard let index = queue.firstIndex(where: { id in if case .waiting? = items[id]?.upload { return true } else { return false } }) else { return }
        let id = queue.remove(at: index)
        guard let item = items[id], let file = staging.url(for: item) else { return }
        let profile = profiles[id] ?? ""
        var uploading = item
        uploading.upload = .uploading(sent: 0, total: item.byteSize)
        items[id] = uploading
        notifyItem(id)
        let stager = self.stager
        let priority: Float = urgent.contains(id) ? URLSessionTask.highPriority : 0.5
        // Kept going when the app leaves the foreground; if iOS ends the time, the upload stops and waits for the next
        // foreground (nothing is lost: spec §6.6).
        let background = BackgroundTime.begin("HQ attachment upload") { [weak self] in
            guard let self, self.current?.id == id else { return }
            self.pausedForBackground = true
            AppLog.trace("offline", "attachment upload \(AppLog.tag(id)) paused: background time ran out, \(self.queue.count) still waiting")
            self.current?.task.cancel()
        }
        AppLog.trace("offline", "attachment upload start \(AppLog.tag(id)): \(item.byteSize) B, \(queue.count) still waiting")
        let task = Task { [weak self] in
            let result: Result<StagedFile, any Error>
            do {
                let staged = try await stager.stage(file: file, name: item.name, profile: profile, priority: priority,
                                                    progress: { sent, total in TransferProgressCenter.report(id, sent: sent, total: total) })
                result = .success(staged)
            } catch {
                result = .failure(error)
            }
            self?.uploadFinished(id, result)
            background.end()
        }
        current = (id, task)
    }

    private func uploadFinished(_ id: String, _ result: Result<StagedFile, any Error>) {
        if current?.id == id { current = nil }
        TransferProgressCenter.finish(id)
        guard var a = items[id] else {
            // Removed while uploading: its gateway copy goes too.
            if case .success(let staged) = result {
                let stager = self.stager, profile = profiles[id] ?? ""
                Task { await stager.release(folder: staged.folder, profile: profile) }
            }
            pump()
            return
        }
        switch result {
        case .success(let staged):
            a.upload = .uploaded(path: staged.path, folder: staged.folder)
            items[id] = a
            waitingTries = 0
            AppLog.trace("offline", "attachment upload \(AppLog.tag(id)) done")
            resumeWaiters(id)
        case .failure(let error):
            if error is CancellationError || Task.isCancelled {
                a.upload = .waiting
                items[id] = a
                queue.insert(id, at: 0)
                AppLog.trace("offline", "attachment upload \(AppLog.tag(id)) cancelled: back to the front of the queue")
            } else if let staged = error as? AttachmentUploadError {
                switch staged.kind {
                case .waiting:
                    a.upload = .waiting
                    items[id] = a
                    queue.insert(id, at: 0)
                    connectionReady = false          // starts again with the next `ready`
                    AppLog.trace("offline", "attachment upload \(AppLog.tag(id)) waiting: gateway unreachable, queued again")
                    if socketReady { retryWhileSocketReady() }   // …which never comes if the socket never left
                case .retryable where !autoRetried.contains(id):
                    autoRetried.insert(id)
                    a.upload = .waiting
                    AppLog.trace("offline", "attachment upload \(AppLog.tag(id)) failed, retrying once in 2 s")
                    items[id] = a
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, case .waiting? = self.items[id]?.upload else { return }
                        self.enqueue(id)
                    }
                case .retryable, .sessionEnded:
                    a.upload = .failed(reason: staged.reason, retryable: true)
                    items[id] = a
                    AppLog.note("offline", "attachment upload \(AppLog.tag(id)) failed (retryable, kind \(staged.kind))")
                    resumeWaiters(id)
                case .final:
                    a.upload = .failed(reason: staged.reason, retryable: false)
                    items[id] = a
                    AppLog.note("offline", "attachment upload \(AppLog.tag(id)) failed (final, kind \(staged.kind))")
                    resumeWaiters(id)
                }
            } else {
                a.upload = .failed(reason: AttachmentUploadError.connection(a.name).reason, retryable: true)
                items[id] = a
                AppLog.note("offline", "attachment upload \(AppLog.tag(id)) failed: \(AppLog.scrub(String(describing: error)))")
                resumeWaiters(id)
            }
        }
        notifyItem(id)
        save()
        pump()
    }

    private func resumeWaiters(_ id: String) {
        let list = waiters.removeValue(forKey: id) ?? []
        list.forEach { $0.resume() }
    }

    /// Waits until `id` is uploaded (spec §6.4 step 3). A failed retryable upload is retried once per send
    /// (`retryFailed`); still failing (or gone) → the failure's reason.
    func awaitUploaded(_ id: String, retryFailed: Bool) async -> Result<StagedFile, AttachmentUploadError> {
        while true {
            if stopRequested.contains(id) { return .failure(.stopped) }
            guard let a = items[id], !shutDown else {
                return .failure(AttachmentUploadError(kind: .final, reason: "This attachment is no longer on this \(DeviceWord.name)."))
            }
            switch a.upload {
            case .uploaded(let path, let folder):
                return .success(StagedFile(path: path, folder: folder))
            case .failed(let reason, let retryable):
                if retryFailed && retryable && !sendRetried.contains(id) {
                    sendRetried.insert(id)
                    retry(id, resetAutoRetry: false)
                    prioritize(id)
                    continue
                }
                return .failure(AttachmentUploadError(kind: retryable ? .retryable : .final, reason: reason))
            default:
                prioritize(id)
                await withCheckedContinuation { waiters[id, default: []].append($0) }
            }
        }
    }

    /// Stop (spec §6.4 step 9): the sends waiting on `ids` stop waiting at once (`awaitUploaded` answers `.stopped`);
    /// the uploads themselves keep going (the attachments return to the draft still uploading).
    func interruptWaits(_ ids: [String]) {
        stopRequested.formUnion(ids)
        for id in ids { resumeWaiters(id) }
    }

    /// The send ended (refused, stopped or delivered): its per-send retry allowance and any Stop mark reset.
    func sendEnded(_ ids: [String]) {
        for id in ids { sendRetried.remove(id); urgent.remove(id); stopRequested.remove(id) }
    }

    // MARK: Persistence

    private func save() {
        guard !shutDown else { return }
        var out: [String: StoredDraft] = [:]
        for (scope, d) in drafts where !d.text.isEmpty || !d.ids.isEmpty {
            out[scope] = StoredDraft(text: d.text, attachments: d.ids.compactMap { items[$0] }, updatedAt: d.updatedAt, profile: d.profile)
        }
        store.save(out)
    }

    /// Writes pending drafts now (the app going to the background).
    func flush() { store.flush() }

    /// Launch sweep (spec §6.6), on a utility queue after first paint: folders nothing references, older than 600 s,
    /// and multipart bodies an earlier run left behind (killed mid-upload).
    private func sweepSoon() {
        let staging = self.staging
        let uploads = Self.uploadsDirectory(account.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.shutDown else { return }
            let referenced = Set(self.items.keys)
            DispatchQueue.global(qos: .utility).async {
                staging.sweep(keeping: referenced)
                AttachmentCenter.sweepUploadBodies(in: uploads)
            }
        }
    }

    /// Where an account's multipart bodies are built (`tmp/HQNUploads/<account key>`).
    nonisolated static func uploadsDirectory(_ accountId: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "HQNUploads", directoryHint: .isDirectory)
            .appending(path: AttachmentStaging.accountKey(accountId), directoryHint: .isDirectory)
    }

    /// Deletes body files older than `age` (an upload in flight now is younger: it was built for this run).
    @discardableResult
    nonisolated static func sweepUploadBodies(in directory: URL, olderThan age: TimeInterval = 600, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        var removed = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let stamp = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.max() ?? now
            guard now.timeIntervalSince(stamp) >= age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Debug / tests

    /// Tests: forget every draft and attachment this center knows (files stay).
    func debugReset() {
        current?.task.cancel()
        current = nil
        queue = []
        items = [:]
        drafts = [:]
        profiles = [:]
        sendRetried = []
        autoRetried = []
    }

    /// Tests: put a center in the registry (so a session for `account` finds it).
    static func debugRegister(_ center: AttachmentCenter) { centers[center.account.id] = center }

    var debugQueue: [String] { queue }
    var debugCurrent: String? { current?.id }
    var debugPausedForBackground: Bool { pausedForBackground }
    /// Tests: what iOS taking the background time back does to the running upload.
    func debugExpireBackgroundTime() {
        guard current != nil else { return }
        pausedForBackground = true
        current?.task.cancel()
    }
    func debugSetConnectionReady(_ ready: Bool) { connectionReady = ready; if ready { pump() } }
}

/// A `beginBackgroundTask` that always ends: by its owner, or when iOS takes the time back (after `expired` runs).
@MainActor final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String, expired: @escaping @MainActor () -> Void = {}) -> BackgroundTime {
        let time = BackgroundTime()
        time.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak time] in
            MainActor.assumeIsolated {
                expired()
                time?.end()
            }
        }
        return time
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
