// Which chat actions show, and when (parity 240 §5 and §8): the chat's ⋯ rows (`chatMenuModel`,
// S:phone-chat-menu-model.ts:27-47), a message's hold menu (`messageMenuItems`, S:ui-chat/message-menu.ts:11-39) and the
// More at the end of the latest reply's action row (S:ui-chat/reply-more.tsx). Pure value logic, so the rules are tested
// without a screen; the chat screen turns the rows into UIMenus (App/Chat/Menus/ChatMenus+Actions.swift).

import Foundation

// MARK: - The chat's ⋯

/// What the ⋯ reads before it opens.
nonisolated struct ChatMenuState: Hashable, Sendable {
    var pinned = false
    var unread = false
    var archived = false
    /// A bot's own chat ("Bot Chat"): no Rename, Archive or Delete — any of them would leave the bot starting over.
    var botChat = false
    /// [tasks] A task's own chat, on its task's page (owner 2026-11-07, Pinned Task step 2): no Pin, Mark as Read,
    /// Rename, Branch, Archive or Delete Chat. It is hidden and belongs to the task; each of those would quietly cut it
    /// from the task (a deleted one left the task pointing at nothing) or start a chat the task doesn't know.
    var taskChat = false
    /// No messages yet: nothing that acts on them (Share, Find, Branch, Export, Mark as Unread).
    var empty = false
    /// Writes go out over the socket and REST: off ("Offline") while the gateway can't be reached.
    var offline = false
    /// The sign-in Hermes stamped on the chat (`SidebarSessionRow.userId`), for a refused write's words.
    var owner: String? = nil
}

/// [mac-audit K] Owner 2026-11-02: one name per action across the menus, with "…" where a panel follows. On the Mac a
/// Share row opens the share panel, so it reads "Share…" as the menu bar's and the media menus' do; the iPhone's tiles
/// keep the short word.
nonisolated enum MenuWords {
    #if targetEnvironment(macCatalyst)
    static let share = "Share…"
    #else
    static let share = "Share"
    #endif
}

nonisolated enum ChatMenuItemID: String, Hashable, Sendable, CaseIterable {
    case share, find, info, pin, unread, rename, files, changes, branch, export, archive, delete
}

nonisolated struct ChatMenuRow: Hashable, Sendable {
    var id: ChatMenuItemID
    var title: String
    var symbol: String
    var disabled = false
    var subtitle: String?
    var destructive = false
}

nonisolated enum ChatMenuModel {
    private static func row(_ id: ChatMenuItemID, _ title: String, _ symbol: String, writing: Bool = false, _ state: ChatMenuState) -> ChatMenuRow {
        ChatMenuRow(id: id, title: title, symbol: symbol, disabled: writing && state.offline, subtitle: writing && state.offline ? "Offline" : nil)
    }

    /// The tiles row: Share and Find (when there are messages), then Info.
    static func tiles(_ s: ChatMenuState) -> [ChatMenuRow] {
        (s.empty ? [] : [row(.share, MenuWords.share, "square.and.arrow.up", s), row(.find, "Find", "magnifyingglass", s)])
            + [row(.info, "Info", "info.circle", s)]
    }

    /// Pin, Mark as Read/Unread, Rename… (under Model ▸).
    static func rows(_ s: ChatMenuState) -> [ChatMenuRow] {
        guard !s.taskChat else { return [] }
        var out = [row(.pin, s.pinned ? "Unpin" : "Pin", s.pinned ? "pin.slash" : "pin", writing: true, s)]
        if !s.empty || s.unread {
            out.append(row(.unread, s.unread ? "Mark as Read" : "Mark as Unread", s.unread ? "envelope.open" : "envelope.badge", writing: true, s))
        }
        if !s.botChat { out.append(row(.rename, "Rename…", "pencil", writing: true, s)) }
        return out
    }

    /// More ▸: Files, Changes, then Branch in New Chat and Export Chat (UX study #73; a .json file) when there are messages.
    static func more(_ s: ChatMenuState) -> [ChatMenuRow] {
        var out = [row(.files, "Files", "folder", s), row(.changes, "Changes", "plus.forwardslash.minus", s)]
        if !s.empty, s.taskChat {
            out.append(row(.export, "Export Chat…", "square.and.arrow.down", writing: true, s))
        } else if !s.empty {
            out += [row(.branch, "Branch in New Chat", "arrow.triangle.branch", writing: true, s),
                    row(.export, "Export Chat…", "square.and.arrow.down", writing: true, s)]
        }
        return out
    }

    /// Archive (or Unarchive) and Delete Chat; none in a bot's own chat.
    static func danger(_ s: ChatMenuState) -> [ChatMenuRow] {
        guard !s.botChat, !s.taskChat else { return [] }
        var delete = row(.delete, "Delete Chat", "trash", writing: true, s)
        delete.destructive = true
        return [row(.archive, s.archived ? "Unarchive" : "Archive", "archivebox", writing: true, s), delete]
    }

    /// Every row the ⋯ offers, in order (the Model ▸ and Watch Browser rows are the screen's own).
    static func all(_ s: ChatMenuState) -> [ChatMenuRow] { tiles(s) + rows(s) + more(s) + danger(s) }
}

