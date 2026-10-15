//
//  Shaders.metal
//  openshape3d
//
//  All render pipelines for the CAD viewport: background gradient, lit solids,
//  procedural grid, unlit color (gizmo/lines), feature edges, sketch lines.
//

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// Section view (spec §16.1): true when the fragment lies beyond the clip
// plane and must be discarded. clipEnabled == 0 keeps everything.
static bool sectionClipped(float3 worldPosition, constant FrameUniforms &frame) {
    return frame.clipEnabled > 0.5
        && dot(worldPosition, frame.clipPlane.xyz) + frame.clipPlane.w < 0.0;
}

// Visualization (spec §14): the sun's colour, and how far its light wraps
// around a surface. The modelling headlight keeps its soft half-Lambert wrap
// in white; a visualization sun is coloured and casts a firmer terminator.
static float3 keyLightColor(constant FrameUniforms &frame) {
    return frame.keyLightColor.w > 0.5 ? frame.keyLightColor.rgb : float3(1.0);
}
static float keyLightWrap(constant FrameUniforms &frame) {
    return frame.keyLightColor.w > 0.5 ? 0.2 : 0.5;
}

// MARK: - Background gradient (fullscreen triangle, no buffers)

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut vertex_fullscreen(uint vid [[vertex_id]]) {
    // Oversized triangle covering the screen: (-1,-1), (3,-1), (-1,3)
    float2 pos = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    FullscreenOut out;
    out.position = float4(pos, 0.999999, 1.0);
    out.uv = pos * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_backgroundGradient(
    FullscreenOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]]
) {
    float t = saturate(in.uv.y);
    float4 color = mix(frame.backgroundBottom, frame.backgroundTop, t);
    // Subtle radial vignette so the center reads brighter, CAD-style.
    float2 centered = in.uv - float2(0.5, 0.45);
    float vignette = 1.0 - 0.18 * dot(centered, centered) * 2.2;
    return float4(color.rgb * vignette, 1.0);
}

// MARK: - Surface analysis (Display Modes ▸ Zebra / Curvature Map)

/// Zebra (1): black and white bands of the reflected view direction — a
/// break in a band's flow is a break in tangency or curvature. Curvature
/// (2): the normal's change per unit of surface, from screen-space
/// derivatives, as a log-scaled ramp by radius: blue flat (r ≥ 1 m), green
/// gentle, yellow, red tight (r ≤ 1 mm).
static float3 surfaceAnalysisColor(float mode, float3 N, float3 V, float3 worldPosition, float ndl) {
    if (mode < 1.5) {
        float3 R = reflect(-V, N);
        float band = step(0.5, fract(atan2(R.z, R.x) * 1.9098593 + R.y * 3.0));
        return mix(float3(0.06), float3(0.97), band) * (0.88 + 0.12 * ndl);
    }
    float dp = length(fwidth(worldPosition));
    float k = dp > 1e-7 ? length(fwidth(N)) / dp : 0.0;
    float t = k < 1e-4 ? 0.0 : saturate((log10(k) + 3.0) / 3.0);
    float3 ramp = t < 0.5
        ? mix(float3(0.15, 0.40, 0.95), float3(0.25, 0.85, 0.35), t * 2.0)
        : mix(float3(0.95, 0.85, 0.20), float3(0.95, 0.20, 0.15), (t - 0.5) * 2.0);
    return ramp * (0.6 + 0.4 * ndl);
}

// MARK: - Lit solid bodies

struct LitOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    /// Body-local, mm: where a material pattern is computed.
    float3 localPosition;
    float3 localNormal;
};

// MARK: - Material patterns (spec §14 texture mapping)
//
// Computed from the body's own coordinates, so a pattern is fixed to the part.
// Mirrored in renderer.ts (LIT_FS) — keep the two in step.

