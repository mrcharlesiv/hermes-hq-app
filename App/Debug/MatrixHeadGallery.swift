// DEBUG: the dot-matrix heads on one sheet, for the brief's screenshots (docs/briefs/refs/bot-heads-face-shapes-light.png
// and -dark.png): every outline large, at every size a list draws and turned both ways, the owner's bots' default heads,
// the faces, the frames the face moves through and a few Bots list rows. MatrixHeadGalleryTests writes both pages when a
// test run sets `TEST_RUNNER_HQ_HEAD_GALLERY=<folder>`.

#if DEBUG
import UIKit

enum MatrixHeadGallery {
    static let width: CGFloat = 1120

    /// The owner's bots (and Hermes), each as the head its name picks.
    static let names = ["default", "home", "inbox", "app", "northwind", "gym", "otto", "finance", "maple-revenue-operator",
                        "bike-shop", "ivy", "hermes"]
    static let unread: Set<String> = ["inbox", "otto", "ivy"]

    static func render(dark: Bool) -> UIImage {
        let sheet = MatrixHeadSheet(dark: dark)
        sheet.build()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let size = CGSize(width: width, height: sheet.y)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            sheet.page.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for draw in sheet.drawing { draw(context.cgContext) }
        }
    }
}

/// Lays the sheet out top to bottom, keeping what to draw until the height is known.
private final class MatrixHeadSheet {
    let dark: Bool
    let margin: CGFloat = 56
    var y: CGFloat = 56
    var drawing: [(CGContext) -> Void] = []

    init(dark: Bool) { self.dark = dark }

