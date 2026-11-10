// [terminal] The Terminal page's wire (TerminalWire), its connection's loop (TerminalConnection, over a stand-in socket)
// and what the page makes of the add-on's status.

import CoreText
import Foundation
import Testing
import UIKit
@testable import HermesHQNative

@Suite("Terminal wire")
struct TerminalWireTests {
    @Test func socketURL() throws {
        let base = try #require(URL(string: "https://me:secret@hq.example.test:8443/hermes#top"))
        let query = TerminalWire.query(session: String(repeating: "a", count: 32), cols: 80, rows: 24, since: 512)
            + [URLQueryItem(name: "ticket", value: "stale"), URLQueryItem(name: "token", value: "x")]
        let url = try #require(TerminalWire.socketURL(base: base, query: query, ticket: "fresh"))
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "wss")
        #expect(parts.host == "hq.example.test" && parts.port == 8443)
        #expect(parts.path == "/hermes/api/plugins/hermes-hq-push/terminal")
        #expect(parts.user == nil && parts.password == nil && parts.fragment == nil)
        let items = parts.queryItems ?? []
        #expect(items.filter { $0.name == "ticket" }.map(\.value) == ["fresh"], "only the fresh ticket")
        #expect(!items.contains { $0.name == "token" })
        #expect(items.first { $0.name == "since" }?.value == "512")
        #expect(TerminalWire.socketURL(base: URL(string: "http://127.0.0.1:9119/")!, query: [], ticket: "t")?.absoluteString
                == "ws://127.0.0.1:9119/api/plugins/hermes-hq-push/terminal?ticket=t")
        #expect(TerminalWire.socketURL(base: URL(string: "file:///tmp")!, query: [], ticket: "t") == nil)
    }

    @Test func sessionNames() {
        let name = TerminalWire.newSession()
        #expect(TerminalWire.isSession(name))
        #expect(name != TerminalWire.newSession())
        #expect(!TerminalWire.isSession(name.uppercased()))
        #expect(!TerminalWire.isSession(String(name.dropLast())))
        #expect(!TerminalWire.isSession(String(repeating: "g", count: 32)))
    }

    @Test func textFrames() {
        #expect(TerminalWire.parse(#"{"type":"ready","session":"x","offset":4096,"shell":"zsh","resumed":true}"#)
                == .ready(offset: 4096, shell: "zsh", resumed: true))
        #expect(TerminalWire.parse(#"{"type":"exit","code":130}"#) == .exit(code: 130))
        #expect(TerminalWire.parse(#"{"type":"exit","code":null}"#) == .exit(code: nil))
        #expect(TerminalWire.parse(#"{"type":"ping"}"#) == .ping)
        #expect(TerminalWire.parse(#"{"type":"pong"}"#) == .pong)
        #expect(TerminalWire.parse("not json") == .other)
        #expect(TerminalWire.parse(#"{"type":"later"}"#) == .other)
        let resize = try? JSONSerialization.jsonObject(with: Data(TerminalWire.resize(cols: 120, rows: 40).utf8)) as? [String: Any]
        #expect(resize?["type"] as? String == "resize" && resize?["cols"] as? Int == 120 && resize?["rows"] as? Int == 40)
    }

    @Test func endings() {
        #expect(TerminalWire.ending(code: nil, reason: nil) == .retry)
        #expect(TerminalWire.ending(code: 1006, reason: nil) == .retry)
        #expect(TerminalWire.ending(code: 1000, reason: "The shell ended") == .ended)
        #expect(TerminalWire.ending(code: 4409, reason: nil) == .replaced)
        #expect(TerminalWire.ending(code: 4403, reason: nil) == .off)
        #expect(TerminalWire.ending(code: 4501, reason: nil) == .unsupported)
        #expect(TerminalWire.ending(code: 4429, reason: nil) == .full)
        #expect(TerminalWire.ending(code: 4500, reason: "The shell could not start (OSError)") == .refused("The shell could not start (OSError)"))
        #expect(TerminalWire.ending(code: 4400, reason: "") == .refused("The computer refused the terminal."))
        // 2026-11-02 Alex's iPhone: the Hermes HQ edge answered every dial 404 and the page spun for good.
        #expect(TerminalWire.ending(code: nil, reason: nil, refused: 404) == .blocked)
        #expect(TerminalWire.ending(code: nil, reason: nil, refused: 503) == .retry, "an edge waiting for Hermes: dial again")
        #expect(TerminalWire.ending(code: nil, reason: nil, refused: 403) == .retry)
        #expect(TerminalWire.ending(code: 4409, reason: nil, refused: nil) == .replaced)
    }

    @Test func logLineLeavesTheReasonOut() {
        let failed = TerminalWire.ending(code: 4500, reason: "The shell could not start (secret path)")
        #expect(TerminalConnection.describe(code: 4500, refused: nil, ending: failed) == "close 4500 → refused")
        #expect(TerminalConnection.describe(code: nil, refused: 404, ending: .blocked) == "HTTP 404 → blocked")
        #expect(TerminalConnection.describe(code: nil, refused: nil, ending: .retry) == "no close frame → retry")
    }

    @MainActor @Test func addOnStatus() {
        typealias Page = TerminalViewController
        #expect(Page.addOn(status: 200, body: ["terminal": true, "terminalOff": false]) == .ready)
        #expect(Page.addOn(status: 200, body: ["terminal": true, "terminalOff": true]) == .off)
        #expect(Page.addOn(status: 200, body: ["terminal": false]) == .unsupported)
        #expect(Page.addOn(status: 200, body: ["pluginVersion": "0.9.24"]) == .needsUpdate, "0.9.24 has no terminal key")
        #expect(Page.addOn(status: 404, body: nil) == .needsUpdate)
        #expect(Page.addOn(status: 0, body: nil) == .unknown, "no answer: the socket says itself")
        #expect(Page.addOn(status: 502, body: nil) == .unknown)
    }
}