static float patternHash(float3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

static float patternNoise(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(patternHash(i + float3(0, 0, 0)), patternHash(i + float3(1, 0, 0)), f.x),
                   mix(patternHash(i + float3(0, 1, 0)), patternHash(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(patternHash(i + float3(0, 0, 1)), patternHash(i + float3(1, 0, 1)), f.x),
                   mix(patternHash(i + float3(0, 1, 1)), patternHash(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

static float patternFbm(float3 p) {
    return patternNoise(p) * 0.5 + patternNoise(p * 2.03 + 1.7) * 0.3 + patternNoise(p * 4.01 + 3.1) * 0.2;
}

/// The albedo with `pattern` over it: 1 wood grain, 2 brushed, 3 carbon fibre,
/// 4 knurl, 5 speckle, 6 marble (MaterialPattern.shaderValue); `size` is one
/// repeat in mm, `rotation` radians.
static float3 patternAlbedo(float3 albedo, float pattern, float size, float rotation, float3 P, float3 N) {
    if (pattern < 0.5) return albedo;
    float c = cos(rotation), s = sin(rotation);
    float3 q = P / max(size, 1e-4);
    // The plane the surface mostly faces, for flat patterns.
    float3 a = abs(N);
    float2 uv = (a.x > a.y && a.x > a.z) ? q.yz : ((a.y > a.z) ? q.xz : q.xy);
    uv = float2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    float k = 1.0;
    if (pattern < 1.5) {
        // Rings round the part's (turned) vertical axis, wobbling, with fibres.
        float3 r = float3(c * q.x - s * q.z, q.y, s * q.x + c * q.z);
        float d = length(r.xz) + patternFbm(r * 0.35) * 1.2;
        float ring = fract(d);
        float early = smoothstep(0.0, 0.3, ring) * smoothstep(1.0, 0.6, ring);
        float fibre = patternNoise(float3(r.x * 3.0, r.y * 40.0, r.z * 3.0));
        k = mix(0.62, 1.06, early) * (0.92 + 0.14 * fibre);
    } else if (pattern < 2.5) {
        // Fine streaks along one direction.
        float n = patternNoise(float3(uv.x * 0.6, uv.y * 120.0, 0.0)) * 0.6
            + patternNoise(float3(uv.x * 2.0, uv.y * 400.0, 1.7)) * 0.4;
        k = 0.86 + 0.24 * n;
    } else if (pattern < 3.5) {
        // 2×2 twill: tows across and along in diagonal steps, each with a sheen.
        float2 g = uv * 2.0;
        float2 cell = floor(g);
        float2 f = g - cell;
        float step2 = (cell.x + cell.y) * 0.25;
        bool across = step2 - floor(step2) < 0.5;
        float along = across ? f.x : f.y;
        float sheen = 0.5 + 0.5 * sin(along * 3.14159265);
        float fibres = patternNoise(float3((across ? f.y : f.x) * 60.0, cell.x, cell.y));
        k = (0.55 + 0.75 * sheen) * (0.92 + 0.12 * fibres);
    } else if (pattern < 4.5) {
        // Diamond knurl: two crossing sets of ridges.
        float d1 = abs(fract(uv.x + uv.y) - 0.5) * 2.0;
        float d2 = abs(fract(uv.x - uv.y) - 0.5) * 2.0;
        float h = min(d1, d2);
        k = 0.5 + 0.7 * smoothstep(0.0, 0.7, h) + 0.08 * (d1 - d2);
    } else if (pattern < 5.5) {
        // Speckle: mottling with dark and light grains.
        float mottle = patternNoise(q * 1.5);
        float dark = step(0.78, patternNoise(q * 6.0 + 11.0));
        float light = step(0.8, patternNoise(q * 7.0 + 23.0));
        k = (0.88 + 0.22 * mottle) * (1.0 - 0.4 * dark) * (1.0 + 0.25 * light);
    } else {
        // Marble: thin wandering veins.
        float v = sin((q.x + q.y * 0.5 + q.z * 0.3) * 6.2831853 + patternFbm(q * 1.5) * 5.0);
        float vein = pow(1.0 - abs(v), 30.0);
        k = (1.0 - 0.55 * vein) * (0.96 + 0.06 * patternNoise(q * 4.0));
    }
    return albedo * k;
}

vertex LitOut vertex_lit(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    const device float3 *normals [[buffer(BufferIndexNormals)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float4 world = body.modelMatrix * float4(positions[vid], 1.0);
    LitOut out;
    out.position = frame.viewProjectionMatrix * world;
    out.worldPosition = world.xyz;
    // Uniform scale + rotation: transforming with the model matrix and
    // renormalizing is exact.
    out.worldNormal = normalize((body.modelMatrix * float4(normals[vid], 0.0)).xyz);
    out.localPosition = positions[vid];
    out.localNormal = normals[vid];
    return out;
}

fragment float4 fragment_lit(
    LitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    if (sectionClipped(in.worldPosition, frame)) {
        discard_fragment();
    }
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 L = normalize(-frame.keyLightDirection.xyz);

    float3 albedo = patternAlbedo(body.baseColor.rgb, body.pattern, body.patternSize, body.patternRotation,
                                  in.localPosition, normalize(in.localNormal));
    float alpha = body.baseColor.a;
    if (body.selectionState == SelectionStateSelected) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.45);
    } else if (body.selectionState == SelectionStateHovered) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.18);
    } else if (body.selectionState == SelectionStatePreview) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.30);
        alpha = body.baseColor.a; // Tool Preview Opacity (the renderer sets it)
    }

    // Half-lambert wrap for a soft CAD look that never goes fully dark.
    float wrap = keyLightWrap(frame);
    float ndl = saturate(dot(N, L)) * (1.0 - wrap) + wrap;
    float3 hemi = mix(frame.groundColor.rgb, frame.skyColor.rgb, N.y * 0.5 + 0.5);
    float3 H = normalize(L + V);
    // Material-lite (visualization v1): roughness 0 keeps the legacy fixed
    // highlight so default bodies render exactly as before; roughness > 0
    // maps to highlight tightness/strength, metallic tints the highlight
    // toward the albedo and damps diffuse.
    float specPower = 48.0;
    float specStrength = 0.30;
    if (body.roughness > 0.0) {
        float r = clamp(body.roughness, 0.05, 1.0);
        specPower = exp2(mix(9.0, 1.5, r));   // 512 (polished) … ~2.8 (matte)
        specStrength = mix(0.85, 0.06, r);
    }
    float3 specTint = mix(float3(1.0), albedo, body.metallic);
    float3 sun = keyLightColor(frame);
    float3 spec = pow(saturate(dot(N, H)), specPower) * specStrength * specTint * sun;
    float rim = pow(1.0 - saturate(dot(N, V)), 3.0) * 0.12;
    float3 rimColor = (body.selectionState == SelectionStateSelected)
        ? frame.accentColor.rgb : float3(1.0);

    float3 diffuse = albedo * (hemi * 0.45 + ndl * 0.70 * sun) * (1.0 - body.metallic * 0.55);
    float3 color = diffuse + spec + rim * rimColor;
    // Visualization: polished and metal surfaces mirror the environment's
    // sky and ground (a cheap stand-in for image-based lighting).
    if (frame.keyLightColor.w > 0.5) {
        float3 R = reflect(-V, N);
        float3 env = mix(frame.groundColor.rgb, frame.skyColor.rgb, saturate(R.y * 0.5 + 0.5));
        float gloss = 1.0 - (body.roughness > 0.0 ? body.roughness : 0.6);
        color += env * specTint * (0.08 + 0.55 * body.metallic) * gloss;
    }
    // Glow: the surface shows its own colour, brighter, whatever the light.
    color = mix(color, albedo * (1.0 + body.emission), saturate(body.emission));
    float analysis = frame.gridParams.w;
    if (analysis > 0.5 && body.selectionState != SelectionStatePreview) {
        color = surfaceAnalysisColor(analysis, N, V, in.worldPosition, ndl);
        if (body.selectionState == SelectionStateSelected) {
            color = mix(color, frame.accentColor.rgb, 0.25);
        }
    }
    return float4(color, alpha);
}

// MARK: - Lit + albedo texture (imported OBJ / glTF / USDZ bodies)

struct LitTexturedOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 uv;
};

vertex LitTexturedOut vertex_litTextured(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    const device float3 *normals [[buffer(BufferIndexNormals)]],
    const device float2 *texcoords [[buffer(BufferIndexTexcoords)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float4 world = body.modelMatrix * float4(positions[vid], 1.0);
    LitTexturedOut out;
    out.position = frame.viewProjectionMatrix * world;
    out.worldPosition = world.xyz;
    out.worldNormal = normalize((body.modelMatrix * float4(normals[vid], 0.0)).xyz);
    out.uv = texcoords[vid];
    return out;
}

/// The `fragment_lit` model with the albedo read from the texture (times the
/// material's baseColor factor), so an imported textured part shades like a
/// native body — same lights, same selection tint, same section clip.
fragment float4 fragment_litTextured(
    LitTexturedOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]],
    texture2d<float> tex [[texture(0)]]
) {
    if (sectionClipped(in.worldPosition, frame)) {
        discard_fragment();
    }
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    mip_filter::linear, address::repeat);
    float4 texel = tex.sample(linearSampler, in.uv);
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 L = normalize(-frame.keyLightDirection.xyz);

    float3 albedo = texel.rgb * body.baseColor.rgb;
    float alpha = body.baseColor.a * texel.a;
    if (body.selectionState == SelectionStateSelected) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.45);
    } else if (body.selectionState == SelectionStateHovered) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.18);
    } else if (body.selectionState == SelectionStatePreview) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.30);
        alpha = body.baseColor.a; // Tool Preview Opacity (the renderer sets it)
    }
    float wrap = keyLightWrap(frame);
    float ndl = saturate(dot(N, L)) * (1.0 - wrap) + wrap;
    float3 hemi = mix(frame.groundColor.rgb, frame.skyColor.rgb, N.y * 0.5 + 0.5);
    float3 H = normalize(L + V);
    float specPower = 48.0;
    float specStrength = 0.30;
    if (body.roughness > 0.0) {
        float r = clamp(body.roughness, 0.05, 1.0);
        specPower = exp2(mix(9.0, 1.5, r));
        specStrength = mix(0.85, 0.06, r);
    }
    float3 specTint = mix(float3(1.0), albedo, body.metallic);
    float3 sun = keyLightColor(frame);
    float3 spec = pow(saturate(dot(N, H)), specPower) * specStrength * specTint * sun;
    float rim = pow(1.0 - saturate(dot(N, V)), 3.0) * 0.12;
    float3 rimColor = (body.selectionState == SelectionStateSelected)
        ? frame.accentColor.rgb : float3(1.0);
    float3 diffuse = albedo * (hemi * 0.45 + ndl * 0.70 * sun) * (1.0 - body.metallic * 0.55);
    float3 color = diffuse + spec + rim * rimColor;
    // Visualization: polished and metal surfaces mirror the environment's
    // sky and ground (a cheap stand-in for image-based lighting).
    if (frame.keyLightColor.w > 0.5) {
        float3 R = reflect(-V, N);
        float3 env = mix(frame.groundColor.rgb, frame.skyColor.rgb, saturate(R.y * 0.5 + 0.5));
        float gloss = 1.0 - (body.roughness > 0.0 ? body.roughness : 0.6);
        color += env * specTint * (0.08 + 0.55 * body.metallic) * gloss;
    }
    color = mix(color, albedo * (1.0 + body.emission), saturate(body.emission));
    return float4(color, alpha);
}

