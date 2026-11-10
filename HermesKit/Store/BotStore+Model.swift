// A bot's own default model, set from the phone (tester batch 3: "Changing the model in Settings only changes it for
// default"). `POST /api/model/set?profile=<bot>` with scope main: the call Settings › Model makes for the gateway's own
// profile, scoped the way the desktop app scopes it. Every Hermes with `profiles.list` takes `?profile=` there, and an
// unknown profile is a 404, never a write to another bot. An expensive model asks first: the gateway answers
// `confirm_required` and writes nothing; the caller asks the user and sends again with `confirm`. The roster row takes
// the new model at once, and a roster read sent before the write settled can't put the old one back (the same fence as
// the meta's, spec 1x-settings §2.4).

import Foundation

/// A default model this device set, kept over roster reads sent before it settled.
nonisolated struct BotModelWrite: Sendable, Equatable {
    var model: String
    var provider: String
    /// When the gateway answered.
    var at: Date

    func apply(to row: inout [String: JSONValue]) {
        row["model"] = .string(model)
        row["provider"] = .string(provider)
    }
}

extension BotStore {
    /// Sets `name`'s default model. Throws `ModelSetError.confirm` when the gateway asks first, a `BotWriteError` otherwise.
    func setDefaultModel(name: String, display: String, provider: String, model: String, baseURL: String? = nil,
                         confirm: Bool = false) async throws {
        let title = SettingsWords.botModelFailureTitle(display)
        if readOnlyGateway { throw BotWriteError(title: title, reason: BotWriteError.readOnlyReason) }
        let answer: JSONValue
        do {
            answer = try await GatewaySettingsAPI(client: client, profile: name)
                .setModel(scope: "main", provider: provider, model: model, baseURL: baseURL, confirm: confirm)
        } catch let ask as ModelSetError {
            throw ask
        } catch {
            throw BotWriteError(title: title, reason: SettingsErrorText.save(error), detail: "\(error)")
        }
        // Hermes answers the names it saved (an alias comes back as its provider).
        let written = BotModelWrite(model: RosterText.trimmed(answer["model"]) ?? model,
                                    provider: RosterText.trimmed(answer["provider"]) ?? provider, at: Date())
        editing.modelWrites[name] = written
        patchRow(name) { written.apply(to: &$0) }
        rebuild()
    }

    /// Roster hook (from `rowsArrived`): a model this device set after the read was sent stays on its row; a read sent
    /// after the write settled carries it, and the fence goes.
    func keepModelWrites(issuedAt: Date) {
        for (name, write) in editing.modelWrites {
            if write.at < issuedAt { editing.modelWrites[name] = nil } else { patchRow(name) { write.apply(to: &$0) } }
        }
    }
}