/// A socket the test drives: frames delivered by hand, a drop with or without a close code.
nonisolated final class FakeTerminalSocket: TerminalSocketing, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<TerminalFrame, Error>] = []
    private var waiter: CheckedContinuation<TerminalFrame, Error>?
    private var _sent: [TerminalFrame] = []
    private var _closed = false
    private var code: Int?
    private var reason: String?
    private var status: Int?

    var sent: [TerminalFrame] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { _closed } }
    var closeCode: Int? { lock.withLock { code } }
    var closeReason: String? { lock.withLock { reason } }
    var refusedStatus: Int? { lock.withLock { status } }

    func receive() async throws -> TerminalFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            } else if _closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func deliver(_ frame: TerminalFrame) { push(.success(frame)) }
    func ready(offset: Int, shell: String = "zsh") {
        deliver(.text(#"{"type":"ready","session":"s","offset":\#(offset),"shell":"\#(shell)","resumed":false}"#))
    }

    /// The link drops: with `code`, as if the computer sent a close frame first.
    func drop(code: Int? = nil, reason: String? = nil) {
        lock.withLock { self.code = code; self.reason = reason }
        push(.failure(URLError(.networkConnectionLost)))
    }

    /// The upgrade is answered `status` instead of becoming a socket (as URLSession reports it: a bad response).
    func refuse(status: Int) {
        lock.withLock { self.status = status }
        push(.failure(URLError(.badServerResponse)))
    }

    private func push(_ next: Result<TerminalFrame, Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: next)
        } else {
            inbox.append(next)
            lock.unlock()
        }
    }

    func send(_ frame: TerminalFrame) { lock.withLock { _sent.append(frame) } }

    func close() {
        lock.lock()
        _closed = true
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: URLError(.cancelled))
    }
}

@MainActor @Suite("Terminal connection", .serialized)
final class TerminalConnectionTests {
    var sockets: [FakeTerminalSocket] = []
    var queries: [[URLQueryItem]] = []
    var phases: [TerminalConnection.Phase] = []
    var output = Data()
    var resets = 0

    /// Quick retries here (each test sets it: one of them makes it long).
    init() {
        TerminalConnection.backoff = { _ in .milliseconds(20) }
        TerminalConnection.giveUpAfter = 8
    }

    func make() -> TerminalConnection {
        let connection = TerminalConnection(session: String(repeating: "b", count: 32)) { [unowned self] query in
            queries.append(query)
            let socket = FakeTerminalSocket()
            sockets.append(socket)
            return socket
        }
        connection.onPhase = { [unowned self] in phases.append($0) }
        connection.onOutput = { [unowned self] in output.append($0) }
        connection.onReset = { [unowned self] in resets += 1 }
        return connection
    }