// MARK: - Decals (spec §14)

/// A body drawn again (`vertex_lit`) keeping only what falls inside a
/// decal's box: projected along the decal's normal, faded where the surface
/// turns away from it, lit like a matte print on the surface.
fragment float4 fragment_decal(
    LitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant DecalUniforms &decal [[buffer(BufferIndexDecal)]],
    texture2d<float> tex [[texture(0)]]
) {
    if (sectionClipped(in.worldPosition, frame)) {
        discard_fragment();
    }
    float3 d = in.worldPosition - decal.center.xyz;
    float s = dot(d, decal.axisU.xyz) / decal.axisU.w;
    float t = dot(d, decal.axisV.xyz) / decal.axisV.w;
    float3 N = normalize(in.worldNormal);
    float facing = dot(N, decal.normal.xyz);
    if (abs(s) > 1.0 || abs(t) > 1.0 || abs(dot(d, decal.normal.xyz)) > decal.normal.w || facing < 0.1) {
        discard_fragment();
    }
    constexpr sampler clampSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 texel = tex.sample(clampSampler, float2(s * 0.5 + 0.5, 0.5 - t * 0.5));
    float3 albedo = texel.rgb;
    if (decal.selected > 0.5) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.25);
    }
    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 L = normalize(-frame.keyLightDirection.xyz);
    float wrap = keyLightWrap(frame);
    float ndl = saturate(dot(N, L)) * (1.0 - wrap) + wrap;
    float3 hemi = mix(frame.groundColor.rgb, frame.skyColor.rgb, N.y * 0.5 + 0.5);
    float3 H = normalize(L + V);
    float3 sun = keyLightColor(frame);
    float3 spec = pow(saturate(dot(N, H)), 12.0) * 0.08 * sun;
    float3 color = albedo * (hemi * 0.45 + ndl * 0.70 * sun) + spec;
    float alpha = texel.a * decal.opacity * smoothstep(0.1, 0.3, facing);
    return float4(color, alpha);
}

