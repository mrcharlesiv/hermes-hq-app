// [first-run] How the stage is drawn: one Metal pipeline that draws a list of soft round marks (discs, rings, radial
// glows, the shaded globe, capsules for the eyes and the arcs' segments), one instanced draw per layer per frame. Each
// layer view owns three instance buffers made once and rewritten in place, so a frame allocates nothing of ours.
// Colours are blended as the mock's canvas blends them (premultiplied, in the colour's own encoding); a mark with
// `additive` set adds its light instead (the canvas's 'lighter', the lit LEDs' bloom).

import Metal
import QuartzCore
import UIKit

/// One mark, as the shader reads it (five float4s: 80 bytes).
nonisolated struct ArrivalMark {
    /// x, y (mock points), extent (how far from the centre it can draw), kind.
    var a: SIMD4<Float>
    /// Per kind: see `ArrivalGPU.source`.
    var p: SIMD4<Float>
    var c0: SIMD4<Float>
    var c1: SIMD4<Float>
    var c2: SIMD4<Float>

    enum Kind: Float { case disc = 0, ring = 1, glow = 2, globe = 3, capsule = 4 }
}

/// What every mark of a layer shares: how mock points land on the view.
nonisolated struct ArrivalUniforms {
    /// View size in points, then points per mock point.
    var view: SIMD4<Float>      // w, h, k, pixels per point
    /// The mock → view offset, then the camera's pivot (mock points).
    var place: SIMD4<Float>     // ox, oy, pivotX, pivotY
    var zoom: SIMD4<Float>      // 1 + cam.z, 0, 0, 0
}

@MainActor final class ArrivalGPU {
    static let shared = ArrivalGPU()
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let pipeline: MTLRenderPipelineState?

