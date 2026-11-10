// What the photo-heads UI tests stand on (docs/spec/3x-photoheads.md §10–11): the stand-in gateway as the tests see
// it (scripts/e2e-photoheads.sh starts it and passes the credentials files), and a reader for screenshots. A face is
// not an accessibility element (it is decoration next to the bot's name), so the tests tell a photo from a head by
// its pixels: every fixture picture is drawn in flat, known colours.

import XCTest

struct PhotoFixture {
    let url: String
    let username: String
    let password: String

    /// "127.0.0.1:9950": how gateway rows and menus name this fixture.
    var hostPort: String {
        guard let parsed = URL(string: url), let host = parsed.host() else { return url }
        return parsed.port.map { "\(host):\($0)" } ?? host
    }

    static func load(_ variable: String) throws -> PhotoFixture {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("Run scripts/e2e-photoheads.sh <simulator> (it starts the photoheads fixtures and sets \(variable)).")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let url = object["url"] as? String else {
            throw XCTSkip("Unreadable credentials file")
        }
        return PhotoFixture(url: url, username: object["username"] as? String ?? "", password: object["password"] as? String ?? "")
    }

    /// A control (`/__photoheads/…` or `/__settings/…`, loopback, no auth). Blocks for at most 10 s.
    @discardableResult
    func control(_ path: String, _ body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url + path)!, timeoutInterval: 10)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 12)
        if let error = box.error { throw error }
        guard let status = box.status, (200..<300).contains(status) else {
            throw NSError(domain: "fixture", code: box.status ?? -1, userInfo: [NSLocalizedDescriptionKey: "\(path) answered \(box.status ?? -1)"])
        }
        return (box.data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    func reset() throws { try control("/__photoheads/reset", [:]) }
    func state() -> [String: Any] { (try? control("/__photoheads/state")) ?? [:] }

    /// One bot's line of the state: has_avatar, avatar_png, avatar_sha, image_kind, revisions, get_asset_calls, set_asset_calls.
    func bot(_ name: String) -> [String: Any] { ((state()["bots"] as? [String: Any])?[name] as? [String: Any]) ?? [:] }
    func botsMeta(_ name: String) -> [String: Any] { ((bot(name)["ui_meta"] as? [String: Any])?["hermes-bots"] as? [String: Any]) ?? [:] }

    /// Every asset call so far, oldest first (method, name, keys, outcome; an upload's png size and hash).
    func calls(_ method: String? = nil, _ name: String? = nil) -> [[String: Any]] {
        ((state()["calls"] as? [[String: Any]]) ?? []).filter {
            (method == nil || $0["method"] as? String == method) && (name == nil || $0["name"] as? String == name)
        }
    }

    func gets(_ name: String? = nil) -> Int { calls("profiles.get_asset", name).count }
    func sets(_ name: String? = nil) -> Int { calls("profiles.set_asset", name).count }

    /// The gateway's write log, oldest first: (method, params).
    func writes() -> [(method: String, params: [String: Any])] {
        ((state()["writes"] as? [[String: Any]]) ?? []).map { (($0["method"] as? String) ?? "", ($0["params"] as? [String: Any]) ?? [:]) }
    }

    /// How often one RPC method was called.
    func count(_ method: String) -> Int { ((state()["methods"] as? [String: Any])?[method] as? Int) ?? 0 }
    /// Messages the app has sent to a bot (`prompt.submit` answers on the socket, outside the method counts).
    func prompts() -> Int { (state()["prompts"] as? Int) ?? 0 }

    private final class Box: @unchecked Sendable {
        var data: Data?
        var status: Int?
        var error: Error?
    }
}

struct RGB: Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    var description: String { "(\(r), \(g), \(b))" }
    var chroma: Int { max(r, g, b) - min(r, g, b) }
    var luminance: Double { (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255 }
    func near(_ other: RGB, _ tolerance: Int) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    // The fixture's pictures (scripts/fixtures/photoheads-gateway.py).
    static let photoA = RGB(232, 93, 58)          // ivy on gateway A: a warm field
    static let photoABeta = RGB(34, 160, 92)      // ivy on the Beta gateway: a green field
    static let photoB = RGB(48, 96, 220)          // "another device" picture: a blue field
    static let webp = RGB(32, 167, 160)           // the WebP: a teal field
    static let pet = RGB(238, 130, 170)           // the 96 × 104 picture: a pink field
    static let mirror = RGB(120, 122, 132)        // a saved head's 288 px copy as the fixture seeds it (never shown)
    static let backfill = RGB(28, 110, 116)       // desktop's own 160 px copy (never shown)
    static let broken = RGB(60, 180, 90)          // the cut PNG (never shown)
    // The pictures a test picks (scripts/fixtures/make-photoheads-media.swift): four quarters.
    static let red = RGB(230, 41, 41), green = RGB(41, 179, 69), blue = RGB(41, 69, 219), yellow = RGB(240, 209, 41)

    enum Hue { case red, green, blue, yellow, other }
    /// Which of the four quarter colours this is nearest to, by its strongest channels (a muted, speckled quarter too).
    var hue: Hue {
        if r > b + 40, g > b + 40, abs(r - g) < 70 { return .yellow }
        if r > g + 40, r > b + 40 { return .red }
        if g > r + 30, g > b + 30 { return .green }
        if b > r + 40, b > g + 30 { return .blue }
        return .other
    }
}

