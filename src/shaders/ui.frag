precision highp float;
uniform sampler2D scene;
varying vec2 uv;

vec2 resolution = vec2(2540, 1440);

vec3 getTextureColorAt(vec2 coord) {
  return texture2D(scene, coord / resolution).rgb;
}

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  vec2 fragCoord = uv * resolution;
  vec3 backgroundColor = getTextureColorAt(fragCoord);

  vec2 glassSize = vec2(120., 80.);
  vec2 glassCenter = vec2(resolution.x / 2., resolution.y / 2.);
  vec2 glassCoord = fragCoord - glassCenter;

  float size = min(glassSize.x, glassSize.y);
  float inversedSDF = -sdf(glassCoord, glassSize * 0.5, 16.0) / size;

  if (inversedSDF < 0.0) {
    return;
  }

  gl_FragColor = vec4(backgroundColor * 0.5, 1.0);
  gl_FragColor.r = inversedSDF;
}
