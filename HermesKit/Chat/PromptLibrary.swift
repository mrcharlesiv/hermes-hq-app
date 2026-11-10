// ⋯ › Prompts: a library of prompts kept on this device, for every bot and chat. A tap puts one in the message box;
// your own message's hold menu saves it here (Save as Prompt). Stored as JSON in the app's defaults.

import Foundation
import Observation

nonisolated struct SavedPrompt: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    /// Optional; the list shows the text's first line without one.
    var title: String
    var text: String
    var updated: Date

    init(id: UUID = UUID(), title: String, text: String, updated: Date = Date()) {
        self.id = id; self.title = title; self.text = text; self.updated = updated
    }

    /// The list's name for it: its title, else its first line that has words.
    var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line.map { String($0.prefix(80)) } ?? "Untitled Prompt"
    }

    /// Under the title: the text, on one line (the first line drops when it is the title already).
    var preview: String {
        var lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: " ")
    }
}

/// A deleted prompt and the place it had in the list.
nonisolated struct DeletedPrompt: Hashable, Sendable {
    var index: Int
    var prompt: SavedPrompt
}

@MainActor @Observable
final class PromptLibrary {
    static let shared = PromptLibrary()
    static let defaultsKey = "hq.prompts.library"

    private(set) var prompts: [SavedPrompt]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    init(defaults: UserDefaults = .standard, key: String = PromptLibrary.defaultsKey) {
        self.defaults = defaults
        self.key = key
        prompts = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedPrompt].self, from: $0) } ?? []
    }

    /// [sync] Reads the stored list again after another device's copy was written (`SettingsSync`), so the next save
    /// doesn't put the old list back.
    func reloadStored() {
        let stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([SavedPrompt].self, from: $0) } ?? []
        if stored != prompts { prompts = stored }
    }

    /// Saves a new prompt at the top; blank text saves nothing. The same text twice keeps one (moved to the top).
    @discardableResult
    func add(title: String = "", text: String) -> SavedPrompt? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = prompts.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == body }) {
            var existing = prompts.remove(at: at)
            if !name.isEmpty { existing.title = name }
            existing.updated = Date()
            prompts.insert(existing, at: 0)
            save()
            return existing
        }
        let prompt = SavedPrompt(title: name, text: body)
        prompts.insert(prompt, at: 0)
        save()
        return prompt
    }

    /// Edits one in place; blank text deletes it.
    func update(_ id: UUID, title: String, text: String) {
        guard let at = prompts.firstIndex(where: { $0.id == id }) else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { delete([id]); return }
        prompts[at].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        prompts[at].text = body
        prompts[at].updated = Date()
        save()
    }

    /// Removes them; returns what went and where it was (for Undo, `restore`).
    @discardableResult
    func delete(_ ids: Set<UUID>) -> [DeletedPrompt] {
        let gone = prompts.enumerated().filter { ids.contains($0.element.id) }.map { DeletedPrompt(index: $0.offset, prompt: $0.element) }
        guard !gone.isEmpty else { return [] }
        prompts.removeAll { ids.contains($0.id) }
        save()
        return gone
    }

    /// Undo of a delete: each prompt goes back at the place it had (one saved again since is left as it is).
    func restore(_ deleted: [DeletedPrompt]) {
        var changed = false
        for item in deleted.sorted(by: { $0.index < $1.index }) where !prompts.contains(where: { $0.id == item.prompt.id }) {
            prompts.insert(item.prompt, at: min(item.index, prompts.count))
            changed = true
        }
        if changed { save() }
    }

    /// Sign Out of the last gateway: the next person to sign in on this device doesn't see them.
    func removeAll() {
        prompts = []
        defaults.removeObject(forKey: key)
    }

    func move(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { prompts[$0] }
        var rest = prompts.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - before)))
        prompts = rest
        save()
    }

    func contains(text: String) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.contains { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == body }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(prompts) { defaults.set(data, forKey: key) }
    }
}