// MARK: - Unlit flat color (gizmo, generic lines)

struct UnlitOut {
    float4 position [[position]];
    float3 worldPosition;
};

vertex UnlitOut vertex_unlit(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float4 world = body.modelMatrix * float4(positions[vid], 1.0);
    UnlitOut out;
    out.position = frame.viewProjectionMatrix * world;
    out.worldPosition = world.xyz;
    return out;
}

fragment float4 fragment_flatColor(
    UnlitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    return body.baseColor;
}

/// Flat color that honors the section clip plane — used by the edge pipeline
/// (feature edges, profile fills, sketch lines). The overlay pass (gizmo,
/// orientation cube) keeps the unclipped fragment_flatColor.
fragment float4 fragment_flatColorClipped(
    UnlitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    if (sectionClipped(in.worldPosition, frame)) {
        discard_fragment();
    }
    return body.baseColor;
}

// MARK: - Feature edges (line list, depth bias applied in vertex shader)

vertex UnlitOut vertex_edge(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float4 world = body.modelMatrix * float4(positions[vid], 1.0);
    UnlitOut out;
    out.position = frame.viewProjectionMatrix * world;
    out.worldPosition = world.xyz;
    // Pull toward the camera in NDC so edges win the depth fight with their
    // own faces. setDepthBias only affects fill primitives on Metal.
    out.position.z -= frame.edgeDepthBiasNDC * out.position.w;
    return out;
}

