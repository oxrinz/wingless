uniform vec2 centers[8];
uniform float scales[8];
uniform float brights[8];
uniform float radius;
uniform float morphK;

varying vec2 v_uv;

float sceneSDF(vec2 p) {
    float d = 1e6;
    for (int i = 0; i < 8; i++) {
        if (scales[i] > 0.001) {
            d = smin(d, length(p - centers[i]) - radius * scales[i], morphK);
        }
    }
    return d;
}

void main() {
    vec2 fragCoord = v_uv * resolution;
    float d = sceneSDF(fragCoord);

    float aa = max(fwidth(d), 0.5);
    float edge = 1.0 - smoothstep(-aa, aa, d);

    if (edge <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }

    // Per-pixel brightness blended by proximity to each circle
    float falloff_r = radius * 2.5;
    float brightness = 0.0;
    float wsum = 0.0001;
    for (int i = 0; i < 8; i++) {
        if (scales[i] > 0.001) {
            float di = length(fragCoord - centers[i]) - radius * scales[i];
            float w = exp(-max(di, 0.0) / falloff_r);
            brightness += w * brights[i];
            wsum += w;
        }
    }
    brightness /= wsum;

    // Glass refraction via finite-difference gradient
    float refractionBand = radius * 0.5;
    float distFromCenter = 1.0 - clamp(-d / refractionBand, 0.0, 1.0);
    float distortion = 1.0 - sqrt(max(0.0, 1.0 - pow(distFromCenter, 2.0)));

    float eps = 0.5;
    float gx = sceneSDF(fragCoord + vec2(eps, 0.0)) - sceneSDF(fragCoord - vec2(eps, 0.0));
    float gy = sceneSDF(fragCoord + vec2(0.0, eps)) - sceneSDF(fragCoord - vec2(0.0, eps));
    vec2 gradVec = vec2(gx, gy);
    float gradMag = length(gradVec);
    vec2 grad = gradVec / max(gradMag, 1e-4);

    vec2 sampleCoord = fragCoord - distortion * grad * 30.0;

    float blurRadius = 1.2 * (1.0 - distFromCenter * 0.5);
    float internalShadow = max(step(d, 0.0), exp(-8.0 * max(d, 0.0) / 400.0)) * 0.5;
    vec3 glassColor = getBlurredColor(sampleCoord, blurRadius) * (1.0 - internalShadow) * 0.9;

    // Rim highlights
    vec2 hl = glassRimHighlight(d, grad, gradMag);
    glassColor += edge * (hl.x + hl.y);
    glassColor += vec3(brightness);
    glassColor *= edge;

    gl_FragColor = vec4(glassColor, edge);
}