    func until(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), "\(what)")
    }

    func since(_ index: Int) -> String? { queries[index].first { $0.name == "since" }?.value }

    @Test func typedBeforeReadyWaitsThenGoesInOrder() async {
        let connection = make()
        connection.start(cols: 100, rows: 30)
        await until("dialled") { sockets.count == 1 }
        #expect(since(0) == "0")
        #expect(queries[0].first { $0.name == "cols" }?.value == "100")
        connection.send(Data("ls".utf8))
        connection.send(Data("\r".utf8))
        #expect(sockets[0].sent.isEmpty, "nothing goes before the computer says ready")
        sockets[0].ready(offset: 0)
        await until("live") { connection.phase == .live }
        #expect(sockets[0].sent == [.binary(Data("ls\r".utf8))], "what waited goes as one, in order; the size was in the URL")
        connection.send(Data("x".utf8))
        #expect(sockets[0].sent.last == .binary(Data("x".utf8)))
        #expect(connection.shell == "zsh")
        connection.stop()
    }

    @Test func outputCountsAndResize() async {
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        sockets[0].deliver(.binary(Data("hello ".utf8)))
        sockets[0].deliver(.binary(Data("world".utf8)))
        await until("shown") { connection.shown == 11 }
        #expect(String(decoding: output, as: UTF8.self) == "hello world")
        connection.resize(cols: 80, rows: 24)
        #expect(!sockets[0].sent.contains { if case .text = $0 { true } else { false } }, "the same size isn't sent again")
        connection.resize(cols: 120, rows: 40)
        #expect(sockets[0].sent.last == .text(TerminalWire.resize(cols: 120, rows: 40)))
        connection.stop()
    }

    @Test func dropDialsAgainForWhatWasMissed() async {
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        sockets[0].deliver(.binary(Data(repeating: 65, count: 300)))
        await until("shown") { connection.shown == 300 }
        sockets[0].drop()
        await until("reconnecting") { phases.contains(.reconnecting) }
        connection.send(Data("typed while away".utf8))
        await until("dialled again") { sockets.count == 2 }
        #expect(since(1) == "300", "asks only for what this page hasn't shown")
        sockets[1].ready(offset: 300)
        await until("live again") { connection.phase == .live }
        #expect(resets == 0, "picking up where it was: the screen stays")
        #expect(sockets[1].sent.first == .binary(Data("typed while away".utf8)))

        // The computer kept less than was missed: it starts from the top of what it has, so the page clears first.
        sockets[1].drop()
        await until("dialled a third time") { sockets.count == 3 }
        sockets[2].ready(offset: 4096)
        await until("live a third time") { connection.phase == .live && connection.shown == 4096 }
        #expect(resets == 1)
        connection.stop()
    }

    @Test func shellEnds() async {
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        await until("live") { connection.phase == .live }
        connection.endShell()
        #expect(sockets[0].sent.last == .text(TerminalWire.end))
        sockets[0].deliver(.text(#"{"type":"exit","code":0}"#))
        sockets[0].drop(code: 1000, reason: "The shell ended")
        await until("ended") { connection.phase == .ended(code: 0) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 1, "an ended shell isn't dialled again")
        connection.send(Data("x".utf8))
        #expect(sockets[0].sent.last == .text(TerminalWire.end), "nothing is sent to an ended shell")
    }

    @Test func openedElsewhereStops() async {
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        sockets[0].drop(code: 4409, reason: "Opened again")
        await until("stopped") { connection.phase == .stopped(.replaced) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 1, "no fight over the shell: not dialled again")
    }

    @Test func turnedOffAndFull() async {
        for (code, ending) in [(4403, TerminalWire.Ending.off), (4429, .full), (4501, .unsupported)] {
            sockets = []
            let connection = make()
            connection.start(cols: 80, rows: 24)
            await until("dialled") { sockets.count == 1 }
            sockets[0].drop(code: code)
            await until("stopped \(code)") { connection.phase == .stopped(ending) }
        }
    }

    @Test func relayRefusalStops() async {
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].refuse(status: 404)
        await until("stopped") { connection.phase == .stopped(.blocked) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 1, "a relay that turns the Terminal away isn't dialled again")
    }

    @Test func firstDialGivesUpButALiveShellKeepsTrying() async {
        TerminalConnection.giveUpAfter = 3
        let connection = make()
        connection.start(cols: 80, rows: 24)
        for index in 0..<3 {
            await until("dial \(index + 1)") { sockets.count == index + 1 }
            #expect(connection.phase == .connecting, "still opening")
            sockets[index].refuse(status: 503)
        }
        await until("gave up") { connection.phase == .stopped(.unreachable) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sockets.count == 3)

        sockets = []
        let live = make()
        live.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        await until("live") { live.phase == .live }
        for index in 0..<4 {
            await until("socket \(index + 1)") { sockets.count == index + 1 }
            sockets[index].drop()
        }
        await until("still dialling after more drops than a first open gets") { sockets.count == 5 }
        #expect(live.phase == .reconnecting, "the shell is still on the computer: keep dialling")
        live.stop()
    }

    @Test func comingBackDialsAtOnce() async {
        TerminalConnection.backoff = { _ in .seconds(30) }
        let connection = make()
        connection.start(cols: 80, rows: 24)
        await until("dialled") { sockets.count == 1 }
        sockets[0].ready(offset: 0)
        await until("live") { connection.phase == .live }
        connection.cameBack(after: .seconds(2))
        #expect(!sockets[0].isClosed, "a short trip away leaves the socket alone")
        connection.cameBack(after: .seconds(60))
        #expect(sockets[0].isClosed, "a socket iOS may have left hanging is closed")
        await until("dialled again without the 30 s wait") { sockets.count == 2 }
        connection.stop()
        #expect(sockets[1].isClosed, "leaving the page closes the socket")
    }
}

