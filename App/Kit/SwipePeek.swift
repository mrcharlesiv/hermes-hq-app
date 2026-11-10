// The one-time swipe peek (`S/ui-bots/bot-row.tsx:141-153`, parity §3 L161 and the Sessions list's own): shortly after
// a list first shows rows, its first whole row slides 60 pt toward the leading edge, showing the colour and symbol of
// its first trailing swipe action, and slides back. Once per install per list; never under Reduce Motion or VoiceOver
// (the flag then stays unset, so it can play later). Bots and Sessions share this code so the two lists peek alike
// (docs/spec/3x-botslist.md §0A item 2).

import UIKit

@MainActor final class SwipePeek {
    static let botsKey = "hqn.bots.swipePeek"
    static let sessionsKey = "hqn.sessions.swipePeek"

    private let key: String
    private let markerId: String
    private let revealColor: UIColor
    private let symbol: String
    private var scheduled = false
    /// The reveal strip, the marker and the moved content of a peek in flight (a touch snaps it back).
    private var playing: (reveal: UIView, marker: UIView, content: UIView, opaque: UIColor?, cell: UICollectionViewListCell, row: String?, run: Int)?
    private var runs = 0
    /// Whether the row is out (it is on its way back otherwise).
    private var out = false

    init(key: String, markerId: String, revealColor: UIColor, symbol: String) {
        self.key = key
        self.markerId = markerId
        self.revealColor = revealColor
        self.symbol = symbol
    }

