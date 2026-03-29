precision highp float;

#define MAX_SHADOWS 16

uniform vec2 shadowPos[MAX_SHADOWS];
uniform vec2 shadowSize[MAX_SHADOWS];
uniform float shadowRoundness[MAX_SHADOWS];
uniform float shadowIntensity[MAX_SHADOWS];
uniform vec2 resolution;

varying vec2 v_uv;

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  vec2 fragCoord = v_uv * resolution;
  float total = 0.0;

  for (int i = 0; i < MAX_SHADOWS; i++) {
    vec2 center = shadowPos[i] + shadowSize[i] * 0.5;
    float d = sdf(fragCoord - center, shadowSize[i] * 0.5, shadowRoundness[i] * 0.5);
    float outline = exp(-8.0 * max(d, 0.0) / 400.0);
    float fill = step(d, 0.0);
    float s = max(fill, outline) * shadowIntensity[i];
    total = 1.0 - (1.0 - total) * (1.0 - s);
  }

  gl_FragColor = vec4(0.0, 0.0, 0.0, total);
}
