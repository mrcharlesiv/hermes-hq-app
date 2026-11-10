// "Couldn’t …" alerts (spec 1x-settings §2.3, `S/ui-kit/native-alert.ts:103-123`): the reason cut to two lines, Show
// Details (a selectable text page with Copy), Try Again (preferred; re-runs the whole action), OK. An error haptic as it
// shows.

import SwiftUI
import UIKit

enum FailureAlert {
    /// Presents over the topmost controller of `presenter`'s window.
    /// `whole` ([offline] §3.4) shows the reason uncut: a sentence whose last words are the way out must not end in "…".
    static func present(title: String, reason: String, detail: String? = nil, from presenter: UIViewController?,
                        whole: Bool = false, retry: (() -> Void)? = nil) {
        guard let host = topmost(presenter) else { return }
        Haptics.play(.error)
        let alert = UIAlertController(title: title, message: whole ? reason : twoLines(reason), preferredStyle: .alert)
        // The raw error can carry a failing URL's query: details (and Copy) never show a token or cookie.
        let details = PageStates.scrubbed([reason, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        alert.addAction(UIAlertAction(title: "Show Details", style: .default) { [weak host] _ in
            guard let host else { return }
            // The shared sheet frame (✕ leading, no grabber, opaque grouped page; verify round 1).
            let page = UIHostingController(rootView: HQScaledRoot(FailureDetailsView(title: title, text: details)))
            host.present(ChatSheet.wrap(page, title: "Details"), animated: true)
        })
        if let retry, !SessionActionText.isRefusal(reason) {
            let again = UIAlertAction(title: "Try Again", style: .default) { _ in retry() }
            alert.addAction(again)
            alert.preferredAction = again
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        host.present(alert, animated: true)
    }

    static func present(_ error: Error, fallbackTitle: String, from presenter: UIViewController?, retry: (() -> Void)? = nil) {
        if let failure = error as? BotWriteError {
            present(title: failure.title.isEmpty ? fallbackTitle : failure.title, reason: failure.reason, detail: failure.detail,
                    from: presenter, retry: retry)
        } else {
            // Plain words in the alert; the raw error only behind Show Details.
            present(title: fallbackTitle, reason: FailureReasonWords.reason(for: error), detail: "\(error)",
                    from: presenter, retry: retry)
        }
    }

    /// At most two lines' worth (the alert itself wraps; the full text is behind Show Details).
    static func twoLines(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let first = lines.prefix(2).joined(separator: "\n")
        return first.count > 160 ? String(first.prefix(157)) + "…" : first
    }

    static func topmost(_ controller: UIViewController?) -> UIViewController? {
        // A list under a pushed page (Sessions under Other Apps) is out of the window: its stack's window still is.
        var top = (controller?.view.window ?? controller?.navigationController?.view.window)?.rootViewController ?? controller
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

struct FailureDetailsView: View {
    var title: String
    var text: String
    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                Text(text)
                    .font(Font.hq(.body).monospaced())
                    .textSelection(.enabled)
                    .padding(.vertical, 12)
            } header: { HQSectionLabel {
                Text(title)
            } }
            Section {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = text
                    Haptics.play(.success)
                    HQAnnounce.say("Copied")
                    copied = true
                    // "Copied" for two seconds, then "Copy" again (as Diagnostics' Copy).
                    copiedTask?.cancel()
                    copiedTask = Task {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { copied = false }
                    }
                }
            }
        }
        .hqGroupedPage()   // [desktoplook] the page follows the skin
        .listStyle(.insetGrouped)
    }
}
