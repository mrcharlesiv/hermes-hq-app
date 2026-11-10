import UIKit
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// The pickers behind the + menu (docs/spec/1x-attachments.md §4.2–§4.5): Photos (`PHPickerViewController`, images and
// videos, no library permission), Camera (`UIImagePickerController`), Files (`UIDocumentPickerViewController`, copies)
// and Paste. Each result becomes a preparing tile at once (pick order) and is imported off the main thread; an iCloud
// download shows its progress on the tile, and removing the tile cancels it.

@MainActor final class AttachmentPickerCoordinator: NSObject, PHPickerViewControllerDelegate, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate, UIDocumentPickerDelegate {

    /// Adds a pick's sources (the chat's attachments controller imports them).
    var onPicked: (([PickedSource]) -> Void)?
    /// "Couldn't Attach" with a reason.
    var onError: ((String) -> Void)?
    weak var presenter: UIViewController?

    /// One picked item, before import.
    enum PickedSource {
        /// A library item: its provider (loaded inside the import, so the iCloud download shows on the tile).
        case library(NSItemProvider, movie: Bool)
        /// The camera's picture as taken: oriented and scaled down by the import, off the main thread.
        case camera(UIImage)
        case file(URL)
        case pasted(NSItemProvider)
        /// A file dropped on the chat or pasted from the Finder (or Files): copied out of its provider by the import.
        case dropped(NSItemProvider)
    }

    // MARK: Photos

    func presentPhotos(remaining: Int) {
        guard remaining > 0 else { onError?(AttachmentPrepareError.limitReached.errorDescription ?? ""); return }
        var config = PHPickerConfiguration()
        config.selectionLimit = min(AttachmentStaging.maxPerPick, remaining)
        config.filter = .any(of: [.images, .videos])
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else {
            AppLog.trace("attach", "photos picker: nothing picked")
            return
        }
        let sources = results.map { result -> PickedSource in
            let movie = result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            return .library(result.itemProvider, movie: movie)
        }
        let movies = sources.filter { if case .library(_, true) = $0 { return true }; return false }.count
        AppLog.trace("attach", "photos picked: \(sources.count) (\(movies) video, \(sources.count - movies) image)")
        onPicked?(sources)
    }

    // MARK: Camera

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            AppLog.note("attach", "camera access alert shown: not authorized")
            // [mac] Mac polish #11: System Settings › Privacy & Security › Camera on the Mac (`PrivacySettingsLink`).
            let alert = UIAlertController(title: "Camera Access", message: "Allow camera access for \(AppIdentity.current.displayName) in \(PrivacySettingsLink.place).",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: PrivacySettingsLink.openTitle, style: .default) { _ in PrivacySettingsLink.open(.camera) })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            presenter?.present(alert, animated: true)
            return
        default:
            break
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.modalPresentationStyle = .fullScreen
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        // The UIImage carries no location; `.mediaMetadata` is never written (spec §4.3). Orienting and scaling a 12 MP
        // picture takes 100–300 ms: the import does it off the main thread while the camera sheet goes (spec §5).
        guard let image = info[.originalImage] as? UIImage else {
            AppLog.note("attach", "camera pick failed: no image")
            onError?(AttachmentPrepareError.cameraNotSaved.errorDescription ?? "")
            return
        }
        AppLog.trace("attach", "camera photo picked")
        onPicked?([.camera(image)])
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }

    // MARK: Files

    func presentFiles(remaining: Int) {
        guard remaining > 0 else { onError?(AttachmentPrepareError.limitReached.errorDescription ?? ""); return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        pendingRemaining = remaining
        presenter?.present(picker, animated: true)
    }

    private var pendingRemaining = AttachmentStaging.maxPerPick

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let allowed = min(AttachmentStaging.maxPerPick, pendingRemaining)
        let picked = Array(urls.prefix(allowed))
        if urls.count > allowed && pendingRemaining <= AttachmentStaging.maxPerPick && urls.count > pendingRemaining {
            AppLog.note("attach", "files picked: \(urls.count), limit reached, kept \(picked.count)")
            onError?(AttachmentPrepareError.limitReached.errorDescription ?? "")
        } else {
            AppLog.trace("attach", "files picked: \(picked.count)")
        }
        onPicked?(picked.map { .file($0) })
    }
}
