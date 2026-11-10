// Add Attachment on a Kanban task (docs/spec/3x-morepages.md §4): a menu row under the task's files (Photo Library /
// Choose File), "Adding…" with a bar while it uploads, then the task is read again. Hidden on a read-only gateway and
// while offline.

import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension KanbanTaskModel {
    static let uploadKey = "upload"
    var uploading: Bool { busy.contains(Self.uploadKey) }
    /// The row shows: the gateway takes writes and is reachable.
    var canAddAttachment: Bool { !store.readOnlyGateway && ((services as? any AppServices)?.connection ?? .ready) == .ready }

    func choosePhoto() {
        guard let controller, !uploading else { return }
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .compatible   // HEIC and HEVC arrive as JPEG and H.264
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = KanbanAttachmentPicker { [weak self] url, name in self?.addAttachment(copy: url, name: name) }
        KanbanAttachmentPicker.current = delegate
        picker.delegate = delegate
        controller.present(picker, animated: true)
    }

    func chooseFile() {
        guard let controller, !uploading else { return }
        #if DEBUG
        // UI tests (`-HQPagesSeedFile brief.pdf [-HQPagesSeedFileMB 30]`): the Files picker runs in another process, so
        // Choose File hands over a file made here instead.
        if let name = UserDefaults.standard.string(forKey: "HQPagesSeedFile"), !name.isEmpty {
            let megabytes = UserDefaults.standard.integer(forKey: "HQPagesSeedFileMB")
            let url = FileManager.default.temporaryDirectory.appending(path: "seed-" + UUID().uuidString)
            let content = megabytes > 0 ? Data(count: megabytes * 1024 * 1024) : Data("A seeded file for the task.\n".utf8)
            try? content.write(to: url)
            addAttachment(copy: url, name: name)
            return
        }
        #endif
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        let delegate = KanbanAttachmentPicker { [weak self] url, name in self?.addAttachment(copy: url, name: name) }
        KanbanAttachmentPicker.current = delegate
        picker.delegate = delegate
        controller.present(picker, animated: true)
    }

    /// Uploads the app's own copy at `url` (removed afterwards) as `name`, then reads the task again.
    func addAttachment(copy url: URL, name: String) {
        guard let task, !uploading else { try? FileManager.default.removeItem(at: url); return }
        if store.readOnlyGateway { KanbanFeedback.readOnly(from: controller); try? FileManager.default.removeItem(at: url); return }
        let id = task.id, board = store.slug, api = store.api
        let filename = KanbanAttachmentUpload.sendName(name)
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        busy.insert(Self.uploadKey)
        uploadProgress = size > KanbanAttachmentUpload.progressFloor ? 0 : nil
        let shows = uploadProgress != nil
        let report: @Sendable (Int64, Int64) -> Void = { [weak self] sent, total in
            guard shows, total > 0 else { return }
            let fraction = min(1, Double(sent) / Double(total))
            Task { @MainActor in if self?.uploading == true { self?.uploadProgress = fraction } }
        }
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                try await api.addAttachment(id, file: url, filename: filename, board: board, progress: report)
                guard let self else { return }
                self.finishUpload()
                await self.read()
                PagesHaptics.success()
                if let controller = self.controller { PagesHUD.show("Attachment Added", symbol: "checkmark", from: controller) }
            } catch {
                guard let self else { return }
                self.finishUpload()
                guard !(error is CancellationError) else { return }
                PagesHaptics.error()
                let reason = KanbanAttachmentUpload.reason(error)
                FailureAlert.present(title: KanbanAttachmentUpload.failureTitle, reason: reason.text, from: self.controller, whole: true)
                if reason.gone {
                    await self.read()
                    await self.store.readBoard()
                }
            }
        }
    }

    private func finishUpload() {
        busy.remove(Self.uploadKey)
        uploadProgress = nil
    }
}

/// The delegate of the photo and file pickers: copies the pick into the app's temporary folder and hands it over.
final class KanbanAttachmentPicker: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    /// Kept while a picker shows (pickers hold their delegate weakly).
    static var current: KanbanAttachmentPicker?
    private let picked: @MainActor @Sendable (URL, String) -> Void

    init(picked: @escaping @MainActor @Sendable (URL, String) -> Void) { self.picked = picked }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        Self.current = nil
        guard let provider = results.first?.itemProvider else { return }
        let type = [UTType.movie, .image].first { provider.hasItemConformingToTypeIdentifier($0.identifier) } ?? .item
        let stem = provider.suggestedName ?? "Photo"
        let picked = self.picked
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
            // The file is gone when this returns: copy it now.
            guard let url else { return }
            let ext = url.pathExtension.isEmpty ? (type == .movie ? "mov" : "jpg") : url.pathExtension
            let copy = FileManager.default.temporaryDirectory.appending(path: "attach-" + UUID().uuidString + "." + ext)
            guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
            let name = (stem as NSString).pathExtension.isEmpty ? stem + "." + ext : stem
            Task { @MainActor in picked(copy, name) }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Self.current = nil
        guard let url = urls.first else { return }
        // `asCopy: true`: the pick is already the app's own copy; move it out of the inbox under a name of ours.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appending(path: "attach-" + UUID().uuidString)
        guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
        picked(copy, url.lastPathComponent)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { Self.current = nil }
}

/// The row under a task's files.
struct KanbanAddAttachmentRow: View {
    let model: KanbanTaskModel

    var body: some View {
        if model.uploading {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Adding…").font(Font.hq(.body)).foregroundStyle(Color.hqLabel2)
                }
                if let progress = model.uploadProgress {
                    ProgressView(value: progress).accessibilityLabel("Upload progress")
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("kanban.task.adding")
        } else {
            Menu {
                Button { model.choosePhoto() } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                Button { model.chooseFile() } label: { Label("Choose File", systemImage: "folder") }
            } label: {
                Label {
                    Text("Add Attachment").font(Font.hq(.body)).foregroundStyle(Color.hqTint)
                } icon: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.green)
                }
                // The whole row opens the menu, not only its words.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("kanban.task.add-attachment")
        }
    }
}
