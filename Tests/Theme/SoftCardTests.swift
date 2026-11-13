// [soft-cards] The Soft Cards material: how dense a card must be for the faintest words on it to read, and how a
// picture's tone is measured.

import CoreGraphics
import Testing
import UIKit
@testable import HermesHQNative

@Suite struct SoftCardTests {
    /// The contrast the rule itself promises, worked out the same way.
    private func contrast(density: Double, picture: Double, dim: Double, page: Double, ink: Double, inkAlpha: Double) -> Double {
        let under = dim * SoftCard.encoded(page) + (1 - dim) * SoftCard.encoded(picture)
        let surface = density * SoftCard.encoded(page) + (1 - density) * under
        let words = inkAlpha * SoftCard.encoded(ink) + (1 - inkAlpha) * surface
        let a = SoftCard.decoded(words) + 0.05, b = SoftCard.decoded(surface) + 0.05
        return max(a, b) / min(a, b)
    }

    @Test func aCalmPictureGetsTheLightestCard() {
        // Dark: a dark picture under the standard Dim, near-white words at 60 %.
        let density = SoftCard.density(picture: 0.02, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(density == SoftCard.densityRange.lowerBound)
    }

    @Test func aBrightPhotoInTheDarkGetsADenserCardThatStillReads() {
        let light = SoftCard.density(picture: 0.05, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        let bright = SoftCard.density(picture: 0.9, dim: 0.45, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(bright > light)
        #expect(contrast(density: bright, picture: 0.9, dim: 0.45, page: 0.004, ink: 0.9, inkAlpha: 0.6) >= SoftCard.contrast)
    }

    @Test func lessDimMeansADenserCard() {
        let dimmed = SoftCard.density(picture: 0.6, dim: 0.8, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        let bare = SoftCard.density(picture: 0.6, dim: 0, page: 0.004, card: 0.004, ink: 0.9, inkAlpha: 0.6)
        #expect(bare > dimmed)
    }

    @Test func everyPictureAndDimReadsOrIsAsDenseAsACardGets() {
        // Light (dark words on a near-white page) and dark, every picture tone and Dim.
        for (page, ink, inkAlpha) in [(0.98, 0.03, 0.6), (0.004, 0.9, 0.6), (0.03, 0.75, 1.0)] {
            for picture in stride(from: 0.0, through: 1.0, by: 0.1) {
                for dim in stride(from: 0.0, through: 0.8, by: 0.2) {
                    let density = SoftCard.density(picture: picture, dim: dim, page: page, card: page, ink: ink, inkAlpha: inkAlpha)
                    #expect(SoftCard.densityRange.contains(density))
                    let reads = contrast(density: density, picture: picture, dim: dim, page: page, ink: ink, inkAlpha: inkAlpha) >= SoftCard.contrast
                    #expect(reads || density >= SoftCard.densityRange.upperBound - 0.001, "picture \(picture), Dim \(dim), page \(page)")
                }
            }
        }
    }

    @Test func aPicturesToneIsItsBrightestAndDarkestTenths() throws {
        // Left nine tenths black, the right tenth white.
        let width = 200, height = 100
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 170, y: 0, width: 30, height: height))
        let tone = SoftCardTone.measure(try #require(context.makeImage()))
        #expect(tone.bright > 0.9 && tone.dark < 0.01)
        // One flat grey: both the same.
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let flat = SoftCardTone.measure(try #require(context.makeImage()))
        #expect(abs(flat.bright - flat.dark) < 0.01)
    }

    // Owner 2026-11-13 (a screenshot of Bots on build 972): "Look at the padding on top and bottom of these. It's not
    // even." A card's two ends are tuned apart: what stands at one end (a name, faces, a foot row) brings other room
    // of its own than a row does.
    @MainActor @Test func aCardTakesMoreRoomAtOneEndOnly() {
        func insets(extraTop: CGFloat = 0, extraBottom: CGFloat = 0, header: Bool = false, join: BackdropCards.Join = []) -> NSDirectionalEdgeInsets {
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)))
            let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            BackdropCards.card(section, on: true, header: header, join: join, extraTop: extraTop, extraBottom: extraBottom)
            return section.contentInsets
        }
        let plain = insets()
        #expect(plain.top == BackdropCards.pad)
        #expect(plain.bottom == BackdropCards.pad + BackdropCards.gap)
        #expect(insets(extraTop: 7).top == plain.top + 7)
        #expect(insets(extraTop: 7).bottom == plain.bottom)
        #expect(insets(extraBottom: 10).bottom == plain.bottom + 10)
        #expect(insets(extraBottom: -3).bottom == plain.bottom - 3)
        // Under a header the card adds no room of its own at the top (the header brings it), and still takes more if asked.
        #expect(insets(header: true).top == 0)
        // A card joined to the one below keeps no gap and no foot; one that takes its foot's room back ends at the row.
        #expect(insets(join: .below).bottom == 0)
        #expect(insets(extraBottom: -BackdropCards.pad, join: .above).bottom == BackdropCards.gap)
    }

    // Owner 2026-11-13: "Stuff is just not consistent." Cards on a grouped page stood 13, 16 or 19 pt apart by what
    // each ended and began with. Two neighbours are always one gap apart, and the words each side of the gap stand
    // equally far from their cards' edges.
    @MainActor @Test func groupedCardsStandOneGapApart() {
        typealias End = BackdropPlates.End
        let space = BackdropPlates.sectionSpacing
        #expect(BackdropPlates.tableGap(afterNote: true) == space)
        // Four sections, the list's one spacing between each: rows; a title and rows; a title, rows and a note; rows.
        var y: CGFloat = 100
        var sections: [(first: (End, CGFloat), last: (End, CGFloat))] = []
        for (first, last) in [(End.rows, End.rows), (.title, .rows), (.title, .note), (.rows, .rows)] {
            sections.append(((first, y), (last, y + 200)))
            y += 200 + space
        }
        let edges = BackdropPlates.edges(of: sections)
        /// How far a card's words stand under its top, less how far they stand over its foot (as rows would).
        func leans(_ index: Int) -> CGFloat {
            (sections[index].first.1 - edges[index].top + BackdropPlates.slack(sections[index].first.0))
                - (edges[index].bottom - sections[index].last.1 + BackdropPlates.slack(sections[index].last.0))
        }
        for index in edges.indices.dropLast() {
            // One gap apart; a card between two unlike neighbours may give up to `lean` back to the gap.
            let gap = edges[index + 1].top - edges[index].bottom
            #expect(gap > BackdropCards.gap - 0.01 && gap < BackdropCards.gap + BackdropPlates.lean + 0.01, "cards \(index) and \(index + 1): \(gap)")
        }
        for index in edges.indices { #expect(abs(leans(index)) < BackdropPlates.lean + 0.01, "card \(index) leans \(leans(index))") }
        // The page's first and last cards mirror their other end.
        #expect(abs(leans(0)) < 0.01 && abs(leans(3)) < 0.01)
        // A page of like cards (each a title over rows): exactly one gap apart, each card even.
        let like = BackdropPlates.edges(of: (0..<3).map { index in
            let top = CGFloat(index) * (200 + space)
            return ((End.title, top), (End.rows, top + 200))
        })
        #expect(abs(like[1].top - like[0].bottom - BackdropCards.gap) < 0.01 && abs(like[2].top - like[1].bottom - BackdropCards.gap) < 0.01)
        #expect(abs((0 - like[0].top) - (like[0].bottom - 200) + BackdropPlates.slack(.title)) < 0.01)
        // A card alone keeps a row's rim.
        let alone = BackdropPlates.edges(of: [((.rows, 50), (.rows, 150))])
        #expect(alone[0].top == 50 - BackdropPlates.rim && alone[0].bottom == 150 + BackdropPlates.rim)
        // Sections too close to part keep their own rooms and never cross... each still starts over its first frame.
        let tight = BackdropPlates.edges(of: [((.rows, 0), (.rows, 100)), ((.rows, 106), (.rows, 200))])
        #expect(tight[0].top < 0 && tight[1].bottom > 200)
    }

    // Owner 2026-11-13 (a screenshot of Sessions on build 974): three projects on one card showed as three bands, one
    // piece of frosted glass per section. A run of joined sections has one card behind all of it.
    @MainActor @Test func joinedSectionsShareOneCard() throws {
        final class Rows: NSObject, UICollectionViewDataSource {
            func numberOfSections(in collectionView: UICollectionView) -> Int { 4 }
            func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 3 }
            func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
                collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath)
            }
        }
        // Sections 0, 1 and 2 are joined (top, middle, foot); section 3 is a card of its own.
        let layout = BackdropCardLayout { index, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(50))
            let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
            var join: BackdropCards.Join = []
            if index == 1 || index == 2 { join.insert(.above) }
            if index == 0 || index == 1 { join.insert(.below) }
            BackdropCards.card(section, on: true, join: join)
            return section
        }
        BackdropCards.register(in: layout)
        let rows = Rows()
        let list = UICollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), collectionViewLayout: layout)
        list.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "row")
        list.dataSource = rows
        list.layoutIfNeeded()

        func cards(in rect: CGRect) -> (runs: [UICollectionViewLayoutAttributes], pieces: [UICollectionViewLayoutAttributes], alone: [UICollectionViewLayoutAttributes]) {
            let decorations = (layout.layoutAttributesForElements(in: rect) ?? []).filter { $0.representedElementCategory == .decorationView }
            return (decorations.filter { $0.representedElementKind == BackdropCards.runKind },
                    decorations.filter { ($0.representedElementKind ?? "").hasPrefix(BackdropCards.kind + ".") && $0.representedElementKind != BackdropCards.runKind },
                    decorations.filter { $0.representedElementKind == BackdropCards.kind })
        }
        let all = cards(in: list.bounds)
        #expect(all.pieces.count == 3)
        #expect(all.alone.count == 1)
        let run = try #require(all.runs.first)
        #expect(all.runs.count == 1)
        #expect(run.indexPath.section == 0)
        #expect(run.frame == all.pieces.reduce(CGRect.null) { $0.union($1.frame) })
        // The card ends where the run does: the next section's own card starts a gap further down.
        #expect(run.frame.maxY + BackdropCards.gap == all.alone.first?.frame.minY)

        // With only the run's foot on the screen the card is still the whole run's (its other pieces are read from
        // above), and asking for the card by its place gives the same one.
        let foot = try #require(all.pieces.max { $0.frame.minY < $1.frame.minY })
        let part = cards(in: foot.frame.insetBy(dx: 0, dy: 4))
        #expect(part.pieces.count == 1)
        #expect(part.runs.first?.frame == run.frame)
        #expect(layout.layoutAttributesForDecorationView(ofKind: BackdropCards.runKind, at: run.indexPath)?.frame == run.frame)
        #expect(layout.layoutAttributesForDecorationView(ofKind: BackdropCards.runKind, at: IndexPath(item: 0, section: 1)) == nil)
    }
}
