// The desktop's running arc (V:styles.css:1111-1280, `.arc-border.arc-row`; V:app/chat/sidebar/session-row.tsx:432):
// a thin ring around a working chat with three bright spikes and their tails travelling round it, 2.23 s a lap. The
// desktop rings the whole sidebar row; the phone does the same in both looks; a pinned tile (a face alone) rings its face.
//
// The same build as the desktop's: a gradient layer three times the ring's size slides from (-10 %, -10 %) to (-50 %,
// -50 %) of its own size under a ring-shaped mask, so the work is one Core Animation transform with nothing per frame.
// Reduce Motion stops it where it stands, as the desktop's `prefers-reduced-motion` rule does (`animation: none`,
// V:styles.css:1273-1277): the ring stays, still. The power saver does not (owner, build 294): the arc says a bot is
// working, so it keeps travelling in Low Power Mode; it is one Core Animation transform the render server runs.

import SwiftUI
import UIKit

struct WorkingArc: UIViewRepresentable {
    /// `outline`: a bare Shapes head's own edge (1024 space, as drawn), ringed `outset` pt outside it.
    enum Shape: Equatable { case circle, rounded(CGFloat), outline(CGPath, outset: CGFloat) }
    var shape: Shape
    var lineWidth: CGFloat

    func makeUIView(context: Context) -> WorkingArcView { WorkingArcView() }

    func updateUIView(_ view: WorkingArcView, context: Context) {
        view.shape = shape
        view.lineWidth = lineWidth
    }
}

final class WorkingArcView: UIView {
    var shape: WorkingArc.Shape = .circle { didSet { if shape != oldValue { setNeedsLayout() } } }
    var lineWidth: CGFloat = 1.25 { didSet { if lineWidth != oldValue { setNeedsLayout() } } }

    /// One lap (`--arc-duration`).
    static let lap: CFTimeInterval = 2.23
    /// `--arc-angle`: the gradient runs 160° (CSS: 0° up, clockwise).
    static let angle: CGFloat = 160

