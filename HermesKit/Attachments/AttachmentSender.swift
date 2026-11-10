// The attach RPCs and the prompt text (docs/spec/1x-attachments.md §3.4–§3.8; R:ios/App/Shared/DispatchShareKit.swift
// :156-163,487-512). Exact param sets — Hermes answers any other key with 4000 (`H:tui_gateway/contracts/base.py`):
//   image.attach  {session_id, path, profile}
//   file.attach   {session_id, path, name, profile}
//   image.detach  {session_id, path, profile}
// Pure helpers plus three calls; the send pipeline (LiveChatSession+Attachments.swift) orders them.

import Foundation

nonisolated enum AttachmentSender {
    /// What a photo-only send says (parity; your bubble hides it, A4).
    static let defaultQuestion = "What do you see in this image?"

    /// The `prompt.submit` text: the files' refs (one per line), a blank line, then your words; photos alone send the
    /// default question.
    static func promptText(typed: String, fileRefs: [String], hasImages: Bool) -> String {
        let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = fileRefs.filter { !$0.isEmpty }.joined(separator: "\n")
        let text = [refs, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return text.isEmpty && hasImages ? defaultQuestion : text
    }

    /// Your bubble's text part: what you typed, or the default question for photos alone (A4: drawn as no text).
    static func bubbleText(typed: String, attachments: [DraftAttachment]) -> String {
        let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty && attachments.contains(where: { $0.kind == .image }) { return defaultQuestion }
        return typed
    }

    static func imageAttachParams(session: String, path: String, profile: String?) -> JSONValue {
        var p: [String: JSONValue] = ["session_id": .string(session), "path": .string(path)]
        if let profile { p["profile"] = .string(profile) }
        return .object(p)
    }

    static func fileAttachParams(session: String, path: String, name: String, profile: String?) -> JSONValue {
        var p: [String: JSONValue] = ["session_id": .string(session), "path": .string(path), "name": .string(name)]
        if let profile { p["profile"] = .string(profile) }
        return .object(p)
    }

    static func imageDetachParams(session: String, path: String, profile: String?) -> JSONValue {
        imageAttachParams(session: session, path: path, profile: profile)
    }

    /// One attach's outcome.
    struct Attached: Sendable, Equatable {
        /// A file's `ref_text`, verbatim (nil for photos).
        var refText: String?
        /// Where the gateway keeps it: a photo's staged path; a file's stored path (`path`, else `ref_path`).
        var storedPath: String
        /// file.attach copied it out of staging (`uploaded == true`).
        var uploaded: Bool
        var width: Int?
        var height: Int?
    }

    enum AttachFailure: Error {
        /// The runtime is stale (4001, or 4007 "…no longer live"): resume once and attach again.
        case staleRuntime(RPCError)
        /// Anything else: the send is refused with this reason.
        case refused(String)
    }

    static func isStale(_ error: RPCError) -> Bool {
        error.code == 4001 || (error.code == 4007 && error.message.localizedCaseInsensitiveContains("no longer live"))
    }

    /// `image.attach` (60 s: the handler opens the image inline). Success = `attached == true`.
    static func attachImage(client: any GatewayClient, session: String, path: String, name: String, profile: String?) async -> Result<Attached, AttachFailure> {
        do {
            let result = try await client.call("image.attach", imageAttachParams(session: session, path: path, profile: profile),
                                               timeout: .seconds(60))
            guard result["attached"]?.bool == true else {
                return .failure(.refused(result["message"]?.nonEmptyString ?? "Your gateway didn’t accept “\(name)”."))
            }
            return .success(Attached(refText: nil, storedPath: result["path"]?.nonEmptyString ?? path, uploaded: false,
                                     width: result["width"]?.int, height: result["height"]?.int))
        } catch let error as RPCError {
            if isStale(error) {
                AppLog.trace("transfer", "image.attach \(AppLog.tag(session)): stale runtime (\(error.code)), will resume and attach again")
                return .failure(.staleRuntime(error))
            }
            return .failure(.refused(error.message.isEmpty ? "Your gateway didn’t accept “\(name)”." : error.message))
        } catch {
            AppLog.swallowed("transfer", "image.attach \(AppLog.tag(session))", error)
            return .failure(.refused("Your gateway didn’t accept “\(name)”."))
        }
    }

    /// `file.attach` (60 s: the handler copies the file inline). Success = `attached != false` and a non-empty `ref_text`.
    static func attachFile(client: any GatewayClient, session: String, path: String, name: String, profile: String?) async -> Result<Attached, AttachFailure> {
        do {
            let result = try await client.call("file.attach", fileAttachParams(session: session, path: path, name: name, profile: profile),
                                               timeout: .seconds(60))
            guard result["attached"]?.bool != false, let ref = result["ref_text"]?.nonEmptyString else {
                return .failure(.refused(result["message"]?.nonEmptyString ?? "Your gateway didn’t accept “\(name)”."))
            }
            let stored = result["path"]?.nonEmptyString ?? result["ref_path"]?.nonEmptyString ?? path
            return .success(Attached(refText: ref, storedPath: stored, uploaded: result["uploaded"]?.bool == true))
        } catch let error as RPCError {
            if isStale(error) {
                AppLog.trace("transfer", "file.attach \(AppLog.tag(session)): stale runtime (\(error.code)), will resume and attach again")
                return .failure(.staleRuntime(error))
            }
            return .failure(.refused(error.message.isEmpty ? "Your gateway didn’t accept “\(name)”." : error.message))
        } catch {
            AppLog.swallowed("transfer", "file.attach \(AppLog.tag(session))", error)
            return .failure(.refused("Your gateway didn’t accept “\(name)”."))
        }
    }

    /// `image.detach`, errors ignored (spec §3.8).
    static func detachImage(client: any GatewayClient, session: String, path: String, profile: String?) async {
        _ = try? await client.call("image.detach", imageDetachParams(session: session, path: path, profile: profile), timeout: .seconds(15))
    }

    /// The path a file's `ref_text` names (`@file:<path>`, quotes stripped): what the stored row will say.
    static func refPath(_ refText: String) -> String? {
        let trimmed = refText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@file:") else { return nil }
        return AttachmentHydration.unquote(String(trimmed.dropFirst("@file:".count)))
    }
}
