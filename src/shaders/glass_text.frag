#extension GL_OES_standard_derivatives : enable
precision highp float;

uniform sampler2D atlas;
uniform float pxRange;
uniform float thickness;

varying vec2 v_uv;

float median(float a, float b, float c) {
  return max(min(a, b), min(max(a, b), c));
}

float softness = 12.;

void main() {
  vec3 s = texture2D(atlas, v_uv).rgb;
  float sd = median(s.r, s.g, s.b) - 0.5;

  float screenPxRange = pxRange * length(vec2(dFdx(v_uv.x), dFdy(v_uv.y)));

  float dist = sd + thickness;
  float alpha =
      smoothstep(-softness * screenPxRange, softness * screenPxRange, dist);

  gl_FragColor = vec4(vec3(1.), alpha * 0.8);
}