    /// Whether this list's peek may still play on this install (and on this launch).
    var wanted: Bool {
        // [mac] Stress test 2026-10-28 #16: a mouse doesn't swipe rows (their actions are on a right-click), so the
        // hint teaches nothing there; caught mid-way by a window snapshot it also left a row frozen half-swiped.
        if DeviceWord.isMac { return false }
        guard !UserDefaults.standard.bool(forKey: key) else { return false }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "HQDebugNoSwipePeek") { return false }
        #endif
        return !HQMotion.reduced && !HQAccessibility.voiceOver
    }

    /// Asks for the peek 0.7 s from now. `ready` is asked again then (and on each later look): the list is on screen,
    /// not searching, not being dragged or edited, nothing presented over it. `rows` lists the cells that may peek,
    /// top first (ordinary rows only: no tiles, headers or cards).
    func schedule(in host: UIViewController, collectionView: UICollectionView, ready: @escaping () -> Bool,
                  rows: @escaping () -> [UICollectionViewListCell]) {
        guard !scheduled, wanted, host.view.window != nil, ready() else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak host, weak collectionView] in
            guard let self, let host, let collectionView else { return }
            self.play(tries: 8, host: host, collectionView: collectionView, ready: ready, rows: rows)
        }
    }

    /// The list can show before its rows arrive: it looks again every 0.5 s a few times, then waits for the next show.
    private func play(tries: Int, host: UIViewController, collectionView: UICollectionView, ready: @escaping () -> Bool,
                      rows: @escaping () -> [UICollectionViewListCell]) {
        let view: UIView = host.view
        let quiet = view.window != nil && ready() && host.presentedViewController == nil
            && !collectionView.isDragging && !collectionView.isDecelerating && !collectionView.hasActiveDrag
            && UIApplication.shared.applicationState == .active
        let shown = rows().first { cell in
            let frame = collectionView.convert(cell.frame, to: view)
            return frame.minY >= view.safeAreaInsets.top && frame.maxY <= view.bounds.maxY - view.safeAreaInsets.bottom
        }
        guard quiet, wanted, let cell = shown else {
            if tries > 1, view.window != nil, wanted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak host, weak collectionView] in
                    guard let self, let host, let collectionView else { return }
                    self.play(tries: tries - 1, host: host, collectionView: collectionView, ready: ready, rows: rows)
                }
            } else {
                scheduled = false
            }
            return
        }
        // Set only now that the peek really runs (`bot-row.tsx:149`).
        UserDefaults.standard.set(true, forKey: key)
        // The strip starts past the trailing edge and slides in as the row's content slides away.
        let reveal = UIView(frame: CGRect(x: cell.bounds.width, y: 0, width: 60, height: cell.bounds.height))
        reveal.backgroundColor = revealColor
        reveal.isUserInteractionEnabled = false
        reveal.isAccessibilityElement = false
        let glyph = UIImageView(image: UIImage(systemName: symbol))
        glyph.tintColor = .white
        glyph.center = CGPoint(x: 30, y: reveal.bounds.midY)
        reveal.addSubview(glyph)
        cell.insertSubview(reveal, aboveSubview: cell.contentView)
        // UI tests see the peek through a marker on the page (it never plays under VoiceOver).
        let marker = UIView(frame: CGRect(x: 0, y: view.bounds.midY, width: 1, height: 1))
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = markerId
        marker.accessibilityLabel = "Swipe peek"
        view.addSubview(marker)
        let content = cell.contentView
        let opaque = content.backgroundColor
        content.backgroundColor = HQPalette.page
        runs += 1
        let run = runs
        out = true
        playing = (reveal, marker, content, opaque, cell, cell.accessibilityIdentifier, run)
        #if DEBUG
        // UI tests (`-HQDebugPeekHold <s>`): the row rests open that long, so a screenshot can catch it.
        let debugHold = UserDefaults.standard.double(forKey: "HQDebugPeekHold")
        let hold = debugHold > 0 ? debugHold : 0.45
        DebugHooks.recordText("played", as: markerId == "sessions.peek" ? "peek.txt" : "\(markerId).txt")
        #else
        let hold = 0.45
        #endif
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {   // motion-ok: the peek never plays under Reduce Motion (`wanted`)
            // The content's own origin moves, not its transform: the list cell lays its content view out by frame, and a
            // frame set on a transformed view puts it straight back where it was (the peek then showed nothing).
            content.bounds.origin.x = 60
            reveal.frame.origin.x = cell.bounds.width - 60
        } completion: { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                guard let self, let playing = self.playing, playing.run == run else { return }   // a touch already put it back
                self.out = false
                let content = playing.content                                   // the row's content now (a reload swaps it)
                UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {   // motion-ok: the way back of the same peek
                    content.bounds.origin.x = 0
                    playing.reveal.frame.origin.x = playing.cell.bounds.width
                } completion: { [weak self] _ in
                    guard let self, self.playing?.run == run else { return }
                    self.finish()
                }
            }
        }
    }

    /// The list redrew a row (new words, a new roster): a hosting cell then has a fresh content view, back at rest. The
    /// peeking row's new content takes the peek over, so a reload during the peek does not cut it short.
    func keep(_ cell: UICollectionViewListCell) {
        // The same row: the same cell, or the cell a reload dequeued for it (rows are named by their identifier).
        guard var current = playing, out,
              current.cell === cell || (current.row != nil && current.row == cell.accessibilityIdentifier) else { return }
        let content = cell.contentView
        guard content !== current.content || content.bounds.origin.x == 0 else { return }
        current.reveal.frame = CGRect(x: cell.bounds.width - 60, y: 0, width: 60, height: cell.bounds.height)
        current.cell = cell
        current.content.bounds.origin.x = 0
        current.content.backgroundColor = current.opaque
        current.opaque = content.backgroundColor
        content.backgroundColor = HQPalette.page
        content.bounds.origin.x = 60
        cell.insertSubview(current.reveal, aboveSubview: content)
        current.content = content
        playing = current
    }

    /// A touch on the list (a tap, a scroll, a swipe) ends a peek in flight at once; the touch then does its own work.
    func cancel() {
        guard let playing else { return }
        playing.content.layer.removeAllAnimations()
        playing.reveal.layer.removeAllAnimations()
        playing.content.bounds.origin.x = 0
        finish()
    }

    private func finish() {
        guard let playing else { return }
        playing.reveal.removeFromSuperview()
        playing.content.backgroundColor = playing.opaque
        playing.marker.removeFromSuperview()
        self.playing = nil
        out = false
    }
}
