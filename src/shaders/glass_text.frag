#extension GL_OES_standard_derivatives : enable
precision highp float;

uniform sampler2D atlas;
uniform sampler2D scene;
uniform float pxRange;
uniform float thickness;
uniform int glassMode;
uniform float darkAmount;

varying vec2 v_uv;
varying vec2 v_screen_uv;

uniform vec2 resolution;

float median(float a, float b, float c) {
  return max(min(a, b), min(max(a, b), c));
}

vec3 getBlurred(vec2 uv, float sigma) {
  vec3 color = vec3(0.0);
  float totalWeight = 0.0;
  for (int x = -12; x <= 12; x++) {
    for (int y = -12; y <= 12; y++) {
      float fx = float(x);
      float fy = float(y);
      vec2 offset = vec2(fx, fy) / resolution;
      float weight = exp(-0.5 * (fx * fx + fy * fy) / (sigma * sigma));
      color += texture2D(scene, uv + offset).rgb * weight;
      totalWeight += weight;
    }
  }
  return color / totalWeight;
}

float softness = 12.;

void main() {
  vec3 s = texture2D(atlas, v_uv).rgb;
  float sd = median(s.r, s.g, s.b) - 0.5;

  float screenPxRange = pxRange * length(vec2(dFdx(v_uv.x), dFdy(v_uv.y)));
  float range = min(softness * screenPxRange, 0.35);
  float base_alpha = smoothstep(-range, range, sd);
  float dist = sd + thickness * base_alpha;
  float alpha = smoothstep(-range, range, dist);

  if (alpha < 0.01)
    discard;

  if (glassMode == 0) {
    gl_FragColor = vec4(mix(vec3(1.0), vec3(0.0), darkAmount), alpha * 0.8);
    return;
  }

  // refraction at edges
  float eps = 0.002;
  float sdR = median(texture2D(atlas, v_uv + vec2(eps, 0.0)).rgb.r,
                     texture2D(atlas, v_uv + vec2(eps, 0.0)).rgb.g,
                     texture2D(atlas, v_uv + vec2(eps, 0.0)).rgb.b) -
              0.5;
  float sdU = median(texture2D(atlas, v_uv + vec2(0.0, eps)).rgb.r,
                     texture2D(atlas, v_uv + vec2(0.0, eps)).rgb.g,
                     texture2D(atlas, v_uv + vec2(0.0, eps)).rgb.b) -
              0.5;
  vec2 n = normalize(vec2(sdR - sd, sdU - sd) + 0.0001);
  float edgeFactor = exp(-sd * 6.0);
  vec2 refractOffset = n * edgeFactor * 9.0 / resolution;

  vec3 glassColor = getBlurred(v_screen_uv + refractOffset, 5.) * 1.1;

  // rim highlights
  vec2 lightDir = normalize(vec2(0.45, 0.35));
  float ndlTL = max(dot(n, lightDir), 0.0);
  float ndlBR = max(dot(n, -lightDir), 0.0);
  float rimStrength = exp(-sd * 8.0);
  float hl = rimStrength * (pow(ndlTL, 2.0) + pow(ndlBR, 2.0) * 0.4) * 0.15;

  glassColor = clamp(glassColor + hl + vec3(0.55), 0.0, 1.0);
  glassColor = mix(glassColor, vec3(0.0), darkAmount);

  gl_FragColor = vec4(glassColor, alpha);
}