// MARK: - Thick lines (sketch strokes)

/// Metal's `.line` primitive is always ONE pixel wide, which reads as a hairline
/// on a Retina display. This expands each segment into a screen-space quad so
/// sketch strokes have a real, Shapr3D-like weight.
///
/// The vertex buffer is the SAME endpoint-pair list the line pipeline uses — the
/// draw just asks for 6 vertices per segment and this derives which endpoint and
/// which side from `vertex_id`, so nothing has to be re-packed on the CPU.
///
/// It also applies a much larger depth bias than `vertex_edge`: a sketch drawn on
/// a solid's FACE is exactly coplanar with it, so the small bias tuned for a
/// body's own feature edges loses the depth fight at many angles and the stroke
/// vanishes into the face.
vertex UnlitOut vertex_thickLine(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    uint segment = vid / 6u;
    uint corner = vid % 6u;
    // Quad as two triangles: (a,-1) (b,-1) (b,+1) / (a,-1) (b,+1) (a,+1)
    const float2 layout[6] = {
        float2(0.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
        float2(0.0, -1.0), float2(1.0, 1.0), float2(0.0, 1.0)
    };
    float2 pick = layout[corner];

    float4 worldA = body.modelMatrix * float4(positions[segment * 2u], 1.0);
    float4 worldB = body.modelMatrix * float4(positions[segment * 2u + 1u], 1.0);
    float4 clipA = frame.viewProjectionMatrix * worldA;
    float4 clipB = frame.viewProjectionMatrix * worldB;

    float2 viewport = max(float2(frame.viewportWidth, frame.viewportHeight), float2(1.0));
    // Screen-space direction of the segment (guard the degenerate case).
    float2 screenA = clipA.xy / max(abs(clipA.w), 1e-6) * viewport;
    float2 screenB = clipB.xy / max(abs(clipB.w), 1e-6) * viewport;
    float2 delta = screenB - screenA;
    float len = length(delta);
    float2 dir = len > 1e-6 ? delta / len : float2(1.0, 0.0);
    float2 normal = float2(-dir.y, dir.x);

    bool useB = pick.x > 0.5;
    float4 clip = useB ? clipB : clipA;
    float3 world = useB ? worldB.xyz : worldA.xyz;

    // Offset by half the stroke width, converted from pixels to clip units.
    float2 offset = normal * pick.y * max(body.lineHalfWidthPx, 0.5);
    clip.xy += offset / viewport * clip.w;
    clip.z -= frame.edgeDepthBiasNDC * 12.0 * clip.w;

    UnlitOut out;
    out.position = clip;
    out.worldPosition = world;
    return out;
}

// MARK: - Sketch-plane / ground grid (procedural, anti-aliased)

struct GridOut {
    float4 position [[position]];
    float3 worldPosition;
};

vertex GridOut vertex_grid(
    uint vid [[vertex_id]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]]
) {
    // Quad as triangle strip corners, generated from vertex_id, sized by fade
    // distance and centered under the camera target so it never runs out.
    float extent = frame.gridParams.z * 2.0;
    float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    float3 world = frame.gridCenter.xyz
        + frame.gridXAxis.xyz * corner.x * extent
        + frame.gridYAxis.xyz * corner.y * extent;
    GridOut out;
    out.position = frame.viewProjectionMatrix * float4(world, 1.0);
    out.worldPosition = world;
    return out;
}

