//
//  ShaderTypes.h
//  openshape3d
//
//  Shared between Swift (via bridging header) and Metal Shading Language so
//  uniform struct layouts are defined exactly once. simd types only; no
//  matrix_float3x3 (its Swift/MSL layouts differ).
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef enum {
    BufferIndexPositions = 0,
    BufferIndexNormals = 1,
    BufferIndexFrameUniforms = 2,
    BufferIndexBodyUniforms = 3,
    BufferIndexTexcoords = 4,
    BufferIndexDecal = 5,
} BufferIndex;

typedef enum {
    SelectionStateNone = 0,
    SelectionStateSelected = 1,
    SelectionStateHovered = 2,
    SelectionStatePreview = 3,
} SelectionState;

typedef struct {
    matrix_float4x4 viewProjectionMatrix;
    vector_float4 cameraPosition;      // xyz used
    vector_float4 keyLightDirection;   // xyz used, normalized, world space
    vector_float4 skyColor;            // hemisphere ambient top
    vector_float4 groundColor;         // hemisphere ambient bottom
    vector_float4 backgroundTop;
    vector_float4 backgroundBottom;
    vector_float4 accentColor;         // selection highlight
    vector_float4 gridParams;          // x: minor spacing, y: major every N, z: fade distance,
                                       // w: surface analysis (0 none, 1 zebra, 2 curvature)
    vector_float4 gridCenter;          // xyz: world position the grid quad is centered on
    vector_float4 gridOrigin;          // sketch coordinate origin in world space
    vector_float4 gridXAxis;           // orthonormal in-plane basis
    vector_float4 gridYAxis;
    vector_float4 clipPlane;           // section view: xyz unit normal, w offset;
                                       // fragments with dot(p, xyz) + w < 0 are discarded
    float edgeDepthBiasNDC;
    float clipEnabled;                 // 0 = section view off (default)
    float viewportWidth;               // drawable pixels — thick lines expand in
    float viewportHeight;              // screen space, so they need the size
    vector_float4 keyLightColor;       // Visualization (spec §14): rgb sun colour × intensity,
                                       // w 1 = world-fixed sun lighting; w 0 = modelling headlight
} FrameUniforms;

typedef struct {
    matrix_float4x4 modelMatrix;       // uniform scale + rotation + translation
    vector_float4 baseColor;
    unsigned int selectionState;       // SelectionState
    float metallic;                    // 0 (default) = dielectric, white highlight
    float roughness;                   // 0 (default) = legacy fixed highlight; >0 mapped
    float lineHalfWidthPx;             // thick-line pipeline: half stroke width
    float emission;                    // Glow (spec §14): 0 lit, 1 self-lit and brightened
    float pattern;                     // MaterialPattern.shaderValue (0 none)
    float patternSize;                 // one repeat, mm (body-local)
    float patternRotation;             // radians
} BodyUniforms;

// A decal (spec §14): its box in world space (DecalDrawable).
typedef struct {
    vector_float4 center;              // xyz
    vector_float4 axisU;               // xyz unit, w half width
    vector_float4 axisV;               // xyz unit, w half height
    vector_float4 normal;              // xyz unit (out of the surface), w depth
    float opacity;
    float selected;                    // 1: tinted with the accent
} DecalUniforms;

// Depth of field (spec §14): the scene's colour and depth, blurred by each
// pixel's distance from the focus (DepthOfFieldKit).
typedef struct {
    matrix_float4x4 inverseViewProjection;
    vector_float4 cameraPosition;      // xyz
    vector_float4 viewDirection;       // xyz, unit
    float focusDistance;
    float widestRadius;                // pixels, at the blur strength
    float imageWidth;
    float imageHeight;
} DepthOfFieldUniforms;

#endif /* ShaderTypes_h */
