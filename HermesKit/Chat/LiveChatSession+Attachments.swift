// Sending photos and files from the live chat (docs/spec/1x-attachments.md §6.4, §6.5, §7.2, §7.8): the optimistic
// bubble's attachments, the pipeline between the send and `prompt.submit` (await uploads → attach in tray order →
// re-attach photos after a stale-runtime submit → detach on a withdrawn send), the clean-up after the ack, and the
// drafts hand-back on a refusal or Stop. The pipeline belongs to the chat's session, never to its screen: leaving the
// chat doesn't cancel it (owner, M:send-lost-on-leave.md).

import Foundation
import UIKit

/// What the attach step did for one send.
struct AttachedSend {
    /// Photos attached to the current runtime: draft id and the staged gateway path.
    var photos: [(id: String, path: String)] = []
    /// Files' `ref_text` lines, tray order (the prompt's first lines).
    var fileRefs: [String] = []
    /// Staging folders of files the gateway copied out (deleted after the ack, spec §3.6).
    var releasedFolders: [String] = []
    /// Where each attachment now lives on the gateway (photo: staged path; file: the ref's path).
    var storedPaths: [String: String] = [:]
}

enum AttachOutcome {
    case ready(AttachedSend)
    case refused(String)
    case stopped
}

enum AttachmentPipeline {
    static func beginBackground() -> BackgroundTime { BackgroundTime.begin("HQ send with attachments") }

    static func endBackground(_ time: BackgroundTime?) { time?.end() }
}

extension LiveChatSession {
    /// The account's center, made on first use: the chat screen's tray asks for it when the chat opens.
    var attachmentCenter: AttachmentCenter { AttachmentCenter.center(for: account, client: client) }

    /// The center while the account is signed in; nil after sign-out. The pipeline and the hand-backs use only this:
    /// making a fresh center for a signed-out account would write its draft (and the typed words) back to disk.
    var liveAttachmentCenter: AttachmentCenter? { AttachmentCenter.existing(account.id) }

    // MARK: The optimistic bubble

    /// Your new bubble shows the tray's photos and files at once, from the phone's own copies (spec §6.4 step 2).
    func noteLocalAttachments(_ localId: String, _ attachments: [DraftAttachment]) {
        var meta = metaById[localId] ?? MessageMeta()
        meta.attachments = attachments.map { a in
            MessageAttachment(kind: a.kind == .image ? .image : (a.kind == .link ? .link : .file), source: .local(draftId: a.id), name: a.name,
                              pixelWidth: a.pixelWidth, pixelHeight: a.pixelHeight, byteSize: a.byteSize > 0 ? a.byteSize : nil,
                              uploadedPath: a.kind == .image ? a.gatewayPath : nil)
        }
        metaById[localId] = meta
        for a in attachments where a.kind == .image {
            if let path = a.gatewayPath, let w = a.pixelWidth, let h = a.pixelHeight { knownMediaSizes[path] = (w, h) }
        }
    }

    private func setUploadedPath(_ localId: String, draftId: String, path: String) {
        guard var meta = metaById[localId], let i = meta.attachments.firstIndex(where: { $0.source == .local(draftId: draftId) }) else { return }
        meta.attachments[i].uploadedPath = path
        if let w = meta.attachments[i].pixelWidth, let h = meta.attachments[i].pixelHeight { knownMediaSizes[path] = (w, h) }
        metaById[localId] = meta
    }

    // MARK: Steps 3–5: uploads, then attach

