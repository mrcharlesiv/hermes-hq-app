import Testing
import UIKit
@testable import HermesHQNative

/// [hover-shape] Owner 2026-11-22: the Activity pill's hover was a capsule round its 44 pt tap area, over the pill's 4 pt
/// box. The pointer's fill and highlight take the shape a control draws (`PointerEffects.drawnOutline`).
@MainActor @Suite struct PointerOutlineTests {
    private func laidOut<V: UIView>(_ view: V, _ size: CGSize) -> V {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        view.frame = CGRect(origin: .zero, size: size)
        host.addSubview(view)
        view.layoutIfNeeded()
        return view
    }

    @Test func aFilledButtonIsOutlinedByItsPlateInItsCorners() throws {
        for style in [UIButton.Configuration.CornerStyle.capsule, .fixed] {
            var config = UIButton.Configuration.filled()
            config.title = "Approve"
            config.cornerStyle = style
            config.background.cornerRadius = 4
            let button = laidOut(UIButton(configuration: config), CGSize(width: 120, height: 36))
            let outline = try #require(PointerEffects.drawnOutline(of: button), "\(style)")
            #expect(outline.rect == button.bounds)
            #expect(abs(outline.radius - (style == .capsule ? 18 : 4)) < 0.5, "\(style): \(outline.radius)")
            #expect(outline.plate != nil && outline.plate !== button, "the fill goes inside the colour, over it")
        }
    }

    @Test func aBareGlyphHasNoDrawnShape() {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark")
        let button = laidOut(UIButton(configuration: config), CGSize(width: 44, height: 44))
        #expect(PointerEffects.drawnOutline(of: button) == nil)
        let control = laidOut(UIControl(), CGSize(width: 150, height: 44))
        control.addSubview(UILabel(frame: control.bounds))
        #expect(PointerEffects.drawnOutline(of: control) == nil)
    }

    @Test func aControlsOwnColourIsItsShape() throws {
        let control = laidOut(UIControl(), CGSize(width: 90, height: 28))
        control.backgroundColor = .systemGray5
        control.layer.cornerRadius = 4
        let outline = try #require(PointerEffects.drawnOutline(of: control))
        #expect(outline.rect == control.bounds && outline.radius == 4)
        // A small dot is not a plate.
        let plain = laidOut(UIControl(), CGSize(width: 90, height: 28))
        let dot = UIView(frame: CGRect(x: 4, y: 10, width: 8, height: 8))
        dot.backgroundColor = .systemRed
        plain.addSubview(dot)
        #expect(PointerEffects.drawnOutline(of: plain) == nil)
    }

    @Test func aScoutedIconNeverOverhangsAndAWideExplicitActionKeepsItsHover() throws {
        for size in [CGSize(width: 40, height: 44), CGSize(width: 44, height: 40), CGSize(width: 68, height: 32)] {
            let box = CGRect(origin: .zero, size: size)
            let outline = try #require(PointerEffects.bareOutline(in: box, discovered: true))
            #expect(box.contains(outline.rect))
            #expect(outline.rect.midX == box.midX && outline.rect.midY == box.midY)
        }
        let row = CGRect(x: 0, y: 0, width: 180, height: 44)
        #expect(PointerEffects.bareOutline(in: row, discovered: true) == nil)
        #expect(PointerEffects.bareOutline(in: row, discovered: false)?.rect == row)
        #expect(PointerEffects.bareOutline(in: .zero, discovered: false) == nil)
    }

    @Test func discoveringAPaintedControlBeforeOrAfterLayoutMakesNoDifference() throws {
        let frame = CGRect(x: 0, y: 0, width: 160, height: 36)
        for before in [true, false] {
            let control = UIControl()
            control.backgroundColor = .systemGray5
            control.layer.cornerRadius = 4
            if !before { control.frame = frame }
            PointerEffects.button(control, discovered: true)
            control.frame = frame
            PointerEffects.button(control, discovered: true)
            #expect(control.interactions.filter { $0 is UIPointerInteraction }.count == 1)
            let outline = try #require(PointerEffects.drawnOutline(of: control))
            #expect(outline.rect == frame && outline.radius == 4)
            #if DEBUG && targetEnvironment(macCatalyst)
            MacHover.debugHoverSurface(control)
            let fill = try #require(control.subviews.first { $0.backgroundColor == MacHover.buttonFill })
            #expect(fill.frame == frame && fill.layer.cornerRadius == 4 && fill.alpha == 1)
            #endif
        }
    }

    #if DEBUG && targetEnvironment(macCatalyst)
    @Test func explicitRowCornersWinOverAnEarlierScanAndAnUndrawnButtonRadius() throws {
        var config = UIButton.Configuration.plain()
        config.title = "Session tab"
        let tab = laidOut(UIButton(configuration: config), CGSize(width: 160, height: 36))
        PointerEffects.button(tab, discovered: true)
        PointerEffects.surface(tab, radius: 6)
        PointerEffects.button(tab, discovered: true)
        MacHover.debugHoverSurface(tab)
        let fill = try #require(tab.subviews.first { $0.backgroundColor == MacHover.rowFill })
        #expect(fill.frame == tab.bounds && fill.layer.cornerRadius == 6 && fill.alpha == 1)
    }
    #endif

    @Test func anOwnOutlineWinsWhateverTheControlsSize() throws {
        // The Activity pill's header: a 44 pt tap area over a 34 pt pill drawn beside it.
        let header = laidOut(UIControl(), CGSize(width: 150, height: 44))
        header.backgroundColor = .systemGray5
        PointerEffects.outline(header) { PointerEffects.Outline(rect: CGRect(x: 0, y: 5, width: 150, height: 34), radius: 4) }
        let outline = try #require(PointerEffects.drawnOutline(of: header))
        #expect(outline.rect == CGRect(x: 0, y: 5, width: 150, height: 34))
        #expect(outline.radius == 4)
        #expect(PointerEffects.hasOwnOutline(header))
        // The path the iPad's highlight is cut to is that box, not the tap area.
        #expect(PointerEffects.path(outline).bounds == CGRect(x: 0, y: 5, width: 150, height: 34))
    }
}