@MainActor @Suite("Terminal view")
struct TerminalViewTests {
    /// The text area is the panel's dark grey, before and after output. Setting the scroll view's `backgroundColor`
    /// cleared the layer colour and made it opaque, so the empty cells drew black.
    @Test func drawsOnThePanelColour() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let view = HQTerminalView(frame: window.bounds, font: TerminalSettings.font())
        view.style()
        window.addSubview(view)
        window.isHidden = false
        func sample() throws -> [UInt8] {
            view.setNeedsDisplay()
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
            // A point in the empty area under the first lines.
            let spot = try #require(image.cgImage?.cropping(to: CGRect(x: 300 * image.scale, y: 500 * image.scale, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(spot, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return pixel
        }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        TerminalViewController.background.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let panel = [red, green, blue].map { Int(($0 * 255).rounded()) }
        func matches(_ pixel: [UInt8]) -> Bool { zip(pixel.prefix(3), panel).allSatisfy { abs(Int($0) - $1) <= 3 } && pixel[3] == 255 }
        #expect(!view.isOpaque)
        #expect(HQTerminalView.palette.count == 16, "SwiftTerm ignores a palette that isn't 16 colours")
        let before = try sample()
        #expect(matches(before), "before output: \(before), panel \(panel)")
        view.feed(text: "hello\r\n")
        RunLoop.main.run(until: .now + 0.2)
        let after = try sample()
        #expect(matches(after), "after output: \(after), panel \(panel)")
    }
}

/// A tester (2026-11-04): the arrow pad and the tabs' saved shells.
@Suite("Terminal arrows and tabs")
@MainActor struct TerminalTabsTests {
    @Test func arrowPadIsALaptopsArrows() {
        let pad = CGRect(x: 0, y: 0, width: TerminalArrowPad.width, height: 44)
        func at(_ x: CGFloat, _ y: CGFloat) -> TerminalArrowPad.Direction { TerminalArrowPad.direction(at: CGPoint(x: x, y: y), in: pad) }
        #expect(at(4, 22) == .left)
        #expect(at(pad.width - 4, 22) == .right)
        #expect(at(pad.midX, 6) == .up)
        #expect(at(pad.midX, 38) == .down)
        // ← and → are whole keys: their tops and feet are theirs, not ↑'s or ↓'s.
        #expect(at(20, 2) == .left)
        #expect(at(pad.width - 20, 42) == .right)
        let host = TerminalArrowPad { _ in }
        host.frame = pad
        for direction in TerminalArrowPad.Direction.allCases {
            // The middle of each key drawn, and of each zone VoiceOver and UI tests tap, is that arrow.
            let face = TerminalArrowPad.face(direction, in: pad)
            #expect(at(face.midX, face.midY) == direction, "\(direction) face")
            let zone = host.zone(direction)
            #expect(at(zone.midX, zone.midY) == direction, "\(direction) zone")
            #expect(zone.contains(CGPoint(x: face.midX, y: face.midY)), "\(direction) is touched where it is drawn")
        }
        // ↑ and ↓ are one key's height together, as a laptop's are.
        let up = TerminalArrowPad.face(.up, in: pad), down = TerminalArrowPad.face(.down, in: pad)
        #expect(down.maxY - up.minY == TerminalKeyBar.capHeight)
        #expect(TerminalArrowPad.face(.left, in: pad).height == TerminalKeyBar.capHeight)
    }

    @Test func oneSavedShellBecomesTheFirstTab() {
        let account = "test-tabs-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            for key in ["hq.terminal.session.", "hq.terminal.sessions.", "hq.terminal.tab."] { defaults.removeObject(forKey: key + account) }
        }
        let old = TerminalWire.newSession()
        defaults.set(old, forKey: "hq.terminal.session." + account)
        #expect(TerminalSettings.sessions(account) == [old])
        #expect(defaults.string(forKey: "hq.terminal.session." + account) == nil)

