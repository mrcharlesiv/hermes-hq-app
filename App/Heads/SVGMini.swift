// Draws the small SVG dialect ThemeHeadSVG writes, with Core Graphics: g, path, rect, circle, ellipse and text;
// transforms; clip paths; linear and radial gradients (bounding-box units); group opacity; Gaussian-blur filters
// (Core Image); stroke caps, joins and dashes; crisp edges. Anything else is skipped. Pure drawing, any thread.

import CoreGraphics
import CoreImage
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

nonisolated final class SVGNode: @unchecked Sendable {
    let name: String
    let attrs: [String: String]
    var children: [SVGNode] = []
    var text = ""
    init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }
    var classes: [Substring] { (attrs["class"] ?? "").split(separator: " ") }
}

nonisolated enum SVGMini {
    // MARK: Parsing

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [SVGNode] = []
        var root: SVGNode?
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = SVGNode(name: name, attrs: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    }

    static func parse(_ svg: String) -> SVGNode? {
        let parser = XMLParser(data: Data(svg.utf8))
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    // MARK: Drawing

    /// Which part of the picture to draw: all of it, all but the face (`dh-face`), the face alone, the still ground (neither
    /// `dh-body` nor face: frame, tile, a robot's shoulders), or the moving body without its face.
    enum Parts: Sendable { case all, body, face, ground, moving }

    private struct Style {
        var fill: String = "#000"
        var stroke: String = "none"
        var strokeWidth: Double = 1
        var cap: CGLineCap = .butt
        var join: CGLineJoin = .miter
        var dash: [CGFloat] = []
        var crisp = false
        mutating func inherit(_ a: [String: String]) {
            if let v = a["fill"] { fill = v }
            if let v = a["stroke"] { stroke = v }
            if let v = a["stroke-width"], let d = Double(v) { strokeWidth = d }
            if let v = a["stroke-linecap"] { cap = v == "round" ? .round : v == "square" ? .square : .butt }
            if let v = a["stroke-linejoin"] { join = v == "round" ? .round : v == "bevel" ? .bevel : .miter }
            if let v = a["stroke-dasharray"] { dash = numbers(v).map { CGFloat($0) } }
            if let v = a["shape-rendering"] { crisp = v == "crispEdges" }
        }
    }

    private final class Renderer {
        var defs: [String: SVGNode] = [:]
        let pixels: CGSize
        let parts: Parts
        init(root: SVGNode, pixels: CGSize, parts: Parts) {
            self.pixels = pixels
            self.parts = parts
            index(root)
        }
        func index(_ node: SVGNode) {
            if let id = node.attrs["id"] { defs[id] = node }
            node.children.forEach(index)
        }
    }

    /// Draws `root` (a 1024-unit viewBox) into `ctx` over a `side`-unit square at the origin, y down. `pixels` is the
    /// context's size in device pixels (for blurs drawn off-screen).
    static func draw(_ root: SVGNode, in ctx: CGContext, side: CGFloat, pixels: CGSize, parts: Parts = .all) {
        let renderer = Renderer(root: root, pixels: pixels, parts: parts)
        ctx.saveGState()
        ctx.scaleBy(x: side / 1024, y: side / 1024)
        ctx.setMiterLimit(4)
        for child in root.children { draw(child, renderer, ctx, Style(), inFace: false) }
        ctx.restoreGState()
    }

    private static let skipped: Set<String> = ["defs", "clipPath", "linearGradient", "radialGradient", "filter", "stop", "title"]

    /// Whether a mark in the face and/or body is drawn in this pass.
    private static func wants(_ parts: Parts, face: Bool, body: Bool) -> Bool {
        switch parts {
        case .all: true
        case .face: face
        case .body: !face
        case .ground: !face && !body
        case .moving: !face && body
        }
    }

    /// Whether anything under `node` is drawn in this pass (so empty groups skip their clips, layers and blurs).
    private static func drawsAnything(_ node: SVGNode, _ parts: Parts, face: Bool, body: Bool) -> Bool {
        if skipped.contains(node.name) { return false }
        let classes = node.classes
        let face = face || classes.contains("dh-face"), body = body || classes.contains("dh-body")
        if node.name == "g" || node.name == "svg" {
            return node.children.contains { drawsAnything($0, parts, face: face, body: body) }
        }
        return wants(parts, face: face, body: body)
    }

    private static func draw(_ node: SVGNode, _ r: Renderer, _ ctx: CGContext, _ parent: Style, inFace: Bool, inBody: Bool = false) {
        if skipped.contains(node.name) { return }
        let classes = node.classes
        let face = inFace || classes.contains("dh-face"), body = inBody || classes.contains("dh-body")
        if r.parts != .all, !drawsAnything(node, r.parts, face: inFace, body: inBody) { return }
        var style = parent
        style.inherit(node.attrs)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if let t = node.attrs["transform"] { ctx.concatenate(transform(t)) }
        if let clip = reference(node.attrs["clip-path"]).flatMap({ r.defs[$0] }) {
            ctx.addPath(clipPath(clip))
            ctx.clip()
        }
        if style.crisp { ctx.setShouldAntialias(false) }
        let opacity = node.attrs["opacity"].flatMap(Double.init) ?? 1
        let blur = reference(node.attrs["filter"]).flatMap { r.defs[$0] }?.children
            .first { $0.name == "feGaussianBlur" }?.attrs["stdDeviation"].flatMap(Double.init)
        let content: (CGContext) -> Void = { ctx in
            switch node.name {
            case "g", "svg":
                for child in node.children { draw(child, r, ctx, style, inFace: face, inBody: body) }
            case "text":
                if wants(r.parts, face: face, body: body) { drawText(node, ctx, style) }
            default:
                guard wants(r.parts, face: face, body: body), let path = shape(node) else { return }
                paint(path, ctx, style, r)
            }
        }
        if let blur, blur > 0 {
            blurred(sigma: blur, opacity: opacity, ctx, r, content)
        } else if opacity < 1 {
            ctx.setAlpha(CGFloat(opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            content(ctx)
            ctx.endTransparencyLayer()
        } else {
            content(ctx)
        }
    }

    // MARK: Shapes and paint

    private static func number(_ node: SVGNode, _ key: String, _ fallback: Double = 0) -> Double {
        node.attrs[key].flatMap(Double.init) ?? fallback
    }

    private static func shape(_ node: SVGNode) -> CGPath? {
        switch node.name {
        case "path":
            guard let d = node.attrs["d"], !d.isEmpty else { return nil }
            return SVGPathData.path(d)
        case "rect":
            let w = number(node, "width"), h = number(node, "height")
            guard w > 0, h > 0 else { return nil }
            var rx = node.attrs["rx"].flatMap(Double.init), ry = node.attrs["ry"].flatMap(Double.init)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let cw = min(max(rx ?? 0, 0), w / 2), ch = min(max(ry ?? 0, 0), h / 2)
            let rect = CGRect(x: number(node, "x"), y: number(node, "y"), width: w, height: h)
            return cw > 0 && ch > 0 ? CGPath(roundedRect: rect, cornerWidth: cw, cornerHeight: ch, transform: nil) : CGPath(rect: rect, transform: nil)
        case "circle":
            let rr = number(node, "r")
            guard rr > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: number(node, "cx") - rr, y: number(node, "cy") - rr, width: 2 * rr, height: 2 * rr), transform: nil)
        case "ellipse":
            let rx = number(node, "rx"), ry = number(node, "ry")
            guard rx > 0, ry > 0 else { return nil }
            return CGPath(ellipseIn: CGRect(x: number(node, "cx") - rx, y: number(node, "cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
        default:
            return nil
        }
    }

    private static func paint(_ path: CGPath, _ ctx: CGContext, _ style: Style, _ r: Renderer) {
        if style.fill != "none" {
            if let id = reference(style.fill), let gradient = r.defs[id] {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                fillGradient(gradient, box: path.boundingBoxOfPath, ctx)
                ctx.restoreGState()
            } else if let color = color(style.fill) {
                ctx.addPath(path)
                ctx.setFillColor(color)
                ctx.fillPath()
            }
        }
        if style.stroke != "none", style.strokeWidth > 0, let color = color(style.stroke) {
            ctx.addPath(path)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(style.strokeWidth)
            ctx.setLineCap(style.cap)
            ctx.setLineJoin(style.join)
            ctx.setLineDash(phase: 0, lengths: style.dash)
            ctx.strokePath()
        }
    }

    private static func fillGradient(_ node: SVGNode, box: CGRect, _ ctx: CGContext) {
        let stops = node.children.filter { $0.name == "stop" }
        guard !stops.isEmpty, box.width > 0, box.height > 0 else { return }
        let colors = stops.map { stop -> CGColor in
            let alpha = stop.attrs["stop-opacity"].flatMap(Double.init) ?? 1
            return color(stop.attrs["stop-color"] ?? "#000", alpha: alpha) ?? CGColor(gray: 0, alpha: 0)
        }
        let locations = stops.map { CGFloat(number($0, "offset")) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
        ctx.concatenate(CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY))
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if node.name == "linearGradient" {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: number(node, "x1"), y: number(node, "y1")),
                                   end: CGPoint(x: number(node, "x2", 1), y: number(node, "y2")), options: extend)
        } else {
            let cx = number(node, "cx", 0.5), cy = number(node, "cy", 0.5)
            let center = CGPoint(x: cx, y: cy), focus = CGPoint(x: number(node, "fx", cx), y: number(node, "fy", cy))
            ctx.drawRadialGradient(gradient, startCenter: focus, startRadius: 0, endCenter: center,
                                   endRadius: number(node, "r", 0.5), options: extend)
        }
    }

    private static func clipPath(_ node: SVGNode) -> CGPath {
        let out = CGMutablePath()
        func add(_ child: SVGNode, _ t: CGAffineTransform) {
            let local = child.attrs["transform"].map(transform).map { $0.concatenating(t) } ?? t
            if child.name == "g" { child.children.forEach { add($0, local) }; return }
            if let path = shape(child) { out.addPath(path, transform: local) }
        }
        node.children.forEach { add($0, .identity) }
        return out
    }

    // MARK: Blur

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Draws `content` off-screen at the device's resolution, blurs it, and lays it back at `opacity`.
    private static func blurred(sigma: Double, opacity: Double, _ ctx: CGContext, _ r: Renderer, _ content: (CGContext) -> Void) {
        let width = Int(r.pixels.width), height = Int(r.pixels.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let off = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let device = ctx.ctm
        off.concatenate(device)
        off.setMiterLimit(4)
        content(off)
        guard let image = off.makeImage() else { return }
        let scale = Double(abs(device.a * device.d - device.b * device.c)).squareRoot()
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma * scale).cropped(to: input.extent)
        guard let result = ciContext.createCGImage(output, from: input.extent) else { return }
        ctx.saveGState()
        ctx.concatenate(device.inverted())
        ctx.setAlpha(CGFloat(opacity))
        ctx.draw(result, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    // MARK: Text

    private static func drawText(_ node: SVGNode, _ ctx: CGContext, _ style: Style) {
        let text = node.text
        guard !text.isEmpty else { return }
        let size = number(node, "font-size", 16)
        let emoji = node.attrs["font-family"] == nil
        let font: CTFont
        if emoji {
            font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        } else {
            let weight = number(node, "font-weight", 400)
            font = roundedSystemFont(size: size, heavy: weight >= 700)
        }
        var attributes: [CFString: Any] = [kCTFontAttributeName: font]
        if let fill = color(style.fill) { attributes[kCTForegroundColorAttributeName] = fill }
        if let spacing = node.attrs["letter-spacing"].flatMap(Double.init) { attributes[kCTKernAttributeName] = spacing }
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        var x = number(node, "x"), y = number(node, "y")
        if node.attrs["text-anchor"] == "middle" { x -= width / 2 } else if node.attrs["text-anchor"] == "end" { x -= width }
        if node.attrs["dominant-baseline"] == "central" { y += (CTFontGetAscent(font) - CTFontGetDescent(font)) / 2 }
        ctx.saveGState()
        ctx.translateBy(x: x, y: y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// The system's rounded face (`ui-rounded`), heavy or regular.
    private static func roundedSystemFont(size: Double, heavy: Bool) -> CTFont {
        #if canImport(UIKit)
        let base = HQFont.system(ofSize: size, weight: heavy ? .heavy : .regular)
        return (base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base) as CTFont
        #else
        let base = NSFont.systemFont(ofSize: size, weight: heavy ? .heavy : .regular)
        return (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
        #endif
    }

    // MARK: Attribute values

    private static func reference(_ value: String?) -> String? {
        guard let value, value.hasPrefix("url(#"), value.hasSuffix(")") else { return nil }
        return String(value.dropFirst(5).dropLast())
    }

    static func color(_ value: String, alpha: Double = 1) -> CGColor? {
        guard value.hasPrefix("#") else { return nil }
        var hex = String(value.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return CGColor(srgbRed: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                       blue: Double(v & 0xFF) / 255, alpha: alpha)
    }

    static func numbers(_ text: String) -> [Double] {
        var out: [Double] = []
        var current = ""
        func flush() { if let v = Double(current) { out.append(v) }; current = "" }
        for ch in text {
            if ch == "-" && !current.isEmpty && current.last != "e" { flush(); current = "-" }
            else if ch == " " || ch == "," { flush() }
            else { current.append(ch) }
        }
        flush()
        return out
    }

    /// An SVG transform list as one affine transform (each step applies inside the previous ones).
    static func transform(_ text: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest.firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: .whitespaces)
            let args = numbers(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
            var step = CGAffineTransform.identity
            switch name {
            case "translate": step = CGAffineTransform(translationX: args.first ?? 0, y: args.count > 1 ? args[1] : 0)
            case "scale": step = CGAffineTransform(scaleX: args.first ?? 1, y: args.count > 1 ? args[1] : args.first ?? 1)
            case "rotate":
                let angle = (args.first ?? 0) * .pi / 180
                if args.count >= 3 {
                    step = CGAffineTransform(translationX: args[1], y: args[2]).rotated(by: angle).translatedBy(x: -args[1], y: -args[2])
                } else {
                    step = CGAffineTransform(rotationAngle: angle)
                }
            case "matrix" where args.count == 6:
                step = CGAffineTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            default: break
            }
            result = step.concatenating(result)
        }
        return result
    }
}
