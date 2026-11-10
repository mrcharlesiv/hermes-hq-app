// [share] Test-only host app for the Share UI tests (docs/spec/3x-share.md §10.3, D13). It presents the real system
// share sheet with the items a test names in the environment variable HQ_PROBE_ITEMS, a JSON array:
//
//   [{"text":"A sentence"}, {"url":"https://example.com/a"}, {"file":"/Users/…/photo-gps.heic"},
//    {"image":"/Users/…/p01.jpg"}, {"repeat":"abc ","count":100000}]
//
// `text` → String, `url` → URL, `file` → a file URL (copied into this app's own temporary folder first, under its own
// name), `image` → the picture itself (a UIImage, the way an app shares a photo it holds rather than a document),
// `repeat` + `count` → a long text (an environment variable cannot carry a megabyte),
// `group` → ONE extension item whose attachments are its members (`file` or `image`), the way Photos hands over a
// selection: {"group":[{"file":"/…/p01.jpg"},{"file":"/…/p02.jpg"}]}. Every other entry is an item of its own.
// Never embedded in the app, never archived.

import SwiftUI
import UIKit

@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

enum ProbeItems {
    static func load() -> (items: [Any], problems: [String]) {
        guard let raw = ProcessInfo.processInfo.environment["HQ_PROBE_ITEMS"], let data = raw.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return ([], ["no HQ_PROBE_ITEMS"]) }
        var items: [Any] = [], problems: [String] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("probe-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func copy(_ path: String, _ slot: String) -> URL? {
            let source = URL(fileURLWithPath: path)
            // Each file in its own folder, so two files of one name stay two files.
            let target = folder.appendingPathComponent(slot, isDirectory: true).appendingPathComponent(source.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            } catch {
                problems.append(source.lastPathComponent)
                return nil
            }
        }
        for (index, entry) in list.enumerated() {
            if let members = entry["group"] as? [[String: Any]] {
                let item = NSExtensionItem()
                item.attachments = members.enumerated().compactMap { position, member in
                    if let path = member["image"] as? String {
                        guard let image = UIImage(contentsOfFile: path) else { problems.append((path as NSString).lastPathComponent); return nil }
                        return NSItemProvider(object: image)
                    }
                    guard let path = member["file"] as? String, let file = copy(path, "\(index)-\(position)") else { return nil }
                    return NSItemProvider(contentsOf: file)
                }
                items.append(item)
            } else if let text = entry["text"] as? String {
                items.append(text)
            } else if let text = entry["repeat"] as? String, let count = entry["count"] as? Int {
                items.append(String(repeating: text, count: max(0, count)))
            } else if let address = entry["url"] as? String, let url = URL(string: address) {
                items.append(url)
            } else if let path = entry["image"] as? String {
                if let image = UIImage(contentsOfFile: path) { items.append(image) } else { problems.append((path as NSString).lastPathComponent) }
            } else if let path = entry["file"] as? String {
                if let file = copy(path, "\(index)") { items.append(file) }
            }
        }
        return (items, problems)
    }
}

struct ProbeView: View {
    @State private var loaded = ProbeItems.load()
    @State private var result = "idle"

    var body: some View {
        VStack(spacing: 20) {
            Text("Share Probe").font(.title2.weight(.semibold))
            Text("\(loaded.items.count) item(s)").accessibilityIdentifier("probe.count")
            if !loaded.problems.isEmpty {
                Text("Missing: " + loaded.problems.joined(separator: ", ")).foregroundStyle(.red)
                    .accessibilityIdentifier("probe.problems")
            }
            Button("Share") { share() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("probe.share")
            Text(result).accessibilityIdentifier("probe.result")
        }
        .padding()
    }

    private func share() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        result = "sharing"
        let sheet = UIActivityViewController(activityItems: loaded.items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { activity, completed, _, _ in
            result = completed ? "completed" : (activity == nil ? "dismissed" : "cancelled")
        }
        root.present(sheet, animated: true)
    }
}
