// [photoheads] Saving and removing a bot's photo (docs/spec/3x-photoheads.md §8). The picture goes first and is
// awaited (`profiles.set_asset`); only when it landed are `imageKind` and `custom` written into `hermes-bots`, in the
// one `profiles.configure` that also carries a Title or Description change. So a refused picture is told, and another
// phone that fetches when the `hermes-bots` revision moves finds the picture already there.

import Foundation

extension BotStore {
    /// Edit Bot's Save with a staged picture. Runs inside the bot's write queue, so it never interleaves with a head
    /// save, a pin or another Save.
    func saveEdit(name: String, title: String?, description: String?, picture: BotPictureChange?) async throws -> EditOutcome {
        guard let picture else { return try await saveEdit(name: name, title: title, description: description) }
        if readOnlyGateway { throw BotWriteError(title: BotPictureWords.failureTitle, reason: BotWriteError.readOnlyReason) }
        return try await editing.serial(name) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performSavePicture(name: name, title: title, description: description, picture: picture)
        }
    }

    private func performSavePicture(name: String, title: String?, description: String?, picture: BotPictureChange) async throws -> EditOutcome {
        // 1. The picture itself.
        var stored: Bool?
        var adopted: String?
        var failure: (reason: String, detail: String)?
        var params: [String: JSONValue] = ["name": .string(name), "asset": "avatar"]
        switch picture {
        case .kindOnly:
            break
        case .photo(let dataURL):
            params["data"] = .string(dataURL)
            adopted = dataURL
        case .remove(let mirror):
            if let mirror { params["data"] = .string(mirror) } else { params["clear"] = true }
            adopted = mirror
        }
        if picture.sendsAsset {
            do {
                let result = try await client.call("profiles.set_asset", .object(params), timeout: photos.timing.uploadTimeout)
                if result["ok"] == .bool(true) {
                    stored = true
                } else {
                    stored = false
                    failure = (BotWriteError.notSavedReason, (try? String(decoding: result.encoded(), as: UTF8.self)) ?? "")
                }
            } catch {
                stored = false
                failure = (BotPictureWords.reason(error), "\(error)")
            }
        }

        if let failure {
            // The picture's kind is not written; the Title and the Description still are.
            var outcome = EditOutcome(titleApplied: nil, descriptionApplied: nil, reason: nil)
            if title != nil || description != nil {
                do {
                    outcome = try await performSaveEdit(name: name, title: title, description: description)
                } catch {
                    if title != nil { outcome.titleApplied = false }
                    if description != nil { outcome.descriptionApplied = false }
                    outcome.reason = (error as? BotWriteError)?.reason ?? BotWriteOutcome.reason(error)
                }
            }
            outcome.pictureApplied = false
            outcome.pictureReason = failure.reason
            outcome.pictureDetail = failure.detail
            return outcome
        }

        // 2. Every face on this phone changes now; the held row knows the bot has (or lost) an avatar.
        if stored == true {
            await photos.adopt(name, dataURL: adopted)
            patchRow(name) { $0["has_avatar"] = .bool(adopted != nil) }
        }

        // 3. The kind, with the Title and Description, in one configure.
        let flags: PinnedSection.Patch = ["imageKind": .string(picture.imageKind), "custom": true]
        var outcome: EditOutcome
        do {
            outcome = try await performSaveEdit(name: name, title: title, description: description, flags: flags)
        } catch {
            outcome = EditOutcome(titleApplied: title != nil ? false : nil, descriptionApplied: description != nil ? false : nil,
                                  reason: (error as? BotWriteError)?.reason ?? BotWriteOutcome.reason(error))
            outcome.pictureKindApplied = false
        }
        outcome.pictureApplied = stored
        return outcome
    }
}

private extension BotPictureChange {
    var sendsAsset: Bool { if case .kindOnly = self { return false } else { return true } }
}
