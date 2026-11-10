// A pinned tile's working arc follows the face: a circle round a round head, the head's own edge round any other bare
// Shapes head, the app-icon square round a tile or a themed head.

import CoreGraphics
import Testing
import UIKit
@testable import HermesHQNative

@MainActor
struct WorkingArcFaceTests {
    private func head(_ form: Head.Form, tile: Head.Tile = .none, seed: Int = 7) -> Head {
        var head = Head(); head.theme = .shape; head.form = form; head.tile = tile; head.seed = seed; head.color = .sky
        return head
    }

    private func shape(_ head: Head, size: CGFloat = 72) -> WorkingArc.Shape {
        WorkingArc.faceShape(raw: head.json, profile: "arc-test", size: size)
    }

    @Test func roundHeadKeepsTheCircleAndTilesKeepTheAppIconCorner() {
        #expect(shape(head(.round)) == .circle)
        guard case .rounded = shape(head(.blob, tile: .color)) else { Issue.record("a tiled head keeps the app-icon ring"); return }
    }

    @Test func everyOtherBareFormRingsItsOwnEdge() {
        for form in Head.Form.allCases where form != .round {
            guard case .outline = shape(head(form)) else { Issue.record("\(form) should ring its outline"); continue }
        }
    }

    /// The ring stands `outset` off the face all round: every point of the drawn edge is inside it, about
    /// outset − line/2 from the ring's centre line, and nowhere does it box out to the frame's corners.
    @Test func ringHugsTheBlobAtTheOutset() throws {
        let size: CGFloat = 72, out = WorkingArc.faceOutset, line = WorkingArc.faceLine
        let bounds = CGRect(x: 0, y: 0, width: size + out * 2, height: size + out * 2)
        for form in [Head.Form.blob, .cloud, .heart, .square, .drop] {
            let h = head(form)
            let ring = WorkingArcView.ringPath(WorkingArc.outline(h), outset: out, lineWidth: line, in: bounds)
            var place = CGAffineTransform(translationX: out, y: out).scaledBy(x: size / 1024, y: size / 1024)
            let face = try #require(WorkingArc.outline(h).copy(using: &place))
            let box = ring.boundingBoxOfPath, faceBox = face.boundingBoxOfPath
            let grow = out - line / 2
            #expect(abs(box.minX - (faceBox.minX - grow)) < 0.6, "\(form) left")
            #expect(abs(box.maxY - (faceBox.maxY + grow)) < 0.6, "\(form) foot")
            // Not the old square: the ring's corner of the frame is empty for a blob.
            if form == .blob || form == .heart || form == .drop {
                #expect(!ring.contains(CGPoint(x: bounds.minX + 2, y: bounds.minY + 2)), "\(form) top-left corner")
            }
            Self.render(h, ring: ring, face: face, bounds: bounds, name: "\(form)")
        }
    }

    /// [perf] A layout pass at the same size and shape keeps the ring's path (an outline is a CGPath union); a new
    /// size or shape builds it again.
    @Test func theRingPathIsBuiltOncePerSizeAndShape() throws {
        let view = WorkingArcView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        view.shape = shape(head(.blob))
        view.layoutIfNeeded()
        let ring = try #require(view.layer.mask as? CAShapeLayer)
        let first = try #require(ring.path)
        view.setNeedsLayout(); view.layoutIfNeeded()
        #expect(ring.path === first, "same size and shape: the path is kept")
        view.frame = CGRect(x: 0, y: 0, width: 90, height: 90)
        view.layoutIfNeeded()
        #expect(ring.path !== first, "a new size builds the path again")
        let resized = try #require(ring.path)
        view.shape = .circle
        view.layoutIfNeeded()
        #expect(ring.path !== resized, "a new shape builds the path again")
    }

    /// Writes the face with its ring to /tmp for a look by eye.
    private static func render(_ head: Head, ring: CGPath, face: CGPath, bounds: CGRect, name: String) {
        let scale: CGFloat = 4
        let image = UIGraphicsImageRenderer(size: bounds.size).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor.white.cgColor); c.fill(bounds)
            c.addPath(face); c.setFillColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor); c.fillPath()
            c.addPath(ring); c.setStrokeColor(UIColor.black.cgColor); c.setLineWidth(WorkingArc.faceLine); c.strokePath()
        }
        _ = scale
        try? image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/arc-check-\(name).png"))
    }
}

private extension Head {
    var json: JSONValue {
        .object(["theme": .string("shape"), "form": .string(form.rawValue), "tile": .string(tile.rawValue),
                 "seed": .number(Double(seed)), "color": .string(color.rawValue), "v": .number(6)])
    }
}
