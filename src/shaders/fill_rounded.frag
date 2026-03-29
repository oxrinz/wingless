precision highp float;

uniform vec4 color;
uniform vec2 size;
uniform vec2 quadPos;
uniform float roundness;
uniform vec2 resolution;

varying vec2 v_uv;

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  vec2 fragCoord = v_uv * resolution;
  vec2 paneCenter = quadPos + size * 0.5;
  vec2 local = fragCoord - paneCenter;
  float d = sdf(local, size * 0.5, roundness);
  float alpha = 1.0 - smoothstep(-1.0, 1.0, d);
  gl_FragColor = vec4(color.rgb, color.a * alpha);
}