    /// Waits for every upload (a failed retryable one is retried once), then attaches in tray order: photos
    /// `image.attach`, files `file.attach`. A stale runtime (4001 / 4007 "…no longer live") resumes once and restarts the
    /// attaches; any other failure detaches the photos already attached and refuses. Stop → detach → stopped.
    func attachForSend(_ attachments: [DraftAttachment], localId: String, epoch: Int) async -> AttachOutcome {
        let ids = attachments.map(\.id)
        guard let center = liveAttachmentCenter else {
            AppLog.note("send", "send \(AppLog.tag(localId)): no attachment center, attachments refused")
            return .refused("This attachment is no longer on this phone.")
        }
        let attachStart = ContinuousClock.now
        AppLog.trace("send", "send \(AppLog.tag(localId)): waiting for \(attachments.count) uploads (\(attachments.map { "\($0.kind)" }.joined(separator: ",")))")
        // Stop wakes these waits (`stop()` → `interruptWaits`), so a send still uploading withdraws at once.
        inFlightAttachments[localId] = ids
        defer { inFlightAttachments[localId] = nil }
        var staged: [String: StagedFile] = [:]
        for a in attachments {
            let uploaded = await center.awaitUploaded(a.id, retryFailed: true)
            // Stop first: an interrupted wait is a withdrawn send, never a refusal.
            if stopEpoch != epoch { center.sendEnded(ids); return .stopped }
            switch uploaded {
            case .success(let file):
                staged[a.id] = file
                if a.kind == .image { setUploadedPath(localId, draftId: a.id, path: file.path) }
            case .failure(let error):
                AppLog.note("send", "send \(AppLog.tag(localId)): upload of \(a.kind) \(AppLog.tag(a.id)) failed, send refused")
                center.sendEnded(ids)
                return .refused(error.reason)
            }
        }
        AppLog.trace("send", "send \(AppLog.tag(localId)): uploads ready, \(AppLog.ms(since: attachStart)) ms")
        var resumed = false
        while true {
            if runtimeSessionId == nil {
                do { try await resumeNow() } catch {
                    center.sendEnded(ids)
                    if stopEpoch != epoch { return .stopped }
                    return .refused((error as? RPCError)?.message ?? "Couldn’t reach this chat.")
                }
            }
            guard let rid = runtimeSessionId else { center.sendEnded(ids); return .refused("Couldn’t reach this chat.") }
            var sent = AttachedSend()
            var stale = false
            for a in attachments {
                if stopEpoch != epoch {
                    await detachPhotos(sent)
                    center.sendEnded(ids)
                    return .stopped
                }
                guard let file = staged[a.id] else { continue }
                if a.kind == .link {                  // nothing to attach: its `@url:` line is the first line of the prompt (L390)
                    if let ref = a.refText { sent.fileRefs.append(ref) }
                    continue
                }
                let result: Result<AttachmentSender.Attached, AttachmentSender.AttachFailure>
                if a.kind == .image {
                    result = await AttachmentSender.attachImage(client: client, session: rid, path: file.path, name: a.name, profile: profileParam)
                } else {
                    result = await AttachmentSender.attachFile(client: client, session: rid, path: file.path, name: a.name, profile: profileParam)
                }
                switch result {
                case .success(let done):
                    if a.kind == .image {
                        // The path Hermes keeps (`Path.resolve()` of ours, H:hermes_cli/cli_terminal_input.py:125): the
                        // stored `@image:` row, `image.detach` and the media cache all use it, so it must match exactly.
                        let stored = done.storedPath
                        sent.photos.append((a.id, stored))
                        sent.storedPaths[a.id] = stored
                        if stored != file.path { setUploadedPath(localId, draftId: a.id, path: stored) }
                    } else {
                        if let ref = done.refText { sent.fileRefs.append(ref) }
                        sent.storedPaths[a.id] = done.refText.flatMap(AttachmentSender.refPath) ?? done.storedPath
                        if AttachmentStager.stagedCopyReleased(uploaded: done.uploaded, storedPath: done.storedPath, folder: file.folder) {
                            sent.releasedFolders.append(file.folder)
                        }
                    }
                case .failure(.staleRuntime(let error)):
                    AppLog.trace("send", "send \(AppLog.tag(localId)): attach of \(a.kind) hit a stale rt \(AppLog.tag(rid)) (\(error.code)), \(resumed ? "already resumed once, refused" : "resume once and attach again")")
                    if resumed {
                        await detachPhotos(sent)
                        center.sendEnded(ids)
                        return stopEpoch != epoch ? .stopped : .refused(error.message)
                    }
                    stale = true
                case .failure(.refused(let reason)):
                    AppLog.note("send", "send \(AppLog.tag(localId)): attach of \(a.kind) \(AppLog.tag(a.id)) refused by the gateway; \(sent.photos.count) photos detached")
                    await detachPhotos(sent)
                    center.sendEnded(ids)
                    return stopEpoch != epoch ? .stopped : .refused(reason)
                }
                if stale { break }
            }
            if stale {
                // The runtime went away under the attaches: resume once and start again from the first (spec §6.4 step 5).
                resumed = true
                runtimeSessionId = nil
                continue
            }
            if stopEpoch != epoch {
                await detachPhotos(sent)
                center.sendEnded(ids)
                return .stopped
            }
            return .ready(sent)
        }
    }