    var page: UIColor { dark ? .black : .white }
    var label: UIColor { dark ? .white : .black }
    var secondary: UIColor { dark ? UIColor(white: 0.6, alpha: 1) : UIColor(white: 0.42, alpha: 1) }
    var separator: UIColor { dark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.86, alpha: 1) }
    var content: CGFloat { MatrixHeadGallery.width - margin * 2 }

    func build() {
        text("Dot-matrix heads", x: margin, y: y, size: 40, weight: .bold, color: label)
        y += 54
        text("Every bot’s own head until it’s given another: one of thirteen outlines, 20 LEDs across, and one colour family, "
             + "picked from its name. " + (dark ? "On a dark page the LEDs glow." : "On a light page they are coloured dots with dark eyes."),
             x: margin, y: y, size: 18, color: secondary, width: content, lines: 2)
        y += 70
        section("Outlines")
        outlines()
        section("Every size, and turned the other way")
        sizes()
        section("Picked from each bot’s name")
        names()
        section("Faces")
        faces()
        section("Alive")
        frames()
        section("In the Bots list")
        rows()
        y += margin - 28
    }

    // MARK: Sections

    func section(_ title: String) {
        text(title.uppercased(), x: margin, y: y, size: 14, weight: .semibold, color: secondary)
        y += 34
    }

    /// The thirteen outlines at a chat header's size and up, each in its own colour, facing right.
    func outlines() {
        let all = MatrixDesign.Silhouette.allCases
        let columns = 7, side: CGFloat = 120, height = side + 46
        let cell = content / CGFloat(columns)
        for (index, outline) in all.enumerated() {
            let line = index / columns
            let inLine = min(columns, all.count - line * columns)
            let x = margin + CGFloat(columns - inLine) * cell / 2 + CGFloat(index % columns) * cell
            let top = y + CGFloat(line) * height
            drawHead(sample(outline, index), in: CGRect(x: x + (cell - side) / 2, y: top, width: side, height: side))
            text(HeadLabels.outlines[outline.rawValue] ?? outline.rawValue, x: x, y: top + side + 10, size: 14, weight: .medium,
                 color: label, width: cell, centred: true)
        }
        y += CGFloat((all.count + columns - 1) / columns) * height + 12
    }

    /// Every outline at the sizes heads are drawn (a list row's 28 to 56, and smaller), then turned to the left.
    func sizes() {
        let all = MatrixDesign.Silhouette.allCases
        let rowLabel: CGFloat = 64
        let cell = (content - rowLabel) / CGFloat(all.count)
        for (index, outline) in all.enumerated() {
            text(HeadLabels.outlines[outline.rawValue] ?? outline.rawValue, x: margin + rowLabel + CGFloat(index) * cell, y: y,
                 size: 12, color: secondary, width: cell, centred: true)
        }
        y += 28
        let rows: [(String, CGFloat, Int)] = [("16", 16, 1), ("20", 20, 1), ("28", 28, 1), ("36", 36, 1), ("44", 44, 1),
                                              ("56", 56, 1), ("Left", 56, -1)]
        for (title, side, facing) in rows {
            text(title, x: margin, y: y + side / 2 - 9, size: 13, weight: .medium, color: secondary)
            for (index, outline) in all.enumerated() {
                let x = margin + rowLabel + CGFloat(index) * cell
                drawHead(sample(outline, index, facing: facing), in: CGRect(x: x + (cell - side) / 2, y: y, width: side, height: side))
            }
            y += side + 18
        }
        y += 22
    }

    func names() {
        let columns = 6, side: CGFloat = 104
        let cell = content / CGFloat(columns)
        for (index, name) in MatrixHeadGallery.names.enumerated() {
            let x = margin + CGFloat(index % columns) * cell, top = y + CGFloat(index / columns) * (side + 52)
            let frame = CGRect(x: x + (cell - side) / 2, y: top, width: side, height: side)
            drawHead(Head.defaultMatrixHead(profile: name), in: frame)
            if MatrixHeadGallery.unread.contains(name) { presence(on: frame) }
            text(name, x: x, y: top + side + 10, size: 14, weight: .medium, color: label, width: cell, centred: true)
        }
        y += 2 * (side + 52) + 12
    }

    /// The eyes, the mouths, blush and Ink (white or black LEDs) on the round outline.
    func faces() {
        let rowLabel: CGFloat = 104, side: CGFloat = 72
        func row(_ title: String, _ heads: [(String, Head)]) {
            text(title, x: margin, y: y + side / 2 - 11, size: 17, weight: .semibold, color: label)
            let cell = (content - rowLabel) / 10
            for (index, item) in heads.enumerated() {
                let x = margin + rowLabel + CGFloat(index) * cell
                var head = item.1
                if head.color != .ink { head.color = Head.matrixColours[(index * 5 + title.count) % Head.matrixColours.count] }
                drawHead(head, in: CGRect(x: x + (cell - side) / 2, y: y, width: side, height: side))
                text(item.0, x: x, y: y + side + 6, size: 12, color: secondary, width: cell, centred: true)
            }
            y += side + 40
        }
        let base = sample(.round, 0)
        row("Eyes", Head.Look.allCases.map { look in
            var head = base; head.look = look; return (HeadLabels.looks[look.rawValue] ?? look.rawValue, head)
        })
        var blush = base
        blush.blush = true
        blush.look = .happy
        var ink = base
        ink.color = .ink
        row("Mouth", Head.Mouth.allCases.map { mouth in
            var head = base; head.look = .ovals; head.mouth = mouth; return (HeadLabels.mouths[mouth.rawValue] ?? mouth.rawValue, head)
        } + [("Blush", blush), ("Ink", ink)])
    }

    /// The frames a face moves through, and the light that runs over it.
    func frames() {
        let head = Head.defaultMatrixHead(profile: "ivy")
        let design = MatrixDesign(head)
        let frames: [(String, MatrixPose, CGFloat?)] = [
            ("At rest", .rest, nil), ("Blink", MatrixPose(lids: 1), nil), ("Shut", MatrixPose(lids: 2), nil),
            ("Glance", MatrixPose(gaze: -1), nil), ("Shimmer", .rest, 0.5), ("Working", MatrixPose.reading[0], 0.3),
            ("…reading", MatrixPose.reading[2], 0.75), ("Reduce Motion", .thinking(design), nil),
        ]
        let side: CGFloat = 104, cell = content / CGFloat(frames.count)
        for (index, frame) in frames.enumerated() {
            let x = margin + CGFloat(index) * cell
            let rect = CGRect(x: x + (cell - side) / 2, y: y, width: side, height: side)
            let working = index == 5 || index == 6
            drawHead(head, pose: frame.1, in: rect, light: frame.2.map { (at: $0, across: working) })
            text(frame.0, x: x, y: y + side + 8, size: 13, color: secondary, width: cell, centred: true)
        }
        y += side + 52
    }

    func rows() {
        let rows: [(String, String, String, String)] = [
            ("ivy", "Ivy", "Sounds good — I’ll pick it up after lunch.", "Yesterday"),
            ("finance", "Finance", "Cron · Daily spend report", "Oct 16"),
            ("bike-shop", "Bike Shop", "Quote sent to the client.", "Oct 5"),
            ("maple-revenue-operator", "Maple Revenue Operator", "Q3 pipeline review is done.", "Sep 15"),
        ]
        let width: CGFloat = 560, height: CGFloat = 76, side: CGFloat = 50
        for (index, row) in rows.enumerated() {
            let top = y + CGFloat(index) * height
            let frame = CGRect(x: margin, y: top + (height - side) / 2, width: side, height: side)
            drawHead(Head.defaultMatrixHead(profile: row.0), in: frame)
            if index != 1 && index != 3 { presence(on: frame) }
            text(row.1, x: margin + 66, y: top + 15, size: 17, weight: .semibold, color: label, width: width - 66 - 90)
            text(row.3, x: margin + width - 90, y: top + 16, size: 15, color: secondary, width: 90, trailing: true)
            text(row.2, x: margin + 66, y: top + 40, size: 15, color: secondary, width: width - 66)
            if index < rows.count - 1 {
                let line = CGRect(x: margin + 66, y: top + height - 0.5, width: width - 66, height: 0.5)
                let colour = separator
                drawing.append { ctx in ctx.setFillColor(colour.cgColor); ctx.fill(line) }
            }
        }
        y += CGFloat(rows.count) * height + 24
    }

    // MARK: Drawing

    /// An outline with slit eyes in its own colour, facing right (bit 7 of the seed set) or left.
    func sample(_ outline: MatrixDesign.Silhouette, _ index: Int, facing: Int = 1) -> Head {
        var head = Head()
        head.theme = .matrix
        head.silhouette = outline
        head.color = Head.matrixColours[(index * 5) % Head.matrixColours.count]
        head.seed = (facing > 0 ? 129 : 1) + index * 256
        return head
    }

    /// A head at `pose`; `light` lays the band of light HeadView sweeps over it (`at` 0…1 along its path; `across` the
    /// working scan rather than the idle corner-to-corner shimmer).
    func drawHead(_ head: Head, pose: MatrixPose = .rest, in frame: CGRect, light: (at: CGFloat, across: Bool)? = nil) {
        let dark = self.dark
        guard let picture = MatrixHeadRenderer.makeImage(MatrixDesign(head), pose: pose, side: frame.width, scale: 2, dark: dark)
        else { return }
        let image = UIImage(cgImage: picture, scale: 2, orientation: .up)
        drawing.append { ctx in
            guard let light else { image.draw(in: frame); return }
            ctx.saveGState()
            ctx.beginTransparencyLayer(in: frame, auxiliaryInfo: nil)
            image.draw(in: frame)
            ctx.setBlendMode(.sourceAtop)
            let white = UIColor.white
            let colours = [white.withAlphaComponent(0).cgColor, white.withAlphaComponent(dark ? 0.62 : 0.45).cgColor,
                           white.withAlphaComponent(0).cgColor] as CFArray
            let middle = light.at, half: CGFloat = light.across ? 0.15 : 0.25
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours,
                                         locations: [middle - half, middle, middle + half]) {
                let start = light.across ? CGPoint(x: frame.minX, y: frame.midY) : CGPoint(x: frame.minX, y: frame.minY + frame.height * 0.15)
                let end = light.across ? CGPoint(x: frame.maxX, y: frame.midY) : CGPoint(x: frame.maxX, y: frame.minY + frame.height * 0.85)
                ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    /// The unread dot on the face's corner, as BotAvatar draws it.
    func presence(on frame: CGRect) {
        let size = BotAvatar.presenceSize(frame.width)
        let dot = CGRect(x: frame.maxX - size + 1, y: frame.maxY - size + 1, width: size, height: size)
        let page = page, label = label
        drawing.append { ctx in
            ctx.setFillColor(page.cgColor)
            ctx.fillEllipse(in: dot.insetBy(dx: -2, dy: -2))
            ctx.setFillColor(label.cgColor)
            ctx.fillEllipse(in: dot)
        }
    }

    func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: UIFont.Weight = .regular, color: UIColor,
              width: CGFloat? = nil, centred: Bool = false, trailing: Bool = false, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = centred ? .center : trailing ? .right : .left
        style.lineBreakMode = lines > 1 ? .byWordWrapping : width == nil ? .byClipping : .byTruncatingTail
        let attributed = NSAttributedString(string: string, attributes: [
            .font: HQFont.face(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ])
        let wide = width ?? MatrixHeadGallery.width
        drawing.append { _ in attributed.draw(in: CGRect(x: x, y: y, width: wide, height: size * 1.4 * CGFloat(lines))) }
    }
}
#endif
