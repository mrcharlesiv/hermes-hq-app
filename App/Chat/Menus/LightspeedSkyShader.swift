// [thinking-drive] Lightspeed's sky's shaders (LightspeedSky.swift). One pass, two draws: the page's night (a full
// triangle), then the stars as additive capsules. No star is touched on the CPU: each comes from its instance number and
// the uniforms. Everything is in points and linear light; the layer is premultiplied, so rgb is what's added and alpha
// what's covered. Source rather than a .metal file: the phone compiles it when the panel first opens, so building the app
// needs no Metal toolchain.

extension LightspeedSky {
    nonisolated static let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

// Field for field with `LightspeedSky.Uniforms`.
struct WarpUniforms {
    float2 size;
    float2 centre;
    float2 landing;     // where the centre lands: the flash goes off there, ahead of it
    float4 card;        // x, y, width, height
    float4 tint;
    float scale;
    float reach;        // the sky's radius
    float far;          // the centre to the far corner
    float cardRadius;
    float beta;
    float kappa;        // how far the speed crowds the stars ahead
    float gamma;
    float stretch;
    float travel;
    float front;        // points; negative while there is none
    float iris;         // points; negative while there is none
    float veil;
    float underVeil;    // the veil behind the card
    float flash;
    float warp;
    float edr;          // the brightest a head may be
    float presence;
    float pass;         // negative while there is none
    float passAngle;
    float starCount;
};

constant float3 warp_hyper = float3(0.60, 0.82, 1.0);

static float warp_card(float2 p, constant WarpUniforms &u) {
    float2 half_ = u.card.zw * 0.5;
    float2 q = abs(p - (u.card.xy + half_)) - half_ + u.cardRadius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cardRadius;
}

// The drop: nothing inside the opening, a soft edge on it.
static float warp_opening(float r, constant WarpUniforms &u) {
    return u.iris < 0.0 ? 1.0 : smoothstep(u.iris - 90.0, u.iris, r);
}

static float3 warp_hash(uint n) {
    n = (n << 13U) ^ n;
    n = n * (n * n * 15731U + 789221U) + 1376312589U;
    uint3 k = n * uint3(n, n * 16807U, n * 48271U);
    return float3(k & uint3(0x7fffffffU)) / float(0x7fffffff);
}

// MARK: The night

struct NightOut { float4 position [[position]]; float2 point; };

vertex NightOut warp_night_vertex(uint vid [[vertex_id]], constant WarpUniforms &u [[buffer(0)]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    NightOut out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.point = uv * u.size;
    return out;
}

fragment float4 warp_night_fragment(NightOut in [[stage_in]], constant WarpUniforms &u [[buffer(0)]]) {
    float d = warp_card(in.point, u);
    float r = distance(in.point, u.centre);
    float inside = d < 0.0 ? 1.0 : 0.0;
    float alpha = mix(u.veil, u.underVeil, inside);

    // Light rising behind the card, its edge an eclipse's rim.
    float3 rgb = u.tint.rgb * exp(-max(d, 0.0) / 12.0) * u.warp * 0.5;
    rgb += mix(u.tint.rgb, warp_hyper, 0.6) * exp(-r / 55.0) * u.warp * 0.6;
    rgb += warp_hyper * (1.0 - smoothstep(0.0, 1.0, d)) * u.warp * u.edr * 0.8 * (1.0 - inside);
    rgb += warp_hyper * u.flash * 0.6 * exp(-distance(in.point, u.landing) / (u.reach * 0.3));
    // Behind the card it stays low, so the card's words read.
    rgb = mix(rgb, min(rgb, float3(u.flash > 0.01 ? 0.12 : 0.03)), inside);

    float open = warp_opening(r, u) * u.presence;
    return float4(rgb * open, alpha * open);
}

// MARK: The stars

struct StarOut {
    float4 position [[position]];
    float2 local;
    float2 point;
    float halfLength;
    float halfWidth;
    float3 ink;
};

static float3 warp_ink(float delta, float3 tint, float beta) {
    // A narrow ramp: red and amber only falling behind, white around the middle, blue-white ahead.
    float3 ramp = delta < 0.6 ? mix(float3(1.0, 0.16, 0.07), float3(1.0, 0.55, 0.2), delta / 0.6)
                : delta < 1.1 ? mix(float3(1.0, 0.55, 0.2), float3(1.0, 0.96, 0.9), (delta - 0.6) / 0.5)
                : mix(float3(1.0, 0.96, 0.9), warp_hyper, saturate((delta - 1.1) / 0.8));
    return mix(mix(tint, float3(1.0), 0.7), ramp, smoothstep(0.3, 0.75, beta));
}

static float warp_bend(float r, float front, thread float &glow) {
    if (front < 0.0) return r;
    float x = (r - front) / 30.0;
    float w = exp(-x * x);
    glow += w * 2.0;
    return r + 14.0 * w;
}

vertex StarOut warp_star_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant WarpUniforms &u [[buffer(0)]]) {
    float3 h = warp_hash(iid * 2U + 1U), h2 = warp_hash(iid * 2U + 2U);
    bool near_ = float(iid) >= u.starCount;
    float2 dir;
    float head, tail, width, bright, delta = 1.0, glow = 1.0;
    if (near_) {
        // The star that passes: out from behind the card and past, the only thick line in the sky.
        float a = u.passAngle;
        dir = float2(cos(a), sin(a));
        float p = max(u.pass, 0.0);
        head = u.far * 1.3 * p * p + 30.0;
        tail = max(0.0, head - 40.0 - u.far * 0.5 * p);
        width = 3.2;
        bright = u.pass < 0.0 ? 0.0 : u.edr;
    } else {
        float a = 6.2831853 * h.x;
        dir = float2(cos(a), sin(a));
        float pace = mix(0.75, 1.25, h.z);
        float s = fract(h.y + u.travel * pace);
        float tau = exp(mix(log(0.03), log(6.0), s));
        float length_ = mix(0.4, 1.4, h2.x);
        head = u.reach * u.kappa * tau;
        tail = head * exp(-u.stretch * length_);
        float c = u.kappa * tau;
        float cosPhi = (1.0 - c * c) / (1.0 + c * c);
        delta = 1.0 / (u.gamma * (1.0 - u.beta * cosPhi));
        width = h2.z < 0.7 ? 0.8 : h2.z < 0.93 ? 1.2 : 1.8;
        bright = min(delta * delta * delta, u.edr) * mix(0.35, 1.0, h2.y) * smoothstep(0.0, 0.06, s);
    }
    head = warp_bend(head, u.front, glow);
    tail = warp_bend(tail, u.front, glow);

    float halfLength = max(0.0, head - tail) * 0.5;
    float halfWidth = width * 0.5;
    float2 mid = u.centre + dir * (head + tail) * 0.5;
    float2 corner = float2((vid & 1) == 0 ? -1.0 : 1.0, (vid & 2) == 0 ? -1.0 : 1.0);
    float2 local = corner * float2(halfLength + halfWidth + 1.0, halfWidth + 1.0);
    float2 point = mid + dir * local.x + float2(-dir.y, dir.x) * local.y;

    StarOut out;
    out.position = float4(point.x / u.size.x * 2.0 - 1.0, 1.0 - point.y / u.size.y * 2.0, 0, 1);
    out.local = local;
    out.point = point;
    out.halfLength = halfLength;
    out.halfWidth = halfWidth;
    out.ink = (near_ ? warp_hyper : warp_ink(delta, u.tint.rgb, u.beta)) * bright * min(glow, 3.0);
    return out;
}

fragment float4 warp_star_fragment(StarOut in [[stage_in]], constant WarpUniforms &u [[buffer(0)]]) {
    float d = length(float2(max(abs(in.local.x) - in.halfLength, 0.0), in.local.y)) - in.halfWidth;
    float cover = saturate(0.5 - d * u.scale);
    // Bright at the head, dying away down the tail.
    float along = in.halfLength > 0.5 ? saturate((in.local.x + in.halfLength) / (2.0 * in.halfLength)) : 1.0;
    float3 rgb = in.ink * cover * exp(-(1.0 - along) * 3.0);
    if (warp_card(in.point, u) < 0.0) rgb = min(rgb * 0.08, float3(0.05));
    rgb *= warp_opening(distance(in.point, u.centre), u) * u.presence;
    return float4(rgb, 0);
}
"""#
}
