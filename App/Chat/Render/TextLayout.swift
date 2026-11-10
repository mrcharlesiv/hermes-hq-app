import UIKit
import os

// Exact row heights for the chat table (estimatedRowHeight = 0): every row is measured here, off the main thread,
// with TextKit 1 — the same engine `TextBlockView` draws with, so measured and drawn text always agree.

// MARK: - TextKit box

/// One laid-out piece of attributed text (TextKit 1). Built and laid out on any thread, then used by one thread at a
/// time: measuring off-main, or drawing and hit-testing on main.
nonisolated final class TextKitLayout: @unchecked Sendable {
    let text: NSAttributedString
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    /// Used size, rounded up to whole points.
    let size: CGSize
    /// Trailing edge of the last line (for the bubble time's reserved space).
    let lastLineMaxX: CGFloat
    /// [mac-audit] The last line's baseline, from the top: a plain reply's time sits on it (`TextLayout.bubble`).
    let lastBaseline: CGFloat
    /// Where the leftmost line starts: 0 for left-to-right text; a right-to-left paragraph (Arabic, Hebrew) lines up
    /// on the container's right edge, so its lines start further in (`TextLayout.pieces` hugs them).
    let inkMinX: CGFloat

    init(_ text: NSAttributedString, width: CGFloat?) {
        self.text = text
        storage = NSTextStorage(attributedString: text)
        manager = ChatLayoutManager()
        manager.usesFontLeading = true
        container = NSTextContainer(size: CGSize(width: width ?? 100_000, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        size = CGSize(width: ceil(used.maxX), height: ceil(used.maxY))
        inkMinX = max(0, floor(used.minX))
        let glyphs = manager.numberOfGlyphs
        if glyphs > 0 {
            var effective = NSRange()
            let rect = manager.lineFragmentUsedRect(forGlyphAt: glyphs - 1, effectiveRange: &effective)
            lastLineMaxX = ceil(rect.maxX)
            // The glyph's location is its baseline within its line fragment.
            lastBaseline = manager.lineFragmentRect(forGlyphAt: glyphs - 1, effectiveRange: nil).minY + manager.location(forGlyphAt: glyphs - 1).y
        } else {
            lastLineMaxX = 0
            lastBaseline = 0
        }
    }

    func draw(at origin: CGPoint) {
        let range = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: range, at: origin)
        manager.drawGlyphs(forGlyphRange: range, at: origin)
    }

    /// MENUS (Find in chat): the line boxes a character range covers, in the text's own coordinates.
    func rects(for range: NSRange) -> [CGRect] {
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length, range.length > 0 else { return [] }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var out: [CGRect] = []
        manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                        in: container) { rect, _ in out.append(rect) }
        return out
    }

    /// [mac] The insertion point nearest a point (in the text's own coordinates), for selecting with the mouse.
    /// [mac] Mac audit 2026-11-02 #11: above the first line is the start and below the last the end (a drag past the
    /// text runs to its end), and the caret never passes a line's own break (past a line's end it stops before it).
    func insertionIndex(at point: CGPoint) -> Int {
        guard text.length > 0 else { return 0 }
        if point.y < 0 { return 0 }
        if point.y >= size.height { return text.length }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < text.length else { return text.length }
        let ns = text.string as NSString
        let breaks = ns.character(at: index) == 0x0A || ns.character(at: index) == 0x2028
        return breaks ? index : min(text.length, index + (fraction > 0.5 ? 1 : 0))
    }

    /// The link under a point (in the text's own coordinates), if any.
    func link(at point: CGPoint) -> URL? { hit(.chatLink, at: point) as? URL }

    /// The inline code under a point, to copy with one tap.
    func copyable(at point: CGPoint) -> String? { hit(.chatCopy, at: point) as? String }

    private func hit(_ key: NSAttributedString.Key, at point: CGPoint) -> Any? {
        guard text.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < text.length else { return nil }
        // Only count a hit on the glyph itself (not the empty space after a line).
        let glyph = manager.glyphIndexForCharacter(at: index)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).insetBy(dx: -6, dy: -6)
        guard rect.contains(point) else { return nil }
        return text.attribute(key, at: index, effectiveRange: nil)
    }
}

/// Draws inline code's `.backgroundColor` as rounded boxes around its glyphs, one per line it is on. TextKit's own rects
/// are the line's: they sat the box above the text (the line's spacing is under the glyphs, so the text touched the
/// box's bottom), ran a wrapped first line's box on to the container's edge, and merged whole middle lines into one
/// rect (a path over three lines drew as a block). Other backgrounds (a Preview's code block) are TextKit's.
nonisolated final class ChatLayoutManager: NSLayoutManager, @unchecked Sendable {
    /// Where the text is being drawn: `fillBackgroundRectArray` works in that space.
    private var drawOrigin: CGPoint = .zero
    /// The code blocks this pass has drawn (a block's background can come in several runs; its fill is translucent).
    private var drawnBlocks = Set<Int>()

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawOrigin = origin
        drawnBlocks.removeAll()
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<CGRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: UIColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? UIFont else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        if storage.attribute(.codeBlockBox, at: charRange.location, effectiveRange: nil) != nil {
            fillCodeBlock(at: charRange.location, font: font, color: color)
            return
        }
        if storage.attribute(.lineWash, at: charRange.location, effectiveRange: nil) != nil {
            // The rows across the page, not a strip behind each line's words (the page's insets are the origin's x).
            // One shape for the run's rows: rows filled one by one left a darker seam where their translucent edges met.
            // Each row's top and bottom on whole pixels, so a red row and a green one meet without a muddy pixel between.
            let origin = drawOrigin
            let context = UIGraphicsGetCurrentContext()
            let rows = UIBezierPath()
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)) { line, _, _, _, _ in
                var row = CGRect(x: 0, y: line.minY + origin.y, width: line.width + 2 * origin.x, height: line.height)
                if let context {
                    let device = context.convertToDeviceSpace(row)
                    let top = device.minY.rounded(), bottom = device.maxY.rounded()
                    row = context.convertToUserSpace(CGRect(x: device.minX, y: top, width: device.width, height: bottom - top))
                }
                rows.append(UIBezierPath(rect: row))
            }
            color.setFill()
            rows.usesEvenOddFillRule = false
            rows.fill()
            return
        }
        guard storage.attribute(.inlineCodeBox, at: charRange.location, effectiveRange: nil) != nil else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        let text = storage.string as NSString
        let run = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let origin = drawOrigin
        color.setFill()
        enumerateLineFragments(forGlyphRange: run) { line, _, container, lineGlyphs, _ in
            var part = NSIntersectionRange(run, lineGlyphs)
            // A space the line broke at stays out of the box (TextKit stretches it to the line's end).
            while part.length > 1, NSMaxRange(part) == NSMaxRange(lineGlyphs), NSMaxRange(part) < NSMaxRange(run),
                  text.character(at: self.characterIndexForGlyph(at: NSMaxRange(part) - 1)) == 0x20 {
                part.length -= 1
            }
            guard part.length > 0 else { return }
            let span = self.boundingRect(forGlyphRange: part, in: container)
            // The glyph location is the baseline, the run's baseline offset included.
            let baseline = line.minY + self.location(forGlyphAt: part.location).y
            let box = CGRect(x: span.minX + origin.x, y: baseline - font.ascender - 1 + origin.y,
                             width: span.width, height: font.ascender - font.descender + 2)
            // Where the code wraps, the box is cut square on both sides of the break (the run's own ends stay round):
            // a wrapped line's start sits on the text's edge, where a rounded, padded start was clipped flat.
            var corners: UIRectCorner = []
            if part.location == run.location { corners.formUnion([.topLeft, .bottomLeft]) }
            if NSMaxRange(part) == NSMaxRange(run) { corners.formUnion([.topRight, .bottomRight]) }
            let radius = min(6, box.height / 2)
            UIBezierPath(roundedRect: box, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).fill()
        }
    }

    /// A read-only page's text view on TextKit 1 with this layout manager: inline code in rounded boxes, code blocks
    /// in one box, a diff's lines washed across the page (the system text view drew each as a strip behind the words).
    @MainActor static func textView() -> UITextView {
        let storage = NSTextStorage()
        let manager = ChatLayoutManager()
        manager.allowsNonContiguousLayout = true   // a report or a log can be hundreds of KB
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return UITextView(frame: .zero, textContainer: container)
    }

    /// A code block's box: the column's width, from its first line's glyphs to its last line's, 8 pt round them (the
    /// block's paragraphs are indented and spaced for it, `ArtifactTextViewController.boxCodeBlocks`). TextKit drew each
    /// line's own strip, ragged on the right, flush with the text and touching the paragraph above.
    private func fillCodeBlock(at index: Int, font: UIFont, color: UIColor) {
        guard let storage = textStorage, let container = textContainers.first else { return }
        var block = NSRange()
        _ = storage.attribute(.codeBlockBox, at: index, longestEffectiveRange: &block, in: NSRange(location: 0, length: storage.length))
        guard block.length > 0, drawnBlocks.insert(block.location).inserted else { return }
        let glyphs = glyphRange(forCharacterRange: block, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let last = NSMaxRange(glyphs) - 1
        let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let end = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let top = first.minY + location(forGlyphAt: glyphs.location).y - font.ascender - 8
        let bottom = end.minY + location(forGlyphAt: last).y - font.descender + 8
        let x = first.minX + container.lineFragmentPadding
        let box = CGRect(x: x + drawOrigin.x, y: top + drawOrigin.y, width: first.width - 2 * container.lineFragmentPadding,
                         height: bottom - top)
        color.setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 8).fill()
    }
}

// MARK: - Keys and caches

/// Identifies one measured row. A layout is reused only when the chat, the row's content fingerprint, the
/// presentation variant, the width and the Dynamic Type size all match.
nonisolated struct TextLayoutKey: Hashable, Sendable {
    /// The chat (account, profile, session): message ids repeat across bots and gateways.
    var scope: String
    var messageId: String
    /// Which row of the message ("b3" = bubble of part 3, "t…" = tool run, "day", "err"…).
    var part: String
    /// The row's own content hash (not the message's revision, which every streamed delta bumps).
    var fingerprint: Int
    var width: CGFloat
    var contentSizeCategory: String
    var variant: Int
    var gapAbove: CGFloat

    init(row: ChatRow, width: CGFloat, category: UIContentSizeCategory) {
        scope = row.scope
        messageId = row.messageId
        part = row.id.hasPrefix(row.messageId + "|") ? String(row.id.dropFirst(row.messageId.count + 1)) : row.id
        fingerprint = row.fingerprint
        self.width = (width * 2).rounded() / 2
        contentSizeCategory = category.rawValue + ThemeTable.layoutTag   // [desktoplook]
        variant = row.variant
        gapAbove = row.gapAbove
    }
}

/// Rendered markdown per (chat, message, part, content, size, side): width changes re-measure without re-parsing,
/// and a part that stopped changing keeps its attributed text while a later part streams.
nonisolated struct MarkdownKey: Hashable, Sendable {
    var scope: String
    var messageId: String
    var partIndex: Int
    /// The bubble's fingerprint (its text, side and speaker).
    var fingerprint: Int
    var contentSizeCategory: String
    var mine: Bool
    var markdown: Bool
    /// Code blocks coloured by token (the message no longer streams, spec 06 §2.6).
    var highlight: Bool = false
}