// Anti-aliased distance to the nearest line of a square grid with `spacing`.
static float gridLine(float2 p, float spacing, float2 fw) {
    float2 grid = abs(fract(p / spacing - 0.5) - 0.5) * spacing / fw;
    return 1.0 - saturate(min(grid.x, grid.y));
}

fragment float4 fragment_grid(
    GridOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]]
) {
    float3 relative = in.worldPosition - frame.gridOrigin.xyz;
    float2 p = float2(dot(relative, frame.gridXAxis.xyz),
                      dot(relative, frame.gridYAxis.xyz));
    float2 fw = max(fwidth(p), 1e-6);

    float minorSpacing = frame.gridParams.x;
    float majorSpacing = frame.gridParams.x * frame.gridParams.y;

    float minor = gridLine(p, minorSpacing, fw) * 0.35;
    float major = gridLine(p, majorSpacing, fw) * 0.6;

    // Color world-aligned axes consistently (X red, Y green, Z blue).
    // Arbitrary sketch axes use the same weighted world-direction palette.
    float axisWidth = max(fw.y, fw.x) * 1.2;
    float onXAxis = 1.0 - saturate(abs(p.y) / axisWidth); // z≈0 line along X
    float onZAxis = 1.0 - saturate(abs(p.x) / axisWidth); // x≈0 line along Z

    float3 lineColor = float3(0.45, 0.48, 0.52);
    float strength = max(minor, major);
    float3 color = lineColor;
    float alpha = strength;

    if (onXAxis > 0.0) {
        float3 axis = abs(frame.gridXAxis.xyz);
        color = axis.x * float3(0.85, 0.30, 0.30)
              + axis.y * float3(0.30, 0.70, 0.35)
              + axis.z * float3(0.25, 0.45, 0.90);
        alpha = max(alpha, onXAxis * 0.9);
    }
    if (onZAxis > 0.0) {
        float3 axis = abs(frame.gridYAxis.xyz);
        color = axis.x * float3(0.85, 0.30, 0.30)
              + axis.y * float3(0.30, 0.70, 0.35)
              + axis.z * float3(0.25, 0.45, 0.90);
        alpha = max(alpha, onZAxis * 0.9);
    }

    // Fade with distance from the grid center and at grazing angles.
    float dist = length(in.worldPosition - frame.gridCenter.xyz);
    float fade = 1.0 - smoothstep(frame.gridParams.z * 0.35, frame.gridParams.z, dist);
    float3 viewDir = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 normal = normalize(cross(frame.gridXAxis.xyz, frame.gridYAxis.xyz));
    float grazing = saturate(abs(dot(viewDir, normal)) * 4.0);

    return float4(color, alpha * fade * grazing * 0.85);
}

// MARK: - Textured quad (Insert Image) + blob shadow

