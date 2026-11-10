// [mac] A list row whose only delete is a swipe (`.onDelete`) can't be removed with a mouse, and a right-click in a
// text field opens the field's own menu, not the row's. On the Mac such rows end in a red minus that removes them;
// elsewhere this draws nothing and the swipe stays the way.

import SwiftUI

struct MacRemoveButton: View {
    var identifier: String?
    var action: () -> Void

    var body: some View {
        if DeviceWord.isMac {
            Button(action: action) {
                Image(systemName: "minus.circle.fill").foregroundStyle(Color.hqRed)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
            .accessibilityIdentifier(identifier ?? "row.remove")
        }
    }
}
