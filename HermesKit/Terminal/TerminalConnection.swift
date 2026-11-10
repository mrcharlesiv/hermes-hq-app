// [terminal] One open Terminal page's link to its shell (docs/spec/terminal.md): dials the add-on's socket, shows what
// the shell prints, sends what is typed, and dials again when the link drops (the phone locked, the network changed),
// asking only for what the page missed (`since`). Keys typed while the link is down wait (up to 64 KB) and go once it
// is back. The page leaving closes the socket but not the shell: the computer keeps it 15 minutes for the page to come
// back to. Only `endShell()` ends it.

import Foundation

@MainActor final class TerminalConnection {
    enum Phase: Equatable, Sendable {
        /// The first dial (or the first after New Shell).
        case connecting
        case live
        /// The link dropped: dialling again; what is typed waits.
        case reconnecting
        /// The shell ended, with its exit code when the computer knew it.
        case ended(code: Int?)
        /// No more dialling: opened again elsewhere, turned off, unsupported, full or refused.
        case stopped(TerminalWire.Ending)
    }

    let session: String
    private(set) var phase: Phase = .connecting {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    /// The shell's name ("zsh"), once the computer has said.
    private(set) var shell = ""
    /// Bytes of this shell's output shown so far: where a new socket asks to start.
    private(set) var shown = 0
    /// Dials in a row that failed (0 once a socket is live).
    private(set) var failures = 0

    var onPhase: ((Phase) -> Void)?
    var onOutput: ((Data) -> Void)?
    /// What follows starts at the beginning of what the computer kept, not where the page is: clear the screen first.
    var onReset: (() -> Void)?

    typealias Dial = @MainActor ([URLQueryItem]) async throws -> any TerminalSocketing
    private let dial: Dial
    private var socket: (any TerminalSocketing)?
    private var runner: Task<Void, Never>?
    private var size = (cols: 80, rows: 24)
    private var sentSize = (cols: 0, rows: 0)
    private var waiting = Data()
    private var heard = ContinuousClock.now
    private var dialNow = false
    private var closed = false

    static let maxWaiting = 64 * 1024
    /// The add-on pings after 20 s of quiet; a socket silent this long is gone.
    static var quietLimit: Duration = .seconds(45)
    /// Failed dials before a page that never went live stops spinning (about 30 s with the waits below).
    static var giveUpAfter = 8
    /// Waits between failed dials: 0.5, 1, 2, 4, then 8 s.
    static var backoff: (Int) -> Duration = { failures in .milliseconds(500 * (1 << min(max(failures - 1, 0), 4))) }

    init(session: String, dial: @escaping Dial) {
        self.session = session
        self.dial = dial
    }

    /// Dials, once; later calls only update the size.
    func start(cols: Int, rows: Int) {
        resize(cols: cols, rows: rows)
        guard runner == nil, !closed else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    /// The page left: the socket closes, the shell stays on the computer.
    func stop() {
        closed = true
        runner?.cancel()
        runner = nil
        socket?.close()
        socket = nil
    }

    /// Keys, or a paste already encoded for the terminal.
    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        switch phase {
        case .live:
            if let socket { socket.send(.binary(data)) } else { hold(data) }
        case .connecting, .reconnecting:
            hold(data)
        case .ended, .stopped:
            break
        }
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        size = (cols, rows)
        sendSize()
    }

    /// Hang up the shell (End Shell). Its `exit` arrives as the phase `.ended`.
    func endShell() {
        if phase == .live, let socket { socket.send(.text(TerminalWire.end)) }
    }

    /// The app is back in front after `away`: a socket iOS left hanging is dialled again now rather than after the
    /// 45 s silence (the computer replays only what was missed, so nothing shows twice).
    func cameBack(after away: Duration) {
        guard !closed, away > .seconds(5) else { return }
        switch phase {
        case .live, .reconnecting, .connecting:
            dialNow = true
            socket?.close()
        case .ended, .stopped:
            break
        }
    }

    // MARK: The loop

    private func hold(_ data: Data) {
        guard waiting.count + data.count <= Self.maxWaiting else { return }
        waiting.append(data)
    }

    private func sendSize() {
        guard phase == .live, let socket, size != sentSize else { return }
        sentSize = size
        socket.send(.text(TerminalWire.resize(cols: size.cols, rows: size.rows)))
    }

    private func run() async {
        while !Task.isCancelled, !closed {
            var opened: (any TerminalSocketing)?
            do {
                let socket = try await dial(TerminalWire.query(session: session, cols: size.cols, rows: size.rows, since: shown))
                opened = socket
                guard !Task.isCancelled, !closed else { socket.close(); return }
                self.socket = socket
                sentSize = size
                heard = .now
                let watchdog = Task { [weak self] in await self?.watch(socket) }
                defer { watchdog.cancel() }
                try await read(socket)
            } catch let failure as GatewayFailure where failure == .connectionChanged {
                closed = true   // signed out or switched gateway: the page is going
                return
            } catch {}
            if socket === opened { socket = nil }
            guard !Task.isCancelled, !closed else { return }
            let ending = TerminalWire.ending(code: opened?.closeCode, reason: opened?.closeReason, refused: opened?.refusedStatus)
            AppLog.trace("terminal", "socket ended: " + Self.describe(code: opened?.closeCode, refused: opened?.refusedStatus, ending: ending))
            opened?.close()
            switch ending {
            case .ended:
                if case .ended = phase {} else { phase = .ended(code: nil) }
                return
            case .retry:
                if case .ended = phase { return }
                failures += 1
                if phase == .live { phase = .reconnecting }
                if phase == .connecting, failures >= Self.giveUpAfter {
                    phase = .stopped(.unreachable)
                    return
                }
                await pause(Self.backoff(failures))
            default:
                phase = .stopped(ending)
                return
            }
        }
    }

    /// For the log: the close code or HTTP answer, never the reason text (it can carry the shell's error).
    nonisolated static func describe(code: Int?, refused: Int?, ending: TerminalWire.Ending) -> String {
        let how = code.map { "close \($0)" } ?? refused.map { "HTTP \($0)" } ?? "no close frame"
        let what: String
        switch ending {
        case .refused: what = "refused"
        default: what = "\(ending)"
        }
        return "\(how) → \(what)"
    }

    /// Waits `delay`, cut short by `cameBack`.
    private func pause(_ delay: Duration) async {
        let until = ContinuousClock.now + delay
        while ContinuousClock.now < until, !dialNow, !Task.isCancelled {
            try? await Task.sleep(for: min(.milliseconds(250), until - ContinuousClock.now))
        }
        dialNow = false
    }

    private func read(_ socket: any TerminalSocketing) async throws {
        while true {
            let frame = try await socket.receive()
            guard !closed else { return }
            heard = .now
            switch frame {
            case .binary(let data):
                shown += data.count
                onOutput?(data)
            case .text(let text):
                switch TerminalWire.parse(text) {
                case .ready(let offset, let shell, _):
                    if offset != shown { onReset?() }
                    shown = offset
                    self.shell = shell
                    failures = 0
                    phase = .live
                    if !waiting.isEmpty {
                        socket.send(.binary(waiting))
                        waiting = Data()
                    }
                    sendSize()
                case .exit(let code):
                    phase = .ended(code: code)
                case .ping, .pong, .other:
                    break
                }
            }
        }
    }

    private func watch(_ socket: any TerminalSocketing) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if ContinuousClock.now - heard > Self.quietLimit {
                AppLog.trace("terminal", "no word from the computer in \(Self.quietLimit); dialling again")
                socket.close()
                return
            }
        }
    }
}
