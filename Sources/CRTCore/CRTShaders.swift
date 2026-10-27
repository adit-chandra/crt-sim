// Metal source for the CRT pipeline. Compiled at runtime so the package builds
// without the separate Metal toolchain and works under `swift run`.
//
// Passes (all full-screen triangles):
//   1. signal      source video -> low-res linear "analog signal" (one row per scanline)
//   2. persist     signal + previous persist -> phosphor afterglow
//   3. bloom       persist -> downsample -> blur H -> blur V
//   4. crt         persist + bloom -> drawable (curvature, beam, mask, glow, noise)
//   passthrough    source -> drawable, used when the effect is off
//
// Output is either gamma-encoded SDR (8-bit targets) or linear extended-range
// light where 1.0 is SDR white and values up to `headroom` use the display's EDR.
//
// `Uniforms` must stay in sync with `CRTUniforms` in CRTRenderer.swift.

enum CRTShaders {
    static let source = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float outputW;
    float outputH;
    float tubeX;
    float tubeY;
    float tubeW;
    float tubeH;
    float signalW;
    float signalH;
    float time;
    float hasSignal;
    float rotation;
    float curvature;
    float scanlines;
    float signalType;
    float saturation;
    float maskType;
    float maskStrength;
    float maskScale;
    float glow;
    float convergence;
    float noise;
    float vignette;
    float brightness;
    float persistDecay;
    float mono;
    float monoR;
    float monoG;
    float monoB;
    float headroom;
    float outputLinear;
    float powerH;
    float powerV;
    float powerBoost;
    float staticAmount;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

constant float3 kLuma601 = float3(0.299, 0.587, 0.114);
constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);
constant float3x3 kRGBToYIQ = float3x3(float3(0.299, 0.596, 0.211),
                                       float3(0.587, -0.274, -0.523),
                                       float3(0.114, -0.322, 0.312));
constant float3x3 kYIQToRGB = float3x3(float3(1.0, 1.0, 1.0),
                                       float3(0.956, -0.272, -1.106),
                                       float3(0.621, -0.647, 1.703));

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Quarter turns clockwise: maps a display uv to the stored (unrotated) frame.
static float2 rotateUV(float2 uv, float r) {
    if (r < 0.5) return uv;
    if (r < 1.5) return float2(uv.y, 1.0 - uv.x);
    if (r < 2.5) return 1.0 - uv;
    return float2(1.0 - uv.y, uv.x);
}

static float3 srgbToLinear(float3 c) {
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

// Linear below 75% of `white`, then a smooth C1 shoulder that approaches `white`.
static float3 shoulder(float3 x, float white) {
    float knee = 0.75 * white;
    float span = white - knee;
    float3 t = max(x - knee, 0.0);
    return min(x, knee) + span * (1.0 - exp(-t / span));
}

// ---------------------------------------------------------------------------
// 1. Signal: box-filter each scanline's slice of the source, then band-limit
//    luma and (more heavily) chroma horizontally the way the chosen video
//    connection would. Signal types: 0 RGB, 1 S-Video, 2 composite, 3 RF.

static float3 sourceLine(texture2d<float> src, float x, float y, float lineH, float rot) {
    float3 c = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float yy = y + (float(i) - 1.5) * 0.25 * lineH;
        c += src.sample(linearClamp, rotateUV(float2(x, yy), rot)).rgb;
    }
    return c * 0.25;
}

