attribute vec2 pos;
attribute vec2 uv;
varying vec2 v_uv;
void main() {
  v_uv = (pos + 1.0) * 0.5;
  gl_Position = vec4(pos, 0.0, 1.0);
}
