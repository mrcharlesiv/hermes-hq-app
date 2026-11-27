// Comprehensive unit & stress tests for Image Markup & Annotated Edits.

import Testing
import UIKit
@testable import HermesHQNative

@MainActor @Suite(.serialized) struct ImageMarkupTests {

    private func sampleImage(width: CGFloat = 400, height: CGFloat = 300) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func documentUndoRedoPinsAndRenumbering() {
        var doc = ImageMarkupDocument()
        #expect(doc.isEmpty)
        #expect(!doc.canUndo && !doc.canRedo)

        let stroke = ImageMarkupStroke(tool: .pen, color: .red, widthRatio: 0.01,
                                       points: [ImageMarkupPoint(x: 0.1, y: 0.2), ImageMarkupPoint(x: 0.8, y: 0.7)])
        doc.addStroke(stroke)
        #expect(doc.strokes.count == 1 && doc.canUndo && !doc.canRedo)

        let p1 = doc.addPin(at: ImageMarkupPoint(x: 0.25, y: 0.3), color: .yellow, note: "Brighten sky")
        let p2 = doc.addPin(at: ImageMarkupPoint(x: 0.6, y: 0.5), color: .blue, note: "Remove pole")
        #expect(p1.number == 1 && p2.number == 2)
        #expect(doc.pins.count == 2)

        doc.updatePin(id: p1.id, note: "Warm sunset sky")
        #expect(doc.pins[0].note == "Warm sunset sky")

        // Removing pin 1 renumbers pin 2 → 1.
        doc.removePin(id: p1.id)
        #expect(doc.pins.count == 1 && doc.pins[0].number == 1 && doc.pins[0].note == "Remove pole")

        // Undo restores both pins; redo removes pin 1 again.
        let didUndo1 = doc.undo()
        #expect(didUndo1)
        #expect(doc.pins.count == 2 && doc.canRedo)
        let didRedo1 = doc.redo()
        #expect(didRedo1)
        #expect(doc.pins.count == 1)

        // Clear + undo restores everything.
        doc.clear()
        #expect(doc.isEmpty)
        let didUndoClear = doc.undo()
        #expect(didUndoClear)
        #expect(doc.strokes.count == 1 && doc.pins.count == 1)
    }

    @Test func normalizedPointsClampOutOfBoundsCoordinates() {
        let p = ImageMarkupPoint(x: -5.0, y: 42.0)
        #expect(p.x == 0 && p.y == 1)
        let cg = p.cgPoint(in: CGSize(width: 200, height: 100))
        #expect(cg == CGPoint(x: 0, y: 100))
    }

    @Test func promptComposerFormatsNotesAndSortedPins() {
        #expect(ImageMarkupPrompt.compose(note: "  ", pins: []) == "Please edit the marked-up areas of this image.")
        #expect(ImageMarkupPrompt.compose(note: "Make background cleaner", pins: [])
            == "Please edit the marked-up areas of this image: Make background cleaner")

        let pins = [
            ImageMarkupPin(number: 2, point: ImageMarkupPoint(x: 0.5, y: 0.5), color: .red, note: "Swap sign text"),
            ImageMarkupPin(number: 1, point: ImageMarkupPoint(x: 0.2, y: 0.2), color: .blue, note: "Remove glare"),
            ImageMarkupPin(number: 3, point: ImageMarkupPoint(x: 0.8, y: 0.8), color: .green, note: "   "),
        ]
        let combined = ImageMarkupPrompt.compose(note: "Keep warm lighting", pins: pins)
        #expect(combined == """
        Please edit the marked-up areas of this image: Keep warm lighting
        1. Remove glare
        2. Swap sign text
        """)
    }

    @Test func compositorRendersAllToolsAndStressHandlesHeavyDocument() {
        var doc = ImageMarkupDocument()
        // Stress test: 120 strokes across all tools + 20 pins (exercises history cap at 50 too).
        let tools: [ImageMarkupTool] = [.pen, .highlighter, .arrow, .box]
        let colors = ImageMarkupColor.allCases
        for i in 0..<120 {
            let t = tools[i % tools.count]
            let c = colors[i % colors.count]
            let x0 = Double(i % 10) / 10.0
            let y0 = Double((i / 10) % 10) / 10.0
            let pts = [
                ImageMarkupPoint(x: x0, y: y0),
                ImageMarkupPoint(x: min(1, x0 + 0.15), y: min(1, y0 + 0.12)),
                ImageMarkupPoint(x: min(1, x0 + 0.22), y: min(1, y0 + 0.25)),
            ]
            doc.addStroke(ImageMarkupStroke(tool: t, color: c, widthRatio: 0.015, points: pts))
        }
        for i in 0..<20 {
            doc.addPin(at: ImageMarkupPoint(x: Double(i) / 20.0, y: 0.5), color: colors[i % colors.count], note: "Edit \(i + 1)")
        }

        // Undo works cleanly up to maxHistory (50) and stops gracefully.
        var undos = 0
        while doc.undo() { undos += 1 }
        #expect(undos == ImageMarkupDocument.maxHistory)
        while doc.redo() {}
        #expect(doc.strokes.count == 120 && doc.pins.count == 20)

        let base = sampleImage(width: 600, height: 400)
        let composited = ImageMarkupRenderer.composite(image: base, document: doc)
        #expect(composited.size == base.size)
        #expect(composited.scale == base.scale)
        let png = composited.pngData()
        #expect(png != nil && png!.count > 1000)
        // Composited image differs from untouched source image.
        #expect(png != base.pngData())
    }
}
