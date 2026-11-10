// A Copy button that says it worked: its title reads "Copied" for two seconds, then its own name again, and VoiceOver
// hears "Copied" (the pattern Diagnostics, FailureAlert and the Talk notice use). A second tap starts the two seconds
// over.

import UIKit

@MainActor enum CopyFeedback {
    private static var pending: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Swaps `button`'s title to "Copied" and back to `title`.
    static func flash(_ button: UIButton, title: String = "Copy") {
        let key = ObjectIdentifier(button)
        pending[key]?.cancel()
        button.setTitle("Copied", for: .normal)
        HQAnnounce.say("Copied")
        pending[key] = Task { [weak button] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            pending[key] = nil
            button?.setTitle(title, for: .normal)
        }
    }
}
