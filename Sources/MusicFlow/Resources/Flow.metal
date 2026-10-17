#include <metal_stdlib>
using namespace metal;
// Reconstructed from Music 1.7.2 AIR. Layout matches the original 368-byte buffer.
struct Model { float4x4 mtx; float timeScale; };
struct Uniforms {
    float4x4 viewMatrix;
    float time, textureTransitionMix, meshWarpTimeScale, saturation;
    float whiteScrimAlpha, blackScrimAlpha, factorForDarkMode, factorForLightMode;
    float floor, ceiling, padding[3];
    Model models[3];
};
struct ColorReplacements { float3 base, secondary, tertiary; float useColors; };
struct QuadInput { float4 position [[attribute(0)]]; float2 textureCoordinates [[attribute(1)]]; };
struct RotationOut { float4 position [[position]]; float2 textureCoordinates; uint instanceId [[flat]]; };
struct MeshInput {
    float4 position [[attribute(0)]];
    float4 fromPosition [[attribute(1)]];
    float4 toPosition [[attribute(2)]];
    float2 textureCoordinates [[attribute(3)]];
};
struct MeshOut { float4 position [[position]]; float2 textureCoordinates; };
constexpr sampler artworkSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
constexpr sampler pinchSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

vertex RotationOut rotation_vertex(QuadInput in [[stage_in]], constant Uniforms& u [[buffer(1)]], uint id [[instance_id]]) {
    float c;
    float s = fast::sincos(u.time * 6.283185307179586f / u.models[id].timeScale, c);
    float4x4 r(float4(c,-s,0,0), float4(s,c,0,0), float4(0,0,1,0), float4(0,0,0,1));
    RotationOut out;
    out.position = u.viewMatrix * r * u.models[id].mtx * r * in.position;
    out.textureCoordinates = in.textureCoordinates;
    out.instanceId = id;
    return out;
}
inline half3 saturateColor(half3 color, float saturation) {
    half luma = dot(color, half3(0.30h, 0.59h, 0.11h));
    return half3(luma) + half(saturation) * (color - half3(luma));
}
inline half3 replacement(constant ColorReplacements& colors, uint id) {
    switch (id) { case 0:return half3(colors.base); case 1:return half3(colors.secondary); case 2:return half3(colors.tertiary); default:return half3(1); }
}
fragment half4 rotation_fragment(RotationOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
    constant ColorReplacements& sourceColors [[buffer(2)]], constant ColorReplacements& destinationColors [[buffer(3)]],
    texture2d<half> source [[texture(0)]], texture2d<half> destination [[texture(1)]]) {
    half3 color = sourceColors.useColors > 0.1f ? replacement(sourceColors,in.instanceId) : source.sample(artworkSampler,in.textureCoordinates).rgb;
    if (u.textureTransitionMix > 0) {
        half3 to = destinationColors.useColors > 0.1f ? replacement(destinationColors,in.instanceId) : destination.sample(artworkSampler,in.textureCoordinates).rgb;
        color = mix(to,color,half(u.textureTransitionMix));
    }
    return half4(saturateColor(color,u.saturation),1);
}
fragment half4 rotation_fragmentNoDestinationTexture(RotationOut in [[stage_in]], constant Uniforms& u [[buffer(1)]],
    constant ColorReplacements& sourceColors [[buffer(2)]], constant ColorReplacements& destinationColors [[buffer(3)]],
    texture2d<half> source [[texture(0)]]) {
    half3 color = sourceColors.useColors > 0.1f ? replacement(sourceColors,in.instanceId) : source.sample(artworkSampler,in.textureCoordinates).rgb;
    if (u.textureTransitionMix > 0) color = mix(destinationColors.useColors > 0.1f ? replacement(destinationColors,in.instanceId) : half3(1),color,half(u.textureTransitionMix));
    return half4(saturateColor(color,u.saturation),1);
}
vertex MeshOut blur_vertex(QuadInput in [[stage_in]]) {
    return {in.position,in.textureCoordinates};
}
fragment half4 gaussianHorizontalBlur(MeshOut in [[stage_in]], texture2d<half> tex [[texture(0)]], constant float* weights [[buffer(1)]]) {
    float step = 1.0f / float(tex.get_width());
    half4 color = half(weights[62]) * tex.sample(artworkSampler,in.textureCoordinates);
    float offset = step;
    for(uint i=0;i<61;i++) {
        half4 a=tex.sample(artworkSampler,in.textureCoordinates+float2(offset,0));
        half4 b=tex.sample(artworkSampler,in.textureCoordinates-float2(offset,0));
        color += half(weights[61-i]) * (a+b);
        offset += step;
    }
    color.a=1; return color;
}
fragment half4 gaussianVerticalBlur(MeshOut in [[stage_in]], texture2d<half> tex [[texture(0)]], constant float* weights [[buffer(1)]]) {
    float step = 1.0f / float(tex.get_height());
    half4 color = half(weights[62]) * tex.sample(artworkSampler,in.textureCoordinates);
    float offset = step;
    for(uint i=0;i<61;i++) {
        half4 a=tex.sample(artworkSampler,in.textureCoordinates+float2(0,offset));
        half4 b=tex.sample(artworkSampler,in.textureCoordinates-float2(0,offset));
        color += half(weights[61-i]) * (a+b);
        offset += step;
    }
    color.a=1; return color;
}
vertex MeshOut pinch_vertex(MeshInput in [[stage_in]], constant Uniforms& u [[buffer(1)]]) {
    float a = fast::acos(fast::sin(u.time * 3.141592653589793f / u.meshWarpTimeScale));
    float q = a * 0.31830987334251404f;
    float w = (q*q) * (3.0f - a * 0.6366197466850281f);
    float4 p = mix(in.fromPosition,in.toPosition,w);
    return {float4(p.xy,0,1),(in.textureCoordinates-0.5f)*0.8f+0.5f};
}
fragment half4 pinch_fragment(MeshOut in [[stage_in]], constant Uniforms& u [[buffer(1)]], texture2d<half> tex [[texture(0)]]) {
    half3 color = min(half3(half(0.9951171875f)),saturateColor(tex.sample(pinchSampler,in.textureCoordinates).rgb,u.saturation));
    if (u.factorForDarkMode > 0) {
        color = mix(color,half3(0),half(u.blackScrimAlpha)) - half(u.factorForDarkMode * 0.1f);
    } else if (u.factorForLightMode > 0) {
        color = min(mix(color,half3(1),half(u.whiteScrimAlpha)) + half(u.factorForLightMode * 0.05f),half3(1));
    }
    return half4(clamp(color,half3(half(u.floor)),half3(half(u.ceiling))),1);
}
// Presentation only; not part of the recovered background pipeline.
vertex MeshOut display_vertex(uint id [[vertex_id]]) {
    float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
    float2 p=positions[id];return {float4(p,0,1),float2((p.x+1)*0.5f,1-(p.y+1)*0.5f)};
}
fragment half4 display_fragment(MeshOut in [[stage_in]], texture2d<half> tex [[texture(0)]]) { return tex.sample(pinchSampler,in.textureCoordinates); }
