precision highp float;

#define MAX_SHADOWS 16
#define MAX_BLOBS 4

uniform vec2 shadowPos[MAX_SHADOWS];
uniform vec2 shadowSize[MAX_SHADOWS];
uniform float shadowRoundness[MAX_SHADOWS];
uniform float shadowIntensity[MAX_SHADOWS];

uniform vec2 blobCenters[32];
uniform float blobScales[32];
uniform float blobWidths[32];
uniform float blobHeights[32];
uniform float blobRadius[MAX_BLOBS];
uniform float blobMorphK[MAX_BLOBS];
uniform float blobIntensity[MAX_BLOBS];
uniform vec2 blobMaskCenter[MAX_BLOBS];
uniform float blobMaskHalfEx[MAX_BLOBS];
uniform float blobMaskHalfEy[MAX_BLOBS];
uniform float blobMaskRadius[MAX_BLOBS];

uniform vec2 resolution;

varying vec2 v_uv;

float smin(float a, float b, float k) {
    if (k <= 0.001) return min(a, b);
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float shapeSDF(vec2 p, vec2 center, float r, float half_ex, float half_ey) {
    vec2 q = abs(p - center) - vec2(half_ex, half_ey);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float sdf(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
    vec2 fragCoord = v_uv * resolution;
    float total = 0.0;

    for (int i = 0; i < MAX_SHADOWS; i++) {
        vec2 center = shadowPos[i] + shadowSize[i] * 0.5;
        float d = sdf(fragCoord - center, shadowSize[i] * 0.5, shadowRoundness[i]);
        float outline = exp(-8.0 * max(d, 0.0) / 400.0);
        float fill = step(d, 0.0);
        float s = max(fill, outline) * shadowIntensity[i];
        total = 1.0 - (1.0 - total) * (1.0 - s);
    }

    for (int b = 0; b < MAX_BLOBS; b++) {
        if (blobIntensity[b] <= 0.0) continue;
        float d = 1e6;
        for (int i = 0; i < 8; i++) {
            int idx = b * 8 + i;
            if (blobScales[idx] > 0.001) {
                d = smin(d, shapeSDF(fragCoord, blobCenters[idx], blobRadius[b] * blobScales[idx], blobWidths[idx], blobHeights[idx]), blobMorphK[b]);
            }
        }
        if (blobMaskRadius[b] > 0.0) {
            float mask = shapeSDF(fragCoord, blobMaskCenter[b], blobMaskRadius[b], blobMaskHalfEx[b], blobMaskHalfEy[b]);
            d = max(d, mask);
        }
        float outline = exp(-8.0 * max(d, 0.0) / 400.0);
        float fill = step(d, 0.0);
        float s = max(fill, outline) * blobIntensity[b];
        total = 1.0 - (1.0 - total) * (1.0 - s);
    }

    gl_FragColor = vec4(0.0, 0.0, 0.0, total);
}
