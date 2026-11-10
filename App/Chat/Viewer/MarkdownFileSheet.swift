import UIKit

// A Markdown file opened from a chat (a file row, a `#media:` link, your own tray tile) or a task's attachment: read
// formatted in a sheet (Preview | Source, as Files and Artifacts read a note), not as Quick Look's raw text. Owner
// 2026-10-29: "markdown files viewed in the app [should] be viewed as pretty, not raw." A file the viewer can't take
// (over 2 MiB) keeps Quick Look.

enum MarkdownFileSheet {
    /// A Markdown file by its name, small enough for the text viewer.
    static func opens(_ url: URL) -> Bool {
        guard WorkspacePage.isMarkdown(url.lastPathComponent) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size <= ArtifactFiles.textLimit
    }

    /// The note in a sheet. With `gateway` (where the file lives on the bot's computer) its links to other files open
    /// them: a note on the same sheet, anything else as a file in a chat opens.
    static func present(_ url: URL, from vc: UIViewController, gateway: (path: String, context: MediaContext)? = nil) {
        let name = url.lastPathComponent
        let page = page(name, file: { url }, gateway: gateway)
        AppLog.trace("chatui", "markdown file opened formatted")
        vc.present(ChatSheet.wrap(page, title: name, detents: [.large()]), animated: true)
    }

    private static func page(_ name: String, file: @escaping () async throws -> URL,
                             gateway: (path: String, context: MediaContext)?) -> ArtifactTextViewController {
        let viewer = ArtifactTextViewController(title: name, markdown: true, language: nil) { try await text(of: file()) }
        viewer.shareItem = { try await file() }
        viewer.openInQuickLook = { [weak viewer] in
            guard let viewer else { return }
            QuickLookPresenter.open(from: viewer, busy: nil) { try await file() }
        }
        guard let gateway else { return viewer }
        let (path, context) = gateway
        // Back from the next note reads this one's name, or plain "Back" when the name is long (as Artifacts does).
        if !ArtifactLinks.backUsesName(name) {
            viewer.navigationItem.backButtonDisplayMode = .generic
            viewer.navigationItem.backButtonTitle = "Back"
        }
        viewer.linkOpener = { target, fragment, from in
            let next = ArtifactLinks.linkedNotePath(from: path, target: target)
            guard !next.isEmpty else { return }
            if next == path {
                if let fragment { from.scroll(toFragment: fragment) }   // a heading in this note: no new page
                return
            }
            let nextName = ArtifactLinks.name(next)
            guard WorkspacePage.isMarkdown(nextName) else {
                FilePreviewPresenter.shared.open(path: next, name: nextName, context: context, from: from, row: nil)
                return
            }
            let download = {
                try await MediaLoader.shared.file(path: next, name: nextName, context: context,
                                                  progressKey: FilePreviewPresenter.progressKey(next))
            }
            let note = page(nextName, file: download, gateway: (next, context))
            note.loadingText = "Loading \(nextName)…"
            note.failureTitle = "Couldn’t open \(nextName) here."
            note.pendingFragment = fragment
            from.navigationController?.pushViewController(note, animated: true)
        }
        return viewer
    }

    /// The file's words, read off the main thread.
    @concurrent
    nonisolated private static func text(of url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= ArtifactFiles.textLimit else { throw PagesMessageError(ArtifactFiles.tooLargeText) }
        guard let text = String(data: data, encoding: .utf8) else { throw PagesMessageError("This file isn’t plain text.") }
        return text
    }
}