/// Small thread-safe LRU-ish cache (clears the oldest half when full).
/// [perf] An unfair lock (it lends the waiting main thread's priority to a utility-queue holder), and evicted values
/// are freed after it is released: a trim drops thousands of layouts, and main shouldn't wait behind those frees.
nonisolated final class ChatCache<Key: Hashable, Value>: @unchecked Sendable {
    private typealias Entry = (value: Value, stamp: UInt64)
    private let lock = OSAllocatedUnfairLock()
    private var values: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    func value(_ key: Key) -> Value? {
        lock.withLockUnchecked {
            guard var entry = values[key] else { return nil }
            clock += 1
            entry.stamp = clock
            values[key] = entry
            return entry.value
        }
    }

    func set(_ key: Key, _ value: Value) {
        let dropped: [Key: Entry] = lock.withLockUnchecked {
            clock += 1
            values[key] = (value, clock)
            return values.count > limit ? trimLocked(to: limit / 2) : [:]
        }
        _ = dropped   // freed here, outside the lock
    }

    func remove(_ key: Key) {
        let dropped: Entry? = lock.withLockUnchecked { values.removeValue(forKey: key) }
        _ = dropped
    }

    /// Keeps the `count` most recently used entries.
    func trim(to count: Int) {
        let dropped = lock.withLockUnchecked { trimLocked(to: count) }
        _ = dropped
    }

    /// Returns the storage that held the evicted entries, for the caller to free after unlocking.
    private func trimLocked(to count: Int) -> [Key: Entry] {
        guard values.count > count else { return [:] }
        var old: [Key: Entry] = [:]
        swap(&old, &values)
        if count <= 0 { return old }
        let cutoff = old.values.map(\.stamp).sorted()[old.count - count]
        values = old.filter { $0.value.stamp >= cutoff }
        return old
    }

    func removeAll() {
        let dropped: [Key: Entry] = lock.withLockUnchecked {
            var old: [Key: Entry] = [:]
            swap(&old, &values)
            return old
        }
        _ = dropped
    }

    var count: Int { lock.withLockUnchecked { values.count } }
}

/// [perf] A streaming reply's newest version only, one slot per row. Every delta changes the row's fingerprint, so the
/// normal caches would keep each partial reply (its markdown, its layout and a TextKit stack per piece) until the LRU
/// trims, and the 800-entry draw pool would push out the rows on screen. A slot keeps the newest version (it must still
/// hit between the measure off-main and the apply on main), drops the draw-pool entries of the version it replaces,
/// and goes away when the row settles (the settled version is cached as usual).
nonisolated final class StreamSlots: @unchecked Sendable {
    struct ID: Hashable {
        var scope: String
        var messageId: String
        var part: String
    }
    struct Slot {
        var layoutKey: TextLayoutKey?
        var layout: RowLayout?
        var mdKey: MarkdownKey?
        var md: RenderedMarkdown?
        var pooled: Set<TextKitPool.Key> = []
        var stamp: UInt64 = 0
    }
    /// Rows abandoned mid-stream (a chat closed while a reply ran) can't pile up.
    static let limit = 32
    private let lock = OSAllocatedUnfairLock()
    private var slots: [ID: Slot] = [:]
    private var clock: UInt64 = 0

    func layout(_ id: ID, key: TextLayoutKey) -> RowLayout? {
        lock.withLockUnchecked { slots[id]?.layoutKey == key ? slots[id]?.layout : nil }
    }

    func markdown(_ id: ID, key: MarkdownKey) -> RenderedMarkdown? {
        lock.withLockUnchecked { slots[id]?.mdKey == key ? slots[id]?.md : nil }
    }

    func setMarkdown(_ id: ID, key: MarkdownKey, _ md: RenderedMarkdown) {
        let dropped = lock.withLockUnchecked {
            update(id) { $0.mdKey = key; $0.md = md }
        }
        TextLayout.unpool(dropped)
    }

    /// Stores the newest layout and lets go of the draw-pool entries only the replaced version used (after the new
    /// version was offered: a cell still drawing the old one rebuilds on a miss, never crashes).
    func setLayout(_ id: ID, key: TextLayoutKey, _ layout: RowLayout) {
        let keys = TextLayout.poolKeys(layout)
        let dropped: [TextKitPool.Key] = lock.withLockUnchecked {
            var old: Set<TextKitPool.Key> = []
            var evicted = update(id) { slot in
                old = slot.pooled
                slot.layoutKey = key
                slot.layout = layout
                slot.pooled = keys
            }
            evicted.append(contentsOf: old.subtracting(keys))
            return evicted
        }
        TextLayout.unpool(dropped)
    }

    /// The row settled (or the caches were cleared): its slot and its draw-pool entries go.
    func remove(_ id: ID) {
        let dropped: Set<TextKitPool.Key> = lock.withLockUnchecked { slots.removeValue(forKey: id)?.pooled ?? [] }
        TextLayout.unpool(dropped)
    }

    func contains(_ id: ID) -> Bool { lock.withLockUnchecked { slots[id] != nil } }

    func removeAll() {
        let dropped: [ID: Slot] = lock.withLockUnchecked {
            var old: [ID: Slot] = [:]
            swap(&old, &slots)
            return old
        }
        TextLayout.unpool(dropped.values.flatMap(\.pooled))
    }

    var count: Int { lock.withLockUnchecked { slots.count } }

    /// Under the lock. Returns the pool keys of a slot evicted to stay under the limit.
    private func update(_ id: ID, _ change: (inout Slot) -> Void) -> [TextKitPool.Key] {
        clock += 1
        var slot = slots[id] ?? Slot()
        change(&slot)
        slot.stamp = clock
        slots[id] = slot
        guard slots.count > Self.limit, let oldest = slots.min(by: { $0.value.stamp < $1.value.stamp })?.key else { return [] }
        return Array(slots.removeValue(forKey: oldest)?.pooled ?? [])
    }
}

/// Lets go of the chat's layout caches when memory runs low (everything) or the app goes to the background (all but
/// the most recent), so a long session of opening big chats can't grow without bound.
enum ChatCaches {
    private static var installed = false

    static func installObservers() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            clearAll()
        }
        // [perf] The background trim follows MemoryTrim's rule (after 20 s away, not on a quick trip); it counts no chats.
        MemoryTrim.register("chat.layout") { reason in
            if reason == .background { trimForBackground() }
            return 0
        }
    }

    nonisolated static func clearAll() {
        TextLayout.layouts.removeAll()
        TextLayout.markdown.removeAll()
        TextKitPool.cache.removeAll()
        TextLayout.streamSlots.removeAll()
    }

    nonisolated static func trimForBackground() {
        TextLayout.layouts.trim(to: 2_000)
        TextLayout.markdown.trim(to: 1_000)
        // [perf] About two screens' pieces across the last few chats, so a reopened chat (not only the last one) draws
        // from the pool instead of building TextKit on main in cellForRow.
        TextKitPool.cache.trim(to: 300)
        TextLayout.streamSlots.removeAll()
    }
}

// MARK: - Layout results

/// One laid-out piece of a block's text. Long text is cut into pieces of at most ~2,000 characters at line or
/// paragraph ends, each drawn by its own view: one tall layer would pass the GPU's texture size limit (about 5,400 pt
/// at 3x) and hold megabytes of backing store.
nonisolated struct TextPiece: @unchecked Sendable {
    var text: NSAttributedString
    /// Inside the block's text content (the scrolling area for code and tables).
    var frame: CGRect
}

nonisolated struct PlacedBlock: @unchecked Sendable {
    var block: MarkdownBlock
    /// The block's frame inside the bubble.
    var frame: CGRect
    /// The visible text area inside the block (a clamped code block shows part of its content).
    var textFrame: CGRect
    /// Full text width for a block that scrolls sideways (tables, unwrapped code); equals textFrame.width otherwise.
    var contentWidth: CGFloat
    /// Full content height (taller than `textFrame` when a code block is clamped).
    var contentHeight: CGFloat
    /// The width the text was laid out at (nil = unbounded, for blocks that scroll sideways).
    var layoutWidth: CGFloat?
    var pieces: [TextPiece]
    /// A code block taller than its clamp: whether it is open (spec 06 §2.6). Nil when it fits.
    var codeOpen: Bool?
    /// Your clamped message: fade the last visible line.
    var fadesBottom: Bool = false
    /// Right-to-left text (`TextLayout.pieces`' shift): its words line up on the bubble's trailing edge.
    var trailingAligned = false
    /// A table's grid lines (the pieces are its cells).
    var grid: TableGrid? = nil
    /// [attachments] A reply's media block: its photos and file rows, in block coordinates.
    var media: BlockMedia? = nil
    /// A page card's chat (where its page is read from).
    var pageContext: MediaContext? = nil
}

/// [attachments] What a `.media` block draws (docs/spec/1x-attachments.md §7.5), relative to the block.
nonisolated struct BlockMedia: @unchecked Sendable {
    var groups: [MediaGroupLayout]
    var rows: [FileRowLayout]
}

/// A table's geometry inside its scrolling content: column and row boundaries (first = 0, last = the full size).
/// Row 0 is the header.
nonisolated struct TableGrid: Sendable, Equatable {
    var columns: [CGFloat]
    var rows: [CGFloat]
    var size: CGSize { CGSize(width: columns.last ?? 0, height: rows.last ?? 0) }
}

nonisolated struct BubbleLayout: @unchecked Sendable {
    var frame: CGRect                 // in row coordinates (top-down)
    var shape: BubbleShape.Key
    var mine: Bool
    var blocks: [PlacedBlock]
    var timeText: String?
    var timeFrame: CGRect             // inside the bubble
    var dimmed: Bool
    var copyText: String
    /// "Show More" under your clamped message (inside the bubble), nil when it shows in full.
    var showMoreFrame: CGRect?
    /// [attachments] Photos (in bubble coordinates) and file rows (docs/spec/1x-attachments.md §7.3).
    var mediaGroups: [MediaGroupLayout] = []
    var fileRows: [FileRowLayout] = []
    /// No fill and no tail: the photos are the bubble.
    var mediaOnly = false
    /// The time's dim capsule over a photo-only bubble (inside the bubble).
    var timeCapsule: CGRect? = nil
    /// VOICE: your voice memo's audio message (spec 1x-voice §5); `blocks` is empty then.
    var memo: MemoBubbleGeometry? = nil
    // [groups] Another sender's name (inside the bubble, above the text) and its face (row coordinates), §7.12.
    var senderName: String? = nil
    var senderNameFrame: CGRect = .zero
    var senderColorHex: String? = nil
    var faceFrame: CGRect? = nil
    var faceSender: ChatSender? = nil
}