        let second = TerminalWire.newSession()
        TerminalSettings.setSessions([old, second, "not-a-session"], account: account)
        #expect(TerminalSettings.sessions(account) == [old, second])
        TerminalSettings.setSessions((0..<12).map { _ in TerminalWire.newSession() }, account: account)
        #expect(TerminalSettings.sessions(account).count == TerminalSettings.maxTabs)
    }
}

/// A tester again (2026-11-05): named and moved tabs, a font choice, backspace, the keyboard only when asked for.
@Suite("Terminal: a tester's second list")
@MainActor struct TerminalTesterListTests {
    @Test func tabNamesKeepTheirPlaces() {
        let account = "test-names-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "hq.terminal.names." + account) }
        #expect(TerminalSettings.tabNames(account).isEmpty)
        TerminalSettings.setTabNames(["", "build", ""], account: account)
        #expect(TerminalSettings.tabNames(account) == ["", "build", ""])
        TerminalSettings.setTabNames(["", ""], account: account)
        #expect(UserDefaults.standard.object(forKey: "hq.terminal.names." + account) == nil, "no names, nothing kept")
        TerminalSettings.setTabNames((0..<12).map(String.init), account: account)
        #expect(TerminalSettings.tabNames(account).count == TerminalSettings.maxTabs)
    }

    @Test func everyFaceLoads() {
        for face in TerminalSettings.Face.allCases {
            let regular = TerminalSettings.font(size: 13, face: face)
            let bold = TerminalSettings.font(size: 13, face: face, bold: true)
            if let names = face.names {
                #expect(regular.fontName == names.regular, "\(face) regular: \(regular.fontName)")
                #expect(bold.fontName == names.bold, "\(face) bold: \(bold.fontName)")
            }
            #expect(regular.pointSize == 13)
        }
        // Hack's Powerline arrow and a Nerd Font icon are in the font itself, not drawn from a fallback.
        let hack = TerminalSettings.font(size: 13, face: .hack) as CTFont
        for scalar: UInt16 in [0xE0B0, 0xF418] {
            var glyph: CGGlyph = 0
            var character = scalar
            #expect(CTFontGetGlyphsForCharacters(hack, &character, &glyph, 1), "U+\(String(scalar, radix: 16, uppercase: true)) in Hack")
        }
    }

    /// The keyboard's delete key always reaches the shell, held too: SwiftTerm's own copy of the line is empty after ↑,
    /// and iOS stopped repeating once it read nothing before the caret (logged 2026-11-05: `position(from: 0, offset:
    /// -1)` → 0, then one deleteBackward). It now reads a space there.
    @Test func deleteAlwaysHasSomethingToDelete() throws {
        let view = HQTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), font: TerminalSettings.font())
        #expect(view.hasText)
        let caret = try #require(view.selectedTextRange?.start)
        func text(_ from: UITextPosition?, _ to: UITextPosition) -> String? {
            from.flatMap { view.textRange(from: $0, to: to) }.flatMap { view.text(in: $0) }
        }
        #expect(view.offset(from: view.beginningOfDocument, to: caret) == 1)
        #expect(text(view.position(from: caret, offset: -1), caret) == " ")
        #expect(text(view.beginningOfDocument, view.endOfDocument) == " ")
        let far = try #require(view.position(from: caret, offset: -50))
        #expect(view.offset(from: far, to: caret) == 1, "no further back than the one space")
        // Typed text follows the space.
        view.insertText("ls")
        let end = view.endOfDocument
        #expect(text(view.beginningOfDocument, end) == " ls")
        #expect(text(view.position(from: end, offset: -1), end) == "s")
    }

    /// Without the keyboard the screen keeps an empty input view (typing focus stays, nothing slides up); asked for,
    /// the keyboard and its key bar come back.
    @Test func keyboardOnlyWhenAskedFor() {
        let view = HQTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), font: TerminalSettings.font())
        let bar = UIView()
        view.keyBar = bar
        view.applyKeyboard()
        #expect(view.inputView == nil && view.inputAccessoryView === bar)
        view.showsKeyboard = false
        #expect(view.inputView != nil && view.inputView?.bounds.height == 0)
        #expect(view.inputAccessoryView == nil)
        #expect(view.keyboardDismissMode == .none)
        view.showsKeyboard = true
        #expect(view.inputView == nil && view.inputAccessoryView === bar)
        #expect(view.keyboardDismissMode == .interactive)
    }
}
