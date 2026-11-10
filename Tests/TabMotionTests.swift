import Testing
import UIKit
@testable import HermesHQNative

/// [tabmotion] Every icon a tab can show has its tap motion (owner 2026-11-03, after the Tiles tab shipped still:
/// "The Tiles icon doesn't animate like the others. Never miss that again."). Each page Settings › Tabs offers
/// (`TabChoice.pageIDs`) and each fixed tab is tried as the system bar draws it (the filled symbol) and as the app's own
/// bars do (the outline: Desktop Look, the Mac's sidebar), regular and bold. A new tab page with no motion fails here.
@MainActor
struct TabMotionTests {
    /// The symbol each page shows as a tab: the More row's, as Settings › Tabs reads it.
    static func pageSymbols() -> [(id: String, symbol: String)] {
        TabChoice.pageIDs.map { id in (id, TabOrderPage.fallback(id).symbol ?? "") }
    }

    /// The fixed tabs' symbols (Bots and Kanban are drawn glyphs, Jobs its own art: each has its own motion).
    static let fixed: [(name: String, outline: String?)] = [("bubble.left.and.bubble.right", nil), ("ellipsis.circle", "ellipsis")]

    /// The motion `image` plays as a real system tab bar's item (the raster the bar draws, as on a phone), nil for none.
    static func barMotion(of image: UIImage, bold: Bool) -> TabMotion.Motion? {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let tabs = UITabBarController()
        tabs.traitOverrides.legibilityWeight = bold ? .bold : .regular
        tabs.viewControllers = (0..<4).map { index in
            let page = UIViewController()
            page.tabBarItem = index == 1 ? UITabBarItem(title: "Tab", image: image, tag: index)
                : UITabBarItem(title: "Other", image: UIImage(systemName: "circle"), tag: index)
            return page
        }
        window.rootViewController = tabs
        window.isHidden = false
        window.layoutIfNeeded()
        tabs.tabBar.layoutIfNeeded()
        // The bar draws its icons on the next pass.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let kind = TabMotion.kind(of: image) else { return nil }
        let icons = TabMotion.barIcons(in: tabs.tabBar, at: 1)
        guard !icons.isEmpty else { Issue.record("no icon view found in the bar"); return nil }
        return icons.lazy.compactMap { TabMotion.motion(kind, source: image, in: $0) }.first
    }