nonisolated struct ToolRowLayout: @unchecked Sendable {
    var rowFrame: CGRect              // the 40 pt line
    var title: String
    var glyph: ChatGlyph
    var meta: String?
    var metaIsError: Bool
    var live: Bool
    var expanded: Bool
    /// A run of one opens its step sheet directly (spec 03 §8.4).
    var single: Bool
    /// Open run: the inset card and its step lines (titles, metas).
    var cardFrame: CGRect
    var steps: [(title: String, meta: String?, frame: CGRect, failed: Bool, live: Bool)]
    /// Open thought: its text inside the card.
    var thoughtText: TextKitLayout?
    var thoughtFrame: CGRect
    /// A long opened One Line card shows only its last steps: the first one's index in the run, the run's whole count,
    /// "Show All N Steps" above them (it opens the Steps sheet) and "Show Less" under them, inside the card.
    var firstStep = 0
    var stepCount = 0
    var showAllFrame: CGRect? = nil
    var showLessFrame: CGRect? = nil
    /// [botdm] The other bot's face, drawn in the glyph's place.
    var face: ChatSender? = nil
    /// [updates] An update group's line: centred, its marks before its words, "· 3 more" after them, no chevron.
    var group: UpdatesGroup? = nil
    var groupOpen = false
}

nonisolated struct LineLayout: @unchecked Sendable {
    var text: TextKitLayout
    var frame: CGRect
    /// A tappable line ("Delivery Unconfirmed · Check"): its target, at least 44 pt wide.
    var tapFrame: CGRect? = nil
    /// "Stopped before <Bot> replied": the Retry capsule as drawn, and its 44 pt target (spec 06 §5.6.3).
    var retryFrame: CGRect? = nil
    var retryTap: CGRect? = nil
}

nonisolated struct ErrorLayout: @unchecked Sendable {
    var cardFrame: CGRect
    var glyphFrame: CGRect
    var title: TextKitLayout
    var titleFrame: CGRect
    var reason: TextKitLayout
    var reasonFrame: CGRect
    var copyText: String
    /// The ✕ (44 pt, trailing end of the heading) and "Details" (spec 06 §5.6.1), inside the card.
    var closeFrame: CGRect
    var detailsFrame: CGRect
    /// The primary recovery, "Try Again" (a tint capsule above Details), when the card offers it.
    var retryFrame: CGRect? = nil
    /// [transcript] The primary button reads "Choose a Model" and opens the model list instead of retrying.
    var chooseModel: Bool = false
}

/// The latest reply's action row: Copy as a 44 pt circle, 10 pt left of the content edge so its glyph lines up with
/// the text (spec 06 §2.5).
nonisolated struct ActionsLayout: Sendable {
    var copyFrame: CGRect
}

nonisolated struct WaitingLayout: @unchecked Sendable {
    /// [thinking] The bot's face, then the typing dots' capsule (it replaced the desktop's dither square).
    static let face: CGFloat = 24
    static let capsule = CGSize(width: 40, height: 24)
    /// The bot's face; nil in a room's typing row (the member's face sits in the face column) or with no bot known.
    var face: CGRect?
    /// The typing dots' capsule.
    var capsule: CGRect
    /// Where the wait text ("Ivy is thinking…", then the timer) starts; one line, centred on the capsule.
    var textFrame: CGRect
}

nonisolated struct RowLayout: @unchecked Sendable {
    /// The cache key this layout was made for.
    var key: TextLayoutKey?
    enum Content {
        case bubble(BubbleLayout)
        case tool(ToolRowLayout)
        case line(LineLayout)          // day separator, notice, caption, stopped-early
        case error(ErrorLayout)
        case waiting(WaitingLayout)
        case actions(ActionsLayout)
        case prompt(PromptRowLayout)      // [questions]
        case activity(ActivityLayout)       // [activity] tool bubbles, delegate card, generated image
        case reactions(ReactionsLayout)     // Tapback badges under a message
        case member(UpdateMemberLayout)     // [updates] a row of an opened update group's card
    }
    var height: CGFloat
    var content: Content
}

// MARK: - Layout

