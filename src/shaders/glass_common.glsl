#extension GL_OES_standard_derivatives : enable

precision highp float;

uniform sampler2D scene;
uniform vec2 resolution;

// Shared glass shader utilities

float smin(float a, float b, float k) {
    if (k <= 0.001) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// Rounded-rect SDF
float sdf(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

// Finite-difference gradient of the rounded-rect SDF.
// Naturally smooth at corners — no discontinuity at the interior diagonal.
// Returns (gradient_vec, gradient_magnitude) so callers can use both.
void sdfGrad(vec2 p, vec2 b, float r, out vec2 grad, out float gradMag) {
    float eps = 0.5;
    float gx = sdf(p + vec2(eps, 0.0), b, r) - sdf(p - vec2(eps, 0.0), b, r);
    float gy = sdf(p + vec2(0.0, eps), b, r) - sdf(p - vec2(0.0, eps), b, r);
    gradMag = length(vec2(gx, gy));
    grad = vec2(gx, gy) / max(gradMag, 1e-4);
}

vec3 getBlurredColor(vec2 coord, float blurRadius) {
    vec3 color = vec3(0.0);
    float totalWeight = 0.0;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            vec2 offset = vec2(float(x), float(y)) * blurRadius;
            float weight = exp(-0.5 * float(x*x + y*y) / 2.0);
            color += texture2D(scene, (coord + offset) / resolution).rgb * weight;
            totalWeight += weight;
        }
    }
    return color / totalWeight;
}

// Rim highlight band for a signed-distance field value d.
// Returns (hlTL, hlBR) packed as xy.
vec2 glassRimHighlight(float d, vec2 grad, float gradMag) {
    float aa = max(fwidth(d), 0.5);
    float hlFade = smoothstep(0.0, 1.5, gradMag);
    float dd = max(-d, 0.0);
    float aaH = max(fwidth(d), 1e-4);
    float insetPx = aaH * 1.5;
    float rimPx = 5.0;
    float rimBand = smoothstep(insetPx, insetPx + aaH, dd) *
                    (1.0 - smoothstep(insetPx + rimPx - aa, insetPx + rimPx + aa, dd));
    float falloff = exp(-dd / 2.0);
    vec2 lightDir = normalize(vec2(-0.35, -0.45));
    float ndlTL = max(dot(-grad, lightDir), 0.0);
    float ndlBR = max(dot(-grad, -lightDir), 0.0);
    float hlTL = rimBand * falloff * pow(ndlTL, 4.0) * hlFade;
    float hlBR = rimBand * falloff * pow(ndlBR, 4.0) * hlFade;
    return vec2(hlTL, hlBR);
}