    /// The motion `image` plays in a tab-sized icon view on screen (the app's own bars), nil for none.
    static func motion(of image: UIImage, bold: Bool) -> TabMotion.Motion? {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.isHidden = false
        let holder = UIViewController()
        window.rootViewController = holder
        holder.traitOverrides.legibilityWeight = bold ? .bold : .regular
        let view = UIImageView(image: image)
        view.frame = CGRect(x: 80, y: 80, width: 30, height: 26)
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)
        holder.view.addSubview(view)
        holder.view.layoutIfNeeded()
        guard let kind = TabMotion.kind(of: image) else { return nil }
        return TabMotion.motion(kind, source: image, in: view)
    }

    /// How much of the icon moves at the motion's peak: the most pixels, over its frames, that differ from the first
    /// frame, as a share of the icon's box at rest. A motion too small to see on a phone (Tiles' first nudge: about a
    /// pixel) is as good as none.
    static func movement(_ motion: TabMotion.Motion) -> Double {
        func alpha(_ image: CGImage) -> [UInt8] {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height)
            bytes.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        guard let first = motion.frames.first else { return 0 }
        let width = first.width, height = first.height
        let rest = alpha(first).map { $0 > 128 }
        // The icon's box at rest: changes count against its area, so filled and outline icons count alike.
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for (index, ink) in rest.enumerated() where ink {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= minX, maxY >= minY else { return 0 }
        let area = (maxX - minX + 1) * (maxY - minY + 1)
        // A pixel or two of drift is not movement anyone sees: ink counts as moved only where none was within
        // `reach` at rest, and ink gone only where none is within `reach` now.
        let reach = max(1, Int((motion.scale * 0.7).rounded()))
        /// True wherever `map` is true within `reach` (a square round each pixel).
        func grown(_ map: [Bool]) -> [Bool] {
            var across = [Bool](repeating: false, count: map.count), out = across
            for y in 0..<height { for x in 0..<width {
                across[y * width + x] = (max(0, x - reach)...min(width - 1, x + reach)).contains { map[y * width + $0] }
            } }
            for y in 0..<height { for x in 0..<width {
                out[y * width + x] = (max(0, y - reach)...min(height - 1, y + reach)).contains { across[$0 * width + x] }
            } }
            return out
        }
        let near = grown(rest)
        var most = 0
        for frame in motion.frames.dropFirst() {
            let shown = alpha(frame).map { $0 > 128 }
            guard shown.count == rest.count else { continue }
            let around = grown(shown)
            var moved = 0
            for index in shown.indices where (shown[index] && !near[index]) || (rest[index] && !around[index]) { moved += 1 }
            most = max(most, moved)
        }
        return Double(most) / Double(area)
    }

    /// The least a tab's motion moves (`movement`). Tiles' first jiggle measured 0.04 to 0.06 and was missed by eye
    /// (owner 2026-11-03); Profiles' head dropping in, the quietest motion that reads, 0.07; most others 0.1 to 0.8.
    static let leastMovement = 0.07

    /// Motions that move one small part inside the icon (dots, a needle, a sun), seen and kept as they are: their part
    /// is too small for `movement` (Sessions' dots measure 0), so they only have to change at all. A new icon doesn't go here without being looked at on a phone.
    static let smallPart: Set<String> = ["artifacts", "bubble.left.and.bubble.right", "command-center", "ellipsis.circle",
                                         "kanban", "webhooks", "spawn-tree", "star-map"]

    /// Every fourth frame side by side, in the test's tmp folder (tabmotion-strips), to look at by eye.
    static func saveStrip(_ motion: TabMotion.Motion, name: String) {
        let picked = motion.frames.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        guard let first = picked.first else { return }
        let size = CGSize(width: first.width * picked.count, height: first.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            for (index, frame) in picked.enumerated() {
                UIImage(cgImage: frame).draw(at: CGPoint(x: index * first.width, y: 0))
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabmotion-strips")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? strip.pngData()?.write(to: folder.appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".png"))
        print("[tabmotion-strip] \(folder.path)")
    }

    @Test func everyTabPageHasASymbol() {
        for (id, symbol) in Self.pageSymbols() {
            #expect(UIImage(systemName: symbol) != nil, "\(id): \(symbol) is no SF Symbol")
        }
    }

    @Test(arguments: [false, true])
    func everyTabIconMoves(bold: Bool) {
        var tried: [(String, UIImage)] = []
        // Kanban is drawn, not a symbol, wherever it shows (`PagesTabs.tabImage`).
        tried.append(("kanban", TabIcons.kanban))
        if Self.barMotion(of: TabIcons.kanban, bold: bold) == nil { Issue.record("kanban (system tab bar): no tap motion") }
        for (id, symbol) in Self.pageSymbols() where id != "kanban" {
            guard let bar = TabIcons.barSymbol(PagesTabs.outlineSymbol(symbol)) else { Issue.record("\(id): no bar symbol for \(symbol)"); continue }
            tried.append(("\(id) (tab bar)", bar))
            if Self.barMotion(of: bar, bold: bold) == nil { Issue.record("\(id) (system tab bar): no tap motion\(bold ? " (Bold Text)" : "")") }
            // The app's own bars draw this one instead (`TabIcons.redrawn`), or the bar's symbol itself.
            tried.append(("\(id) (Desktop Look)", TabIcons.redrawn(bar, pointSize: 21) ?? bar))
        }
        for (name, outline) in Self.fixed {
            if let bar = TabIcons.barSymbol(name, outline: outline) {
                tried.append((name, bar))
                if Self.barMotion(of: bar, bold: bold) == nil { Issue.record("\(name) (system tab bar): no tap motion") }
                tried.append(("\(name) (Desktop Look)", TabIcons.redrawn(bar, pointSize: 21) ?? bar))
            }
        }
        for (label, image) in tried {
            let motion = Self.motion(of: image, bold: bold)
            #expect(motion != nil, "\(label): no tap motion\(bold ? " (Bold Text)" : "")")
            if let motion {
                #expect(motion.frames.count > 20, "\(label): \(motion.frames.count) frames")
                let moved = Self.movement(motion)
                Self.saveStrip(motion, name: "\(label)\(bold ? " bold" : "")")
                print("[tabmotion-test] \(label)\(bold ? " bold" : ""): moves \(String(format: "%.2f", moved))")
                if Self.smallPart.contains(label.components(separatedBy: " (").first ?? label) {
                    let first = motion.frames.first?.dataProvider?.data as Data?
                    #expect(motion.frames.contains { $0.dataProvider?.data as Data? != first }, "\(label): every frame the same")
                } else {
                    #expect(moved >= Self.leastMovement, "\(label): moves \(String(format: "%.2f", moved)) of its box at most, too little to see\(bold ? " (Bold Text)" : "")")
                }
            }
        }
    }
}
