import UIKit
import QuickLook
import AVFoundation

// Opening a file from a chat (docs/spec/1x-attachments.md §10): from the media store at once, else downloaded
// (512 MB ceiling) with the row reading "Downloading… 40 %" (a second tap cancels: "Cancelled"); then a Markdown file
// formatted (`MarkdownFileSheet`), anything else Quick Look, or the share sheet for a type Quick Look can't show. Errors
// say what happened in an alert.

@MainActor final class FilePreviewPresenter: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    static let shared = FilePreviewPresenter()

    private var previewURL: URL?
    private var downloads: [String: Task<Void, Never>] = [:]
    private var tokens: [String: TransferProgressCenter.Token] = [:]
    /// What a file does once it is on the phone: opens, goes to the share sheet, or ([mac-audit] Mac audit J1) to the
    /// Mac's save panel.
    enum Delivery { case open, share, save }
    /// What a running download does when it lands (the latest ask wins).
    private var sharing: [String: Delivery] = [:]

    /// The progress key of a file download.
    static func progressKey(_ path: String) -> String { "dl|" + path }

    /// The row while it still shows `path` (a reused cell may show another file by the time the download moves on).
    private static func showing(_ row: FileRowView?, _ path: String) -> FileRowView? {
        guard let row, row.item?.attachment.gatewayPath == path else { return nil }
        return row
    }

    /// Opens a gateway file (a tap on a file row, "Tap to open" on a too-large photo).
    func open(path: String, name: String, context: MediaContext, from vc: UIViewController, row: FileRowView?,
              tile: HTMLPageSheet.Tile? = nil) {
        // [tiles] A page opened from Tiles opens as the tile (its name, its Updates).
        tiles[Self.progressKey(path)] = tile
        fetch(path: path, name: name, context: context, from: vc, row: row, share: .open)
    }

    /// [tiles] The tile a page is opening as, until it opens.
    private var tiles: [String: HTMLPageSheet.Tile] = [:]

    /// The row's Share…: the same download as Open (the row reads "Downloading… 40 %", a second tap cancels), then the
    /// share sheet.
    func shareFile(path: String, name: String, context: MediaContext, from vc: UIViewController, row: FileRowView?) {
        fetch(path: path, name: name, context: context, from: vc, row: row, share: .share)
    }

    /// [mac-audit] Owner 2026-11-02 (Mac audit J1): the row's Save As…: the same download as Share… (the row's progress,
    /// a second click cancels), then the Mac's save panel.
    func saveFile(path: String, name: String, context: MediaContext, from vc: UIViewController, row: FileRowView?) {
        fetch(path: path, name: name, context: context, from: vc, row: row, share: .save)
    }

    private func fetch(path: String, name: String, context: MediaContext, from vc: UIViewController, row: FileRowView?,
                       share: Delivery) {
        let key = Self.progressKey(path)
        if downloads[key] != nil {
            // Share… while it downloads to open (or the reverse) changes what it does when it lands (review: it cancelled).
            if sharing[key] != share { sharing[key] = share; return }
            // A second tap while it downloads cancels it.
            downloads[key]?.cancel()
            downloads[key] = nil
            tokens[key] = nil
            sharing[key] = nil
            MediaLoader.shared.cancelFile(path: path, context: context)
            Self.showing(row, path)?.showCancelled()
            AppLog.trace("chatui", "file \(share) cancelled (second tap)")
            return
        }
        let store = MediaLoader.shared.store(for: context.accountId)
        // A page is read again each time it opens (a bot rewrites its page in place); the kept copy if that fails.
        let page = share == .open && HTMLPageSheet.opens(name: name)
        if !page, let cached = store.cachedFile(MediaStore.gatewayKey(accountId: context.accountId, profile: context.profile, path: path), name: name) {
            AppLog.trace("chatui", "file \(share) from cache: \(Self.byteSize(cached)) bytes")
            deliver(cached, from: vc, anchor: row, share: share, gateway: (path, context))
            return
        }
        row?.showDownload(0)
        sharing[key] = share
        let started = ContinuousClock.now
        AppLog.trace("chatui", "file \(share) downloading")
        tokens[key] = TransferProgressCenter.shared.observe(key) { [weak row] fraction in
            if let fraction { Self.showing(row, path)?.showDownload(fraction) }
        }
        downloads[key] = Task { [weak self, weak vc, weak row] in
            do {
                let url = try await MediaLoader.shared.file(path: path, name: name, context: context, progressKey: key, fresh: page)
                guard let self else { return }
                self.downloads[key] = nil
                self.tokens[key] = nil
                let share = self.sharing.removeValue(forKey: key) ?? share
                Self.showing(row, path)?.showDownload(nil)
                AppLog.trace("chatui", "file downloaded: \(Self.byteSize(url)) bytes in \(AppLog.ms(since: started)) ms")
                if let vc { self.deliver(url, from: vc, anchor: Self.showing(row, path), share: share, gateway: (path, context)) }
            } catch is CancellationError {
            } catch {
                guard let self else { return }
                self.downloads[key] = nil
                self.tokens[key] = nil
                self.sharing[key] = nil
                if Task.isCancelled { return }
                Self.showing(row, path)?.showDownload(nil)
                let message = (error as? MediaLoadError)?.fileMessage ?? MediaLoadError.unreachable.fileMessage
                let known = (error as? MediaLoadError).map { String(describing: $0) } ?? "\(type(of: error))"
                AppLog.note("chatui", "file download failed (\(known)) after \(AppLog.ms(since: started)) ms: \(AppLog.scrub(message))")
                if let vc { Self.alert(message, on: vc) }
            }
        }
    }

    /// Byte size for logs only (never the file name).
    private static func byteSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func deliver(_ url: URL, from vc: UIViewController, anchor: UIView?, share: Delivery,
                         gateway: (path: String, context: MediaContext)) {
        switch share {
        case .share: self.share(url, from: vc, anchor: anchor)
        case .save: FileSaver.present(url, from: vc)   // the cached copy stays: only a copy goes where you save it
        case .open: present(url, from: vc, anchor: anchor, gateway: gateway)
        }
    }

    /// A file already on the phone (a tray tile): no download.
    func openLocal(_ url: URL, from vc: UIViewController, anchor: UIView?) {
        present(url, from: vc, anchor: anchor)
    }

    static func alert(_ message: String, on vc: UIViewController) {
        let alert = UIAlertController(title: "Couldn’t Open File", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(alert, animated: true)
    }

    /// A Markdown file reads formatted (`MarkdownFileSheet`), an HTML page live (`HTMLPageSheet`); anything else Quick
    /// Look, or the share sheet.
    private func present(_ url: URL, from vc: UIViewController, anchor: UIView?,
                         gateway: (path: String, context: MediaContext)? = nil) {
        if MarkdownFileSheet.opens(url) {
            MarkdownFileSheet.present(url, from: vc, gateway: gateway)
            return
        }
        // A page a bot made runs its scripts (Quick Look draws HTML without them).
        if HTMLPageSheet.opens(url) {
            let tile = gateway.flatMap { tiles.removeValue(forKey: Self.progressKey($0.path)) }
            HTMLPageSheet.present(url, source: gateway.map { Self.pageSource($0.path, $0.context, from: vc) }, tile: tile, from: vc)
            return
        }
        Task { [weak self, weak vc, weak anchor] in
            let previewable = await Self.canPreview(url)
            guard let self, let vc else { return }
            #if targetEnvironment(macCatalyst)
            // [mac-files] A window of its own on the Mac, not a sheet over the chat.
            if previewable, MacFileWindow.open(url) { return }
            #endif
            if previewable {
                self.previewURL = url
                let preview = QLPreviewController()
                preview.dataSource = self
                preview.delegate = self
                AppLog.trace("chatui", "file preview opened: \(Self.byteSize(url)) bytes")
                vc.present(preview, animated: true)
            } else {
                AppLog.trace("chatui", "file preview unsupported, sharing instead: \(Self.byteSize(url)) bytes")
                self.share(url, from: vc, anchor: anchor)
            }
        }
    }

    /// Where a page lives, and the chat it was opened from (its buttons message that chat's bot).
    static func pageSource(_ path: String, _ context: MediaContext, from vc: UIViewController) -> HTMLPageSheet.Source {
        var chat: ChatViewController?
        var cursor: UIViewController? = vc
        while let c = cursor, chat == nil {
            chat = c as? ChatViewController
            cursor = c.parent ?? c.presentingViewController
        }
        let activity = chat?.session as? ChatActivityProviding
        let send: ((String) -> Void)? = activity.map { provider in { [weak provider] prompt in provider?.sendHidden(prompt, display: nil) } }
        return HTMLPageSheet.Source(path: path, context: context, send: send, botName: chat?.botName ?? "the bot")
    }

    /// Quick Look takes the type; a movie or a sound must also be one AVFoundation can play (a file named .mov that
    /// isn't a movie gets the share sheet, not Quick Look's error).
    static func canPreview(_ url: URL) async -> Bool {
        #if !targetEnvironment(macCatalyst)   // [mac] the Mac's Quick Look shows any file (an unknown one as its icon)
        guard QLPreviewController.canPreview(url as NSURL) else { return false }
        #endif
        let kind = MediaKinds.kind(ofName: url.lastPathComponent)
        guard kind == .video || kind == .audio else { return true }
        return (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
    }

    func share(_ url: URL, from vc: UIViewController, anchor: UIView?) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = anchor ?? vc.view
        if let anchor { sheet.popoverPresentationController?.sourceRect = anchor.bounds }   // [mac-audit] the row, not its corner
        vc.present(sheet, animated: true)
    }

    // MARK: Quick Look

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        AppLog.trace("chatui", "file preview closed")
        if let url = previewURL { MediaLoader.shared.purgeBigPreview(url) }
        previewURL = nil
    }
}

extension MediaLoader {
    /// A file preview over 64 MB isn't kept once it closes (spec §8.1).
    func purgeBigPreview(_ url: URL) {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > MediaStore.keepFileLimit, url.path.contains("/HQNMedia/") else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
