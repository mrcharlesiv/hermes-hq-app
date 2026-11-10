// Linked notes (docs/spec/3x-morepages.md §3): a link in a Markdown note that names another file opens that file in
// another text viewer pushed on the same stack, read with the first note's session and bot. Back is the note before.

import UIKit

@MainActor
enum ArtifactLinkedNotes {
    /// Makes `viewer` (showing `record`) follow links to other files.
    static func wire(_ viewer: ArtifactTextViewController, record: ArtifactRecord, client: any GatewayClient, account: GatewayAccount) {
        // Back from the next note reads this one's name, or plain "Back" when the name is long (the web's 12 characters).
        // (The bar draws Back as a chevron; the name is what VoiceOver and the hold-Back menu read.)
        if !ArtifactLinks.backUsesName(viewer.title ?? "") {
            viewer.navigationItem.backButtonDisplayMode = .generic
            viewer.navigationItem.backButtonTitle = "Back"
        }
        viewer.linkOpener = { target, fragment, from in
            let path = ArtifactLinks.linkedNotePath(from: record.value, target: target)
            guard !path.isEmpty else { return }
            if path == record.value {
                // The note on screen, with only a heading named: scroll, no new page.
                if let fragment { from.scroll(toFragment: fragment) }
                return
            }
            open(path: path, fragment: fragment, base: record, from: from, client: client, account: account)
        }
    }

    private static func open(path: String, fragment: String?, base: ArtifactRecord, from: ArtifactTextViewController,
                             client: any GatewayClient, account: GatewayAccount) {
        let name = ArtifactLinks.name(path)
        var record = base
        record.value = path
        record.href = path
        record.label = name
        record.kind = .file
        record.repeats = 1
        record.id = base.id + "\u{1F}" + path
        let opening = ArtifactFiles.opening(record)
        let url = ArtifactFiles.previewURL(account: account, record: record)
        guard case .text(let markdown, let language) = opening else {
            // Not text (a PDF, an image, a page): downloaded, then Quick Look over the note.
            quickLook(record, url: url, from: from, client: client)
            return
        }
        let box = Downloaded()
        let viewer = ArtifactTextViewController(title: name, markdown: markdown, language: language) {
            let data = try await ArtifactFiles.download(client, record)
            box.data = data
            guard data.count <= ArtifactFiles.textLimit else { throw PagesMessageError(ArtifactFiles.tooLargeText) }
            guard let text = String(data: data, encoding: .utf8) else { throw PagesMessageError("This file isn’t plain text.") }
            return text
        }
        viewer.loadingText = "Loading \(name)…"
        viewer.failureTitle = "Couldn’t open \(name) here."
        viewer.pendingFragment = fragment
        viewer.shareItem = {
            let data = if let kept = box.data { kept } else { try await ArtifactFiles.download(client, record) }
            try await ArtifactFiles.save(data, to: url)
            return url
        }
        viewer.openInQuickLook = { [weak viewer] in
            guard let viewer else { return }
            quickLook(record, url: url, from: viewer, client: client, kept: box.data)
        }
        wire(viewer, record: record, client: client, account: account)
        from.navigationController?.pushViewController(viewer, animated: true)
    }

    /// What the note's download gave, kept for Share and Quick Look (main actor only).
    private final class Downloaded { var data: Data? }

    private static func quickLook(_ record: ArtifactRecord, url: URL, from: UIViewController, client: any GatewayClient, kept: Data? = nil) {
        Task { [weak from] in
            do {
                let data = if let kept { kept } else { try await ArtifactFiles.download(client, record) }
                try await ArtifactFiles.save(data, to: url)
                guard let from, from.viewIfLoaded?.window != nil else { return }
                QuickLookPresenter.present(url: url, from: from)
            } catch {
                guard !(error is CancellationError), let from else { return }
                FailureAlert.present(title: "Couldn’t open \(record.label) here.", reason: ArtifactFiles.failureText(error, image: false), from: from)
            }
        }
    }
}