    private init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        var state: MTLRenderPipelineState?
        if let device, let library = try? device.makeLibrary(source: Self.source, options: nil) {
            let description = MTLRenderPipelineDescriptor()
            description.vertexFunction = library.makeFunction(name: "arrivalVertex")
            description.fragmentFunction = library.makeFunction(name: "arrivalFragment")
            let colour = description.colorAttachments[0]!
            colour.pixelFormat = .bgra8Unorm
            colour.isBlendingEnabled = true
            colour.rgbBlendOperation = .add
            colour.alphaBlendOperation = .add
            colour.sourceRGBBlendFactor = .one
            colour.sourceAlphaBlendFactor = .one
            colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            state = try? device.makeRenderPipelineState(descriptor: description)
        }
        pipeline = state
        if state == nil { AppLog.note("onboard", "first-run stage: no Metal pipeline, the stage stays empty") }
    }

    /// The marks' shader. Every mark is a quad round its centre; the fragment works out its cover in mock points.
    ///   disc     p.w additive · c0 colour+alpha
    ///   ring     p.x line width · c0
    ///   glow     p.x inner radius, p.y outer radius, p.z the middle stop (0…1) · c0 inner, c1 middle, c2 outer
    ///   globe    p.xy the bright spot's offset, p.z its radius · c0 at 0, c1 at 0.7, c2 at 1 (a two-circle gradient)
    ///   capsule  p.x half length, p.y radius, p.z angle · c0
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Mark { float4 a; float4 p; float4 c0; float4 c1; float4 c2; };
    struct Uniforms { float4 view; float4 place; float4 zoom; };
    struct Out { float4 position [[position]]; float2 local; uint index [[flat]]; };

    vertex Out arrivalVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device Mark *marks [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
        Mark m = marks[iid];
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float extent = m.a.z + 1.5 / max(u.view.z * u.view.w, 0.001);
        float2 local = corner * extent;
        float2 p = m.a.xy + local;
        p = u.place.zw + (p - u.place.zw) * u.zoom.x;
        float2 v = u.place.xy + p * u.view.z;
        Out o;
        o.position = float4(v.x / u.view.x * 2.0 - 1.0, 1.0 - v.y / u.view.y * 2.0, 0, 1);
        o.local = local;
        o.index = iid;
        return o;
    }

    float4 premul(float4 c, float cover) { float a = c.a * cover; return float4(c.rgb * a, a); }

    fragment float4 arrivalFragment(Out in [[stage_in]], const device Mark *marks [[buffer(0)]],
                                    constant Uniforms &u [[buffer(1)]]) {
        Mark m = marks[in.index];
        float aa = 1.0 / max(u.view.z * u.view.w * u.zoom.x, 0.001);
        float2 q = in.local;
        float d = length(q);
        int kind = int(m.a.w + 0.5);
        if (kind == 0) {
            float cover = clamp((m.a.z - d) / aa + 0.5, 0.0, 1.0);
            float4 c = premul(m.c0, cover);
            if (m.p.w > 0.5) c.a = 0.0;
            return c;
        }
        if (kind == 1) {
            float half_w = m.p.x * 0.5;
            float cover = clamp((half_w - abs(d - (m.a.z - half_w - 0.0))) / aa + 0.5, 0.0, 1.0);
            return premul(m.c0, cover);
        }
        if (kind == 2) {
            float r0 = m.p.x, r1 = m.p.y, mid = m.p.z;
            float t = clamp((d - r0) / max(r1 - r0, 0.001), 0.0, 1.0);
            float4 c = t < mid ? mix(m.c0, m.c1, t / max(mid, 0.001)) : mix(m.c1, m.c2, (t - mid) / max(1.0 - mid, 0.001));
            return premul(c, 1.0);
        }
        if (kind == 3) {
            float R = m.a.z;
            float cover = clamp((R - d) / aa + 0.5, 0.0, 1.0);
            float2 f = m.p.xy;
            float rf = m.p.z, dr = R - rf;
            float2 a = q - f;
            float A = dot(f, f) - dr * dr, B = 2.0 * (dot(a, f) - rf * dr), C = dot(a, a) - rf * rf;
            float t;
            if (abs(A) < 1e-4) { t = -C / B; }
            else { float disc = max(B * B - 4.0 * A * C, 0.0); t = max((-B + sqrt(disc)) / (2.0 * A), (-B - sqrt(disc)) / (2.0 * A)); }
            t = clamp(t, 0.0, 1.0);
            float4 c = t < 0.7 ? mix(m.c0, m.c1, t / 0.7) : mix(m.c1, m.c2, (t - 0.7) / 0.3);
            return premul(c, cover);
        }
        float angle = m.p.z;
        float2 axis = float2(cos(angle), sin(angle));
        float along = clamp(dot(q, axis), -m.p.x, m.p.x);
        float dist = length(q - axis * along);
        float cover = clamp((m.p.y - dist) / aa + 0.5, 0.0, 1.0);
        return premul(m.c0, cover);
    }
    """
}

/// A layer of the stage: a Metal surface the stage fills with marks each frame. It never takes a touch itself (the
/// stage's touch view says which touches it keeps).
final class ArrivalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metal: CAMetalLayer { layer as! CAMetalLayer }   // swiftlint:disable:this force_cast
    static let capacity = 6144
    private var buffers: [MTLBuffer] = []
    private var slot = 0
    private let inFlight = DispatchSemaphore(value: 3)
    /// The marks of the frame being written (into the buffer `slot`).
    private(set) var count = 0
    private var pointer: UnsafeMutablePointer<ArrivalMark>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        let gpu = ArrivalGPU.shared
        metal.device = gpu.device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = false
        metal.contentsScale = traitCollection.displayScale
        if let device = gpu.device {
            for _ in 0..<3 {
                if let buffer = device.makeBuffer(length: MemoryLayout<ArrivalMark>.stride * Self.capacity, options: .storageModeShared) {
                    buffers.append(buffer)
                }
            }
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        metal.contentsScale = scale
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if metal.drawableSize != size { metal.drawableSize = size }
    }

    /// Starts a frame's list. False when there is nothing to draw with (no Metal, or every buffer still in flight).
    func begin() -> Bool {
        guard buffers.count == 3, ArrivalGPU.shared.pipeline != nil else { return false }
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        pointer = buffers[slot].contents().bindMemory(to: ArrivalMark.self, capacity: Self.capacity)
        count = 0
        return true
    }

    @inline(__always) func add(_ kind: ArrivalMark.Kind, x: Double, y: Double, extent: Double, p: SIMD4<Float> = .zero,
                               c0: SIMD4<Float>, c1: SIMD4<Float> = .zero, c2: SIMD4<Float> = .zero) {
        guard let pointer, count < Self.capacity else { return }
        pointer[count] = ArrivalMark(a: SIMD4(Float(x), Float(y), Float(extent), kind.rawValue), p: p, c0: c0, c1: c1, c2: c2)
        count += 1
    }

    /// Draws the frame's list and hands the buffer on.
    func commit(uniforms: ArrivalUniforms) {
        let gpu = ArrivalGPU.shared
        let buffer = buffers[slot]
        slot = (slot + 1) % 3
        pointer = nil
        guard let queue = gpu.queue, let pipeline = gpu.pipeline, let drawable = metal.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let encoder = commands.makeRenderCommandEncoder(descriptor: pass) {
            if count > 0 {
                var u = uniforms
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&u, length: MemoryLayout<ArrivalUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&u, length: MemoryLayout<ArrivalUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
            }
            encoder.endEncoding()
        }
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.present(drawable)
        commands.commit()
    }
}
