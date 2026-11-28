import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite("Minimal activity layout", .serialized)
struct ActivityPillLayoutTests {
    private func makeShelf() -> ActivityShelfView {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: ShelfPieceKind.allCases.map {
            .init(kind: $0, words: $0 == .tasks ? "Tasks 2/5" : "Category \($0.rawValue)", isRunning: $0 == .background)
        })
        for entry in shelf.summary.entries {
            let body = UIView()
            body.heightAnchor.constraint(equalToConstant: 400).isActive = true
            let piece = shelf.piece(entry.kind) { ShelfPieceView(kind: entry.kind, body: body) }
            piece.header.set(words: entry.words, spinner: nil)
            piece.setPresent(true, animated: false)
        }
        return shelf
    }

    private func layout(_ shelf: ActivityShelfView, width: CGFloat = 386) {
        shelf.frame = CGRect(x: 0, y: 0, width: width, height: shelf.height(for: width))
        shelf.setNeedsLayout()
        shelf.layoutIfNeeded()
        shelf.pieces.values.forEach { $0.layoutIfNeeded() }
    }

    @Test func collapsedHugsContentAndOnlyThePillTakesTouches() {
        let shelf = makeShelf()
        layout(shelf)
        #expect(shelf.bounds.height == 44)
        #expect(shelf.summaryHeader.bounds.height == 44)
        #expect(shelf.summaryHeader.bounds.width < shelf.bounds.width)
        let glass = shelf.subviews.compactMap { $0 as? UIVisualEffectView }.first
        #expect(glass?.bounds.height == 34)
        #expect(shelf.pieces.values.allSatisfy { $0.isHidden })
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElementsHidden }, "folded categories are not exposed through their explicit accessibility containers")
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElements?.isEmpty == true })
        #expect(!shelf.point(inside: CGPoint(x: 0, y: 22), with: nil))
        #expect(shelf.point(inside: CGPoint(x: 193, y: 1), with: nil), "invisible top margin is tappable")
        #expect(shelf.summaryHeader.accessibilityLabel == shelf.summary.accessibilityLabel)
    }

    @Test func pointerFollowsThePaintedShelfWithoutShrinkingTheTapTarget() throws {
        let shelf = makeShelf(), header = shelf.summaryHeader
        layout(shelf)
        let glass = try #require(shelf.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let folded = try #require(PointerEffects.drawnOutline(of: header))
        #expect(folded.rect == glass.convert(glass.bounds, to: header))
        #expect(folded.rect.height == 34 && header.bounds.height == 44)
        #expect(folded.radius == (Theme.isDesktop ? DesktopRows.radius : 17))
        #expect(shelf.point(inside: CGPoint(x: header.center.x, y: 1), with: nil))
        #expect(!PointerEffects.path(folded).contains(CGPoint(x: header.bounds.midX, y: 1)))

        shelf.expanded = true
        layout(shelf)
        let opened = try #require(PointerEffects.drawnOutline(of: header))
        #expect(opened.rect == header.bounds)
        #expect(opened.corners == [.layerMinXMinYCorner, .layerMaxXMinYCorner])
        #expect(!opened.strong)

        shelf.expanded = false
        shelf.summaryIcon = ("phone.fill", .systemGreen)
        layout(shelf)
        let call = try #require(PointerEffects.drawnOutline(of: header))
        #expect(call.rect == header.bounds && call.rect.height >= 48)
        #expect(call.radius == HQShape.radius(18, .card))
        shelf.pieces.values.forEach { $0.setPresent(false, animated: false) }
        layout(shelf)
        #expect(PointerEffects.drawnOutline(of: header) == nil)
    }

    @Test func overviewHasEveryCategoryAndExactlyOneDetailScroller() throws {
        let shelf = makeShelf()
        shelf.expanded = true
        shelf.maxHeight = 220
        layout(shelf)
        #expect(shelf.bounds.height == 220)
        #expect(shelf.targetFrames(width: 386).count == ShelfPieceKind.allCases.count)
        #expect(shelf.pieces.values.allSatisfy { !$0.isOpen && !$0.isHidden })
        #expect(shelf.pieces.values.allSatisfy { !$0.accessibilityElementsHidden }, "opening restores the category controls")
        #expect(shelf.pieces.values.allSatisfy { $0.accessibilityElements?.count == 1 }, "overview exposes headers, not hidden actions or bodies")
        for kind in ShelfPieceKind.allCases where kind != .browser && kind != .phone {
            for piece in shelf.pieces.values { piece.setOpen(piece.kind == kind, animated: false) }
            layout(shelf)
            let selected = try #require(shelf.pieces[kind])
            #expect(shelf.targetFrames(width: 386).count == 1)
            #expect(shelf.pieces.values.filter { !$0.isHidden }.map(\.kind) == [kind])
            #expect(shelf.pieces.values.filter { !$0.accessibilityElementsHidden }.map(\.kind) == [kind])
            #expect(selected.scroll.frame.height > 0)
            #expect(selected.scroll.isHidden == false)
            #expect((selected.accessibilityElements?.last as? UIView) === selected.scroll)
            selected.header.showsMore = true
            #expect(selected.accessibilityElements?.count == 3, "visible actions join the open detail")
            selected.header.showsMore = false
            #expect(selected.accessibilityElements?.count == 2, "hidden actions leave the accessibility container immediately")
            var parent = selected.scroll.superview
            while let view = parent {
                #expect(!(view is UIScrollView), "the body scroller has no scrolling ancestor")
                parent = view.superview
            }
            #expect(shelf.summaryHeader.accessibilityLabel == "All activity")
        }
    }

    @Test func arrivingAndRemovedCategoriesFollowAccessibilityVisibility() {
        let shelf = ActivityShelfView()
        layout(shelf)
        let piece = shelf.piece(.tasks) { ShelfPieceView(kind: .tasks, body: UIView()) }
        piece.setPresent(true, animated: false)
        layout(shelf)
        #expect(piece.accessibilityElementsHidden)
        shelf.expanded = true
        piece.setOpen(true, animated: false)
        layout(shelf)
        #expect(!piece.accessibilityElementsHidden)
        #expect(!piece.scroll.accessibilityElementsHidden)
        piece.setOpen(false, animated: false)
        layout(shelf)
        #expect(piece.scroll.accessibilityElementsHidden)
        piece.setPresent(false, animated: false)
        layout(shelf)
        #expect(shelf.accessibilityElementsHidden)
        piece.setPresent(true, animated: false)
        layout(shelf)
        #expect(!shelf.accessibilityElementsHidden)
    }

    @Test func countRefreshDoesNotOpenOrResizeTheOverview() {
        let shelf = makeShelf()
        layout(shelf)
        shelf.summary.entries[1].words = "Tasks 3/5"
        layout(shelf)
        #expect(!shelf.expanded)
        #expect(shelf.bounds.height == 44)
        shelf.expanded = true
        layout(shelf)
        let size = shelf.bounds.size
        shelf.summary.entries[1].words = "Tasks 4/5"
        layout(shelf)
        #expect(shelf.bounds.size == size)
        #expect(shelf.pieces.values.allSatisfy { !$0.isOpen })
    }

    @Test func attentionAndLargeTextGrowWithoutClippingTheAction() {
        let shelf = makeShelf()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 280, height: 500))
        window.addSubview(shelf)
        defer { shelf.removeFromSuperview(); window.isHidden = true }
        shelf.summary = ActivityPill(entries: [.init(kind: .browser, words: "Browser needs you", needsAttention: true)])
        layout(shelf, width: 180)
        #expect(shelf.bounds.height == 44, "ordinary text keeps the approved one-line touch target even when urgent")
        #expect(shelf.summaryHeader.label.numberOfLines == 1)
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.summaryHeader.bounds.height)
        shelf.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        shelf.updateTraitsIfNeeded()
        shelf.summaryHeader.updateTraitsIfNeeded()
        layout(shelf, width: 180)
        #expect(shelf.summaryHeader.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        #expect(shelf.bounds.height > 44, "accessibility text grows beyond the ordinary touch row")
        #expect(shelf.summaryHeader.label.numberOfLines == 2)
        #expect(shelf.summaryHeader.label.frame.height > shelf.summaryHeader.label.font.lineHeight, "the narrow accessibility pill actually wraps")
        #expect(shelf.summaryHeader.label.frame.minY >= 0)
        #expect(shelf.summaryHeader.label.frame.maxY <= shelf.summaryHeader.bounds.height)
        shelf.expanded = true
        layout(shelf, width: 280)
        #expect(shelf.targetFrames(width: 280)[.browser]?.width == 280)
    }

    @Test func newAttentionStaysVisibleWhileAnotherDetailIsOpen() {
        let shelf = makeShelf()
        shelf.expanded = true
        shelf.pieces[.tasks]?.setOpen(true, animated: false)
        shelf.summary.entries.removeAll { $0.kind == .browser }
        shelf.summary.entries.append(.init(kind: .browser, words: "Browser needs you", needsAttention: true))
        layout(shelf)
        #expect(shelf.summaryHeader.label.text?.hasPrefix("Browser needs you") == true)
        #expect(shelf.summaryHeader.accessibilityValue == "detail")
        #expect(shelf.pieces[.tasks]?.isHidden == false, "a refresh does not switch the selected detail")
    }

    @Test func aRunningParentAloneDrawsNoPill() {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: [], parentIsRunning: true)
        layout(shelf)
        #expect(shelf.bounds.height == 0)
        #expect(shelf.summaryHeader.isHidden)
    }

    /// The owner-approved mock: "Tasks 2/5 · 1 background ⌄" collapsed; "Activity ⌃" over rows of
    /// "Title ··· value ›" with hairlines; "‹ Activity" over one detail. The step stays in the transcript.
    @Test func matchesTheApprovedMock() throws {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: [
            .init(kind: .tasks, words: "Tasks 2/5"),
            .init(kind: .background, words: "1 background", isRunning: true)], parentIsRunning: true)
        for (kind, title, value) in [(ShelfPieceKind.tasks, "Tasks", "2/5"), (.background, "Background", "1 running")] {
            let piece = shelf.piece(kind) { ShelfPieceView(kind: kind, body: UIView()) }
            piece.header.set(words: title, value: value, spinner: nil)
            piece.setPresent(true, animated: false)
        }
        layout(shelf, width: 386)
        let header = shelf.summaryHeader
        #expect(header.label.text == "Tasks 2/5 · 1 background", "every current category is named, no \"+N more\"")
        #expect(header.chevronStyle == .expand)
        #expect(header.chevron.transform == .identity, "⌄ while collapsed")
        #expect(header.chevron.frame.minX > header.label.frame.maxX, "the chevron follows the words")

        shelf.expanded = true
        layout(shelf, width: 386)
        #expect(header.label.text == "Activity", "the expanded header is neither the pill again nor the transcript's step")
        // [collapse-all] The ⌃ left the words for the trailing edge, where it folds the whole shelf.
        #expect(header.chevronStyle == .hidden)
        #expect(header.chevron.isHidden, "no arrow beside \"Activity\"")
        #expect(!shelf.collapseAll.isHidden)
        #expect(abs(shelf.collapseAll.frame.maxX - (header.frame.maxX - 10)) < 1, "⌃ at the trailing edge, in line with the rows' ›")
        #expect(header.label.frame.maxX <= shelf.collapseAll.frame.minX - header.frame.minX)
        let tasks = try #require(shelf.pieces[.tasks])
        tasks.layoutIfNeeded()
        tasks.header.layoutIfNeeded()
        #expect(tasks.header.label.text == "Tasks")
        #expect(tasks.header.valueLabel.text == "2/5")
        #expect(abs(tasks.header.chevron.frame.maxX - (tasks.header.bounds.width - 10)) < 1, "› at the row's trailing edge")
        #expect(abs(tasks.header.valueLabel.frame.maxX - (tasks.header.chevron.frame.minX - 6)) < 1, "the value right-aligned before ›")
        #expect(tasks.header.valueLabel.frame.minX > tasks.header.label.frame.maxX)
        func all(_ view: UIView) -> [UIView] { view.subviews + view.subviews.flatMap(all) }
        let rules = all(shelf).filter { $0.backgroundColor == ChatPalette.separator && !$0.isHidden }
        #expect(rules.count == 2, "a hairline under the header and one between the two rows")

        tasks.setOpen(true, animated: false)
        layout(shelf, width: 386)
        #expect(header.chevronStyle == .back)
        #expect(header.label.text == "Activity")
        #expect(header.chevron.frame.maxX <= header.label.frame.minX, "‹ before the words")
        #expect(!header.chevron.isHidden)
        #expect(!shelf.collapseAll.isHidden, "a detail keeps the trailing collapse-all")
        #expect(header.accessibilityLabel == "All activity")

        shelf.expanded = false
        layout(shelf, width: 386)
        #expect(shelf.collapseAll.isHidden, "the folded pill has no collapse-all")
        #expect(header.chevronStyle == .expand && !header.chevron.isHidden)
    }

    @Test func aNarrowPillDropsOnlyWhatDoesNotFit() {
        let shelf = ActivityShelfView()
        shelf.summary = ActivityPill(entries: [
            .init(kind: .tasks, words: "Tasks 2/5"),
            .init(kind: .subagents, words: "1 helper", isRunning: true),
            .init(kind: .background, words: "1 background", isRunning: true),
            .init(kind: .goal, words: "Goal done", isHistorical: true)])
        for entry in shelf.summary.entries {
            let piece = shelf.piece(entry.kind) { ShelfPieceView(kind: entry.kind, body: UIView()) }
            piece.setPresent(true, animated: false)
        }
        layout(shelf, width: 386)
        #expect(shelf.summaryHeader.label.text == "Tasks 2/5 · 1 helper · 1 background")
        layout(shelf, width: 200)
        let words = shelf.summaryHeader.label.text ?? ""
        #expect(words.hasPrefix("Tasks 2/5"))
        #expect(words.hasSuffix("more"))
        #expect(!words.contains("+3 more"), "finished history never counts as more")
        #expect(shelf.summaryHeader.fittingWidth <= 200 || words == "Tasks 2/5 · +2 more")
    }

    @Test func aLargeGoalHeaderMeasuresTheSpaceItsControlsActuallyLeave() {
        let header = ShelfHeader()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        window.addSubview(header)
        defer { header.removeFromSuperview(); window.isHidden = true }
        header.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        header.updateTraitsIfNeeded()
        #expect(header.traitCollection.preferredContentSizeCategory == .accessibilityExtraExtraExtraLarge)
        header.label.font = .systemFont(ofSize: 22)
        header.showsLeadingDot = true
        header.showsMore = true
        header.setOpen(true, animated: false)
        header.set(words: "Goal blocked · Turn 12345/99999 · 23h", spinner: nil)
        for width: CGFloat in [180, 220, 280, 300] {
            header.frame = CGRect(x: 0, y: 0, width: width, height: header.height(width: width))
            header.setNeedsLayout()
            header.layoutIfNeeded()
            #expect(header.label.frame.minY >= 0)
            #expect(header.label.frame.maxY <= header.bounds.height)
        }
    }
}
