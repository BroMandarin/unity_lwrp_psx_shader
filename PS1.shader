Shader "Lightweight Render Pipeline/Custom/PS1"
{
	Properties
	{
		[MainColor] _BaseColor("Color", Color) = (0.5,0.5,0.5,1)
		[MainTexture] _BaseMap("Albedo", 2D) = "white" {}

		// Blending state
		[HideInInspector] _Surface("__surface", Float) = 0.0
		[HideInInspector] _Blend("__blend", Float) = 0.0
		[HideInInspector] _AlphaClip("__clip", Float) = 0.0
		[HideInInspector] _SrcBlend("__src", Float) = 1.0
		[HideInInspector] _DstBlend("__dst", Float) = 0.0
		[HideInInspector] _ZWrite("__zw", Float) = 1.0
		[HideInInspector] _Cull("__cull", Float) = 2.0

			// Editmode props
			[HideInInspector] _QueueOffset("Queue offset", Float) = 0.0
	}

		SubShader
		{
			Tags{ "RenderType" = "Opaque" "RenderPipeline" = "LightweightPipeline" "IgnoreProjector" = "True" }
			LOD 300

			Pass
			{
				Name "StandardLit"
				Tags{ "LightMode" = "LightweightForward" }

				Blend[_SrcBlend][_DstBlend]
				ZWrite[_ZWrite]
				Cull[_Cull]

				HLSLPROGRAM
		#pragma prefer_hlslcc gles
		#pragma exclude_renderers d3d11_9x
		#pragma target 2.0

		#pragma shader_feature _NORMALMAP
		#pragma shader_feature _ALPHATEST_ON
		#pragma shader_feature _ALPHAPREMULTIPLY_ON
		#pragma shader_feature _EMISSION
		#pragma shader_feature _METALLICSPECGLOSSMAP
		#pragma shader_feature _SMOOTHNESS_TEXTURE_ALBEDO_CHANNEL_A
		#pragma shader_feature _OCCLUSIONMAP

		#pragma shader_feature _SPECULARHIGHLIGHTS_OFF
		#pragma shader_feature _GLOSSYREFLECTIONS_OFF
		#pragma shader_feature _SPECULAR_SETUP
		#pragma shader_feature _RECEIVE_SHADOWS_OFF

		#pragma multi_compile _ _MAIN_LIGHT_SHADOWS
		#pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
		#pragma multi_compile _ _ADDITIONAL_LIGHTS_VERTEX _ADDITIONAL_LIGHTS
		#pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS
		#pragma multi_compile _ _SHADOWS_SOFT
		#pragma multi_compile _ _MIXED_LIGHTING_SUBTRACTIVE

		#pragma multi_compile _ DIRLIGHTMAP_COMBINED
		#pragma multi_compile _ LIGHTMAP_ON
		#pragma multi_compile_fog

		#pragma multi_compile_instancing

		#pragma vertex LitPassVertex
		#pragma fragment LitPassFragment

		#define _ADDITIONAL_LIGHTS_VERTEX

		#include "Packages/com.unity.render-pipelines.lightweight/ShaderLibrary/Core.hlsl"
		#include "Packages/com.unity.render-pipelines.lightweight/ShaderLibrary/Lighting.hlsl"
		#include "Packages/com.unity.render-pipelines.lightweight/Shaders/LitInput.hlsl"

				struct Attributes
			{
				float4 positionOS   : POSITION;
				float3 normalOS     : NORMAL;
				float4 tangentOS    : TANGENT;
				float2 uv           : TEXCOORD0;
				float2 uvLM         : TEXCOORD1;
				half4 color         : COLOR;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			struct Varyings
			{
				float2 uv                       : TEXCOORD0;
				float2 uvLM                     : TEXCOORD1;
				float4 positionWSAndFogFactor   : TEXCOORD2; // xyz: positionWS, w: vertex fog factor
				half3  normalWS                 : TEXCOORD3;
				half4 color                     : COLOR0;


		#if _NORMALMAP
				half3 tangentWS                 : TEXCOORD4;
				half3 bitangentWS               : TEXCOORD5;
		#endif

		#ifdef _MAIN_LIGHT_SHADOWS
				float4 shadowCoord              : TEXCOORD6; // compute shadow coord per-vertex for the main light
		#endif
				float4 positionCS               : SV_POSITION;
			};

			Varyings LitPassVertex(Attributes input)
			{
				Varyings output;

				VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
				VertexNormalInputs vertexNormalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);

				float fogFactor = ComputeFogFactor(vertexInput.positionCS.z);
				output.positionWSAndFogFactor = float4(vertexInput.positionWS, fogFactor);
				output.normalWS = vertexNormalInput.normalWS;

				// Vertex snapping
				float4 snapToPixel = TransformObjectToHClip(input.positionOS);
				float4 vertex = snapToPixel;
				vertex.xyz = snapToPixel.xyz / snapToPixel.w;
				vertex.x = floor(160 * vertex.x) / 160;
				vertex.y = floor(120 * vertex.y) / 120;
				vertex.xyz *= snapToPixel.w;
				output.positionCS = vertex;

				// Vertex lighting
				output.color = float4(VertexLighting(vertexInput.positionWS, vertexNormalInput.normalWS), 1.0);
				output.color += _BaseColor;
				output.color *= input.color;

				//Affine Texture Mapping
				float distance = length(mul(UNITY_MATRIX_MV, input.positionOS));
				output.uv = TRANSFORM_TEX(input.uv, _BaseMap);
				output.uv *= distance + (vertex.w * 8) / distance / 2;
				output.uvLM = distance + (vertex.w * 8) / distance / 2;

				return output;
			}

			SAMPLER(sampler_BaseMap_Point_Repeat);

			half4 LitPassFragment(Varyings input) : COLOR
			{
				SurfaceData surfaceData;
				InitializeStandardLitSurfaceData(input.uv, surfaceData);

				float3 positionWS = input.positionWSAndFogFactor.xyz;
				half3 viewDirectionWS = SafeNormalize(GetCameraPositionWS() - positionWS);

				Light mainLight = GetMainLight();

				float fogFactor = input.positionWSAndFogFactor.w;
				half4 tex = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap_Point_Repeat, input.uv / input.uvLM.r);
				half4 color = tex;
				color.xyz *= input.color;
				color.xyz *= mainLight.color;

				color.xyz = MixFog(color, fogFactor);

				return color;
			}
				ENDHLSL
			}

			// Used for rendering shadowmaps
			UsePass "Lightweight Render Pipeline/Lit/ShadowCaster"

				// Used for depth prepass
				// If shadows cascade are enabled we need to perform a depth prepass. 
				// We also need to use a depth prepass in some cases camera require depth texture
				// (e.g, MSAA is enabled and we can't resolve with Texture2DMS
				UsePass "Lightweight Render Pipeline/Lit/DepthOnly"

				// Used for Baking GI. This pass is stripped from build.
				UsePass "Lightweight Render Pipeline/Lit/Meta"
		}

			FallBack "Hidden/InternalErrorShader"
}