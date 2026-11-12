// [island-fit] Test-only: another app with a Live Activity of its own, so the island tour can photograph ours sharing
// the Dynamic Island (scripts/island-shots.sh builds and installs it; never embedded, never archived). At launch it
// ends what it had and starts one; `-HQTwinEnd YES` only ends.

import ActivityKit
import SwiftUI

@main struct TwinApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Twin").task {
                for activity in Activity<TwinAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
                guard !UserDefaults.standard.bool(forKey: "HQTwinEnd") else { return }
                try? await Task.sleep(for: .seconds(2))
                _ = try? Activity.request(attributes: TwinAttributes(name: "Twin"),
                                          content: ActivityContent(state: .init(n: 1), staleDate: nil), pushType: nil)
            }
        }
    }
}