// MARK: - A message's hold menu

nonisolated enum MessageMenuKind: Hashable, Sendable { case you, reply }

nonisolated struct MessageMenuContext: Hashable, Sendable {
    /// The newest reply (Regenerate is offered on it only).
    var latest = false
    /// This message is still being written: everything but Copy and Select Text waits ("Still Replying").
    var streaming = false
    /// A reply runs in the chat (Regenerate and Branch wait for it to end).
    var running = false
    /// Your message can be edited and resent, or rewound to (it is stored: it has a row on the gateway).
    var canEdit = false
    var canRewind = false
    /// Your send whose delivery is unconfirmed: Send Again and Delete.
    var undelivered = false
    /// Show / Hide Steps on a reply whose steps fold (nil: none).
    var steps: StepsToggle?
    /// The chat's gateway can be reached (Edit, Regenerate, Branch and Rewind write).
    var offline = false

    /// [talk] Read Aloud on a reply: nil where it is not offered; true while this reply is being read.
    var reading: Bool? = nil

    nonisolated enum StepsToggle: Hashable, Sendable { case show, hide }
}

nonisolated enum MessageMenuItemID: String, Hashable, Sendable {
    case copy, share, edit, selectText, regenerate, branch, steps, rewind, retry, delete
    /// [talk] Read Aloud / Stop Reading on a reply (docs/spec/3x-talk.md §7.2).
    case readAloud
}

nonisolated struct MessageMenuRow: Hashable, Sendable {
    var id: MessageMenuItemID
    var title: String
    var symbol: String
    var disabled = false
    var subtitle: String?
    var destructive = false
}

