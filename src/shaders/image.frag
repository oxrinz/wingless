precision mediump float;
uniform sampler2D image;

varying vec2 v_uv;

void main() {
  gl_FragColor = texture2D(image, v_uv);

  // gl_FragColor = vec4(v_uv, 0., 1.);
}
