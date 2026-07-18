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

// MARK: - Lit solid bodies

struct LitOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
};

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
    return out;
}

fragment float4 fragment_lit(
    LitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
    float3 N = normalize(in.worldNormal);
    float3 V = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 L = normalize(-frame.keyLightDirection.xyz);

    float3 albedo = body.baseColor.rgb;
    float alpha = body.baseColor.a;
    if (body.selectionState == SelectionStateSelected) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.45);
    } else if (body.selectionState == SelectionStateHovered) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.18);
    } else if (body.selectionState == SelectionStatePreview) {
        albedo = mix(albedo, frame.accentColor.rgb, 0.30);
        alpha = 0.55;
    }

    // Half-lambert wrap for a soft CAD look that never goes fully dark.
    float ndl = saturate(dot(N, L)) * 0.5 + 0.5;
    float3 hemi = mix(frame.groundColor.rgb, frame.skyColor.rgb, N.y * 0.5 + 0.5);
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 48.0) * 0.30;
    float rim = pow(1.0 - saturate(dot(N, V)), 3.0) * 0.12;
    float3 rimColor = (body.selectionState == SelectionStateSelected)
        ? frame.accentColor.rgb : float3(1.0);

    float3 color = albedo * (hemi * 0.45 + ndl * 0.70) + spec + rim * rimColor;
    return float4(color, alpha);
}

// MARK: - Unlit flat color (gizmo, generic lines)

struct UnlitOut {
    float4 position [[position]];
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
    return out;
}

fragment float4 fragment_flatColor(
    UnlitOut in [[stage_in]],
    constant FrameUniforms &frame [[buffer(BufferIndexFrameUniforms)]],
    constant BodyUniforms &body [[buffer(BufferIndexBodyUniforms)]]
) {
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
    // Pull toward the camera in NDC so edges win the depth fight with their
    // own faces. setDepthBias only affects fill primitives on Metal.
    out.position.z -= frame.edgeDepthBiasNDC * out.position.w;
    return out;
}

// MARK: - Ground grid (procedural, anti-aliased)

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
    float3 world = float3(
        frame.gridCenter.x + corner.x * extent,
        0.0,
        frame.gridCenter.z + corner.y * extent
    );
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
    float2 p = in.worldPosition.xz;
    float2 fw = max(fwidth(p), 1e-6);

    float minorSpacing = frame.gridParams.x;
    float majorSpacing = frame.gridParams.x * frame.gridParams.y;

    float minor = gridLine(p, minorSpacing, fw) * 0.35;
    float major = gridLine(p, majorSpacing, fw) * 0.6;

    // X (red-ish) and Z (blue-ish) axes drawn in the same pass.
    float axisWidth = max(fw.y, fw.x) * 1.2;
    float onXAxis = 1.0 - saturate(abs(p.y) / axisWidth); // z≈0 line along X
    float onZAxis = 1.0 - saturate(abs(p.x) / axisWidth); // x≈0 line along Z

    float3 lineColor = float3(0.45, 0.48, 0.52);
    float strength = max(minor, major);
    float3 color = lineColor;
    float alpha = strength;

    if (onXAxis > 0.0) {
        color = float3(0.85, 0.30, 0.30);
        alpha = max(alpha, onXAxis * 0.9);
    }
    if (onZAxis > 0.0) {
        color = float3(0.25, 0.45, 0.90);
        alpha = max(alpha, onZAxis * 0.9);
    }

    // Fade with distance from the grid center and at grazing angles.
    float dist = length(in.worldPosition - frame.gridCenter.xyz);
    float fade = 1.0 - smoothstep(frame.gridParams.z * 0.35, frame.gridParams.z, dist);
    float3 viewDir = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float grazing = saturate(abs(viewDir.y) * 4.0);

    return float4(color, alpha * fade * grazing * 0.85);
}
