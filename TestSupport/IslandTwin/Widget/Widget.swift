import ActivityKit
import SwiftUI
import WidgetKit
@main struct TwinBundle: WidgetBundle { var body: some Widget { TwinWidget() } }
struct TwinWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TwinAttributes.self) { _ in Text("Twin").padding() } dynamicIsland: { _ in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) { Text("Twin") }
            } compactLeading: { Image(systemName: "triangle.fill") } compactTrailing: { Text("····") } minimal: { Image(systemName: "triangle.fill") }
        }
    }
}
