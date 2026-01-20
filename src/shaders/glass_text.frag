#extension GL_OES_standard_derivatives : enable
precision mediump float;

uniform sampler2D atlas;

varying vec2 v_uv;

float median(float a, float b, float c) {
  return max(min(a, b), min(max(a, b), c));
}

void main() {
  vec3 sample = texture2D(atlas, v_uv).rgb;

  float sd = median(sample.r, sample.g, sample.b);

  float w = fwidth(sd);
  float alpha = smoothstep(0.5 - w, 0.5 + w, sd);

  gl_FragColor = vec4(sample, 1.);
}