nonisolated enum MessageMenuModel {
    static let stillReplying = "Still Replying"

    private static func row(_ id: MessageMenuItemID, _ title: String, _ symbol: String, destructive: Bool = false,
                            writes: Bool = false, waitsForTurn: Bool = false, _ ctx: MessageMenuContext) -> MessageMenuRow {
        var out = MessageMenuRow(id: id, title: title, symbol: symbol, destructive: destructive)
        if ctx.streaming && id != .copy && id != .selectText {
            out.disabled = true
            out.subtitle = stillReplying
        } else if waitsForTurn && ctx.running {
            out.disabled = true
            out.subtitle = stillReplying
        } else if writes && ctx.offline {
            out.disabled = true
            out.subtitle = "Offline"
        }
        return out
    }

    /// The tiles across the top: yours Copy (and Edit); a reply's Copy and Share.
    static func tiles(_ kind: MessageMenuKind, _ ctx: MessageMenuContext) -> [MessageMenuRow] {
        let copy = row(.copy, "Copy", "doc.on.doc", ctx)
        switch kind {
        case .you: return [copy] + (ctx.canEdit ? [row(.edit, "Edit", "pencil", writes: true, ctx)] : [])
        case .reply:
            // [talk] Copy · Read Aloud · Share, as on the web (`W:src/ui-chat/message-menu.ts`).
            let read = ctx.reading.map { [row(.readAloud, $0 ? "Stop Reading" : "Read Aloud", $0 ? "stop.fill" : "speaker.wave.2", ctx)] } ?? []
            return [copy] + read + [row(.share, MenuWords.share, "square.and.arrow.up", ctx)]
        }
    }

    /// The rows under the tiles, in the web's order.
    static func rows(_ kind: MessageMenuKind, _ ctx: MessageMenuContext) -> [MessageMenuRow] {
        var out = [row(.selectText, "Select Text", "text.cursor", ctx)]
        switch kind {
        case .reply:
            if ctx.latest { out.append(row(.regenerate, "Regenerate", "arrow.clockwise", writes: true, waitsForTurn: true, ctx)) }
            out.append(row(.branch, "Branch in New Chat", "arrow.triangle.branch", writes: true, waitsForTurn: true, ctx))
            if let steps = ctx.steps { out.append(row(.steps, steps == .show ? "Show Steps" : "Hide Steps", "list.bullet", ctx)) }
        case .you:
            // The kit forbids an ellipsis on destructive rows.
            if ctx.canRewind { out.append(row(.rewind, "Rewind to Here", "clock.arrow.circlepath", destructive: true, writes: true, ctx)) }
            if ctx.undelivered {
                out.append(row(.retry, "Send Again", "arrow.clockwise", writes: true, ctx))
                out.append(row(.delete, "Delete", "trash", destructive: true, ctx))
            }
        }
        return out
    }

    /// The hold menu's title: "<sender> · <model> · <when>" — the model only when it isn't the chat's current one.
    static func title(sender: String, model: String?, currentModel: String?, when: String) -> String {
        let shown = model.flatMap { $0.isEmpty || $0 == currentModel ? nil : $0 }
        return [sender, shown ?? "", when].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The More at the end of the latest reply's action row: what didn't fit in its icons.
    static func replyMore(running: Bool, offline: Bool) -> [MessageMenuRow] {
        let ctx = MessageMenuContext(running: running, offline: offline)
        return [row(.share, MenuWords.share, "square.and.arrow.up", ctx), row(.selectText, "Select Text", "text.cursor", ctx),
                row(.branch, "Branch in New Chat", "arrow.triangle.branch", writes: true, waitsForTurn: true, ctx)]
    }
}

// MARK: - Rewind addressing

/// How a rewind, edit or regenerate names the turn it truncates before (`truncateSubmitParams`, V:use-prompt-actions/
/// rewind.ts:135-190): the user row's id, `confirm_truncate`, and every loaded row id so the gateway can tell the phone
/// the kept rows' new ids.
nonisolated enum RewindParams {
    static func make(beforeRowId row: Int, loadedRowIds: [Int]) -> [String: JSONValue] {
        var seen = Set<Int>()
        let survivors = loadedRowIds.filter { seen.insert($0).inserted }
        return ["truncate_before_row_id": .number(Double(row)), "confirm_truncate": true, "confirm_empty_truncate": true,
                "rebind_survivor_row_ids": .array(survivors.map { .number(Double($0)) })]
    }

    /// The kept rows' new ids from a rewind's answer: `survivor_row_id_map` {"old": new|null}; nil maps a row away.
    static func survivorMap(_ result: JSONValue) -> [Int: Int?] {
        guard let map = result["survivor_row_id_map"]?.object else { return [:] }
        var out: [Int: Int?] = [:]
        for (key, value) in map {
            guard let old = Int(key) else { continue }
            out[old] = value.int
        }
        return out
    }

    /// Text-bearing user and assistant messages up to and including `messageId` (`session.branch`'s `count`).
    static func branchCount(upTo messageId: String, in messages: [ChatMessage]) -> Int? {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return nil }
        return messages[...index].filter { ($0.role == .user || $0.role == .assistant) && !ChatTranscript.blocks($0).isEmpty }.count
    }
}

// MARK: - Export JSON

nonisolated enum ChatExport {
    /// `<slug(title)|session>-<slug(id) first 8>.json` (S:phone-chat-menu.tsx:88-91).
    static func fileName(sessionId: String, title: String?) -> String {
        func part(_ value: String) -> String {
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var out = ""
            var dash = false
            for scalar in lowered.unicodeScalars {
                let ok = ("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)) || scalar == "." || scalar == "_" || scalar == "-"
                if ok { out.unicodeScalars.append(scalar); dash = false } else if !dash { out += "-"; dash = true }
            }
            let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            return String(trimmed.prefix(48))
        }
        let name = title.map(part).flatMap { $0.isEmpty ? nil : $0 } ?? "session"
        let id = String(part(sessionId).prefix(8))
        return "\(name)-\(id.isEmpty ? "session" : id).json"
    }

    /// `{exported_at, session_id, title, session: null, message_count, messages}`, pretty-printed (2 spaces).
    static func payload(sessionId: String, title: String?, messages: [JSONValue], now: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keys in the web's order: JSONEncoder sorts or scrambles them, so the object is written by hand.
        func encode(_ value: JSONValue) throws -> String { String(decoding: try value.encoded(), as: UTF8.self) }
        let rows = try messages.map { "    " + (try encode($0)) }
        var lines = ["{"]
        lines.append("  \"exported_at\": \(try encode(.string(formatter.string(from: now)))),")
        lines.append("  \"session_id\": \(try encode(.string(sessionId))),")
        lines.append("  \"title\": \(try encode(trimmed.flatMap { $0.isEmpty ? nil : JSONValue.string($0) } ?? .null)),")
        lines.append("  \"session\": null,")
        lines.append("  \"message_count\": \(messages.count),")
        lines.append(rows.isEmpty ? "  \"messages\": []" : "  \"messages\": [\n" + rows.joined(separator: ",\n") + "\n  ]")
        lines.append("}")
        return Data(lines.joined(separator: "\n").utf8)
    }
}