nonisolated enum TextLayout {
    static let layouts = ChatCache<TextLayoutKey, RowLayout>(limit: 12_000)
    static let markdown = ChatCache<MarkdownKey, RenderedMarkdown>(limit: 8_000)
    /// The screen height, for the open code cap (40 % of it). Set by the chat screen; the layout key doesn't carry it
    /// because it only changes with the device.
    nonisolated(unsafe) static var screenHeight: CGFloat = 874
    /// Text longer than this many UTF-16 units is cut into pieces (see `TextPiece`).
    static let pieceLength = 2_000

    /// The row's layout, from the cache when the key matches.
    /// `keep`: hand the TextKit objects made while measuring to the draw pool (rows about to be drawn).
    static func layout(_ row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool = false) -> RowLayout {
        let key = TextLayoutKey(row: row, width: width, category: style.category)
        let slot = streamSlot(row)
        if let slot {
            if let hit = streamSlots.layout(slot, key: key) { return hit }
        } else if let hit = layouts.value(key) {
            return hit
        }
        var made = make(row, width: width, style: style, keep: keep)
        made.key = key
        if let slot {
            streamSlots.setLayout(slot, key: key, made)
        } else {
            layouts.set(key, made)
            settle(row)
        }
        return made
    }

    static func cached(_ row: ChatRow, width: CGFloat, style: ChatStyle) -> RowLayout? {
        let key = TextLayoutKey(row: row, width: width, category: style.category)
        if let slot = streamSlot(row) { return streamSlots.layout(slot, key: key) }
        return layouts.value(key)
    }

    // MARK: Streaming slots

    static let streamSlots = StreamSlots()

    /// A streaming bubble's slot (nil for every other row).
    static func streamSlot(_ row: ChatRow) -> StreamSlots.ID? {
        guard case .bubble(let b) = row.kind, b.streaming else { return nil }
        return slotID(row)
    }

    private static func slotID(_ row: ChatRow) -> StreamSlots.ID {
        let part = row.id.hasPrefix(row.messageId + "|") ? String(row.id.dropFirst(row.messageId.count + 1)) : row.id
        return StreamSlots.ID(scope: row.scope, messageId: row.messageId, part: part)
    }

    /// A bubble that stopped streaming: its slot goes (called on a cache miss, so once per settled version).
    private static func settle(_ row: ChatRow) {
        guard case .bubble = row.kind, streamSlots.count > 0 else { return }
        let id = slotID(row)
        if streamSlots.contains(id) { streamSlots.remove(id) }
    }

    /// The draw-pool keys of a layout's text pieces (as `TextBlockView` looks them up).
    static func poolKeys(_ layout: RowLayout) -> Set<TextKitPool.Key> {
        guard case .bubble(let b) = layout.content else { return [] }
        var keys = Set<TextKitPool.Key>()
        for block in b.blocks {
            for piece in block.pieces { keys.insert(TextKitPool.Key(id: ObjectIdentifier(piece.text), width: block.layoutWidth)) }
        }
        return keys
    }

    static func unpool<S: Sequence>(_ keys: S) where S.Element == TextKitPool.Key {
        for key in keys { TextKitPool.cache.remove(key) }
    }

    static func make(_ row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool = false) -> RowLayout {
        let gap = row.gapAbove
        switch row.kind {
        case .bubble(let b):
            if b.senderInset && !b.mine { return senderBubble(b, row: row, width: width, style: style, keep: keep) }   // [groups]
            return bubble(b, row: row, width: width, style: style, keep: keep)
        case .toolRun(let t):
            if let line = t.line {                          // Tool Call Style › One Line: the reply's line
                let failed = t.tools.filter { $0.state == .failed }.count
                let opensStep = t.tools.count == 1 && line.thought == nil
                var layout = toolRow(title: line.title, glyph: line.glyph,
                                     meta: t.group != nil ? nil : failed > 0 ? "\(failed) Failed" : line.meta,
                                     metaIsError: failed > 0, live: t.live, expanded: t.expanded && !opensStep, single: opensStep,
                                     steps: t.expanded && !opensStep ? t.tools : [], thought: t.expanded ? line.thought : nil,
                                     gap: gap, width: width, style: style, capsSteps: true, centered: t.group != nil)
                // [updates] Alone between two real rows it is a centred update line, its glyph before its words.
                if let group = t.group, case .tool(var tl) = layout.content {
                    tl.group = group
                    tl.groupOpen = t.expanded && !opensStep
                    layout.content = .tool(tl)
                }
                return layout
            }
            let title = ChatRunSummary.summarize(t.tools, live: t.live)
            let failedAlone = t.tools.count == 1 && t.tools[0].state == .failed
            let note = t.tools.count == 1 && !t.live ? t.tools[0].note : nil   // [transcript] "10 KB output"
            return toolRow(title: title, glyph: ChatRunSummary.glyph(forSummary: title), meta: failedAlone ? "Failed" : note,
                           metaIsError: failedAlone, live: t.live, expanded: t.expanded && t.tools.count > 1,
                           single: t.tools.count == 1, steps: t.expanded ? t.tools : [], thought: nil, gap: gap,
                           width: width, style: style)
        case .thought(let t):
            return toolRow(title: t.title, glyph: .thinking, meta: nil, metaIsError: false, live: t.live, expanded: t.expanded,
                           single: false, steps: [], thought: t.expanded ? t.text : nil, gap: gap, width: width, style: style)
        case .backgroundResult(let b):
            // [updates] A group's line opens on its own words only when it stands for one update; a bigger group's
            // members draw as rows of their own under it.
            let opensHere = b.expanded && (b.group?.count ?? 1) == 1
            // [btw] What you asked leads in the secondary ink, apart from the answer under it (Mac polish #25: the two
            // read alike).
            let asked = b.aside ? BackgroundResults.split(b.title).rest : ""
            let opened = asked.isEmpty ? BackgroundResults.opened(title: b.title, result: b.result) : b.result
            var layout = toolRow(title: BackgroundResults.split(b.title).head, glyph: b.glyph,
                                 meta: nil, metaIsError: false, live: false,
                                 expanded: opensHere, single: false, steps: [],
                                 thought: opensHere ? SpacedText.repair(opened) : nil, gap: gap,
                                 width: width, style: style, thoughtLinks: b.process ? .addresses : .formatted,
                                 asked: asked, centered: b.group != nil)
            if case .tool(var t) = layout.content {
                t.face = b.group == nil ? b.face : nil                                                 // [botdm]
                t.group = b.group
                t.groupOpen = b.expanded
                layout.content = .tool(t)
            }
            return layout
        case .updateMember(let member):
            return UpdateMemberLayouts.make(member, gap: gap, width: width, style: style)     // [updates]
        case .day(let date, let now, let until):
            let text = until.map { ChatRowBuilder.dayRange(date, $0, now: now) } ?? ChatRowBuilder.dayLabel(date, now: now)
            let tk = TextKitLayout(line(text, font: style.day, color: ChatPalette.lineInk, align: .center), width: width - 16)
            let h = 12 + tk.size.height + 12
            return RowLayout(height: ceil(max(0, gap) + h),
                             content: .line(LineLayout(text: tk, frame: CGRect(x: 8, y: max(0, gap) + 12, width: width - 16, height: tk.size.height))))
        case .notice(let text):
            let w = width - 2 * 32
            let tk = TextKitLayout(line(text, font: style.notice, color: ChatPalette.lineInk, align: .center), width: w)
            return RowLayout(height: ceil(gap + 6 + tk.size.height + 6),
                             content: .line(LineLayout(text: tk, frame: CGRect(x: 32, y: gap + 6, width: w, height: tk.size.height))))
        case .caption(let text):
            let tk = TextKitLayout(line(text, font: style.caption, color: ChatPalette.lineInk, align: .natural), width: width - 32)
            return RowLayout(height: ceil(gap + tk.size.height + 2),
                             content: .line(LineLayout(text: tk, frame: CGRect(x: ChatMetrics.sideInset, y: gap, width: width - 32, height: tk.size.height))))
        case .stoppedEarly(let text, let retry):
            // The line, then a Retry capsule 12 pt after it (under it when it doesn't fit), 4 pt above and below; the
            // row is at least the capsule's 44 pt target tall (spec 06 §5.6.3). A row that offers no Retry (an older
            // turn, a reply running, a prompt with pictures) is the line alone.
            let side = ChatMetrics.sideInset
            let available = width - 2 * side
            let tk = TextKitLayout(line(text, font: style.stoppedLine, color: ChatPalette.lineInk, align: .natural), width: available)
            guard retry else {
                let rowH = tk.size.height + 8
                return RowLayout(height: ceil(gap + rowH),
                                 content: .line(LineLayout(text: tk, frame: CGRect(x: side, y: gap + 4, width: available, height: tk.size.height))))
            }
            let capsule = RetryCapsuleMetrics.size(style: style)
            let textH = tk.size.height
            var textFrame = CGRect(x: side, y: 0, width: available, height: textH)
            var capsuleFrame: CGRect
            if tk.size.width + 12 + capsule.width <= available {
                let lineH = max(textH, capsule.height)
                textFrame.origin.y = (lineH - textH) / 2
                capsuleFrame = CGRect(x: side + tk.size.width + 12, y: (lineH - capsule.height) / 2, width: capsule.width, height: capsule.height)
            } else {
                capsuleFrame = CGRect(x: side, y: textH + 4, width: capsule.width, height: capsule.height)
            }
            let contentH = max(textFrame.maxY, capsuleFrame.maxY)
            let rowH = max(44, contentH + 8)
            let shift = gap + (rowH - contentH) / 2
            textFrame.origin.y += shift
            capsuleFrame.origin.y += shift
            let tap = capsuleFrame.insetBy(dx: -8, dy: -(44 - capsuleFrame.height) / 2)
            return RowLayout(height: ceil(gap + rowH),
                             content: .line(LineLayout(text: tk, frame: textFrame, retryFrame: capsuleFrame, retryTap: tap)))
        case .error(let e):
            return errorCard(e, gap: gap, width: width, style: style)
        case .sendState(let state):
            // One line under your bubble, trailing, Footnote: red and a button when it offers Check (spec 06 §5.6.4).
            let color = state.actionable ? ChatPalette.red : ChatPalette.lineInk
            let w = width - 2 * ChatMetrics.sideInset - 12
            let tk = TextKitLayout(line(state.text, font: style.notice, color: color, align: .right), width: w)
            let rowH = max(32, tk.size.height + 8)
            let frame = CGRect(x: ChatMetrics.sideInset + 6, y: gap + (rowH - tk.size.height) / 2, width: w, height: tk.size.height)
            let textW = min(w, tk.lastLineMaxX > 0 ? tk.size.width : w)
            let tapW = max(44, textW + 24)
            let tap = CGRect(x: width - ChatMetrics.sideInset - tapW, y: gap, width: tapW, height: rowH)
            return RowLayout(height: ceil(gap + rowH), content: .line(LineLayout(text: tk, frame: frame, tapFrame: state.actionable ? tap : nil)))
        case .slashOutput(let command, let output):
            return slashOutput(command: command, output: output, gap: gap, width: width, style: style)   // MENUS (spec 1x §8.4)
        case .actions:
            return RowLayout(height: gap + 44,
                             content: .actions(ActionsLayout(copyFrame: CGRect(x: ChatMetrics.sideInset - 10, y: gap, width: 44, height: 44))))
        case .prompt(let prompt):
            return PromptLayout.make(prompt, row: row, width: width, style: style)   // [questions]
        case .activity(let kind):
            return ActivityLayouts.make(kind, row: row, width: width, style: style)       // [activity]
        case .reactions(let r):
            return reactions(r, gap: gap, width: width, style: style)
        case .waiting(let waiting):
            let textH = ceil(style.notice.lineHeight)
            let h = max(30, textH)
            // [groups] A room's typing row leaves the face column free (the face sits in it).
            let lead = ChatMetrics.sideInset + (waiting.plain ? TextLayout.senderColumn : 0)
            // [thinking] The bot's face, 6 pt, the typing dots' capsule, 8 pt, then the words and the timer.
            var x = lead
            var face: CGRect?
            if !waiting.plain, waiting.bot != nil {
                let side = WaitingLayout.face
                face = CGRect(x: x, y: gap + ((h - side) / 2).rounded(), width: side, height: side)
                x += side + 6
            }
            let size = WaitingLayout.capsule
            let capsule = CGRect(x: x, y: gap + ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            let textX = capsule.maxX + 8
            return RowLayout(height: gap + h, content: .waiting(WaitingLayout(
                face: face, capsule: capsule,
                textFrame: CGRect(x: textX, y: gap + (h - textH) / 2, width: max(0, width - textX - 16), height: textH))))
        }
    }

    static func line(_ text: String, font: UIFont, color: UIColor, align: NSTextAlignment) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    // MARK: Bubbles

    static func rendered(_ b: BubbleRow, row: ChatRow, style: ChatStyle) -> RenderedMarkdown {
        let highlight = b.markdown && !b.mine && !b.streaming
        let key = MarkdownKey(scope: row.scope, messageId: row.messageId, partIndex: b.partIndex, fingerprint: row.fingerprint,
                              contentSizeCategory: style.category.rawValue + ThemeTable.layoutTag, mine: b.mine, markdown: b.markdown, highlight: highlight)
        let slot = b.streaming ? slotID(row) : nil
        if let slot {
            if let hit = streamSlots.markdown(slot, key: key) { return hit }
        } else if let hit = markdown.value(key) {
            return hit
        }
        let r: RenderedMarkdown
        if let memo = b.memoTitle {
            r = memoBubble(title: memo, transcript: b.text, style: style)
        } else if b.markdown && b.mine {
            r = MarkdownRenderer.renderUser(b.text, style: style)                    // DECISION 2026-10-26: inline markdown
        } else if b.markdown {
            r = MarkdownRenderer.render(b.text, style: style, theme: b.mine ? .me : .bot, highlight: highlight,
                                        linkChips: !b.mine && !b.streaming,   // [transcript] §3.7: chips under a settled reply's bare links
                                        filePaths: !b.mine,                    // a path the bot names opens in Files
                                        streaming: b.streaming)
        } else {
            r = RenderedMarkdown(blocks: [.text(MarkdownRenderer.plain(b.text, style: style, theme: b.mine ? .me : .bot))],
                                 plainText: b.text)
        }
        if let slot { streamSlots.setMarkdown(slot, key: key, r) } else { markdown.set(key, r) }
        return r
    }

    /// Your voice memo (`VoiceMemo`): a "Voice Memo" header with a waveform glyph, then the transcript as plain text.
    private static func memoBubble(title: String, transcript: String, style: ChatStyle) -> RenderedMarkdown {
        let color = ChatPalette.meTime
        let header = NSMutableAttributedString()
        let config = UIImage.SymbolConfiguration(font: style.timeBold)
        if let glyph = UIImage(systemName: "waveform", withConfiguration: config)?.withTintColor(.white.withAlphaComponent(0.85),
                                                                                                    renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: glyph)
            let h = style.timeBold.capHeight
            attachment.bounds = CGRect(x: 0, y: (h - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
            header.append(NSAttributedString(attachment: attachment))
            header.append(NSAttributedString(string: " "))
        }
        header.append(NSAttributedString(string: title))
        let lineH = (style.timeBold.pointSize * 1.3).rounded(.up)
        header.addAttributes([.font: style.timeBold, .foregroundColor: color,
                              .paragraphStyle: MarkdownRenderer.paragraphStyle(lineHeight: lineH, font: style.timeBold, spacingBefore: 0),
                              .baselineOffset: MarkdownRenderer.baselineOffset(lineHeight: lineH, font: style.timeBold)],
                             range: NSRange(location: 0, length: header.length))
        let body = MarkdownRenderer.plain(transcript, style: style, theme: .me)
        return RenderedMarkdown(blocks: [.text(header), .text(body)], plainText: "\(title): \(transcript)")
    }

    /// The width a reply's rows take (text, tool rows and their cards, error cards): the column, but on the Mac no
    /// wider than Grok Bot's 560 pt bubbles (`ChatMetrics.replyMaxWidth`).
    static func replyWidth(_ width: CGFloat) -> CGFloat { min(width - 2 * ChatMetrics.sideInset, ChatMetrics.replyMaxWidth) }

    /// [wide-tables] Tester 2026-11-06 (a tester: "When the response has a table, it would be better to expand the width
    /// of the bubble to use almost all the available space", a 3-column table beside Hermes Desktop's): a reply's table
    /// may reach the column's edges where the reply's words stop at `replyWidth` (the Mac's 728 in its 1280 column).
    /// The words keep their width; only the bubble round a wider table grows.
    static func tableReplyWidth(_ width: CGFloat) -> CGFloat { width - 2 * ChatMetrics.sideInset }

    static func maxBubbleWidth(mine: Bool, width: CGFloat, style: ChatStyle) -> CGFloat {
        let column = width - 2 * ChatMetrics.sideInset
        if !mine { return replyWidth(width) }
        return style.isAccessibilitySize ? column * 0.9 : min(column * ChatMetrics.userMaxFraction, ChatMetrics.userMaxWidth)
    }

    /// Lays `text` out at `width` as one or more pieces stacked from y = 0 (see `TextPiece`). Returns the pieces, the
    /// widest piece's width, the total height and the last line's trailing edge. Text that is right-to-left throughout
    /// (its lines all start in from the left, natural alignment) is hugged: the pieces move left by where its leftmost
    /// line starts (`shift`), so a short Arabic or Hebrew reply gets a bubble as wide as its words, not the column.
    static func pieces(_ text: NSAttributedString, width: CGFloat?, keep: Bool)
        -> (pieces: [TextPiece], width: CGFloat, height: CGFloat, lastLineMaxX: CGFloat, lastBaseline: CGFloat, shift: CGFloat) {
        let parts = TextSplit.split(text, maxLength: pieceLength)
        var out: [TextPiece] = []
        out.reserveCapacity(parts.count)
        var y: CGFloat = 0, w: CGFloat = 0, lastMaxX: CGFloat = 0, baseline: CGFloat = 0
        var shift = CGFloat.greatestFiniteMagnitude
        for (i, part) in parts.enumerated() {
            if i > 0 { y += part.gapBefore }
            let tk = TextKitLayout(part.text, width: width)
            if keep { TextKitPool.offer(tk, width: width) }
            out.append(TextPiece(text: part.text, frame: CGRect(x: 0, y: y, width: tk.size.width, height: tk.size.height)))
            baseline = y + tk.lastBaseline
            y += tk.size.height
            w = max(w, tk.size.width)
            lastMaxX = tk.lastLineMaxX
            shift = min(shift, tk.inkMinX)
        }
        if shift == .greatestFiniteMagnitude || shift < 0.5 || !naturallyAligned(text) { shift = 0 }
        if shift > 0 {
            for i in out.indices { out[i].frame.origin.x -= shift }
            w -= shift
            lastMaxX -= shift
        }
        return (out, w, y, lastMaxX, baseline, shift)
    }

    /// Every paragraph keeps its natural alignment (a centred formula's or a right-aligned line's start is its own).
    private static func naturallyAligned(_ text: NSAttributedString) -> Bool {
        var natural = true
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if let p = value as? NSParagraphStyle, p.alignment != .natural && p.alignment != .justified { natural = false; stop.pointee = true }
        }
        return natural
    }

    /// [groups] A room's typing row: a 28 pt face and 6 pt before the capsule (§7.12).
    static let senderColumn: CGFloat = 34
    static let senderFace: CGFloat = 28
    /// A sender's face on its name line, before the name (owner, 2026-10-14: no face column pushing replies in).
    static let nameFace: CGFloat = 20
    static let nameFaceGap: CGFloat = 6
    /// [desktoplook] A reply's side padding: none in the look, where its bubble is not drawn.
    static func sidePad(mine: Bool) -> CGFloat { !mine && HQShape.plainReplies ? 0 : ChatMetrics.bubblePadH }
    /// [groups] A sender's name over their message: the notice's size (which already carries UI Scale), semibold. With
    /// `system` the scale went on twice and the name came out bigger than the message under it (Mac polish #71).
    static func senderNameFont(_ style: ChatStyle) -> UIFont { HQFont.face(ofSize: style.notice.pointSize, weight: .semibold) }

    /// [groups] An incoming bubble of a chat with senders: laid out as ever, then the sender's face and name as the
    /// first line of its text column.
    private static func senderBubble(_ b: BubbleRow, row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool) -> RowLayout {
        let padH = sidePad(mine: false)
        var layout = bubble(b, row: row, width: width, style: style, keep: keep)
        guard case .bubble(var box) = layout.content else { return layout }
        var label = b.showsSenderName ? b.sender?.name : b.byline
        // [transcript] A cron delivery names its job after its bot, on every one (a job is not a run of one speaker).
        if let job = b.job, let name = b.sender?.name { label = CronDeliveries.header(sender: name, job: job) }
        if let label, !label.isEmpty, box.memo == nil, !box.mediaOnly, box.mediaGroups.isEmpty, box.fileRows.isEmpty {
            let font = senderNameFont(style)
            let face = b.showsSenderName ? b.sender : b.bylineSender
            // The face grows with the name's text size (a dot beside a huge name at AX5 read as nothing), up to 28 pt.
            let faceSide = min(senderFace, max(nameFace, ceil(font.lineHeight)))
            let faceW = face == nil ? 0 : faceSide + nameFaceGap
            let lineH = max(ceil(font.lineHeight), face == nil ? 0 : faceSide)
            let maxText = maxBubbleWidth(mine: false, width: width, style: style) - 2 * padH
            let nameW = min(maxText - faceW, ceil((label as NSString).size(withAttributes: [.font: font]).width))
            let shift = lineH + 2
            for i in box.blocks.indices { box.blocks[i].frame.origin.y += shift }
            box.timeFrame.origin.y += shift
            if var more = box.showMoreFrame { more.origin.y += shift; box.showMoreFrame = more }
            let wider = max(box.frame.width, faceW + nameW + 2 * padH)
            box.timeFrame.origin.x += wider - box.frame.width
            box.frame.size.width = wider
            box.frame.size.height += shift
            box.shape.width = box.frame.width
            box.shape.height = box.frame.height
            box.senderName = label
            box.senderNameFrame = CGRect(x: padH + faceW, y: ChatMetrics.bubblePadV - 1, width: nameW, height: lineH)
            if let face {
                box.faceFrame = CGRect(x: box.frame.minX + padH, y: box.frame.minY + ChatMetrics.bubblePadV - 1 + (lineH - faceSide) / 2,
                                       width: faceSide, height: faceSide)
                box.faceSender = face
            }
            box.senderColorHex = b.showsSenderName ? b.sender?.colorHex : nil
            layout.height += shift
        }
        layout.content = .bubble(box)
        return layout
    }

    private static func bubble(_ b: BubbleRow, row: ChatRow, width: CGFloat, style: ChatStyle, keep: Bool) -> RowLayout {
        // [attachments] your photos and files, a generated image (docs/spec/1x-attachments.md §7.3, §7.7)
        if !b.media.isEmpty || !b.files.isEmpty { return AttachmentBubbleLayout.bubble(b, row: row, width: width, style: style, keep: keep) }
        if let memo = b.memo { return MemoBubbleLayout.make(b, memo: memo, row: row, width: width, style: style) }   // VOICE
        let rendered = rendered(b, row: row, style: style)
        // [attachments] a reply part of images only draws like a photo-only bubble (spec §7.5)
        if !b.mine, let photos = AttachmentBubbleLayout.photoOnlyReply(rendered, b, row: row, width: width, style: style) { return photos }
        var maxBubble = maxBubbleWidth(mine: b.mine, width: width, style: style)
        let padH = sidePad(mine: b.mine)
        let maxText = maxBubble - 2 * padH
        // [wide-tables] A reply's table may be as wide as the column (`tableReplyWidth`); the words stay at `maxText`.
        let maxTable = b.mine ? maxText : max(maxText, tableReplyWidth(width) - 2 * padH)
        // [desktoplook] Your own message carries no time in the look: no room is kept for one (HQShape.showsTime).
        let timeText = HQShape.showsTime(mine: b.mine) ? b.time.map(ChatRowBuilder.clock) : nil
        let timeAttr: NSAttributedString? = timeText.map {
            NSAttributedString(string: $0, attributes: [.font: style.time, .foregroundColor: b.mine ? ChatPalette.meTime : ChatPalette.label2])
        }
        let timeSize = timeAttr.map { CGSize(width: ceil($0.size().width), height: style.timeLineHeight) } ?? .zero
        // Clear of a round corner (Theme › Bubble Corners); a plain reply has no corner.
        let timeShift = timeAttr == nil || padH == 0 ? 0 : ChatMetrics.timeShift(mine: b.mine, joinsBelow: b.joinsBelow, tail: b.tail)
        let reserve = timeAttr == nil ? 0 : timeSize.width + ChatMetrics.timeReserveGap + timeShift

        var placed: [PlacedBlock] = []
        var y: CGFloat = 0
        var contentWidth: CGFloat = 0
        /// [mac] The widest text (cards left out), and whether the reply ends in text: a plain reply's time (`timeFrame`).
        var proseWidth: CGFloat = 0
        var endsInText = false
        var fullWidth = false
        var extraTimeLine: CGFloat = 0
        var showMore = false
        /// [mac-audit] The last text line's baseline (the time's line when it wraps under it), for a plain reply's time.
        var timeBaseline: CGFloat?
        let blocks = rendered.blocks.isEmpty ? [MarkdownBlock.text(NSAttributedString(string: " ", attributes: [.font: style.body]))] : rendered.blocks
        for (i, block) in blocks.enumerated() {
            if i > 0 { y += style.paragraphGap }
            let isLast = i == blocks.count - 1
            switch block {
            case .text(let s):
                let laid = pieces(s, width: maxText, keep: keep)
                var w = laid.width, h = laid.height
                var visibleH = laid.height
                // Your long message clamps at 10 lines (spec 06 §2.1); "Show More" and the time share a line under it.
                let clampH = style.bodyLineHeight * CGFloat(ChatMetrics.userClampLines) + 2
                if b.mine && !b.expanded && blocks.count == 1 && laid.height > clampH + 0.5 {
                    visibleH = clampH
                    h = clampH
                    showMore = true
                } else if isLast && reserve > 0 {
                    if laid.lastLineMaxX + reserve <= maxText { w = max(w, laid.lastLineMaxX + reserve); timeBaseline = y + laid.lastBaseline }
                    else { h += style.bodyLineHeight; w = max(w, reserve); timeBaseline = y + laid.lastBaseline + style.bodyLineHeight }
                }
                var p = PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: w, height: h),
                                    textFrame: CGRect(x: 0, y: 0, width: laid.width, height: visibleH),
                                    contentWidth: laid.width, contentHeight: laid.height, layoutWidth: maxText,
                                    pieces: laid.pieces, codeOpen: nil, fadesBottom: showMore)
                p.trailingAligned = laid.shift > 0
                placed.append(p)
                contentWidth = max(contentWidth, w)
                proseWidth = max(proseWidth, w)
                endsInText = isLast
                y += h
            case .quote(let s, let alert):
                // Inside a list item it sits under the item's text (`RenderedMarkdown.indents`).
                let listIndent = min(rendered.indents[i] ?? 0, maxText / 3)
                let blockMax = maxText - listIndent
                defer { if listIndent > 0, !placed.isEmpty { placed[placed.count - 1].frame.origin.x += listIndent } }
                if alert != nil {
                    let pad: CGFloat = 10
                    let titleH = ceil(HQFont.scaled(13, weight: .semibold, like: .footnote, cap: 22, category: style.category).lineHeight) + 4
                    let laid = pieces(s, width: blockMax - 2 * pad, keep: keep)
                    let h = pad + titleH + laid.height + pad
                    placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: blockMax, height: h),
                                              textFrame: CGRect(x: pad, y: pad + titleH, width: laid.width, height: laid.height),
                                              contentWidth: laid.width, contentHeight: laid.height, layoutWidth: blockMax - 2 * pad,
                                              pieces: laid.pieces, codeOpen: nil))
                    fullWidth = true
                    y += h
                } else {
                    let indent: CGFloat = 12
                    let laid = pieces(s, width: blockMax - indent, keep: keep)
                    let w = laid.width + indent
                    placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: w, height: laid.height),
                                              textFrame: CGRect(x: indent, y: 0, width: laid.width, height: laid.height),
                                              contentWidth: laid.width, contentHeight: laid.height, layoutWidth: blockMax - indent,
                                              pieces: laid.pieces, codeOpen: nil))
                    contentWidth = max(contentWidth, w + listIndent)
                    y += laid.height
                }
            case .code(let label, _, let s, let lines):
                let listIndent = min(rendered.indents[i] ?? 0, maxText / 3)
                let blockMax = maxText - listIndent
                defer { if listIndent > 0, !placed.isEmpty { placed[placed.count - 1].frame.origin.x += listIndent } }
                // "Compact" (no label, under 3 lines) centres its text across the whole card, the same band the copy
                // button sits in, with trailing room reserved to clear it. A line long enough to scroll sideways stays
                // compact: it scrolls in that room and fades out short of the button (`updateEdgeFade`). It had moved
                // to the labelled cards' layout (n20 revisit, 2026-10-31: the line met the button), under a strip that
                // held only the button and read as a card missing its label (Mac polish #73).
                let compact = label == nil && lines < 3
                let strip = compact ? 0 : ChatMetrics.codeStrip
                let trailing = compact ? ChatMetrics.codeCompactTrailing : ChatMetrics.codePadH
                let textWidth = blockMax - ChatMetrics.codePadH - trailing
                let codeWidth: CGFloat? = ChatRenderOptions.codeBlocksWrap ? textWidth : nil
                var laid = pieces(s, width: codeWidth, keep: keep)
                let padV = ChatMetrics.codePadV
                // Code wider than the card scrolls sideways; its bar runs under the last line, not on it (owner
                // 2026-10-29). The Mac's scroller is taller than the 10 pt pad.
                let below = laid.width > textWidth + 0.5 ? max(padV, ScrollBarLane.height) : padV
                var h: CGFloat
                var area: CGFloat
                var open: Bool?
                let content = padV + laid.height + below
                if compact {
                    h = max(content, ChatMetrics.codeCompactMinHeight)
                    area = h
                    // Centred in the room over the bar's lane.
                    let top = ((h - laid.height - (below - padV)) / 2).rounded()
                    for p in laid.pieces.indices { laid.pieces[p].frame.origin.y += top }
                } else {
                    // The code area clamps at 120 pt; open, at 40 % of the screen, scrolling inside (spec 06 §2.6).
                    if content > ChatMetrics.codeClamp + 1 {
                        let isOpen = b.openCode.contains(i)
                        open = isOpen
                        area = isOpen ? min(content, max(ChatMetrics.codeClamp, (screenHeight * 0.4).rounded())) : ChatMetrics.codeClamp
                    } else {
                        area = content
                    }
                    h = strip + area
                    for p in laid.pieces.indices { laid.pieces[p].frame.origin.y += padV }
                }
                placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: blockMax, height: h),
                                          textFrame: CGRect(x: ChatMetrics.codePadH, y: strip, width: min(laid.width, textWidth), height: area),
                                          contentWidth: laid.width, contentHeight: compact ? area : content, layoutWidth: codeWidth,
                                          pieces: laid.pieces, codeOpen: open))
                fullWidth = true
                y += h
            case .table(let table):
                // A grid that scrolls sideways when wider than the bubble (spec 03 §9.5), on a card whose footer (the
                // row count and Expand, which opens the Table page: docs/spec/3x-transcript.md §3.4, L309) never
                // scrolls, so no control sits over the cells (owner 2026-10-29: the Expand glyph on the header row
                // "meshed together with the text"). Every table has it, so it never comes and goes.
                let laid = tableGrid(table, style: style, keep: keep, minWidth: ChatMetrics.tableStripMinWidth)
                let size = laid.grid.size
                let footer = ChatMetrics.tableFooter(style)
                let w = min(maxTable, size.width)
                if w > maxText { maxBubble = max(maxBubble, w + 2 * padH) }
                placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: w, height: size.height + footer),
                                          textFrame: CGRect(x: 0, y: 0, width: w, height: size.height),
                                          contentWidth: size.width, contentHeight: size.height, layoutWidth: nil,
                                          pieces: laid.pieces, codeOpen: nil, grid: laid.grid))
                contentWidth = max(contentWidth, w)
                y += size.height + footer
            case .linkChip:
                // [transcript] A fixed size from the start (§3.7): the title and icon land without moving anything.
                let w = LinkChipView.width(maxText: maxText), h = LinkChipView.height(style: style)
                y += 6
                placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: w, height: h), textFrame: .zero,
                                          contentWidth: w, contentHeight: h, layoutWidth: nil, pieces: [], codeOpen: nil))
                contentWidth = max(contentWidth, w)
                y += h
            case .pageCard:
                let w = PageCardView.width(maxText: maxText), h = PageCardView.height(style: style)
                y += 6
                var p = PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: w, height: h), textFrame: .zero,
                                    contentWidth: w, contentHeight: h, layoutWidth: nil, pieces: [], codeOpen: nil)
                p.pageContext = b.mediaContext
                placed.append(p)
                contentWidth = max(contentWidth, w)
                y += h + 4
            case .spacer(let h):
                placed.append(PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: 0, height: h), textFrame: .zero,
                                          contentWidth: 0, contentHeight: 0, layoutWidth: nil, pieces: [], codeOpen: nil))
                y += h
            case .media(let refs):
                // [attachments] photos (album, ≤ 280 wide, radius 12) and file rows (spec §7.5)
                let laid = AttachmentBubbleLayout.mediaBlock(refs, context: b.mediaContext, maxText: maxText, mine: b.mine, style: style,
                                                             reserve: isLast ? reserve : 0, unavailable: b.mediaUnavailable,
                                                             sizes: b.mediaSizes)
                var p = PlacedBlock(block: block, frame: CGRect(x: 0, y: y, width: laid.size.width, height: laid.size.height), textFrame: .zero,
                                    contentWidth: laid.size.width, contentHeight: laid.size.height, layoutWidth: nil, pieces: [], codeOpen: nil)
                p.media = laid.media
                placed.append(p)
                contentWidth = max(contentWidth, laid.size.width)
                y += laid.size.height
            }
            // [attachments] a reply ending in file rows keeps the time on the last row's line (no extra line)
            let endsInRows: Bool = { if case .media = block, placed.last?.media?.rows.isEmpty == false { return true } else { return false } }()
            if isLast && !endsInRows && (showMore || (reserve > 0 && !block.isProse)) {
                // A code card, table or quote ends the text, or your message is clamped: the time (and Show More)
                // take their own line under it.
                extraTimeLine = style.timeLineHeight + 9 - ChatMetrics.bubblePadV + 1 + timeShift
                contentWidth = max(contentWidth, reserve)
            }
        }
        // Your long message clamps at 10 lines however it is made (spec 06 §2.1): one that opens with a quote (Swipe
        // to Reply) or holds a code card stops at the same height. Blocks past it wait for Show More; text or a quote
        // that crosses it is cut there with its last line faded; a card that crosses it shows whole.
        let clampLimit = style.bodyLineHeight * CGFloat(ChatMetrics.userClampLines) + 2
        if b.mine && !b.expanded && !showMore && y > clampLimit + 0.5 {
            var kept = placed.filter { $0.frame.minY < clampLimit }
            if var last = kept.last, last.frame.maxY > clampLimit + 0.5 {
                switch last.block {
                case .text, .quote(_, alert: nil):
                    let room = clampLimit - last.frame.minY
                    last.frame.size.height = room
                    last.textFrame.size.height = min(last.textFrame.height, max(0, room - last.textFrame.minY))
                    last.fadesBottom = true
                    kept[kept.count - 1] = last
                default:
                    break
                }
            }
            if let last = kept.last, kept.count < placed.count || last.fadesBottom {
                placed = kept
                y = last.frame.maxY
                showMore = true
                endsInText = false
                timeBaseline = nil
                extraTimeLine = style.timeLineHeight + 9 - ChatMetrics.bubblePadV + 1 + timeShift
                contentWidth = max(contentWidth, reserve)
            }
        }
        // [desktoplook] A plain reply is the whole column (no bubble is drawn): its time sits at the column's trailing
        // edge, bottom right, not just after the text's last line (owner: "the time should be bottom right").
        let plainReply = padH == 0 && timeAttr != nil
        // [mac] Stress test 2026-10-28 #25: the Mac's reply column is 728 pt, so a short reply's time sat far out at its
        // edge, apart from the words. There the reply is as wide as its text and the time is still bottom right: after
        // the last line, or under it at the widest line's end (Telegram's place, which the owner's note asked for).
        if fullWidth || (plainReply && !DeviceWord.isMac) { contentWidth = max(contentWidth, maxText) }
        var showMoreWidth: CGFloat = 0
        if showMore {
            let more = NSAttributedString(string: "Show More", attributes: [.font: style.timeBold])
            showMoreWidth = max(44, ceil(more.size().width) + 20)
            contentWidth = max(contentWidth, showMoreWidth + reserve)
        }
        let bubbleW = ceil(min(maxBubble, contentWidth + 2 * padH))
        let bubbleH = ceil(y + 2 * ChatMetrics.bubblePadV + extraTimeLine)
        let gap = max(0, row.gapAbove)
        let x = b.mine ? width - ChatMetrics.sideInset - bubbleW : ChatMetrics.sideInset
        // Offset blocks by the bubble padding.
        for i in placed.indices {
            placed[i].frame.origin.x += padH
            placed[i].frame.origin.y += ChatMetrics.bubblePadV
            // [wide-tables] Cards as wide as the words' width stretch to the bubble (a wide table's, too); the words don't.
            if placed[i].frame.width >= maxText - 0.5 {
                let was = placed[i].frame.width
                placed[i].frame.size.width = placed[i].block.isProse ? min(placed[i].frame.width, bubbleW - 2 * padH) : bubbleW - 2 * padH
                // A code card's text area grows with it, so a long line scrolls out to the card's copy button, not
                // fading halfway across the wider card (Mac polish #76).
                if case .code = placed[i].block, placed[i].frame.width > was + 0.5 {
                    placed[i].textFrame.size.width = min(placed[i].contentWidth, placed[i].textFrame.width + placed[i].frame.width - was)
                }
            }
            // Right-to-left words keep to the bubble's right edge when a wider block (a code card) widened it.
            let room = bubbleW - 2 * padH - placed[i].frame.width
            if placed[i].trailingAligned, room > 0.5 {
                placed[i].frame.size.width += room
                placed[i].textFrame.origin.x += room
            }
        }
        // [mac] Stress test 2026-10-31 (#25 again): a code card or table as wide as the column carried the time of the
        // text under it out to the card's edge, 500 pt from "That starts both.". A plain reply that ends in text keeps
        // its time at that text's widest line, cards left out.
        let timeEdge = plainReply && DeviceWord.isMac && endsInText && proseWidth > 0 ? min(bubbleW, proseWidth) : bubbleW
        var timeFrame = CGRect(x: timeEdge - (plainReply ? 0 : ChatMetrics.timeTrailing + timeShift) - timeSize.width,
                               y: bubbleH - ChatMetrics.timeBottom - timeShift - timeSize.height, width: timeSize.width, height: timeSize.height)
        // [mac-audit] Owner 2026-11-02 (Mac audit #26, d6): with no bubble round it, a plain reply's time hung 5–7 pt
        // below the words beside it (it sat on the bubble's bottom padding, which the look doesn't draw). It sits on
        // the last line's baseline instead. The label centres its one line in its frame, so its baseline is that
        // much down plus the font's ascender.
        if plainReply, endsInText, let timeBaseline {
            let font = style.time
            let labelBaseline = (timeSize.height - font.lineHeight) / 2 + font.ascender
            timeFrame.origin.y = (ChatMetrics.bubblePadV + timeBaseline - labelBaseline).rounded()
        }
        let shape = BubbleShape.Key(width: bubbleW, height: bubbleH, mine: b.mine, joinsAbove: b.joinsAbove,
                                    joinsBelow: b.joinsBelow, tail: b.tail)
        // Show More: 2 pt in from the bubble's padding edge, on the bottom line, a 44 pt target (spec 06 §2.1).
        let showMoreFrame: CGRect? = showMore ? CGRect(x: 3, y: bubbleH - 1 - 44, width: showMoreWidth, height: 44) : nil
        let layout = BubbleLayout(frame: CGRect(x: x, y: gap, width: bubbleW, height: bubbleH), shape: shape, mine: b.mine,
                                  blocks: placed, timeText: timeText, timeFrame: timeFrame,
                                  // A send is never drawn faded (spec 06 §5.2 "no fade"; §5.6.4: nothing for 2 s, then
                                  // "Sending…" under it). The pending flag isn't in the row's fingerprint either, so a
                                  // dimmed layout outlived the acknowledgement.
                                  dimmed: false,
                                  copyText: rendered.plainText, showMoreFrame: showMoreFrame)
        return RowLayout(height: gap + bubbleH, content: .bubble(layout))
    }

    /// Cells laid out unbounded (one line each; `<br>` breaks lines), columns as wide as their widest cell, rows as tall
    /// as their tallest; 6 × 10 pt cell padding, top-aligned (spec 03 §9.5). A right or centred column (or a column of
    /// numbers, `MarkdownTable.alignment`) places each cell in it (the text itself is laid out leading).
    /// `minWidth`: a narrower table's last column grows to it (the card's footer needs the room).
    static func tableGrid(_ table: MarkdownTable, style: ChatStyle, keep: Bool, minWidth: CGFloat = 0) -> (pieces: [TextPiece], grid: TableGrid) {
        let columns = table.columnCount
        let all = [table.header] + table.rows
        let padH = ChatMetrics.tableCellPadH, padV = ChatMetrics.tableCellPadV
        var layouts: [[TextKitLayout?]] = []
        var widths = Array(repeating: CGFloat(12), count: columns)
        var heights: [CGFloat] = []
        let emptyHeight = ceil(style.tableLineHeight)
        for row in all {
            var line: [TextKitLayout?] = []
            var h: CGFloat = 0
            for c in 0..<columns {
                guard c < row.count, row[c].length > 0 else { line.append(nil); continue }
                let tk = TextKitLayout(row[c], width: nil)
                if keep { TextKitPool.offer(tk, width: nil) }
                widths[c] = max(widths[c], tk.size.width)
                h = max(h, tk.size.height)
                line.append(tk)
            }
            layouts.append(line)
            heights.append((h > 0 ? h : emptyHeight) + 2 * padV)
        }
        widths = widths.map { ceil($0) }
        let total = widths.reduce(0) { $0 + $1 + 2 * padH }
        if total < minWidth, !widths.isEmpty { widths[widths.count - 1] += minWidth - total }
        var xs: [CGFloat] = [0]
        for w in widths { xs.append(xs.last! + w + 2 * padH) }
        var ys: [CGFloat] = [0]
        for h in heights { ys.append(ys.last! + ceil(h)) }
        var pieces: [TextPiece] = []
        for (r, line) in layouts.enumerated() {
            for (c, tk) in line.enumerated() {
                guard let tk else { continue }
                let free = widths[c] - tk.size.width
                let align = table.alignment(c)
                let shift = align == .right ? free : align == .center ? (free / 2).rounded() : 0
                pieces.append(TextPiece(text: tk.text, frame: CGRect(x: xs[c] + padH + shift, y: ys[r] + padV,
                                                                     width: tk.size.width, height: tk.size.height)))
            }
        }
        return (pieces, TableGrid(columns: xs, rows: ys))
    }

    // MARK: Tool rows

    private static func toolRow(title: String, glyph: ChatGlyph, meta: String?, metaIsError: Bool, live: Bool, expanded: Bool,
                                single: Bool, steps: [ToolCall], thought: String?, gap: CGFloat, width: CGFloat,
                                style: ChatStyle, thoughtLinks: ResultLinks = .none, capsSteps: Bool = false,
                                asked: String = "", centered: Bool = false) -> RowLayout {
        let lineH = ceil((centered ? style.notice : style.tool).lineHeight)
        // A negative gap pulls the row into its neighbour's padding (adjacent runs read as one list).
        let topPad = ChatMetrics.toolRowPadV + min(0, gap)
        let rowH = max(ChatMetrics.toolRowMin + min(0, gap), topPad + lineH + ChatMetrics.toolRowPadV)
        let top = max(0, gap)
        // [updates] A group's line spans the chat (the cell centres its words in it).
        let rowFrame = CGRect(x: ChatMetrics.sideInset, y: top, width: centered ? width - 2 * ChatMetrics.sideInset : replyWidth(width),
                              height: rowH)
        // [updates] Open or shut, a centred line keeps its whole row, so its press highlight is the same pill both ways;
        // its card follows 4 pt under that row (owner, 2026-10-30: cut 4 pt under the words, the highlight lay over the
        // card). An opened group's members are the rows after it (UpdateMemberCell.swift).
        var height = top + rowH
        var cardFrame = CGRect.zero
        var stepLines: [(String, String?, CGRect, Bool, Bool)] = []
        var thoughtTK: TextKitLayout?
        var thoughtFrame = CGRect.zero
        var firstStep = 0
        var showAllFrame: CGRect?, showLessFrame: CGRect?
        if expanded {
            // [updates] Under a centred line the card is centred too (on the Mac it sat at the column's left, under a line
            // centred in the whole width), 4 pt under it.
            let cardW = centered ? UpdateMemberLayouts.cardWidth(width) : replyWidth(width)
            let cardX = centered ? UpdateMemberLayouts.cardX(width) : ChatMetrics.sideInset
            var y: CGFloat = 0
            if let thought {
                let tk = TextKitLayout(askedText(asked, then: resultText(thought, links: thoughtLinks, style: style), style: style),
                                       width: cardW - 24)
                thoughtTK = tk
                thoughtFrame = CGRect(x: 12, y: 10, width: tk.size.width, height: tk.size.height)
                y = 10 + tk.size.height + 10
            }
            do {   // One Line opens on its thought and its steps together; other rows have one or the other
                let stepH = max(ChatMetrics.stepMinHeight, ChatMetrics.stepPadV * 2 + lineH)
                // A long opened One Line card (past 12 steps) keeps its last 10: the rest are a row away in the Steps
                // sheet, and "Show Less" under them closes it without a scroll back to the line.
                let capped = capsSteps && steps.count > 12
                if capped {
                    firstStep = steps.count - 10
                    showAllFrame = CGRect(x: 12, y: y, width: cardW - 24, height: stepH)
                    y += stepH
                }
                for call in steps[firstStep...] {
                    let stepTitle = ChatRunSummary.summarize([call], live: live && call.state == .running)
                    stepLines.append((stepTitle, call.state == .failed ? "Failed" : nil,
                                      CGRect(x: 12, y: y, width: cardW - 24, height: stepH), call.state == .failed,
                                      call.state == .running))
                    y += stepH
                }
                if capped {
                    showLessFrame = CGRect(x: 12, y: y, width: cardW - 24, height: stepH)
                    y += stepH
                }
            }
            if centered {
                // 4 pt under its line's row, as an opened group's card is.
                cardFrame = CGRect(x: cardX, y: height + 4, width: cardW, height: ceil(y))
                height = cardFrame.maxY + UpdateMemberLayouts.after
            } else {
                cardFrame = CGRect(x: cardX, y: height + 2, width: cardW, height: ceil(y))
                height += 2 + ceil(y) + 8
            }
        }
        var layout = ToolRowLayout(rowFrame: rowFrame, title: title, glyph: glyph, meta: meta, metaIsError: metaIsError,
                                   live: live, expanded: expanded, single: single, cardFrame: cardFrame,
                                   steps: stepLines.map { (title: $0.0, meta: $0.1, frame: $0.2, failed: $0.3, live: $0.4) },
                                   thoughtText: thoughtTK, thoughtFrame: thoughtFrame)
        layout.firstStep = firstStep
        layout.stepCount = steps.count
        layout.showAllFrame = showAllFrame
        layout.showLessFrame = showLessFrame
        return RowLayout(height: ceil(height), content: .tool(layout))
    }

    /// What in an opened card's text opens: nothing (a thought), written-out web addresses (a process's log), or those
    /// and Markdown links as their words (a report or another bot's message).
    /// `formatted`: an update's words as the chat writes a reply (paragraphs, lists, code), in the body face.
    enum ResultLinks { case none, addresses, markdown, formatted }

    /// An opened card's text in the row's face and label-2, its links in the tint and tappable (`.chatLink`). Only http
    /// and https addresses open; other link words stay plain text.
    static func resultText(_ text: String, links: ResultLinks, style: ChatStyle) -> NSAttributedString {
        if links == .formatted { return formattedResult(text, style: style) }
        let plain: [NSAttributedString.Key: Any] = [.font: style.tool, .foregroundColor: ChatPalette.label2]
        guard links != .none else { return NSAttributedString(string: text, attributes: plain) }
        func web(_ url: URL?) -> URL? {
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        var linked = plain
        linked[.foregroundColor] = ChatPalette.tintText
        let out = NSMutableAttributedString()
        let ns = text as NSString
        var at = 0
        if links == .markdown {
            // "[words](address)": the words, opening the address.
            for m in BackgroundResults.markdownLink.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out.append(NSAttributedString(string: ns.substring(with: NSRange(location: at, length: m.range.location - at)), attributes: plain))
                let words = ns.substring(with: m.range(at: 1))
                if let url = web(URL(string: ns.substring(with: m.range(at: 2)))), !words.isEmpty {
                    linked[.chatLink] = url
                    out.append(NSAttributedString(string: words, attributes: linked))
                } else {
                    out.append(NSAttributedString(string: words, attributes: plain))
                }
                at = m.range.location + m.range.length
            }
        }
        out.append(NSAttributedString(string: ns.substring(from: at), attributes: plain))
        // Web addresses written out in full ("https://…"), not inferred from a bare "example.com".
        if let detector = resultLinkDetector {
            let string = out.string as NSString
            for match in detector.matches(in: out.string, range: NSRange(location: 0, length: string.length)) {
                guard let url = web(match.url), string.substring(with: match.range).lowercased().hasPrefix("http"),
                      out.attribute(.chatLink, at: match.range.location, effectiveRange: nil) == nil else { continue }
                out.addAttributes([.chatLink: url, .foregroundColor: ChatPalette.tintText], range: match.range)
            }
        }
        return out
    }

    /// [updates] An opened update in the reply's own type and Markdown, not a block of small grey text (owner,
    /// 2026-10-27: "the text inside these needs to be formatted in some way that makes them legible"). Tables read as
    /// lines; pictures stay in the chat they came from.
    private static func formattedResult(_ text: String, style: ChatStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let gap = NSAttributedString(string: "\n", attributes: [.font: style.body])
        for block in MarkdownRenderer.render(text, style: style, filePaths: true).blocks {   // a path the bot names opens in Files
            let piece: NSAttributedString?
            switch block {
            case .text(let s), .quote(let s, _): piece = s
            case .code(_, _, let s, _): piece = s
            case .table(let t):
                let lines = ([t.header] + t.rows).map { $0.map(\.string).joined(separator: " · ") }
                piece = NSAttributedString(string: lines.joined(separator: "\n"),
                                           attributes: [.font: style.body, .foregroundColor: ChatPalette.label])
            case .spacer, .media, .linkChip, .pageCard: piece = nil
            }
            guard let piece, piece.length > 0 else { continue }
            if out.length > 0 { out.append(gap) }
            out.append(piece)
        }
        return out
    }

    /// [btw] A /btw card's question over its answer: the row's face in the secondary ink, as a question quoted above a
    /// reply (Mac polish #25). No question: the answer as it is.
    static func askedText(_ asked: String, then answer: NSAttributedString, style: ChatStyle) -> NSAttributedString {
        guard !asked.isEmpty else { return answer }
        let out = NSMutableAttributedString(string: asked, attributes: [.font: style.tool, .foregroundColor: ChatPalette.label2])
        guard answer.length > 0 else { return out }
        out.append(NSAttributedString(string: "\n", attributes: [.font: style.body]))
        out.append(answer)
        return out
    }

    private static let resultLinkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    // MARK: Error card

    private static func errorCard(_ e: ErrorRow, gap: CGFloat, width: CGFloat, style: ChatStyle) -> RowLayout {
        let cardW = replyWidth(width)
        let pad: CGFloat = 12
        let textX = pad + 18 + 8
        // The heading leaves room for the ✕ (a 44 pt target at its trailing end, spec 06 §5.6.1).
        let close: CGFloat = 44
        let titleW = cardW - textX - close + 4
        let textW = cardW - textX - pad
        let title = TextKitLayout(NSAttributedString(string: e.title, attributes: [.font: style.errorTitle, .foregroundColor: ChatPalette.label]),
                                  width: titleW)
        let reason = TextKitLayout(NSAttributedString(string: e.reason, attributes: [.font: style.errorBody, .foregroundColor: ChatPalette.label2]),
                                   width: textW)
        let titleH = title.size.height
        let reasonY = pad + titleH + 4
        // The actions: a column across the card, 44 pt buttons 4 pt apart, the primary recovery first as a tint capsule
        // ("Retry"), then a borderless "Details" (spec 06 §5.6.1; the web's `[data-ios-error-primary]` stretches them).
        let columnW = cardW - 2 * pad
        // At least 44 pt, and taller once the words need it: the cell draws one line of `errorBody` with 10 pt above
        // and below it (at the largest sizes a fixed 44 pt let the words spill over the button under it).
        let buttonH = max(44, ceil(style.errorBody.lineHeight) + 20)
        var y = reasonY + reason.size.height + 8
        var retryFrame: CGRect?
        var detailsFrame = CGRect(x: pad, y: y, width: columnW, height: buttonH)
        // [ui-sizing 2026-11-09] Both actions side by side when each half has room for its word ("Choose a Model" the
        // longest): two full-width 44 pt buttons stacked made a two-line error the tallest card in the chat.
        let half = (columnW - 8) / 2
        let longest = ("Choose a Model" as NSString).size(withAttributes: [.font: style.errorBody]).width + 32
        if e.retry || e.chooseModel {
            if half >= longest {
                retryFrame = CGRect(x: pad, y: y, width: half, height: buttonH)
                detailsFrame = CGRect(x: pad + half + 8, y: y, width: half, height: buttonH)
            } else {
                retryFrame = CGRect(x: pad, y: y, width: columnW, height: buttonH)
                y += buttonH + 4
                detailsFrame = CGRect(x: pad, y: y, width: columnW, height: buttonH)
            }
        }
        let cardH = detailsFrame.maxY + 4
        let top = max(0, gap)
        return RowLayout(height: ceil(top + cardH + 8), content: .error(ErrorLayout(
            cardFrame: CGRect(x: ChatMetrics.sideInset, y: top, width: cardW, height: ceil(cardH)),
            glyphFrame: CGRect(x: pad, y: pad + max(0, (min(titleH, ceil(style.errorTitle.lineHeight)) - 18) / 2), width: 18, height: 18),
            title: title, titleFrame: CGRect(x: textX, y: pad, width: titleW, height: titleH),
            reason: reason, reasonFrame: CGRect(x: textX, y: reasonY, width: textW, height: reason.size.height),
            copyText: e.details,
            closeFrame: CGRect(x: cardW - close, y: 0, width: close, height: close),
            detailsFrame: detailsFrame, retryFrame: retryFrame, chooseModel: e.chooseModel)))
    }
}