fragment float4 signal_fragment(VOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                constant Uniforms &u [[buffer(0)]]) {
    float frame = floor(fmod(u.time * 30.0, 997.0));
    if (u.hasSignal < 0.5) {
        // No picture yet: analog snow.
        float2 cell = floor(in.position.xy * float2(0.5, 1.0));
        float n = hash12(cell + float2(frame * 13.7, frame * 7.3));
        float v = n * n * (0.42 + 0.08 * sin(in.uv.y * 12.0 - u.time * 9.0));
        return float4(float3(v), 1.0);
    }

    float type = u.signalType;
    float lineH = 1.0 / u.signalH;
    float vp = 2.0 / u.signalW;  // one square "virtual pixel" in uv
    // Luma and chroma bandwidth as Gaussian widths, in virtual pixels.
    float sigmaY = type < 0.5 ? 0.35 : type < 1.5 ? 0.6 : type < 2.5 ? 0.85 : 1.3;
    float sigmaC = type < 0.5 ? 0.35 : type < 1.5 ? 1.8 : type < 2.5 ? 3.0 : 3.8;

    float luma = 0.0;
    float2 chroma = float2(0.0);
    float wsum = 0.0;
    for (int k = -4; k <= 4; k++) {
        float o = float(k) * 0.6;
        float w = exp(-0.5 * o * o);
        float3 cy = sourceLine(src, in.uv.x + o * sigmaY * vp, in.uv.y, lineH, u.rotation);
        float3 cc = sourceLine(src, in.uv.x + o * sigmaC * vp, in.uv.y, lineH, u.rotation);
        luma += dot(cy, kLuma601) * w;
        chroma += (kRGBToYIQ * cc).yz * w;
        wsum += w;
    }
    luma /= wsum;
    chroma /= wsum;

    if (type > 1.5) {
        // Composite: luma and chroma share one wire. Saturated areas crawl with
        // the subcarrier's dot pattern, and sharp luma edges leak into chroma as
        // rainbows. The phase flips every line and every frame, as in NTSC.
        float line = floor(in.uv.y * u.signalH);
        float phase = (in.uv.x / vp) * 1.5707963 + (line + frame) * 3.1415927;
        float edge = dot(sourceLine(src, in.uv.x + vp, in.uv.y, lineH, u.rotation)
                         - sourceLine(src, in.uv.x - vp, in.uv.y, lineH, u.rotation), kLuma601);
        luma += 0.14 * sin(phase) * length(chroma);
        chroma += float2(cos(phase), sin(phase)) * abs(edge) * 0.22;
    }
    if (type > 2.5) {
        // RF: a faint delayed echo (multipath ghost) and tuner noise.
        float ghost = dot(sourceLine(src, in.uv.x - 0.025, in.uv.y, lineH, u.rotation), kLuma601);
        luma = (luma + 0.22 * ghost) / 1.12;
        luma += (hash12(float2(in.position.x, in.position.y + frame * 61.0)) - 0.5) * 0.06;
    }

    float3 yiq = float3(luma, chroma * u.saturation);
    float3 rgb = pow(saturate(kYIQToRGB * yiq), 2.2);

    if (u.mono > 0.5) {
        rgb = dot(rgb, kLuma709) * float3(u.monoR, u.monoG, u.monoB);
    }
    return float4(rgb, 1.0);
}

// ---------------------------------------------------------------------------
// 2. Phosphor persistence: bright pixels fade out instead of vanishing.

fragment float4 persist_fragment(VOut in [[stage_in]],
                                 texture2d<float> sig [[texture(0)]],
                                 texture2d<float> prev [[texture(1)]],
                                 constant Uniforms &u [[buffer(0)]]) {
    uint2 p = uint2(in.position.xy);
    float3 c = sig.read(p).rgb;
    float3 old = prev.read(p).rgb * u.persistDecay;
    return float4(max(c, old), 1.0);
}

// ---------------------------------------------------------------------------
// 3. Bloom / halation.

fragment float4 bloom_down_fragment(VOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]]) {
    float2 texel = abs(float2(dfdx(in.uv.x), dfdy(in.uv.y)));
    float3 c = float3(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            c += src.sample(linearClamp, in.uv + float2(i, j) * texel / 3.0).rgb;
        }
    }
    return float4(c / 9.0, 1.0);
}

fragment float4 blur_fragment(VOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant float2 &sigma [[buffer(1)]]) {
    float3 c = float3(0.0);
    float wsum = 0.0;
    for (int k = -6; k <= 6; k++) {
        float o = float(k) * 0.5;
        float w = exp(-0.5 * o * o);
        c += src.sample(linearClamp, in.uv + sigma * o).rgb * w;
        wsum += w;
    }
    return float4(c / wsum, 1.0);
}

