// [thinking-drive] Lightspeed's sky, behind the card: its shaders (LightspeedSkyShader.swift) on a layer of its own. Made when the drive first
// draws (never in the calm cases) and hidden when it fades. A frame the GPU can't take yet is skipped, never waited for,
// so a busy GPU costs a frame of sky and not a frame of the knob. Brighter than white on screens that can.

import Metal
import QuartzCore
import UIKit
import os

final class LightspeedSky {
    /// Field for field with `WarpUniforms`.
    nonisolated struct Uniforms {
        var size: SIMD2<Float>
        var centre: SIMD2<Float>
        var landing: SIMD2<Float>
        var card: SIMD4<Float>
        var tint: SIMD4<Float>
        var scale: Float
        var reach: Float
        var far: Float
        var cardRadius: Float
        var beta: Float
        var kappa: Float
        var gamma: Float
        var stretch: Float
        var travel: Float
        var front: Float
        var iris: Float
        var veil: Float
        var underVeil: Float
        var flash: Float
        var warp: Float
        var edr: Float
        var presence: Float
        var pass: Float
        var passAngle: Float
        var starCount: Float
    }

    nonisolated private struct Pipelines: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let night: MTLRenderPipelineState
        let stars: MTLRenderPipelineState

        static func make() -> Pipelines? {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: LightspeedSky.shaderSource, options: nil) else { return nil }
            func pipeline(_ vertex: String, _ fragment: String, blend: (MTLRenderPipelineColorAttachmentDescriptor) -> Void) -> MTLRenderPipelineState? {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = library.makeFunction(name: fragment)
                guard let color = d.colorAttachments[0] else { return nil }
                color.pixelFormat = LightspeedSky.format
                blend(color)
                return try? device.makeRenderPipelineState(descriptor: d)
            }
            guard let night = pipeline("warp_night_vertex", "warp_night_fragment", blend: { _ in }),
                  let stars = pipeline("warp_star_vertex", "warp_star_fragment", blend: {
                      $0.isBlendingEnabled = true
                      $0.rgbBlendOperation = .add
                      $0.alphaBlendOperation = .add
                      $0.sourceRGBBlendFactor = .one
                      $0.destinationRGBBlendFactor = .one
                      $0.sourceAlphaBlendFactor = .zero
                      $0.destinationAlphaBlendFactor = .one
                  }) else { return nil }
            return Pipelines(device: device, queue: queue, night: night, stars: stars)
        }
    }

    nonisolated private static let format = MTLPixelFormat.rgba16Float
    private static let starCount = 1400
    private static var pipelines: Pipelines?
    private static var preparing = false
    /// No Metal here: the backdrop draws its older lines instead.
    private(set) static var unavailable = false

    /// Off the main thread, as the panel opens.
    static func prepare() {
        guard pipelines == nil, !preparing, !unavailable else { return }
        preparing = true
        Task.detached(priority: .userInitiated) {
            let made = Pipelines.make()
            await MainActor.run {
                preparing = false
                pipelines = made
                unavailable = made == nil
                if made == nil { AppLog.trace("thinking", "lightspeed sky: no Metal, drawing the lines") }
            }
        }
    }

    nonisolated private final class Stats: @unchecked Sendable {
        private let peak = OSAllocatedUnfairLock(initialState: 0.0)
        func note(_ seconds: Double) { peak.withLock { $0 = max($0, seconds) } }
        func take() -> Double { peak.withLock { let v = $0; $0 = 0; return v } }
    }

    let layer = CAMetalLayer()
    /// One in flight, one queued and one on glass: the three drawables, so `nextDrawable` never has to wait.
    private let inFlight = DispatchSemaphore(value: 1)
    private let stats = Stats()
    private var frames = 0
    private var skips = 0
    private var headroom: CGFloat = 1

    init?() {
        guard let pipelines = Self.pipelines else { return nil }
        layer.device = pipelines.device
        layer.pixelFormat = Self.format
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 3
        layer.contentsScale = 2
        layer.actions = ["hidden": NSNull(), "bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        layer.isHidden = true
    }

    func layout(bounds: CGRect) {
        layer.frame = bounds
        layer.drawableSize = CGSize(width: bounds.width * 2, height: bounds.height * 2)
    }

    /// `knob` and `card` in the sky's space; `headroom`: how far past white this screen goes now.
    func render(_ s: LightspeedState, knob: CGPoint, card: CGRect, cardRadius: CGFloat, tint: UIColor, dark: Bool, headroom: CGFloat) {
        guard let pipelines = Self.pipelines, s.presence >= 0.01, layer.bounds.width > 0 else { return hide() }
        layer.isHidden = false
        self.headroom = headroom
        guard inFlight.wait(timeout: .now()) == .success else {
            skips += 1
            return
        }
        guard let drawable = layer.nextDrawable(), let commands = pipelines.queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        var u = uniforms(s, knob: knob, card: card, cardRadius: cardRadius, tint: tint, dark: dark, headroom: headroom)
        encoder.setRenderPipelineState(pipelines.night)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(pipelines.stars)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: Self.starCount + 1)
        encoder.endEncoding()
        let inFlight = inFlight, stats = stats
        commands.addCompletedHandler { done in
            stats.note(done.gpuEndTime - done.gpuStartTime)
            inFlight.signal()
        }
        commands.present(drawable)
        commands.commit()
        frames += 1
    }

    func hide() {
        guard !layer.isHidden else { return }
        layer.isHidden = true
        AppLog.trace("thinking", "lightspeed sky: \(frames) frames, \(skips) skipped, peak GPU \(Int(stats.take() * 1000)) ms, headroom \(headroom)")
        frames = 0
        skips = 0
    }

    private func uniforms(_ s: LightspeedState, knob: CGPoint, card: CGRect, cardRadius: CGFloat, tint: UIColor, dark: Bool, headroom: CGFloat) -> Uniforms {
        let size = layer.bounds.size
        // On the knob, or up to just behind the card's top edge: the light rises over it.
        let landing = CGPoint(x: card.midX, y: card.minY + 24)
        let centre = CGPoint(x: knob.x + (landing.x - knob.x) * s.centred,
                             y: knob.y + (landing.y - knob.y) * s.centred + s.jolt)
        let far = hypot(max(centre.x, size.width - centre.x), max(centre.y, size.height - centre.y))
        let beta = Float(s.beta)
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linear(_ v: CGFloat) -> Float { Float(pow(max(0, v), 2.2)) }
        let veil = Float(s.veil)
        return Uniforms(size: SIMD2(Float(size.width), Float(size.height)),
                        centre: SIMD2(Float(centre.x), Float(centre.y)),
                        landing: SIMD2(Float(landing.x), Float(landing.y)),
                        card: SIMD4(Float(card.minX), Float(card.minY), Float(card.width), Float(card.height)),
                        tint: SIMD4(linear(r), linear(g), linear(b), 1),
                        scale: 2,
                        reach: Float(max(size.width, size.height)) * 0.5,
                        far: Float(far),
                        cardRadius: Float(cardRadius),
                        beta: beta,
                        kappa: sqrt((1 - beta) / (1 + beta)),
                        gamma: 1 / sqrt(max(0.0001, 1 - beta * beta)),
                        stretch: Float(s.stretch),
                        travel: Float(s.travel),
                        front: s.front < 0 ? -1 : Float(s.front * far),
                        iris: s.iris < 0 ? -1 : Float(s.iris * (far + 90)),
                        veil: veil,
                        // Dark words on a light card need their light kept.
                        underVeil: dark ? veil : min(veil, 0.55),
                        flash: Float(s.flash),
                        warp: Float(s.warp),
                        edr: Float(min(3, max(1, headroom))),
                        presence: Float(s.presence),
                        pass: Float(s.pass ?? -1),
                        passAngle: Float(s.passAngle),
                        starCount: Float(Self.starCount))
    }
}
