import UIKit
import UniformTypeIdentifiers

// [mac-audit] Owner 2026-11-02 (Mac audit J1): Save As… for a file from the bot's computer. Artifacts, Files and
// Changes rows, chat file cards and photos only offered Share, Copy Path and Save to Photos; the only save panel on the
// Mac was Export Chat's (ExportSaver in ChatMenus+Actions.swift). Each place fetches its file the way its Share… does,
// then hands the copy to the Mac's save panel (UIDocumentPickerViewController forExporting, as a copy). The phone keeps
// Share's "Save to Files", so these menus add Save As… on the Mac only (`FileSaver.offered`).
// Also here: the lazy NSItemProvider a row dragged out of the app hands the Finder (as chat file cards already do).

@MainActor final class FileSaver: NSObject, UIDocumentPickerDelegate {
    /// Whether menus offer Save As… (the Mac: the phone saves through the share sheet).
    static let offered = DeviceWord.isMac
    static let title = "Save As…"
    static let symbol = "square.and.arrow.down"

    private static var open: [FileSaver] = []
    private let removing: URL?
    private weak var host: UIViewController?

    private init(removing: URL?, host: UIViewController) {
        self.removing = removing
        self.host = host
    }

    /// The menu item: `run` fetches the file (each place as its Share… does) and calls `present`.
    static func action(_ run: @escaping () -> Void) -> UIAction {
        let action = UIAction(title: title, image: UIImage(systemName: symbol)) { _ in run() }
        action.accessibilityIdentifier = "menu.save-as"
        return action
    }

    /// The save panel for `url` over whatever is on top of `vc`. `removing` (a temporary folder holding a named copy)
    /// goes when the panel closes; cached files stay.
    static func present(_ url: URL, from vc: UIViewController, removing: URL? = nil) {
        let top = MenusSheet.top(vc) ?? vc
        let saver = FileSaver(removing: removing, host: top)
        let panel = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        panel.delegate = saver
        open.append(saver)
        AppLog.trace("files", "save panel opened (.\(url.pathExtension))")
        top.present(panel, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if urls.first != nil {
            Haptics.play(.success)
            MenusHUD.show("Saved", in: host?.view)
            AppLog.trace("files", "save panel saved")
        }
        finish()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }

    private func finish() {
        if let removing { try? FileManager.default.removeItem(at: removing) }
        Self.open.removeAll { $0 === self }
    }

    // MARK: Dragging a file out

    /// A provider for a file dragged out of the app: `load` runs only when the drop asks for the bytes (the Finder, Mail,
    /// another app), and answers the file on disk. `name` gives the dragged file its name and type.
    /// Mac polish 2026-11-06 #47: `failed` hears why a drop got nothing (the page says so in its own alert); the drop
    /// itself only showed nothing.
    static func dragProvider(name: String, failed: (@MainActor (Error) -> Void)? = nil,
                             load: @escaping @MainActor () async throws -> URL) -> NSItemProvider {
        let uti = UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? UTType.data.identifier
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: uti, fileOptions: [], visibility: .all) { done in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor in
                do {
                    done(try await load(), false, nil)
                } catch {
                    AppLog.note("files", "file drag: download failed (\(type(of: error)))")
                    done(nil, false, error)
                    if !(error is CancellationError) { failed?(error) }
                }
                progress.completedUnitCount = 1
            }
            return progress
        }
        return provider
    }
}