    /// After a 4001/4007 on `prompt.submit` and its resume: the photos again, on the new runtime (A5). Files' refs stay
    /// valid (the copy or the in-place path still exists). Returns a refusal reason, or nil when all attached.
    func reattachPhotos(_ sent: inout AttachedSend) async -> String? {
        guard let rid = runtimeSessionId else { return "Couldn’t reach this chat." }
        var attached: [(id: String, path: String)] = []
        for photo in sent.photos {
            let name = MediaKinds.name(ofPath: photo.path, image: true)
            let result = await AttachmentSender.attachImage(client: client, session: rid, path: photo.path, name: name, profile: profileParam)
            if case .failure = result { AppLog.note("send", "reattach of photo \(AppLog.tag(photo.id)) on new rt \(AppLog.tag(rid)) failed; \(attached.count) reattached, send refused") }
            switch result {
            case .success(let done):
                // The new runtime's answer names the path it keeps (normally the same resolved path).
                attached.append((photo.id, done.storedPath))
                sent.storedPaths[photo.id] = done.storedPath
            case .failure(.staleRuntime(let error)):
                sent.photos = attached
                await detachPhotos(sent)
                return error.message
            case .failure(.refused(let reason)):
                sent.photos = attached
                await detachPhotos(sent)
                return reason
            }
        }
        sent.photos = attached
        return nil
    }

    /// `image.detach` for each photo attached in a send that won't be submitted (A6), errors ignored.
    func detachPhotos(_ sent: AttachedSend) async {
        guard !sent.photos.isEmpty, let rid = runtimeSessionId else { return }
        for photo in sent.photos {
            await AttachmentSender.detachImage(client: client, session: rid, path: photo.path, profile: profileParam)
        }
    }

    // MARK: Step 7: after the ack

    /// Seeds the media store with your photos and files under their gateway paths (so the stored row shows the same
    /// pictures with no placeholder), deletes released file staging folders, lets the phone copies go, and switches the
    /// bubble's attachments to their gateway paths.
    func finishAttachmentSend(_ sent: AttachedSend, attachments: [DraftAttachment], localId: String) {
        guard let center = liveAttachmentCenter else { return }            // signed out meanwhile: the copies are gone
        let context = MediaContext(accountId: account.id, profile: profile, storedSessionId: readSessionId)
        let store = MediaLoader.shared.store(for: account.id)
        var seeds: [(key: String, name: String, source: URL, image: Bool, id: String)] = []
        for a in attachments {
            let item = center.items[a.id] ?? a
            guard let path = sent.storedPaths[a.id], let local = center.staging.url(for: item) else { continue }
            let key = MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path)
            seeds.append((key, a.name, local, a.kind == .image, a.id))
            if a.kind == .image {
                // The decoded pictures the bubble already shows move to the gateway key: the switch finds them at once.
                for bucket in MediaMemoryCache.buckets {
                    if let image = MediaMemoryCache.shared.exact("l|" + a.id, bucket: bucket) {
                        MediaMemoryCache.shared.set(image, key: key, bucket: bucket)
                    }
                }
                MediaLoader.shared.markSeeded(key)
                if let w = a.pixelWidth, let h = a.pixelHeight { knownMediaSizes[path] = (w, h) }
            }
        }
        // Sizes stay known by gateway path: the stored row (refs only) keeps the bubble's "PDF · 2.4 MB" and frames.
        for a in attachments {
            guard let path = sent.storedPaths[a.id] else { continue }
            if a.byteSize > 0 { knownMediaBytes[path] = a.byteSize }
            if let w = a.pixelWidth, let h = a.pixelHeight { knownMediaSizes[path] = (w, h) }
        }
        let releasedFolders = sent.releasedFolders
        let stager = center.stager
        let profileName = profile
        let ids = attachments.map(\.id)
        let storedPaths = sent.storedPaths
        center.sendEnded(ids)
        Task.detached(priority: .utility) { [weak self] in
            for seed in seeds {
                if seed.image { _ = store.seedOriginal(seed.key, from: seed.source) } else { _ = store.seedFile(seed.key, name: seed.name, from: seed.source) }
            }
            await MainActor.run {
                // Only now does the bubble point at the gateway copies: the media store holds them (spec §7.8).
                self?.switchToGateway(localId, storedPaths: storedPaths)
                center.release(ids)
            }
            for folder in releasedFolders { await stager.release(folder: folder, profile: profileName) }
        }
    }

    private func switchToGateway(_ localId: String, storedPaths: [String: String]) {
        guard var meta = metaById[localId] else { return }
        var changed = false
        for i in meta.attachments.indices {
            guard case .local(let draftId) = meta.attachments[i].source, let path = storedPaths[draftId] else { continue }
            meta.attachments[i].source = .gateway(path: path)
            meta.attachments[i].uploadedPath = nil
            changed = true
        }
        guard changed else { return }
        metaById[localId] = meta
        changes.update(localId)
        scheduleFlush()
    }

    // MARK: Refusal / Stop / unqueue

    /// The attachments of a send that didn't go out go back to this chat's draft (spec §6.4 step 8), in front of what the
    /// tray holds now. With the screen gone, the words go in too when the draft has none.
    func returnAttachments(_ attachments: [DraftAttachment], text: String?, refused: Bool = false) {
        if refused { Haptics.play(.error) }        // spec §6.4 step 8
        // Signed out meanwhile: nothing goes back (the account's drafts and copies were purged with it).
        guard let center = liveAttachmentCenter else { return }
        let current = attachments.map { center.items[$0.id] ?? $0 }
        center.sendEnded(attachments.map(\.id))
        // The chat's scope now (`ensureStoredId` moved an early draft to the resolved id): where the tray looks.
        center.returnToDraft(draftScope, profile: profile, text: text, attachments: current, setTextIfEmpty: !observing)
    }

    // MARK: Learnt sizes

    /// Pixel sizes known by gateway path (your sends, loaded history images): a stored row whose refs carry none takes
    /// them, so the local → stored switch and a reopen keep the exact frames (spec §7.8).
    func applyKnownMediaSizes() {
        guard !knownMediaSizes.isEmpty || !knownMediaBytes.isEmpty else { return }
        for (id, meta) in metaById where !meta.attachments.isEmpty {
            var m = meta
            var changed = false
            for i in m.attachments.indices {
                guard let path = m.attachments[i].gatewayPath else { continue }
                if m.attachments[i].pixelWidth == nil, let size = knownMediaSizes[path] {
                    m.attachments[i].pixelWidth = size.0
                    m.attachments[i].pixelHeight = size.1
                    changed = true
                }
                if m.attachments[i].byteSize == nil, let bytes = knownMediaBytes[path] {
                    m.attachments[i].byteSize = bytes
                    changed = true
                }
            }
            if changed { metaById[id] = m }
        }
    }
}