struct TexturedQuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex TexturedQuadOut vertex_texturedQuad(
    uint vid [[vertex_id]],
    const device float3 *positions [[buffer(BufferIndexPositions)]],
    const device float2 *texcoords [[buffer(BufferIndexTexcoords)]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]]
) {
    TexturedQuadOut out;
    out.position = frame.viewProjectionMatrix * float4(positions[vid], 1.0);
    out.uv = texcoords[vid];
    return out;
}

fragment float4 fragment_texturedQuad(
    TexturedQuadOut in [[stage_in]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]],
    texture2d<float> tex [[texture(0)]]
) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    mip_filter::none, address::clamp_to_edge);
    float4 c = tex.sample(linearSampler, in.uv);
    // baseColor.a carries the per-image opacity.
    return float4(c.rgb, c.a * body.baseColor.a);
}

/// Cheap planar ground shadow (visualization v1): a soft dark ellipse under a
/// body's AABB. uv spans 0…1 across the quad; baseColor.a is peak strength.
fragment float4 fragment_blobShadow(
    TexturedQuadOut in [[stage_in]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float r = length(in.uv * 2.0 - 1.0);
    float alpha = (1.0 - smoothstep(0.45, 1.0, r)) * body.baseColor.a;
    return float4(body.baseColor.rgb, alpha);
}

// MARK: - Depth of field (spec §14)

// The scene drawn first into a texture with its depth; this pass blurs each
// pixel by how far it lies from the focus distance (DepthOfFieldKit.radius):
// a disc of taps on a golden-angle spiral, each counted only where its own
// blur reaches the centre, so a sharp subject does not smear onto a blurred
// background and a blurred foreground still spreads over a sharp one.

static float dofDepth(depth2d<float> depth, uint2 p) { return depth.read(p); }
static float dofDepth(depth2d_ms<float> depth, uint2 p) { return depth.read(p, 0); }

static float dofRadius(float depth, float2 pixel, constant DepthOfFieldUniforms &u) {
    float2 ndc = float2((pixel.x + 0.5) / u.imageWidth * 2.0 - 1.0, 1.0 - (pixel.y + 0.5) / u.imageHeight * 2.0);
    float4 world = u.inverseViewProjection * float4(ndc, depth, 1.0);
    float distance = dot(world.xyz / world.w - u.cameraPosition.xyz, u.viewDirection.xyz);
    // DepthOfFieldKit.radius (falloff 3).
    return u.widestRadius * min(1.0, 3.0 * abs(distance - u.focusDistance) / max(u.focusDistance, 1e-4));
}

template <typename Depth>
static float4 dofBlur(Depth depth, texture2d<float> color, float2 pixel, constant DepthOfFieldUniforms &u) {
    uint2 size = uint2(color.get_width(), color.get_height());
    uint2 centre = min(uint2(pixel), size - 1);
    float radius = dofRadius(dofDepth(depth, centre), float2(centre), u);
    float4 sum = color.read(centre);
    float weight = 1.0;
    if (radius < 0.5) return sum;
    const int taps = 48;
    for (int i = 1; i <= taps; i++) {
        // Golden-angle spiral filling the widest disc.
        float r = sqrt(float(i) / float(taps)) * u.widestRadius;
        float a = float(i) * 2.39996323;
        float2 at = pixel + float2(cos(a), sin(a)) * r;
        if (at.x < 0 || at.y < 0 || at.x >= float(size.x) || at.y >= float(size.y)) continue;
        uint2 q = uint2(at);
        float own = dofRadius(dofDepth(depth, q), float2(q), u);
        // A tap counts where its own blur, or the centre's, covers it.
        float w = saturate(min(own, radius) - r + 1.0);
        sum += color.read(q) * w;
        weight += w;
    }
    return sum / weight;
}

fragment float4 fragment_depthOfField(
    FullscreenOut in [[stage_in]],
    texture2d<float> color [[texture(0)]],
    depth2d<float> depth [[texture(1)]],
    constant DepthOfFieldUniforms &u [[buffer(0)]]
) {
    return dofBlur(depth, color, in.position.xy, u);
}

fragment float4 fragment_depthOfFieldMS(
    FullscreenOut in [[stage_in]],
    texture2d<float> color [[texture(0)]],
    depth2d_ms<float> depth [[texture(1)]],
    constant DepthOfFieldUniforms &u [[buffer(0)]]
) {
    return dofBlur(depth, color, in.position.xy, u);
}