// ---------------------------------------------------------------------------
// 4. The tube.

static float3 phosphorMask(float2 pix, float type, float strength, float scale) {
    float lo = 1.0 - strength;
    float3 m = float3(lo);
    float2 p = floor(pix / scale);
    if (type < 1.5) {
        // Aperture grille: continuous vertical RGB stripes.
        m[int(fmod(p.x, 3.0))] = 1.0;
    } else if (type < 2.5) {
        // Shadow mask: 2px phosphors, triads offset by half a triad every two rows.
        float x = p.x + floor(p.y * 0.5) * 3.0;
        m[int(fmod(floor(x * 0.5), 3.0))] = 1.0;
    } else {
        // Slot mask: stripes broken into staggered slots.
        m[int(fmod(p.x, 3.0))] = 1.0;
        float triad = floor(p.x / 3.0);
        if (fmod(p.y + fmod(triad, 2.0) * 2.0, 4.0) < 1.0) {
            m *= lo;
        }
    }
    return m;
}

// Adds display-space grain, then converts to the output encoding.
static float4 finish(float3 linearColor, float grain, constant Uniforms &u) {
    float3 encoded = pow(max(linearColor, 0.0), 1.0 / 2.2) + grain;
    if (u.outputLinear > 0.5) {
        return float4(pow(max(encoded, 0.0), 2.2), 1.0);
    }
    return float4(saturate(encoded), 1.0);
}