// MARK: - Splitting long text

/// Cuts attributed text into pieces of at most `maxLength` UTF-16 units, at paragraph ends ("\n") first, then line
/// ends (U+2028), then spaces, so each piece lays out exactly as it did inside the whole (fixed line heights).
nonisolated enum TextSplit {
    struct Part {
        var text: NSAttributedString
        /// Space above this piece: the paragraph spacing that sat between it and the previous piece.
        var gapBefore: CGFloat
    }

    static func split(_ text: NSAttributedString, maxLength: Int) -> [Part] {
        let length = text.length
        guard length > maxLength else { return [Part(text: text, gapBefore: 0)] }
        let ns = text.string as NSString
        var parts: [Part] = []
        var start = 0
        var gap: CGFloat = 0
        var continuesParagraph = false
        while start < length {
            if length - start <= maxLength {
                parts.append(Part(text: piece(text, NSRange(location: start, length: length - start), continuesParagraph), gapBefore: gap))
                break
            }
            let window = NSRange(location: start, length: maxLength)
            // The last paragraph end in the window, else the last line end, else the last space; else a hard cut.
            var cut = ns.range(of: "\n", options: .backwards, range: window).location
            var kind = 0
            if cut == NSNotFound || cut <= start {
                cut = ns.range(of: "\u{2028}", options: .backwards, range: window).location
                kind = 1
            }
            // One paragraph longer than a piece has to break early somewhere: between two sentences when one ends in
            // the window's second half, so the forced line end doesn't fall mid-sentence.
            if cut == NSNotFound || cut <= start {
                cut = lastMark([". ", "! ", "? "], in: ns, window: window, after: start + maxLength / 2).map { $0 + 1 } ?? NSNotFound
                kind = 2
            }
            if cut == NSNotFound || cut <= start {
                cut = ns.range(of: " ", options: .backwards, range: window).location
                kind = 2
            }
            if cut == NSNotFound || cut <= start, let end = lastMark(["。", "！", "？"], in: ns, window: window, after: start + maxLength / 2) {
                cut = end + 1   // Chinese and Japanese sentences have no space after them
                kind = 3
            }
            if cut == NSNotFound || cut <= start {
                cut = start + maxLength
                // Never inside one character as it's drawn: a surrogate pair, an accent, a flag or a family emoji.
                if cut < length {
                    let cluster = ns.rangeOfComposedCharacterSequence(at: cut)
                    if cluster.location > start, cluster.location < cut { cut = cluster.location }
                }
                kind = 3
            }
            parts.append(Part(text: piece(text, NSRange(location: start, length: cut - start), continuesParagraph), gapBefore: gap))
            switch kind {
            case 0:
                // A paragraph boundary: the gap is the previous paragraph's spacing after plus the next one's before.
                let before = text.attribute(.paragraphStyle, at: max(start, cut - 1), effectiveRange: nil) as? NSParagraphStyle
                let after = cut + 1 < length ? text.attribute(.paragraphStyle, at: cut + 1, effectiveRange: nil) as? NSParagraphStyle : nil
                gap = (before?.paragraphSpacing ?? 0) + (after?.paragraphSpacingBefore ?? 0)
                continuesParagraph = false
                start = cut + 1
            case 1, 2:
                gap = 0
                continuesParagraph = true
                start = cut + 1
            default:
                gap = 0
                continuesParagraph = true
                start = cut
            }
        }
        return parts
    }

    /// Where the last of `marks` starts in the window, when that is past `after`.
    private static func lastMark(_ marks: [String], in ns: NSString, window: NSRange, after: Int) -> Int? {
        let found = marks.map { ns.range(of: $0, options: .backwards, range: window).location }.filter { $0 != NSNotFound && $0 > after }
        return found.max()
    }

    /// The substring, with its first paragraph's spacing-before dropped (the caller adds it as a gap) and, when it
    /// continues a paragraph cut at a line end, the first line indented like the paragraph's other lines.
    private static func piece(_ text: NSAttributedString, _ range: NSRange, _ continuesParagraph: Bool) -> NSAttributedString {
        let sub = NSMutableAttributedString(attributedString: text.attributedSubstring(from: range))
        guard sub.length > 0, let style = sub.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return sub }
        guard style.paragraphSpacingBefore != 0 || (continuesParagraph && style.firstLineHeadIndent != style.headIndent) else { return sub }
        let fixed = style.mutableCopy() as! NSMutableParagraphStyle
        fixed.paragraphSpacingBefore = 0
        if continuesParagraph { fixed.firstLineHeadIndent = style.headIndent }
        // Only the first paragraph of the piece.
        let firstEnd = (sub.string as NSString).range(of: "\n").location
        let firstRange = NSRange(location: 0, length: firstEnd == NSNotFound ? sub.length : firstEnd + 1)
        sub.addAttribute(.paragraphStyle, value: fixed, range: firstRange)
        return sub
    }
}

