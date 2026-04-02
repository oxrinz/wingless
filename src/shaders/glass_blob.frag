uniform vec2 centers[8];
uniform float scales[8];
uniform float widths[8];   // half-extent X for rounded rect (0 = circle)
uniform float heights[8];  // half-extent Y for rounded rect (0 = circle)
uniform float radius;
uniform float morphK;
uniform float openState;
uniform vec2 maskCenter;
uniform float maskHalfEx;
uniform float maskHalfEy;
uniform float maskRadius;  // 0 = no mask

varying vec2 v_uv;

const float interiorDarken = 0.6;

// Rounded rect SDF. When widths/heights are 0 it's a circle.
float shapeSDF(vec2 p, vec2 center, float r, float half_ex, float half_ey) {
    vec2 q = abs(p - center) - vec2(half_ex, half_ey);
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

float fullSDF(vec2 p) {
    // Blob: smin union of growing circles — provides glass texture and shape visuals.
    float d = 1e6;
    for (int i = 0; i < 8; i++) {
        if (scales[i] > 0.001) {
            d = smin(d, shapeSDF(p, centers[i], radius * scales[i], widths[i], heights[i]), morphK);
        }
    }
    if (maskRadius > 0.0) {
        float mask = shapeSDF(p, maskCenter, maskRadius, maskHalfEx, maskHalfEy);
        // Reveal boundary: morphs from button circles (state=0) to panel mask (state=1).
        // This ties fill directly to openState — state=t means the panel is t-fraction full.
        // The blob circles grow inside this boundary; smin inflation cannot overshoot it.
        float buttons = 1e6;
        for (int i = 0; i < 8; i++) {
            if (scales[i] > 0.001) {
                buttons = smin(buttons, shapeSDF(p, centers[i], radius, widths[i], heights[i]), morphK);
            }
        }
        float reveal = mix(buttons, mask, openState);
        d = max(d, reveal);
        d = max(d, mask); // hard clip failsafe
    }
    return d;
}

void main() {
    vec2 fragCoord = v_uv * resolution;
    float d = fullSDF(fragCoord);

    float aa = max(fwidth(d), 0.5);
    float edge = 1.0 - smoothstep(-aa, aa, d);

    if (edge <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }

    // Glass refraction via finite-difference gradient
    float refractionBand = radius * 1.8;
    float distFromCenter = 1.0 - clamp(-d / refractionBand, 0.0, 1.0);
    float distortion = 1.0 - sqrt(max(0.0, 1.0 - pow(distFromCenter, 2.0)));

    float eps = 0.5;
    float gx = fullSDF(fragCoord + vec2(eps, 0.0)) - fullSDF(fragCoord - vec2(eps, 0.0));
    float gy = fullSDF(fragCoord + vec2(0.0, eps)) - fullSDF(fragCoord - vec2(0.0, eps));
    vec2 gradVec = vec2(gx, gy);
    float gradMag = length(gradVec);
    vec2 grad = gradVec / max(gradMag, 1e-4);

    vec2 sampleCoord = fragCoord - distortion * grad * 30.0;

    float blurRadius = 1.2 * (1.0 - distFromCenter * 0.5);
    float internalShadow = max(step(d, 0.0), exp(-8.0 * max(d, 0.0) / 400.0)) * interiorDarken;
    vec3 glassColor = getBlurredColor(sampleCoord, blurRadius) * (1.0 - internalShadow) * 0.9;
    glassColor += vec3(0.12);

    // Rim highlights
    vec2 hl = glassRimHighlight(d, grad, gradMag);
    glassColor += edge * (hl.x + hl.y);
    glassColor *= edge;

    gl_FragColor = vec4(glassColor, edge);
}
