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
    vector_float4 gridParams;          // x: minor spacing, y: major every N, z: fade distance, w: unused
    vector_float4 gridCenter;          // xyz: world position the grid quad is centered on
    float edgeDepthBiasNDC;
    float _pad0;
    float _pad1;
    float _pad2;
} FrameUniforms;

typedef struct {
    matrix_float4x4 modelMatrix;       // uniform scale + rotation + translation
    vector_float4 baseColor;
    unsigned int selectionState;       // SelectionState
    unsigned int _pad[3];
} BodyUniforms;

#endif /* ShaderTypes_h */
