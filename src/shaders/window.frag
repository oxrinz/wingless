#extension GL_OES_standard_derivatives : enable

precision highp float;
uniform sampler2D image;
// quadPos/size: the surface texture's screen position and size (for UV sampling)
uniform vec2 size;
uniform vec2 quadPos;
// clipPos/clipSize: the actual window content bounds (xdg geometry)
uniform vec2 clipPos;
uniform vec2 clipSize;
uniform float roundness;
uniform float borderWidth;
uniform vec4 borderColor;

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

void main() {
  // In scene_buffer context gl_FragCoord.y == screen row from top
  vec2 fragCoord = gl_FragCoord.xy;

  // texture UV: screen pos relative to the surface buffer origin
  vec2 texUV = (fragCoord - quadPos) / size;

  // SDF against the window content clip rect
  vec2 clipCenter = clipPos + clipSize * 0.5;
  vec2 cp = fragCoord - clipCenter;
  float clipD = sdf(cp, clipSize * 0.5, roundness);
  float aa = fwidth(clipD);

  // outer boundary = clip edge + borderWidth
  float outerFill = 1.0 - smoothstep(borderWidth - aa, borderWidth + aa, clipD);
  if (outerFill < 0.001) discard;

  // inner content fill
  float fill = 1.0 - smoothstep(-aa, aa, clipD);

  // border ring: outside content, inside outer boundary
  float border = (1.0 - fill) * outerFill;

  vec4 tex = texture2D(image, clamp(texUV, 0.0, 1.0));
  vec3 col = mix(tex.rgb, borderColor.rgb, border);
  float alpha = tex.a * fill + border * borderColor.a;
  gl_FragColor = vec4(col, alpha);
}
