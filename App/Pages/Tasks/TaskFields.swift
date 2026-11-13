// [tasks-first] Step 3 (owner 2026-11-12: "complex enough to handle any task or use case"; mockup 3-task-your-own): what
// a task manager's task has, each one line on the task's page and only once it is set: an alert before it's due, a
// start day, a priority (the circle's colour), tags, and your own files, photos and links beside what a bot made. What
// isn't set waits as quiet words under the who row. All of it needs hermes-hq-push 0.9.53 (`TasksStore.fieldsSupported`,
// `filesSupported`); on an older add-on none of it shows.

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A priority's colour: the circle on the task's row and page, and its flag. High is the look's red, low its accent;
/// medium is an amber of its own (the look's orange is a burnt orange made for words, and read as a second red beside
/// the red circle).
enum TodoPriorityLook {
    private static let amber = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.70, blue: 0.20, alpha: 1) : UIColor(red: 0.93, green: 0.58, blue: 0, alpha: 1)
    }

    static func color(_ priority: Int) -> Color? {
        switch priority {
        case 1: return Color.hqRed
        case 2: return Color(uiColor: amber)
        case 3: return Color.hqTint
        default: return nil
        }
    }
}

extension TodoSheetModel {
    var hasFields: Bool { store.fieldsSupported }
    /// Files, photos and links can be added: the add-on takes them, and the gateway takes writes.
    var canAttach: Bool { store.filesSupported && !gone && !store.readOnlyGateway && task?.isDone != true }

    func setPriority(_ priority: Int) {
        guard task?.priority != priority else { return }
        PagesHaptics.selection()
        Task { if await !store.patch(taskID, ["priority": .number(Double(priority))]) { PagesHaptics.error() } }
    }

    /// nil: no alert of its own (it rings at its due time, as before).
    func setAlert(_ minutes: Int?) {
        guard task?.alert != minutes else { return }
        PagesHaptics.selection()
        Task { if await !store.patch(taskID, ["alert": minutes.map { .number(Double($0)) } ?? .null]) { PagesHaptics.error() } }
    }

    func setStart(_ date: Date?) {
        PagesHaptics.selection()
        let value: JSONValue = date.map { .string(TodoDates.wire($0, hasTime: false)) } ?? .null
        Task { if await !store.patch(taskID, ["starts": value]) { PagesHaptics.error() } }
    }

    func pickStart() {
        guard let controller, let task else { return }
        let now = task.starts.flatMap { TodoDates.day(String($0.prefix(10))) }
        let picker = TodoDatePicker.make(date: now, hasTime: false, rings: false, dayOnly: true) { [weak self] date, _ in
            self?.setStart(date)
        }
        controller.present(picker, animated: true)
    }

    /// The tags in one field, comma between them ("hiring, q4").
    func editTags() {
        guard let controller, let task else { return }
        PagesHaptics.selection()
        let alert = UIAlertController(title: "Tags", message: "Short words to find it by, with a comma between them.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = task.tags.joined(separator: ", ")
            field.placeholder = "hiring, q4"
            field.autocapitalizationType = .none
            field.returnKeyType = .done
            field.accessibilityIdentifier = "task.tags.field"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let save = UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let tags = TodoViews.tags(from: alert?.textFields?.first?.text ?? "")
            guard tags != task.tags else { return }
            Task { if await !self.store.patch(self.taskID, ["tags": .array(tags.map(JSONValue.string))]) { PagesHaptics.error() } }
        }
        alert.addAction(save)
        alert.preferredAction = save
        controller.present(alert, animated: true)
    }

    // MARK: Files, photos and links

    func choosePhoto() {
        guard let controller, !attaching else { return }
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible   // HEIC and HEVC arrive as JPEG and H.264
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = KanbanAttachmentPicker { [weak self] url, name in self?.attach(copy: url, name: name) }
        KanbanAttachmentPicker.current = delegate
        picker.delegate = delegate
        controller.present(picker, animated: true)
    }

    func chooseFile() {
        guard let controller, !attaching else { return }
        #if DEBUG
        // UI tests (`-HQPagesSeedFile brief.pdf`): the Files picker runs in another process, so Choose File hands over
        // a file made here instead (as Kanban's).
        if let name = UserDefaults.standard.string(forKey: "HQPagesSeedFile"), !name.isEmpty {
            let url = FileManager.default.temporaryDirectory.appending(path: "seed-" + UUID().uuidString)
            try? Data("A seeded file for the task.\n".utf8).write(to: url)
            attach(copy: url, name: name)
            return
        }
        #endif
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = KanbanAttachmentPicker { [weak self] url, name in self?.attach(copy: url, name: name) }
        KanbanAttachmentPicker.current = delegate
        picker.delegate = delegate
        controller.present(picker, animated: true)
    }

    /// Sends the app's own copy at `url` (removed afterwards) to the task as `name`.
    func attach(copy url: URL, name: String) {
        guard !attaching else { try? FileManager.default.removeItem(at: url); return }
        attaching = true
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            // Read off the main actor: a photo is a few megabytes.
            let data = await Task.detached { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
            guard let self else { return }
            defer { self.attaching = false }
            guard let data else { PagesHaptics.error(); self.show("Couldn’t read that file."); return }
            if await self.store.attachFile(self.taskID, name: name, data: data) {
                PagesHaptics.success()
                HQAnnounce.say("Added \(name)")
            } else {
                PagesHaptics.error()
            }
        }
    }

    func addLink() {
        guard let controller else { return }
        PagesHaptics.selection()
        let alert = UIAlertController(title: "Add Link", message: nil, preferredStyle: .alert)
        let add = UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            var text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return }
            if !text.contains("://"), !text.hasPrefix("mailto:"), !text.hasPrefix("tel:") { text = "https://" + text }
            Task {
                if await self.store.attachLink(self.taskID, url: text) { PagesHaptics.success() } else { PagesHaptics.error() }
            }
        }
        add.isEnabled = false
        alert.addTextField { [weak add] field in
            field.placeholder = "example.com/page"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.returnKeyType = .done
            field.accessibilityIdentifier = "task.link.field"
            // A link copied a moment ago is offered as typed.
            if UIPasteboard.general.hasURLs, let copied = UIPasteboard.general.url?.absoluteString { field.text = copied; add?.isEnabled = true }
            field.addAction(UIAction { [weak add, weak field] _ in
                add?.isEnabled = !(field?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(add)
        alert.preferredAction = add
        controller.present(alert, animated: true)
    }

    func remove(_ made: TodoMade) {
        PagesHaptics.selection()
        Task { if await !store.detach(taskID, made: made.id) { PagesHaptics.error() } }
    }
}