    private let ring = CAShapeLayer()
    /// [perf] What `ring.path` was last built from: an outline ring is a CGPath union, so a layout pass at the same
    /// size and shape keeps the path it has.
    private var ringKey: (shape: WorkingArc.Shape, size: CGSize, lineWidth: CGFloat)?
    private let travel = CAGradientLayer()
    private var observers: [NSObjectProtocol] = []
    private static let key = "hq.working-arc"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.mask = ring
        ring.fillColor = nil
        ring.strokeColor = UIColor.black.cgColor
        travel.anchorPoint = .zero
        layer.addSublayer(travel)
        let center = NotificationCenter.default
        for name in [HQAccessibility.didChange, PowerState.changed, UIApplication.willEnterForegroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            })
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeGenerationTrait.self]) { (self: WorkingArcView, _) in self.paint() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.lineWidth = lineWidth
        if let key = ringKey, key.shape == shape, key.size == bounds.size, key.lineWidth == lineWidth {
            // the path is already this shape at this size
        } else {
            ringKey = (shape, bounds.size, lineWidth)
            let box = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            switch shape {
            case .circle: ring.path = UIBezierPath(ovalIn: box).cgPath
            case .rounded(let radius):
                ring.path = UIBezierPath(roundedRect: box, cornerRadius: max(0, radius - lineWidth / 2)).cgPath
            case .outline(let path, let outset):
                ring.path = Self.ringPath(path, outset: outset, lineWidth: lineWidth, in: bounds)
            }
        }
        let size = CGSize(width: bounds.width * 3, height: bounds.height * 3)
        if travel.bounds.size != size {
            travel.bounds = CGRect(origin: .zero, size: size)
            (travel.startPoint, travel.endPoint) = Self.ends(size)
            CATransaction.commit()
            restart()
            return
        }
        CATransaction.commit()
    }

    /// The head's edge grown evenly to the ring's centre line (`outset` less half the line), so the ring hugs a blob
    /// or a heart the way the circle hugs a round head, rather than boxing it in the app-icon square.
    static func ringPath(_ outline: CGPath, outset: CGFloat, lineWidth: CGFloat, in bounds: CGRect) -> CGPath {
        let side = min(bounds.width, bounds.height) - outset * 2
        guard side > 0 else { return CGMutablePath() }
        var place = CGAffineTransform(translationX: outset, y: outset).scaledBy(x: side / 1024, y: side / 1024)
        guard let face = outline.copy(using: &place) else { return CGMutablePath() }
        let grow = max(0, outset - lineWidth / 2)
        guard grow > 0 else { return face }
        return face.union(face.copy(strokingWithWidth: grow * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
    }

    /// The CSS gradient line for `angle` in a box of `size`, as unit points: it passes through the centre and is
    /// `|w·sin a| + |h·cos a|` long, so the 0 % and 100 % stops land on the box's far corners.
    ///
    /// Core Animation lays its bands square to the start→end line in *unit* space and then stretches them to the
    /// layer, so on a wide row the 160° bands came out nearly flat: the whole foot lit at once, then a long dark gap
    /// (owner's recording, build 271). The points here run along (w·sin a, −h·cos a) in unit space instead, which
    /// stretches back to bands square to the CSS angle in points, each stop at the CSS distance along it.
    static func ends(_ size: CGSize) -> (CGPoint, CGPoint) {
        guard size.width > 0, size.height > 0 else { return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)) }
        let a = angle * .pi / 180
        let dx = sin(a), dy = -cos(a)   // y grows down
        let length = abs(size.width * dx) + abs(size.height * dy)
        let vx = dx * size.width, vy = dy * size.height
        let k = length / (vx * vx + vy * vy) / 2
        return (CGPoint(x: 0.5 - k * vx, y: 0.5 - k * vy), CGPoint(x: 0.5 + k * vx, y: 0.5 + k * vy))
    }

    /// c0 a clear sentinel, c1 the accent (the label colour in dark, `:root.dark .arc-border`), c2 c1 at 45 %
    /// (`.arc-row`: a tail behind each spike).
    private func paint() {
        let dark = traitCollection.userInterfaceStyle == .dark
        let c1 = (dark ? HQPalette.label : HQPalette.tint).resolvedColor(with: traitCollection)
        let clear = c1.withAlphaComponent(0).cgColor, bright = c1.cgColor, tail = c1.withAlphaComponent(0.45).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        travel.colors = [clear, clear, bright, tail, clear, clear, clear, bright, tail, clear, clear, clear, bright]
        travel.locations = [0, 0.15, 0.20, 0.25, 0.35, 0.40, 0.55, 0.60, 0.65, 0.75, 0.80, 0.95, 1]
        CATransaction.commit()
    }

    /// One endless lap; still at its start under Reduce Motion only (`HQMotion.reduced`; not the power saver, build 294).
    private func restart() {
        travel.removeAnimation(forKey: Self.key)
        guard window != nil, bounds.width > 0 else { return }
        paint()
        let size = travel.bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        travel.position = CGPoint(x: -size.width * 0.1, y: -size.height * 0.1)
        CATransaction.commit()
        guard !HQMotion.reduced else { return }
        let lap = CABasicAnimation(keyPath: "position")   // HQMotion: reduced checked above
        lap.fromValue = CGPoint(x: -size.width * 0.1, y: -size.height * 0.1)
        lap.toValue = CGPoint(x: -size.width * 0.5, y: -size.height * 0.5)
        lap.duration = Self.lap
        lap.repeatCount = .infinity
        lap.isRemovedOnCompletion = false
        travel.position = lap.fromValue as! CGPoint
        travel.add(lap, forKey: Self.key)
    }
}

extension WorkingArc {
    /// The face's arc (the iOS look): `faceOutset` outside a `size` pt face, lapping its frame as the picked chip's
    /// ring does: a circle round a plain round head or a dot-matrix head, the head's own edge round any other bare
    /// Shapes head (a blob, a cloud: owner, the square round Inbox's blob read as a different animation from Hermes's
    /// circle), else the app-icon corner (22.37 %) of a tile or photo so it never cuts a corner.
    static let faceOutset: CGFloat = 3
    static let faceLine: CGFloat = 1.25