// MARK: - Screen side (contract `ChatAttachmentSending`)

extension LiveChatSession: ChatAttachmentSending {
    var draftScope: String { layoutScope }

    /// A bot's chat opening with its stored id known takes in words left under `"<account>|<profile>|"` by an earlier
    /// open whose id never resolved (it was left first, or offline). The bot's row reads that scope when the chat's own
    /// is empty, so it said "Draft: …" while the field opened empty (2026-11-08, Home). The chat's own words win.
    func adoptEarlierDraft() {
        guard storedSessionId != nil, pendingScope == nil else { return }
        AttachmentCenter.existing(account.id)?.moveDraft(from: "\(account.id)|\(profile)|", to: draftScope, keepTargetText: true)
    }

    var mediaContext: MediaContext { MediaContext(accountId: account.id, profile: profile, storedSessionId: readSessionId) }

    func attachments(for messageId: String) -> [MessageAttachment] { metaById[messageId]?.attachments ?? [] }

    /// Read on every streaming flush: rebuilt only after `metaById` changed (its `mediaRevision`), so streamed text
    /// costs nothing here (spec §15.3).
    var mediaSnapshot: ChatMediaSnapshot {
        var snapshot: ChatMediaSnapshot
        if let cached = mediaSnapshotCache, cached.revision == mediaRevision {
            snapshot = cached.snapshot
        } else {
            snapshot = ChatMediaSnapshot()
            for (id, meta) in metaById {
                if !meta.attachments.isEmpty { snapshot.attachments[id] = meta.attachments }
                for (toolId, detail) in meta.tools {
                    if let info = detail.generatedImage { snapshot.generated[id, default: [:]][toolId] = info }
                }
            }
            mediaSnapshotCache = (mediaRevision, snapshot)
        }
        snapshot.context = mediaContext
        snapshot.unavailable = unavailableMedia
        snapshot.replySizes = replyMediaSizes
        return snapshot
    }

    func noteMediaUnavailable(messageId: String, path: String, reason: String) {
        guard unavailableMedia[path] != reason else { return }
        unavailableMedia[path] = reason
        changes.update(messageId)
        scheduleFlush()
    }

    func noteReplyMediaSize(messageId: String, key: String, width: Int, height: Int) {
        let size = MediaPixelSize(width: width, height: height)
        guard width > 0, height > 0, replyMediaSizes[messageId]?[key] != size else { return }
        replyMediaSizes[messageId, default: [:]][key] = size
        changes.update(messageId)
        scheduleFlush()
    }

    func noteMediaSize(messageId: String, index: Int, width: Int, height: Int) {
        guard width > 0, height > 0, var meta = metaById[messageId], meta.attachments.indices.contains(index) else { return }
        let a = meta.attachments[index]
        if let path = a.gatewayPath { knownMediaSizes[path] = (width, height) }
        guard a.pixelWidth != width || a.pixelHeight != height else { return }
        meta.attachments[index].pixelWidth = width
        meta.attachments[index].pixelHeight = height
        metaById[messageId] = meta
        changes.update(messageId)
        scheduleFlush()
    }
}