/// A screenshot's pixels in sRGB, addressed in points from its top-left corner.
final class Pixels {
    let width: Int, height: Int
    let scale: CGFloat
    private let data: [UInt8]

    init?(_ image: CGImage, points: CGSize) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, points.width > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width; self.height = height
        data = bytes
        scale = CGFloat(width) / points.width
    }

    /// The element as it is on screen now.
    @MainActor convenience init?(_ element: XCUIElement) {
        let size = element.frame.size
        guard let image = element.screenshot().image.cgImage else { return nil }
        self.init(image, points: size)
    }

    @inline(__always) private func pixel(_ x: Int, _ y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    private func bounds(_ rect: CGRect?) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        guard let rect else { return (0, 0, width, height) }
        let x0 = max(0, Int((rect.minX * scale).rounded(.down))), y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.up))), y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
        return (x0, y0, max(x0, x1), max(y0, y1))
    }

    func colour(at point: CGPoint) -> RGB {
        pixel(min(width - 1, max(0, Int(point.x * scale))), min(height - 1, max(0, Int(point.y * scale))))
    }

    /// The mean colour of a rectangle (points).
    func average(in rect: CGRect) -> RGB {
        let b = bounds(rect)
        var r = 0, g = 0, bl = 0, n = 0
        for y in b.y0..<b.y1 { for x in b.x0..<b.x1 { let p = pixel(x, y); r += p.r; g += p.g; bl += p.b; n += 1 } }
        guard n > 0 else { return RGB(0, 0, 0) }
        return RGB(r / n, g / n, bl / n)
    }

    /// The longest unbroken horizontal stretch of `target`, in points: a flat field of a picture is long, text is not.
    func longestRun(of target: RGB, tolerance: Int = 26, in rect: CGRect? = nil) -> CGFloat {
        let b = bounds(rect)
        var best = 0
        for y in b.y0..<b.y1 {
            var run = 0
            for x in b.x0..<b.x1 {
                if pixel(x, y).near(target, tolerance) { run += 1; best = max(best, run) } else { run = 0 }
            }
        }
        return CGFloat(best) / scale
    }

    /// The box (points) around every horizontal stretch at least `minRun` points long whose pixels all pass `test`.
    func box(minRun: CGFloat, in rect: CGRect? = nil, where test: (RGB) -> Bool) -> CGRect? {
        let b = bounds(rect)
        let need = max(1, Int(minRun * scale))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in b.y0..<b.y1 {
            var start = -1
            for x in b.x0...b.x1 {
                let passes = x < b.x1 && test(pixel(x, y))
                if passes {
                    if start < 0 { start = x }
                } else if start >= 0 {
                    if x - start >= need {
                        minX = min(minX, start); maxX = max(maxX, x - 1); minY = min(minY, y); maxY = max(maxY, y)
                    }
                    start = -1
                }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    /// The box around a flat field of one colour (and anything else of that colour on its rows).
    func box(of target: RGB, tolerance: Int = 26, minRun: CGFloat = 6, in rect: CGRect? = nil) -> CGRect? {
        box(minRun: minRun, in: rect) { $0.near(target, tolerance) }
    }

    /// The box around everything strongly coloured (a face in a row of grey text), read in 2 pt blocks so a speckled
    /// photo counts as its colours: at least three such blocks side by side.
    func colourfulBox(in rect: CGRect? = nil) -> CGRect? {
        let b = bounds(rect)
        let block = max(2, Int((2 * scale).rounded()))
        let columns = (b.x1 - b.x0) / block, rows = (b.y1 - b.y0) / block
        guard columns > 0, rows > 0 else { return nil }
        var minC = Int.max, minR = Int.max, maxC = -1, maxR = -1
        for row in 0..<rows {
            var start = -1
            for column in 0...columns {
                var colourful = false
                if column < columns {
                    var r = 0, g = 0, bl = 0
                    for y in 0..<block { for x in 0..<block {
                        let p = pixel(b.x0 + column * block + x, b.y0 + row * block + y)
                        r += p.r; g += p.g; bl += p.b
                    } }
                    let n = block * block
                    colourful = RGB(r / n, g / n, bl / n).chroma >= 45
                }
                if colourful {
                    if start < 0 { start = column }
                } else if start >= 0 {
                    if column - start >= 3 { minC = min(minC, start); maxC = max(maxC, column - 1); minR = min(minR, row); maxR = max(maxR, row) }
                    start = -1
                }
            }
        }
        guard maxC >= 0 else { return nil }
        return CGRect(x: CGFloat(b.x0 + minC * block) / scale, y: CGFloat(b.y0 + minR * block) / scale,
                      width: CGFloat((maxC - minC + 1) * block) / scale, height: CGFloat((maxR - minR + 1) * block) / scale)
    }

    /// The four quarters of `rect` (top-left, top-right, bottom-left, bottom-right), each read off its middle.
    func quarters(of rect: CGRect) -> [RGB.Hue] {
        let w = rect.width * 0.16, h = rect.height * 0.16
        return [(0.22, 0.22), (0.78, 0.22), (0.22, 0.78), (0.78, 0.78)].map { fx, fy in
            average(in: CGRect(x: rect.minX + rect.width * fx - w / 2, y: rect.minY + rect.height * fy - h / 2, width: w, height: h)).hue
        }
    }

    static let uprightQuarters: [RGB.Hue] = [.red, .green, .blue, .yellow]
}

/// JSON-ish equality for fixture dictionaries.
func equal(_ a: Any?, _ b: Any?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return (a as AnyObject).isEqual(b)
}

/// The app's own folders, read from the test runner (the simulator shares one disk): where the bots' photos are kept.
enum AppFiles {
    /// Whether the run tests the original record's build (scripts/e2e-photoheads.sh with HQ_IDENTITY=original).
    static var isOriginal: Bool { ProcessInfo.processInfo.environment["HQN_IDENTITY"] == "original" }

    /// The data container of the app under test: the identity this run builds first, the other one when a simulator
    /// only has that.
    static func container() -> URL? {
        // The runner's home is …/data/Containers/Data/Application/<runner id>; the app's container is a sibling.
        let containers = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let native = "com.charlesmcdowell.hermeshq.native", original = "com.charlesmcdowell.dispatch"
        let ids = isOriginal ? [original, native] : [native, original]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) else { return nil }
        var found: [String: URL] = [:]
        for entry in entries {
            let meta = entry.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let plist = NSDictionary(contentsOf: meta), let id = plist["MCMMetadataIdentifier"] as? String, ids.contains(id) else { continue }
            found[id] = entry
        }
        return ids.compactMap { found[$0] }.first
    }

    /// `…/Library/Application Support/lists` of the app under test, nil when it has none yet.
    static func listsFolder() -> URL? {
        guard let lists = container()?.appendingPathComponent("Library/Application Support/lists"),
              FileManager.default.fileExists(atPath: lists.path) else { return nil }
        return lists
    }

    /// `tmp/bot-photo-picks` of the app under test: where a pick keeps the file it reads (it may not exist yet).
    static func picksFolder() -> URL? { container()?.appendingPathComponent("tmp/bot-photo-picks") }

    /// What a pick left behind: the names in the picks folder, and in the folder iOS puts a Files copy in.
    static func pickLeftovers() -> [String] {
        guard let container = container() else { return [] }
        let fm = FileManager.default
        var names = (try? fm.contentsOfDirectory(atPath: container.appendingPathComponent("tmp/bot-photo-picks").path)) ?? []
        for entry in (try? fm.contentsOfDirectory(atPath: container.appendingPathComponent("tmp").path)) ?? [] where entry.hasSuffix("-Inbox") {
            names += ((try? fm.contentsOfDirectory(atPath: container.appendingPathComponent("tmp/\(entry)").path)) ?? []).map { entry + "/" + $0 }
        }
        return names.sorted()
    }

    /// The `botphotos-…` folders (one per signed-in account).
    static func photoFolders() -> [URL] {
        guard let lists = listsFolder(), let entries = try? FileManager.default.contentsOfDirectory(at: lists, includingPropertiesForKeys: nil) else { return [] }
        return entries.filter { $0.lastPathComponent.hasPrefix("botphotos-") }.sorted { $0.path < $1.path }
    }

    /// Every file in one photo folder with its size in bytes.
    static func files(in folder: URL) -> [(name: String, bytes: Int)] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []).map {
            ($0.lastPathComponent, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// A PNG's width and height from its header.
    static func pngSize(_ url: URL) -> (Int, Int)? {
        guard let data = try? Data(contentsOf: url), data.count > 24, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        func be(_ at: Int) -> Int { data[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16), be(20))
    }
}