fragment float4 crt_fragment(VOut in [[stage_in]],
                             texture2d<float> sig [[texture(0)]],
                             texture2d<float> bloomTex [[texture(1)]],
                             constant Uniforms &u [[buffer(0)]]) {
    float2 pix = in.position.xy;
    float aspect = u.tubeW / u.tubeH;
    float2 uv = (pix - float2(u.tubeX, u.tubeY)) / float2(u.tubeW, u.tubeH);

    // Barrel distortion of a curved faceplate.
    float2 c = uv * 2.0 - 1.0;
    float k = u.curvature * 0.09;
    c *= float2(1.0 + c.y * c.y * k, 1.0 + c.x * c.x * k * aspect);

    // Power on/off: the raster collapses to a line, then to a dot.
    float2 cp = c / float2(max(u.powerH, 1e-3), max(u.powerV, 1e-3));
    float2 tuv = cp * 0.5 + 0.5;

    // Rounded-rectangle tube boundary, in half-heights. Positive outside.
    float radius = 0.04 + 0.1 * u.curvature;
    float2 q = abs(c) * float2(aspect, 1.0) - (float2(aspect, 1.0) - radius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;

    // Derivatives before any divergent control flow.
    float aa = max(fwidth(d), 1e-4);
    float lines = u.signalH;
    float ly = tuv.y * lines - 0.5;
    float fw = fwidth(ly);
    float rasterEdge = max(abs(cp.x), abs(cp.y));
    float raster = 1.0 - smoothstep(1.0, 1.0 + max(fwidth(rasterEdge), 1e-4), rasterEdge);

    float white = max(u.headroom, 1.0);
    float inside = 1.0 - smoothstep(-aa, aa, d);
    float3 glow = bloomTex.sample(linearClamp, saturate(tuv)).rgb * raster;
    float lit = saturate(u.powerV * 4.0) * min(u.powerBoost, 1.0);
    float3 bezel = glow * u.glow * 0.12 * exp(-max(d, 0.0) * 25.0) * lit;
    if (inside <= 0.0) {
        return finish(bezel, 0.0, u);
    }

    // Misconvergence: red and blue beams land slightly off, more so at the edges.
    float vp = 2.0 / u.signalW;
    float dx = u.convergence * vp * (0.35 + 0.65 * abs(c.x));
    float xr = tuv.x + dx;
    float xg = tuv.x;
    float xb = tuv.x - dx;

    // Electron beam: Gaussian spot per scanline, wider when brighter. The pixel
    // footprint is folded into the variance so fine scanlines don't alias.
    float base = floor(ly);
    float f = ly - base;
    float3 beam = float3(0.0);
    for (int i = -1; i <= 2; i++) {
        float ty = (base + float(i) + 0.5) / lines;
        float3 col = float3(sig.sample(linearClamp, float2(xr, ty)).r,
                            sig.sample(linearClamp, float2(xg, ty)).g,
                            sig.sample(linearClamp, float2(xb, ty)).b);
        float dist = f - float(i);
        float3 s = mix(float3(0.18), float3(0.3), sqrt(saturate(col)));
        float3 v2 = s * s + fw * fw / 12.0;
        beam += col * exp(-0.5 * dist * dist / v2) * rsqrt(v2) * 0.3989423;
    }
    float3 flat = float3(sig.sample(linearClamp, float2(xr, tuv.y)).r,
                         sig.sample(linearClamp, float2(xg, tuv.y)).g,
                         sig.sample(linearClamp, float2(xb, tuv.y)).b);
    float resolvable = 1.0 - smoothstep(0.45, 0.85, fw);
    float3 color = mix(flat, beam, u.scanlines * resolvable);

    // Phosphor mask in physical pixels. Compensating for the light it blocks
    // keeps average brightness; with EDR headroom the lit phosphors can exceed
    // SDR white instead of clipping, just as a real tube's did.
    if (u.maskType > 0.5 && u.maskStrength > 0.0) {
        float lo = 1.0 - u.maskStrength;
        float avg = (1.0 + 2.0 * lo) / 3.0;
        if (u.maskType > 2.5) {
            avg *= (3.0 + lo) / 4.0;
        }
        color *= phosphorMask(pix, u.maskType, u.maskStrength, u.maskScale) / avg;
    }

    // Halation inside the glass.
    float glowLum = dot(glow, kLuma709);
    color += glow * u.glow * (0.25 + 0.75 * saturate(glowLum * 2.0)) * 0.6;

    // Vignette and a soft shadow where the bezel meets the glass.
    float2 vv = saturate(tuv * (1.0 - tuv));
    color *= pow(saturate(vv.x * vv.y * 16.0), u.vignette * 0.35);
    color *= 0.7 + 0.3 * smoothstep(0.0, 0.05, -d);

    // Slow rolling hum bar.
    float bar = 0.5 + 0.5 * sin((tuv.y - u.time * 0.11) * 6.2831853 * 1.5);
    color *= 1.0 - u.noise * 0.12 * bar;

    color *= raster * u.powerBoost;

    // Channel-change static.
    float snow = hash12(floor(pix / 2.0) + floor(u.time * 60.0) * float2(7.0, 13.0));
    color = mix(color, float3(snow * snow * 0.5), u.staticAmount);

    color = shoulder(max(color * u.brightness, 0.0), min(white, 8.0));

    // Grain in display space so it reads evenly across tones; RF adds tuner snow.
    float grainAmount = u.noise * 0.07 + (u.signalType > 2.5 ? 0.04 : 0.0);
    float n = hash12(pix + fract(u.time * 7.13) * 3971.0) - 0.5;
    return finish(mix(bezel, color, inside), n * grainAmount * inside * raster, u);
}

fragment float4 passthrough_fragment(VOut in [[stage_in]],
                                     texture2d<float> src [[texture(0)]],
                                     constant Uniforms &u [[buffer(0)]]) {
    float2 uv = (in.position.xy - float2(u.tubeX, u.tubeY)) / float2(u.tubeW, u.tubeH);
    if (u.hasSignal < 0.5 || any(uv < 0.0) || any(uv > 1.0)) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    float3 c = src.sample(linearClamp, rotateUV(uv, u.rotation)).rgb;
    return float4(u.outputLinear > 0.5 ? srgbToLinear(c) : c, 1.0);
}
"""#
}
