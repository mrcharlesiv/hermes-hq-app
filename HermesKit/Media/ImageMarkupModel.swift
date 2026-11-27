// [image-markup] Pure data model, undo/redo history, and edit-prompt builder for image markup & annotated edits.
// Coordinates are normalized to 0...1 relative to the image bounds so strokes and callout pins scale cleanly across
// iPhone, iPad, Mac Catalyst, and full-resolution PNG export.

import CoreGraphics
import Foundation

nonisolated enum ImageMarkupTool: String, CaseIterable, Hashable, Sendable {
    case pen
    case highlighter
    case arrow
    case box
    case pin

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .box: "Box"
        case .pin: "Pin Note"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .box: "rectangle"
        case .pin: "mappin.circle.fill"
        }
    }
}

nonisolated enum ImageMarkupColor: String, CaseIterable, Hashable, Sendable {
    case red
    case yellow
    case blue
    case green
    case white
    case black

    var title: String {
        switch self {
        case .red: "Red"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .green: "Green"
        case .white: "White"
        case .black: "Black"
        }
    }

    /// sRGB RGBA values for cross-platform CoreGraphics / UIKit rendering.
    var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        switch self {
        case .red: (0.96, 0.24, 0.22, 1.0)
        case .yellow: (0.99, 0.80, 0.08, 1.0)
        case .blue: (0.14, 0.52, 0.98, 1.0)
        case .green: (0.18, 0.78, 0.35, 1.0)
        case .white: (1.0, 1.0, 1.0, 1.0)
        case .black: (0.08, 0.08, 0.10, 1.0)
        }
    }
}

nonisolated struct ImageMarkupPoint: Hashable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    init(_ cgPoint: CGPoint, in size: CGSize) {
        let w = max(1, Double(size.width))
        let h = max(1, Double(size.height))
        self.init(x: Double(cgPoint.x) / w, y: Double(cgPoint.y) / h)
    }

    func cgPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
    }
}

nonisolated struct ImageMarkupStroke: Hashable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var tool: ImageMarkupTool
    var color: ImageMarkupColor
    /// Relative stroke thickness as a fraction of min(width, height).
    var widthRatio: Double
    var points: [ImageMarkupPoint]

    var opacity: CGFloat { tool == .highlighter ? 0.38 : 1.0 }
}

nonisolated struct ImageMarkupPin: Hashable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var number: Int
    var point: ImageMarkupPoint
    var color: ImageMarkupColor
    var note: String
}

/// Snapshot-based undo/redo document for image markup annotations.
nonisolated struct ImageMarkupDocument: Equatable, Sendable {
    struct State: Equatable, Sendable {
        var strokes: [ImageMarkupStroke] = []
        var pins: [ImageMarkupPin] = []
    }

    private(set) var current = State()
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    static let maxHistory = 50

    var strokes: [ImageMarkupStroke] { current.strokes }
    var pins: [ImageMarkupPin] { current.pins }
    var isEmpty: Bool { current.strokes.isEmpty && current.pins.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private mutating func recordUndo() {
        undoStack.append(current)
        if undoStack.count > Self.maxHistory { undoStack.removeFirst(undoStack.count - Self.maxHistory) }
        redoStack.removeAll()
    }

    mutating func addStroke(_ stroke: ImageMarkupStroke) {
        guard !stroke.points.isEmpty else { return }
        recordUndo()
        current.strokes.append(stroke)
    }

    @discardableResult
    mutating func addPin(at point: ImageMarkupPoint, color: ImageMarkupColor, note: String) -> ImageMarkupPin {
        recordUndo()
        let nextNumber = (current.pins.map(\.number).max() ?? 0) + 1
        let pin = ImageMarkupPin(number: nextNumber, point: point, color: color, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        current.pins.append(pin)
        return pin
    }

    mutating func updatePin(id: String, note: String) {
        guard let idx = current.pins.firstIndex(where: { $0.id == id }) else { return }
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current.pins[idx].note != cleaned else { return }
        recordUndo()
        current.pins[idx].note = cleaned
    }

    mutating func removePin(id: String) {
        guard current.pins.contains(where: { $0.id == id }) else { return }
        recordUndo()
        current.pins.removeAll { $0.id == id }
        // Renumber remaining pins sequentially 1…N so callout references stay clean.
        for i in current.pins.indices {
            current.pins[i].number = i + 1
        }
    }

    mutating func clear() {
        guard !isEmpty else { return }
        recordUndo()
        current = State()
    }

    @discardableResult
    mutating func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(current)
        current = prev
        return true
    }

    @discardableResult
    mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(current)
        current = next
        return true
    }
}

nonisolated enum ImageMarkupPrompt {
    /// Formats the edit prompt combining the overall note and any numbered pin notes. `hasMarks` is false when
    /// nothing was drawn or pinned: the words then ask for the note alone, not for "marked-up areas" that aren't there.
    static func compose(note: String, pins: [ImageMarkupPin], hasMarks: Bool = true) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let notedPins = pins.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.number < $1.number }

        if !hasMarks && pins.isEmpty {
            return trimmedNote.isEmpty ? "" : "Please edit this image: \(trimmedNote)"
        }
        if trimmedNote.isEmpty && notedPins.isEmpty {
            return "Please edit the marked-up areas of this image."
        }
        var lines: [String] = []
        if !trimmedNote.isEmpty {
            lines.append("Please edit the marked-up areas of this image: \(trimmedNote)")
        } else {
            lines.append("Please edit the marked-up areas of this image:")
        }
        for pin in notedPins {
            // One line per pin, so the numbers on the picture and the numbers in the words stay in step.
            let words = pin.note.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(pin.number). \(words)")
        }
        return lines.joined(separator: "\n")
    }
}
