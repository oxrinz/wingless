#extension GL_OES_standard_derivatives : enable

precision highp float;
uniform sampler2D image;
uniform vec2 size;
uniform vec2 quadPos;
uniform float roundness;

varying vec2 v_uv;

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  vec2 fragCoord = quadPos + v_uv * size;
  vec2 center = quadPos + size * 0.5;
  vec2 p = fragCoord - center;

  float d = sdf(p, size * 0.5, roundness);
  float aa = fwidth(d);
  float fill = 1.0 - smoothstep(0.0, aa * 2.0, d);
  if (fill < 0.001) discard;

  vec4 tex = texture2D(image, v_uv);
  gl_FragColor = vec4(tex.rgb, tex.a * fill);
}