    @MainActor static func faceShape(raw: JSONValue?, profile: String, size: CGFloat) -> Shape {
        let head = Head.resolve(raw, profile: profile)
        let tile = Shape.rounded((size + faceOutset * 2) * BotFaces.cornerShare)
        guard head.theme == .shape || head.theme == .matrix, head.tile == .none, BotFaces.shared.photo(for: profile) == nil
        else { return tile }
        if SessionsHeaderView.isRound(head) { return .circle }
        return .outline(outline(head), outset: faceOutset)
    }

    /// The bare head's edge as `HeadRenderer` draws it: the outline under the head's placement, in 1024 space. Kept
    /// per head, as a tile's body asks again on every change.
    @MainActor private static var outlines: [Head: CGPath] = [:]

    @MainActor static func outline(_ head: Head) -> CGPath {
        if let path = outlines[head] { return path }
        let path = drawnOutline(head)
        if outlines.count > 64 { outlines.removeAll() }
        outlines[head] = path
        return path
    }

    private static func drawnOutline(_ head: Head) -> CGPath {
        let layout = HeadGeometry.layout(head, compact: false, darkPage: nil)
        let path = HeadRenderer.outlinePath(layout.outline)
        guard let p = layout.placement else { return path }
        var place = CGAffineTransform(a: p.k, b: 0, c: 0, d: p.k, tx: p.tx, ty: p.ty)
        return path.copy(using: &place) ?? path
    }

    /// The row's arc, as the desktop's sidebar row draws it (`.arc-border.arc-row`, V:styles.css:1139-1180,
    /// V:app/chat/sidebar/chrome.tsx:189): flush on the row's box (standoff 0), 0.078125 rem = 1.25 pt wide, the row's
    /// `rounded-md` corner (`--radius-scalar` 0.2 × 0.625 rem = 2 pt, V:styles.css:158, 501). In the Desktop Look the
    /// row's box is the one a press lights: 2 pt in at the top and foot, 8 pt in at the sides.
    ///
    /// The iOS look has no inset press box and draws hairlines between rows: a square box 2 pt off them sat on the
    /// rule beneath (owner, build 328). There the ring is a rounded card 5 pt in at the top and foot, and the list
    /// hides the hairlines that touch a ringed row (`ringHidesSeparator`), as UIKit does round a pressed row.
    static let rowLine: CGFloat = 1.25
    static var rowCorner: CGFloat { Theme.isDesktop ? 2 : 14 }
    static var rowInsets: EdgeInsets {
        guard Theme.isDesktop else { return EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8) }
        let inset = DesktopRows.pressInset
        return EdgeInsets(top: inset.top, leading: inset.leading, bottom: inset.bottom, trailing: inset.trailing)
    }

    /// The iOS look's list: a row's foot hairline goes while it or the row below it is ringed.
    static func ringHidesSeparator(_ indexPath: IndexPath, ringed: (IndexPath) -> Bool) -> Bool {
        guard !Theme.isDesktop else { return false }
        return ringed(indexPath) || ringed(IndexPath(item: indexPath.item + 1, section: indexPath.section))
    }
}

extension View {
    /// The row's working arc (both looks), round the whole row like the desktop's sidebar.
    func rowArc(_ on: Bool) -> some View {
        overlay {
            if on {
                WorkingArc(shape: .rounded(WorkingArc.rowCorner), lineWidth: WorkingArc.rowLine)
                    .padding(WorkingArc.rowInsets)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The working arc over this view while `on`: a ring `outset` outside its frame.
    func workingArc(_ on: Bool, shape: WorkingArc.Shape, lineWidth: CGFloat, outset: CGFloat = 0) -> some View {
        overlay {
            if on {
                WorkingArc(shape: shape, lineWidth: lineWidth).padding(-outset).allowsHitTesting(false)
            }
        }
    }
}