// MARK: - TextKit pool

/// Laid-out text kept for drawing: the rows on and near the screen. Built on main when a cell needs one and isn't
/// pooled yet, or ahead of time off-main (prefetch). Keyed by the attributed string's identity (the entry retains it,
/// so the identity can't be reused) and the layout width.
nonisolated enum TextKitPool {
    struct Key: Hashable {
        let id: ObjectIdentifier
        let width: CGFloat?
    }
    static let cache = ChatCache<Key, TextKitLayout>(limit: 800)

    static func offer(_ layout: TextKitLayout, width: CGFloat?) {
        cache.set(Key(id: ObjectIdentifier(layout.text), width: width), layout)
    }

    static func pooled(_ text: NSAttributedString, width: CGFloat?) -> TextKitLayout? {
        guard let hit = cache.value(Key(id: ObjectIdentifier(text), width: width)), hit.text === text else { return nil }
        return hit
    }

    nonisolated(unsafe) static var mainThreadMisses = 0
    nonisolated(unsafe) static var mainThreadHits = 0

    /// The pooled layout, or a new one (stored).
    static func layout(_ text: NSAttributedString, width: CGFloat?) -> TextKitLayout {
        if let hit = pooled(text, width: width) {
            if Thread.isMainThread { mainThreadHits += 1 }
            return hit
        }
        if Thread.isMainThread { mainThreadMisses += 1 }
        let made = TextKitLayout(text, width: width)
        offer(made, width: width)
        return made
    }
}

/// The stopped row's Retry capsule (spec 06 §5.6.3, `.aui-error-action`): a 14 pt refresh glyph and an 11.5 pt label in
/// the accent, a 1 pt accent border at 35 %, no fill, padding 1.6 / 8.8 pt.
nonisolated enum RetryCapsuleMetrics {
    static let title = "Try Again"
    static let gap: CGFloat = 4.8
    static let padH: CGFloat = 8.8

    /// The glyph's box grows with the label (the text size, and the Mac's 13 pt floor) so the arrow keeps its 14 : 11.5.
    static func glyph(_ style: ChatStyle) -> CGFloat { max(14, (14 * font(style).pointSize / 11.5).rounded()) }
    static func font(_ style: ChatStyle) -> UIFont { HQFont.face(ofSize: HQFont.legible((11.5 * style.body.pointSize / 17).rounded(toPlaces: 1)), weight: .medium) }

    static func size(style: ChatStyle) -> CGSize {
        let f = font(style)
        let label = ceil((title as NSString).size(withAttributes: [.font: f]).width)
        let g = glyph(style)
        let height = max(g, ceil(f.lineHeight * 1.5)) + 4
        return CGSize(width: ceil(padH + g + gap + label + padH), height: height)
    }
}
