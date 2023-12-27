/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

[numthreads( GROUP_X, GROUP_Y, 1 )]
NRD_EXPORT void NRD_CS_MAIN( uint2 pixelPos : SV_DispatchThreadId )
{
    float2 pixelUv = float2( pixelPos + 0.5 ) * gRectSizeInv;
    if( pixelUv.x > gSplitScreen || any( pixelPos >= gRectSize ) )
        return;

    float viewZ = gIn_ViewZ[ WithRectOrigin( pixelPos ) ];
    uint2 checkerboardPos = pixelPos;

    #ifdef RELAX_DIFFUSE
        checkerboardPos.x = pixelPos.x >> ( gDiffCheckerboard != 2 ? 1 : 0 );

        float4 diff = gIn_Diff[ checkerboardPos ];
        #ifdef RELAX_SH
            diff.xyz = _NRD_LinearToYCoCg( diff.xyz ); // TODO: RELAX uses RGB for SH instead of SG_Create (see NRD.hlsli)
        #endif
        gOut_Diff[ pixelPos ] = diff * float( viewZ < gDenoisingRange );

        #ifdef RELAX_SH
            float4 diffSh = gIn_DiffSh[ checkerboardPos ];
            gOut_DiffSh[ pixelPos ] = diffSh * float( viewZ < gDenoisingRange );
        #endif
    #endif

    #ifdef RELAX_SPECULAR
        checkerboardPos.x = pixelPos.x >> ( gSpecCheckerboard != 2 ? 1 : 0 );

        float4 spec = gIn_Spec[ checkerboardPos ];
        #ifdef RELAX_SH
            spec.xyz = _NRD_LinearToYCoCg( spec.xyz ); // TODO: RELAX uses RGB for SH instead of SG_Create (see NRD.hlsli)
        #endif
        gOut_Spec[ pixelPos ] = spec * float( viewZ < gDenoisingRange );

        #ifdef RELAX_SH
            float4 specSh = gIn_SpecSh[ checkerboardPos ];
            gOut_SpecSh[ pixelPos ] = specSh * float( viewZ < gDenoisingRange );
        #endif
    #endif
}
