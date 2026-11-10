// App logos as SVG (owner, 2026-10-14: "the apps you can connect to don't have their actual logos"). logos.composio.dev
// answers every app in SVG, which UIImage can't read, and the app has no web view (D-P8), so this draws the subset
// logo files use: path / rect / circle / ellipse / line / polygon / polyline in groups with transforms, fills and
// strokes (colour, opacity, even-odd), linear and radial gradients, clip paths, masks (alpha and luminance) and
// Gaussian blur. Anything else is skipped. A file that draws nothing (or can't be read) gives nil: the monogram stays.

import CoreGraphics
import CoreImage
import UIKit

nonisolated enum SVGLogo {
    /// The logo drawn `pixels` square (its aspect kept, centred), as a UIImage at scale 3.
    static func image(_ data: Data, pixels: Int = 192) -> UIImage? {
        guard data.count <= 256 * 1024, let root = Node.parse(data), root.name == "svg" else { return nil }
        return Renderer(root: root, pixels: pixels)?.render()
    }

    /// A downloaded logo: PNG / JPEG / WebP as is, else drawn from SVG, off the main thread.
    static func decode(_ data: Data) async -> UIImage? {
        await Task.detached(priority: .utility) { UIImage(data: data) ?? image(data) }.value
    }

    private static let blurContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Tree

    final class Node {
        let name: String
        var attrs: [String: String]
        var children: [Node] = []
        weak var parent: Node?
        init(name: String, attrs: [String: String]) { self.name = name; self.attrs = attrs }

        /// An attribute or the same property in `style="…"` (the style wins, as in CSS).
        func value(_ key: String) -> String? {
            if let style = attrs["style"] {
                for item in style.split(separator: ";") {
                    let pair = item.split(separator: ":", maxSplits: 1)
                    if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == key {
                        return pair[1].trimmingCharacters(in: .whitespaces)
                    }
                }
            }
            return attrs[key]
        }

        static func parse(_ data: Data) -> Node? {
            let builder = Builder()
            let parser = XMLParser(data: data)
            parser.delegate = builder
            parser.shouldResolveExternalEntities = false
            guard parser.parse() else { return nil }
            return builder.root
        }

        private final class Builder: NSObject, XMLParserDelegate {
            var root: Node?
            var stack: [Node] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                let local = name.split(separator: ":").last.map(String.init) ?? name
                let node = Node(name: local, attrs: attributes)
                if let top = stack.last { node.parent = top; top.children.append(node) } else { root = node }
                stack.append(node)
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                _ = stack.popLast()
            }
        }
    }

    // MARK: - Values

    static func number(_ s: String?) -> CGFloat? {
        guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("px") { s.removeLast(2) }
        if s.hasSuffix("%") { return Double(s.dropLast()).map { CGFloat($0) / 100 } }
        return Double(s).map { CGFloat($0) }
    }

    static func numbers(_ s: String) -> [CGFloat] {
        s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\t" || $0 == "\r" }).compactMap { Double($0).map { CGFloat($0) } }
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(…)`/`rgba(…)` (numbers or percentages) and the common names.
    static func color(_ raw: String) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard let v = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                return (CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, 1)
            }
            if hex.count == 8 {
                return (CGFloat((v >> 24) & 255) / 255, CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255)
            }
            return nil
        }
        if s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ p: String) -> CGFloat {
                p.hasSuffix("%") ? (CGFloat(Double(p.dropLast()) ?? 0) / 100) : (CGFloat(Double(p) ?? 0) / 255)
            }
            let alpha = parts.count > 3 ? (number(parts[3]) ?? 1) : 1
            return (channel(parts[0]), channel(parts[1]), channel(parts[2]), alpha)
        }
        if s.hasPrefix("hsl"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") {
            let parts = s[s.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                  let sat = number(parts[1]), let light = number(parts[2]) else { return nil }
            let c = (1 - abs(2 * light - 1)) * sat, hp = CGFloat(h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = light - c / 2
            let (r, g, b): (CGFloat, CGFloat, CGFloat) = switch Int(hp) {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
            return (r + m, g + m, b + m, parts.count > 3 ? (number(parts[3]) ?? 1) : 1)
        }
        let names: [String: UInt32] = ["black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
                                       "yellow": 0xFFFF00, "orange": 0xFFA500, "gray": 0x808080, "grey": 0x808080,
                                       "purple": 0x800080, "currentcolor": 0x000000]
        if let v = names[s] { return (CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255, CGFloat(v & 255) / 255, 1) }
        return nil
    }

    static func transform(_ s: String?) -> CGAffineTransform {
        guard let s else { return .identity }
        var result = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t"))
            let v = numbers(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where v.count == 6: t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "translate" where !v.isEmpty: t = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty: t = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                let a = v[0] * .pi / 180
                t = v.count == 3 ? CGAffineTransform(translationX: v[1], y: v[2]).rotated(by: a).translatedBy(x: -v[1], y: -v[2])
                                 : CGAffineTransform(rotationAngle: a)
            case "skewX" where !v.isEmpty: t = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewY" where !v.isEmpty: t = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: break
            }
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    static func reference(_ s: String?) -> String? {
        guard let s, let open = s.range(of: "url(#"), let close = s[open.upperBound...].firstIndex(of: ")") else { return nil }
        return String(s[open.upperBound..<close]).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
    }

    // MARK: - Drawing

    struct Style {
        var fill = "black", fillOpacity: CGFloat = 1, fillRule = "nonzero"
        var stroke = "none", strokeOpacity: CGFloat = 1, strokeWidth: CGFloat = 1
        var lineCap = "butt", lineJoin = "miter", clipRule = "nonzero"
        var nonScalingStroke = false
        /// Inside a mask of type alpha, or a clip path: every paint is opaque white.
        var flat = false

        func inheriting(_ n: Node) -> Style {
            var s = self
            if let v = n.value("fill") { s.fill = v }
            if let v = number(n.value("fill-opacity")) { s.fillOpacity = v }
            if let v = n.value("fill-rule") { s.fillRule = v }
            if let v = n.value("stroke") { s.stroke = v }
            if let v = number(n.value("stroke-opacity")) { s.strokeOpacity = v }
            if let v = number(n.value("stroke-width")) { s.strokeWidth = v }
            if let v = n.value("stroke-linecap") { s.lineCap = v }
            if let v = n.value("stroke-linejoin") { s.lineJoin = v }
            if let v = n.value("clip-rule") { s.clipRule = v }
            if let v = n.value("vector-effect") { s.nonScalingStroke = v == "non-scaling-stroke" }
            return s
        }
    }

    final class Renderer {
        let root: Node
        let size: Int
        let viewBox: CGRect
        let base: CGAffineTransform
        var ids: [String: Node] = [:]
        let space = CGColorSpaceCreateDeviceRGB()
        let gray = CGColorSpaceCreateDeviceGray()
        var depth = 0

        init?(root: Node, pixels: Int) {
            self.root = root
            size = pixels
            let box = numbers(root.attrs["viewBox"] ?? "")
            if box.count == 4, box[2] > 0, box[3] > 0 {
                viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
            } else if let w = number(root.attrs["width"]), let h = number(root.attrs["height"]), w > 1, h > 1 {
                viewBox = CGRect(x: 0, y: 0, width: w, height: h)
            } else {
                return nil
            }
            let scale = CGFloat(pixels) / max(viewBox.width, viewBox.height)
            let dx = (CGFloat(pixels) - viewBox.width * scale) / 2, dy = (CGFloat(pixels) - viewBox.height * scale) / 2
            // Device space is CG's (origin bottom left): flip so SVG's y runs down.
            base = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: dx - viewBox.minX * scale, ty: CGFloat(pixels) - dy + viewBox.minY * scale)
            index(root)
        }

        private func index(_ n: Node) {
            if let id = n.attrs["id"] { ids[id] = n }
            n.children.forEach(index)
        }

        func context(gray isGray: Bool = false) -> CGContext? {
            let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: isGray ? gray : space,
                                bitmapInfo: isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setShouldAntialias(true)
            ctx?.interpolationQuality = .high
            return ctx
        }

        func render() -> UIImage? {
            guard let ctx = context() else { return nil }
            ctx.concatenate(base)
            draw(children: root.children, in: ctx, style: Style().inheriting(root))
            guard let image = ctx.makeImage(), Self.drewSomething(image) else { return nil }
            return UIImage(cgImage: image, scale: 3, orientation: .up)
        }

        static func drewSomething(_ image: CGImage) -> Bool {
            guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
            let count = CFDataGetLength(data)
            var i = 3
            while i < count { if bytes[i] > 8 { return true }; i += 4 * 7 }
            return false
        }

        func draw(children: [Node], in ctx: CGContext, style: Style) {
            for child in children { draw(child, in: ctx, style: style) }
        }

        func draw(_ n: Node, in ctx: CGContext, style inherited: Style) {
            guard depth < 40 else { return }
            depth += 1; defer { depth -= 1 }
            switch n.name {
            case "defs", "linearGradient", "radialGradient", "clipPath", "mask", "filter", "style", "title", "desc", "metadata",
                 "namedview", "symbol", "text", "image":
                return
            default: break
            }
            if n.value("display") == "none" || n.value("visibility") == "hidden" { return }
            let style = inherited.inheriting(n)
            let opacity = style.flat ? 1 : (number(n.value("opacity")) ?? 1)
            let mask = reference(n.value("mask")).flatMap { ids[$0] }
            let blur = reference(n.value("filter")).flatMap { ids[$0] }.flatMap(blurRadius)

            ctx.saveGState(); defer { ctx.restoreGState() }
            ctx.concatenate(transform(n.attrs["transform"]))
            if let clipId = reference(n.value("clip-path")), let clip = ids[clipId] { applyClip(clip, for: n, in: ctx) }

            let body: (CGContext) -> Void = { c in
                if n.name == "g" || n.name == "svg" || n.name == "a" || n.name == "switch" {
                    self.draw(children: n.children, in: c, style: style)
                } else if n.name == "use" {
                    if let id = (n.attrs["href"] ?? n.attrs["xlink:href"]).map({ String($0.drop(while: { $0 == "#" })) }), let target = self.ids[id] {
                        c.translateBy(x: number(n.attrs["x"]) ?? 0, y: number(n.attrs["y"]) ?? 0)
                        self.draw(target, in: c, style: style)
                    }
                } else {
                    self.shape(n, in: c, style: style)
                }
            }

            if mask == nil, blur == nil, opacity >= 1 { body(ctx); return }
            // Drawn into its own layer, then masked, blurred and faded as one.
            guard let layer = context() else { return }
            layer.concatenate(ctx.ctm)
            body(layer)
            guard var image = layer.makeImage() else { return }
            if let blur, let blurred = gaussian(image, radius: blur * scale(of: ctx.ctm)) { image = blurred }
            let ctm = ctx.ctm
            ctx.saveGState()
            ctx.concatenate(ctm.inverted())
            let device = CGRect(x: 0, y: 0, width: size, height: size)
            if let mask, let maskImage = maskImage(mask, for: n, ctm: ctm) { ctx.clip(to: device, mask: maskImage) }
            ctx.setAlpha(opacity)
            ctx.draw(image, in: device)
            ctx.restoreGState()
        }

        func scale(of t: CGAffineTransform) -> CGFloat { sqrt(abs(t.a * t.d - t.b * t.c)) }

        // MARK: Shapes

        func path(_ n: Node) -> CGPath? {
            func v(_ k: String) -> CGFloat { number(n.attrs[k]) ?? 0 }
            switch n.name {
            case "path":
                guard let d = n.attrs["d"], !d.isEmpty else { return nil }
                return SVGPath.parse(d)
            case "rect":
                var w = v("width"), h = v("height")
                if n.attrs["width"]?.hasSuffix("%") == true { w *= viewBox.width }
                if n.attrs["height"]?.hasSuffix("%") == true { h *= viewBox.height }
                guard w > 0, h > 0 else { return nil }
                var rx = number(n.attrs["rx"]) ?? number(n.attrs["ry"]) ?? 0
                var ry = number(n.attrs["ry"]) ?? rx
                rx = min(rx, w / 2); ry = min(ry, h / 2)
                let r = CGRect(x: v("x"), y: v("y"), width: w, height: h)
                return rx > 0 && ry > 0 ? CGPath(roundedRect: r, cornerWidth: rx, cornerHeight: ry, transform: nil) : CGPath(rect: r, transform: nil)
            case "circle":
                let r = v("r"); guard r > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(x: v("cx") - r, y: v("cy") - r, width: 2 * r, height: 2 * r), transform: nil)
            case "ellipse":
                let rx = v("rx"), ry = v("ry"); guard rx > 0, ry > 0 else { return nil }
                return CGPath(ellipseIn: CGRect(x: v("cx") - rx, y: v("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil)
            case "line":
                let p = CGMutablePath(); p.move(to: CGPoint(x: v("x1"), y: v("y1"))); p.addLine(to: CGPoint(x: v("x2"), y: v("y2"))); return p
            case "polygon", "polyline":
                let pts = numbers(n.attrs["points"] ?? "")
                guard pts.count >= 4 else { return nil }
                let p = CGMutablePath()
                p.move(to: CGPoint(x: pts[0], y: pts[1]))
                var i = 2
                while i + 1 < pts.count { p.addLine(to: CGPoint(x: pts[i], y: pts[i + 1])); i += 2 }
                if n.name == "polygon" { p.closeSubpath() }
                return p
            default:
                return nil
            }
        }

        func shape(_ n: Node, in ctx: CGContext, style: Style) {
            guard let path = path(n) else { return }
            if style.fill != "none" {
                paint(style.fill, opacity: style.fillOpacity, path: path, node: n, in: ctx, style: style) {
                    ctx.addPath(path)
                    ctx.clip(using: style.fillRule == "evenodd" ? .evenOdd : .winding)
                }
            }
            if style.stroke != "none", style.strokeWidth > 0 {
                ctx.saveGState()
                let width = style.nonScalingStroke ? style.strokeWidth / max(scale(of: ctx.ctm) / scale(of: base), 0.0001) : style.strokeWidth
                let outline = path.copy(strokingWithWidth: width, lineCap: SVGLogo.lineCap(style.lineCap),
                                        lineJoin: SVGLogo.lineJoin(style.lineJoin), miterLimit: 4)
                paint(style.stroke, opacity: style.strokeOpacity, path: outline, node: n, in: ctx, style: style) {
                    ctx.addPath(outline); ctx.clip(using: .winding)
                }
                ctx.restoreGState()
            }
        }

        /// Fills the area `clip` sets with a colour or a gradient.
        func paint(_ value: String, opacity: CGFloat, path: CGPath, node: Node, in ctx: CGContext, style: Style, clip: () -> Void) {
            ctx.saveGState(); defer { ctx.restoreGState() }
            if style.flat {
                clip(); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)); return
            }
            if let id = reference(value), let gradient = ids[id] {
                clip()
                drawGradient(gradient, bounds: path.boundingBoxOfPath, opacity: opacity, in: ctx)
                return
            }
            guard let c = color(value) else {
                // An unknown or missing paint server falls back to its fallback colour, if any ("url(#x) red").
                if let fallback = value.split(separator: ")").last.map(String.init), let c = color(fallback) {
                    clip(); ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: c.3 * opacity)
                    ctx.fill(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1))
                }
                return
            }
            clip()
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: c.3 * opacity)
            ctx.fill(path.boundingBoxOfPath.insetBy(dx: -1, dy: -1))
        }

        // MARK: Gradients

        /// A gradient's own attribute, else the one it links to (`href`), as Inkscape files chain them.
        func gradientValue(_ g: Node, _ key: String, hops: Int = 0) -> String? {
            if let v = g.attrs[key] { return v }
            guard hops < 8, let link = (g.attrs["href"] ?? g.attrs["xlink:href"]).map({ String($0.drop(while: { $0 == "#" })) }),
                  let next = ids[link] else { return nil }
            return gradientValue(next, key, hops: hops + 1)
        }

        func stops(_ g: Node, hops: Int = 0) -> [Node] {
            let own = g.children.filter { $0.name == "stop" }
            if !own.isEmpty || hops >= 8 { return own }
            guard let link = (g.attrs["href"] ?? g.attrs["xlink:href"]).map({ String($0.drop(while: { $0 == "#" })) }),
                  let next = ids[link] else { return [] }
            return stops(next, hops: hops + 1)
        }

        func drawGradient(_ g: Node, bounds: CGRect, opacity: CGFloat, in ctx: CGContext) {
            let stopNodes = stops(g)
            guard !stopNodes.isEmpty else { return }
            var colors: [CGColor] = [], locations: [CGFloat] = []
            var last: CGFloat = 0
            for s in stopNodes {
                let c = color(s.value("stop-color") ?? "black") ?? (0, 0, 0, 1)
                let a = (number(s.value("stop-opacity")) ?? 1) * c.3 * opacity
                colors.append(CGColor(colorSpace: space, components: [c.0, c.1, c.2, a]) ?? CGColor(gray: 0, alpha: a))
                last = max(last, min(1, max(0, number(s.attrs["offset"]) ?? 0)))
                locations.append(last)
            }
            if colors.count == 1 { colors.append(colors[0]); locations = [0, 1] }
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
            let userSpace = gradientValue(g, "gradientUnits") == "userSpaceOnUse"
            if !userSpace {
                guard bounds.width > 0, bounds.height > 0 else { return }
                ctx.concatenate(CGAffineTransform(a: bounds.width, b: 0, c: 0, d: bounds.height, tx: bounds.minX, ty: bounds.minY))
            }
            ctx.concatenate(transform(gradientValue(g, "gradientTransform")))
            func v(_ k: String, _ fallback: CGFloat) -> CGFloat {
                guard let raw = gradientValue(g, k), let n = number(raw) else { return fallback }
                if raw.hasSuffix("%") && userSpace { return n * (k.contains("y") ? viewBox.height : viewBox.width) }
                return n
            }
            let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            if g.name == "radialGradient" {
                let cx = v("cx", userSpace ? viewBox.midX : 0.5), cy = v("cy", userSpace ? viewBox.midY : 0.5)
                let r = v("r", userSpace ? viewBox.width / 2 : 0.5)
                let fx = v("fx", cx), fy = v("fy", cy)
                ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: fx, y: fy), startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: options)
            } else {
                let x1 = v("x1", 0), y1 = v("y1", 0), x2 = v("x2", userSpace ? viewBox.maxX : 1), y2 = v("y2", 0)
                ctx.drawLinearGradient(gradient, start: CGPoint(x: x1, y: y1), end: CGPoint(x: x2, y: y2), options: options)
            }
        }

        // MARK: Clips, masks, blur

        func applyClip(_ clip: Node, for n: Node, in ctx: CGContext) {
            let combined = CGMutablePath()
            var rule = "nonzero"
            let units = clip.attrs["clipPathUnits"] == "objectBoundingBox"
            var bboxTransform = CGAffineTransform.identity
            if units, let b = path(n)?.boundingBoxOfPath { bboxTransform = CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY) }
            func collect(_ node: Node, _ t: CGAffineTransform) {
                let t2 = transform(node.attrs["transform"]).concatenating(t)
                if node.name == "g" { node.children.forEach { collect($0, t2) }; return }
                if node.name == "use", let id = (node.attrs["href"] ?? node.attrs["xlink:href"]).map({ String($0.drop(while: { $0 == "#" })) }),
                   let target = ids[id] { collect(target, t2); return }
                if let p = path(node) {
                    var tt = t2
                    if let c = p.copy(using: &tt) { combined.addPath(c) }
                    if let r = node.value("clip-rule") { rule = r }
                }
            }
            clip.children.forEach { collect($0, transform(clip.attrs["transform"]).concatenating(bboxTransform)) }
            if combined.isEmpty { ctx.clip(to: .zero); return }
            ctx.addPath(combined)
            ctx.clip(using: rule == "evenodd" ? .evenOdd : .winding)
        }

        /// The mask as a device-size gray image: luminance (the default) or, for `mask-type:alpha`, coverage.
        func maskImage(_ mask: Node, for n: Node, ctm: CGAffineTransform) -> CGImage? {
            guard let m = context(gray: true) else { return nil }
            m.setFillColor(gray: 0, alpha: 1)
            m.fill(CGRect(x: 0, y: 0, width: size, height: size))
            m.concatenate(ctm)
            if mask.attrs["maskContentUnits"] == "objectBoundingBox", let b = path(n)?.boundingBoxOfPath {
                m.concatenate(CGAffineTransform(a: b.width, b: 0, c: 0, d: b.height, tx: b.minX, ty: b.minY))
            }
            var style = Style()
            style.flat = mask.value("mask-type") == "alpha"
            draw(children: mask.children, in: m, style: style)
            return m.makeImage()
        }

        func blurRadius(_ filter: Node) -> CGFloat? {
            guard let blur = filter.children.first(where: { $0.name == "feGaussianBlur" }) else { return nil }
            return numbers(blur.attrs["stdDeviation"] ?? "").first
        }

        func gaussian(_ image: CGImage, radius: CGFloat) -> CGImage? {
            guard radius > 0.1 else { return image }
            let input = CIImage(cgImage: image)
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            filter?.setValue(radius, forKey: kCIInputRadiusKey)
            guard let output = filter?.outputImage?.cropped(to: input.extent) else { return nil }
            return SVGLogo.blurContext.createCGImage(output, from: input.extent)
        }
    }
}

nonisolated extension SVGLogo {
    static func lineCap(_ s: String) -> CGLineCap { s == "round" ? .round : s == "square" ? .square : .butt }
    static func lineJoin(_ s: String) -> CGLineJoin { s == "round" ? .round : s == "bevel" ? .bevel : .miter }
}
