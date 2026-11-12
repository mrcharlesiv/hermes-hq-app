import ActivityKit
import Foundation
struct TwinAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable { var n: Int }
    var name: String
}
