/*
Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE( cbuffer, globalConstants, b, 0, 0 )
{
    float4x4 gViewToClip;
    float4 gFrustum;
    float2 gInvScreenSize;
    float2 gScreenSize;
    float gMetersToUnits;
    float gIsOrtho;
    float gUnproject;
    float gDebug;
    float gInf;
    float gReference;
    uint gFrameIndex;
    uint gWorldSpaceMotion;

    float4x4 gWorldToView;
    float4 gRotator;
    float4 gDiffScalingParams;
    float4 gSpecScalingParams;
    float3 gSpecTrimmingParams;
    float gDiffBlurRadius;
    float gSpecBlurRadius;
    uint gDiffCheckerboard;
    uint gSpecCheckerboard;
};

#include "NRD_Common.hlsl"

// Inputs
NRI_RESOURCE( Texture2D<float4>, gIn_Normal_Roughness, t, 0, 0 );
NRI_RESOURCE( Texture2D<float>, gIn_ViewZ, t, 1, 0 );
NRI_RESOURCE( Texture2D<float4>, gIn_Diff, t, 2, 0 );
NRI_RESOURCE( Texture2D<float4>, gIn_Spec, t, 3, 0 );

// Outputs
NRI_RESOURCE( RWTexture2D<float4>, gOut_Diff, u, 0, 0 );
NRI_RESOURCE( RWTexture2D<float4>, gOut_Spec, u, 1, 0 );
NRI_RESOURCE( RWTexture2D<float>, gOut_ScaledViewZ, u, 2, 0 );

void Preload( int2 sharedId, int2 globalId )
{
    s_Normal_Roughness[ sharedId.y ][ sharedId.x ] = _NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ globalId ] );
    s_ViewZ[ sharedId.y ][ sharedId.x ] = gIn_ViewZ[ globalId ];
}

[numthreads( GROUP_X, GROUP_Y, 1 )]
void main( int2 threadId : SV_GroupThreadId, int2 pixelPos : SV_DispatchThreadId, uint threadIndex : SV_GroupIndex )
{
    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvScreenSize;

    PRELOAD_INTO_SMEM;

    // Checkerboard
    bool2 hasData = true;
    uint2 checkerboardPixelPos = pixelPos.xx; // yes, .xx
    uint checkerboard = STL::Sequence::CheckerBoard( pixelPos, gFrameIndex );

    if( gDiffCheckerboard != 2 )
    {
        hasData.x = checkerboard == gDiffCheckerboard;
        checkerboardPixelPos.x >>= 1;
    }

    if( gSpecCheckerboard != 2 )
    {
        hasData.y = checkerboard == gSpecCheckerboard;
        checkerboardPixelPos.y >>= 1;
    }

    // Early out
    int2 smemPos = threadId + BORDER;
    float centerZ = s_ViewZ[ smemPos.y ][ smemPos.x ];

    [branch]
    if( abs( centerZ ) > gInf )
    {
        #if( BLACK_OUT_INF_PIXELS == 1 )
            gOut_Diff[ pixelPos ] = 0;
            gOut_Spec[ pixelPos ] = 0;
        #endif
        gOut_ScaledViewZ[ pixelPos ] = NRD_FP16_MAX;
        return;
    }

    // Center data
    float3 centerPos = STL::Geometry::ReconstructViewPosition( pixelUv, gFrustum, centerZ, gIsOrtho );
    float4 diff = gIn_Diff[ uint2( checkerboardPixelPos.x, pixelPos.y ) ];
    float4 spec = gIn_Spec[ uint2( checkerboardPixelPos.y, pixelPos.y ) ];

    int3 smemCheckerboardPos = smemPos.xyx + int3( -1, 0, 1 );
    float viewZ0 = s_ViewZ[ smemCheckerboardPos.y ][ smemCheckerboardPos.x ];
    float viewZ1 = s_ViewZ[ smemCheckerboardPos.y ][ smemCheckerboardPos.z ];
    float2 w = GetBilateralWeight( float2( viewZ0, viewZ1 ), centerZ );
    w *= STL::Math::PositiveRcp( w.x + w.y );

    int3 checkerboardPos = pixelPos.xyx + int3( -1, 0, 1 );
    checkerboardPos.xz >>= 1;
    float4 d0 = gIn_Diff[ checkerboardPos.xy ];
    float4 d1 = gIn_Diff[ checkerboardPos.zy ];
    if( !hasData.x )
        diff = d0 * w.x + d1 * w.y;

    float4 s0 = gIn_Spec[ checkerboardPos.xy ];
    float4 s1 = gIn_Spec[ checkerboardPos.zy ];
    if( !hasData.y )
        spec = s0 * w.x + s1 * w.y;

    float diffCenterNormHitDist = diff.w;
    float specCenterNormHitDist = spec.w;

    // Normal and roughness
    float4 normalAndRoughness = s_Normal_Roughness[ smemPos.y ][ smemPos.x ];
    float3 N = normalAndRoughness.xyz;
    float3 Nv = STL::Geometry::RotateVector( gWorldToView, N );
    float roughness = normalAndRoughness.w;

    // Blur radius
    float diffHitDist = GetHitDistance( diff.w, centerZ, gDiffScalingParams );
    float diffBlurRadius = DIFF_PRE_BLUR_RADIUS_SCALE * GetBlurRadius( gDiffBlurRadius, 1.0, diffHitDist, centerPos, 1.0 );
    float diffWorldBlurRadius = PixelRadiusToWorld( diffBlurRadius, centerZ );

    float specHitDist = GetHitDistance( spec.w, centerZ, gSpecScalingParams, roughness );
    float specBlurRadius = SPEC_PRE_BLUR_RADIUS_SCALE * GetBlurRadius( gSpecBlurRadius, roughness, specHitDist, centerPos, 1.0 );
    specBlurRadius *= GetBlurRadiusScaleBasingOnTrimming( roughness, gSpecTrimmingParams );
    float specWorldBlurRadius = PixelRadiusToWorld( specBlurRadius, centerZ );

    // Tangent basis
    float2x3 diffTvBv = GetKernelBasis( centerPos, Nv, diffWorldBlurRadius );
    float2x3 specTvBv = GetKernelBasis( centerPos, Nv, specWorldBlurRadius, roughness );

    // Random rotation
    float4 rotator = GetBlurKernelRotation( PRE_BLUR_ROTATOR_MODE, pixelPos, gRotator );

    // Edge detection
    float edge = DetectEdge( N, smemPos );

    // Denoising
    float diffSum = 1.0;
    float2 specSum = 1.0;

    float2 geometryWeightParams = GetGeometryWeightParams( centerPos, Nv, gMetersToUnits, centerZ );
    float diffNormalWeightParams = GetNormalWeightParams( 1.0, edge );
    float specNormalWeightParams = GetNormalWeightParams( roughness, edge );
    float2 specRoughnessWeightParams = GetRoughnessWeightParams( roughness );
    float2 specHitDistanceWeightParams = GetHitDistanceWeightParams( roughness, specCenterNormHitDist );

    UNROLL
    for( uint i = 0; i < POISSON_SAMPLE_NUM; i++ )
    {
        float3 offset = POISSON_SAMPLES[ i ];

        // Diffuse
        {
            // Sample coordinates
            float2 uv = GetKernelSampleCoordinates( offset, centerPos, diffTvBv[ 0 ], diffTvBv[ 1 ], rotator );

            // Handle half res input in the checkerboard mode
            float3 checkerboardUv = float3( uv, 1.0 );
            if( gDiffCheckerboard != 2 )
                checkerboardUv = ApplyCheckerboard( uv, gDiffCheckerboard, i );

            // Fetch data
            float4 d = gIn_Diff.SampleLevel( gNearestMirror, checkerboardUv.xy, 0 );
            float z = gIn_ViewZ.SampleLevel( gNearestMirror, uv, 0 );
            float4 normal = gIn_Normal_Roughness.SampleLevel( gNearestMirror, uv, 0 );

            float3 samplePos = STL::Geometry::ReconstructViewPosition( uv, gFrustum, z, gIsOrtho );
            normal = _NRD_FrontEnd_UnpackNormalAndRoughness( normal );

            // Sample weight
            float w = GetGeometryWeight( Nv, samplePos, geometryWeightParams );
            w *= GetNormalWeight( diffNormalWeightParams, N, normal.xyz );
            w *= checkerboardUv.z;

            diff += d * w;
            diffSum += w;
        }

        // Specular
        {
            // Sample coordinates
            float2 uv = GetKernelSampleCoordinates( offset, centerPos, specTvBv[ 0 ], specTvBv[ 1 ], rotator );

            // Handle half res input in the checkerboard mode
            float3 checkerboardUv = float3( uv, 1.0 );
            if( gSpecCheckerboard != 2 )
                checkerboardUv = ApplyCheckerboard( uv, gSpecCheckerboard, i );

            // Fetch data
            float4 s = gIn_Spec.SampleLevel( gNearestMirror, checkerboardUv.xy, 0 );
            float z = gIn_ViewZ.SampleLevel( gNearestMirror, uv, 0 );
            float4 normal = gIn_Normal_Roughness.SampleLevel( gNearestMirror, uv, 0 );

            float3 samplePos = STL::Geometry::ReconstructViewPosition( uv, gFrustum, z, gIsOrtho );
            normal = _NRD_FrontEnd_UnpackNormalAndRoughness( normal );

            // Sample weight
            float w = GetGeometryWeight( Nv, samplePos, geometryWeightParams );
            w *= GetNormalWeight( specNormalWeightParams, N, normal.xyz );
            w *= GetRoughnessWeight( specRoughnessWeightParams, normal.w );
            w *= checkerboardUv.z;

            float2 ww = w;
            ww.x *= GetHitDistanceWeight( specHitDistanceWeightParams, s.w );

            spec += s * ww.xxxy;
            specSum += ww;
        }
    }

    diff *= STL::Math::PositiveRcp( diffSum );
    spec *= STL::Math::PositiveRcp( specSum ).xxxy;

    // Special case for hit distance
    diff.w = lerp( diff.w, diffCenterNormHitDist, HIT_DIST_INPUT_MIX );
    spec.w = lerp( spec.w, specCenterNormHitDist, HIT_DIST_INPUT_MIX );

    // Output
    float scaledViewZ = clamp( centerZ * NRD_FP16_VIEWZ_SCALE, -NRD_FP16_MAX, NRD_FP16_MAX );

    gOut_Diff[ pixelPos ] = diff;
    gOut_Spec[ pixelPos ] = spec;
    gOut_ScaledViewZ[ pixelPos ] = scaledViewZ;
}
