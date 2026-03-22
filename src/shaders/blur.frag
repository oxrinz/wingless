precision highp float;
uniform sampler2D scene;
uniform float intensity;
uniform vec2 direction;
varying vec2 v_uv;

vec2 resolution = vec2(2560, 1440);

void main() {
  vec2 coord = v_uv * resolution;
  float radius = intensity;

  vec3 color = vec3(0.0);
  float totalWeight = 0.0;

  for (int i = 0; i <= 0; i++) {
    float fi = float(i);
    float weight = exp(-0.5 * fi * fi / 90.0);
    vec2 offset = direction * fi * radius;
    color += texture2D(scene, (coord + offset) / resolution).rgb * weight;
    totalWeight += weight;
  }

  color /= totalWeight;

  color *= 0.8 * intensity;

  gl_FragColor = vec4(color, intensity);
}
