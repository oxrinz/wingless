precision highp float;

uniform vec2 size;
uniform vec2 quadPos;
uniform float roundness;
uniform float intensity;

varying vec2 v_uv;

vec2 resolution = vec2(2560, 1440);

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  vec2 fragCoord = v_uv * resolution;
  vec2 paneCenter = quadPos + size * 0.5;
  vec2 glassCoord = fragCoord - paneCenter;

  float shadowSDF = sdf(glassCoord, size * 0.5, roundness / 2.);
  float curvature = 8.0;
  float falloff = 400.0;
  float outline = exp(-curvature * max(shadowSDF, 0.0) / falloff);
  float fill = step(shadowSDF, 0.0);
  float shadow = max(fill, outline) * intensity;

  gl_FragColor = vec4(0.0, 0.0, 0.0, shadow);
}
