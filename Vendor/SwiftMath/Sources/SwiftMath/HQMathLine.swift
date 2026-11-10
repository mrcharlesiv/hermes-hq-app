import CoreGraphics
import Foundation

/// Hermes HQ's own way in (not upstream's): a formula set once, with its measures, drawn into a context in a colour.
/// Upstream keeps the typesetter and a display's colour and position internal, behind its label and image classes.
public final class HQMathLine {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    private let display: MTMathListDisplay

    /// nil when the TeX can't be read. `block`: display style (large operators, limits above and below).
    public init?(latex: String, size: CGFloat, block: Bool) {
        var error: NSError?
        guard let list = MTMathListBuilder.build(fromString: latex, error: &error), error == nil,
              let font = MTFontManager.fontManager.latinModernFont(withSize: size),
              let display = MTTypesetter.createLineForMathList(list, font: font, style: block ? .display : .text) else { return nil }
        self.display = display
        width = display.width
        ascent = display.ascent
        descent = display.descent
    }

    /// Draws with the baseline's start at `origin`, in a context whose y grows upward.
    public func draw(in context: CGContext, at origin: CGPoint, color: MTColor) {
        display.textColor = color
        display.position = origin
        display.draw(context)
    }
}
