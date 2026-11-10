// A window scene for the Screen views that are laid out in a real window. The hosting app connects its scene a
// moment after launch, so a suite that starts first waits for it.

import UIKit

@MainActor
enum ScreenHosting {
    static func scene(wait seconds: Double = 15) async -> UIWindowScene? {
        let until = Date().addingTimeInterval(seconds)
        while true {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { return scene }
            if Date() > until { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
