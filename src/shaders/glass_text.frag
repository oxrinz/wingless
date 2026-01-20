precision mediump float;

uniform sampler2D atlas;

varying vec2 v_uv;

void main() {
  vec3 sample = texture2D(atlas, v_uv).rgb;

  gl_FragColor = vec4(sample, 1.);
}
