#extension GL_OES_standard_derivatives : enable

precision highp float;
uniform sampler2D scene;
uniform vec2 size;
uniform float shadowIntensity;
uniform vec2 v_uv;
varying vec2 g_uv;

vec2 resolution = vec2(2540, 1440);

vec3 getTextureColorAt(vec2 coord) {
  return texture2D(scene, coord / resolution).rgb;
}

float sdf(vec2 p, vec2 b, float r) {
  vec2 d = abs(p) - b + vec2(r);
  return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

vec3 getBlurredColor(vec2 coord, float blurRadius) {
  vec3 color = vec3(0.);
  float totalWeight = 0.;

  for (int x = -2; x <= 2; x++) {
    for (int y = -2; y <= 2; y++) {
      vec2 offset = vec2(float(x), float(y)) * blurRadius;
      float weight = exp(-.5 * (float(x * x + y * y)) / 2.0);

      color += getTextureColorAt(coord + offset) * weight;
      totalWeight += weight;
    }
  }

  return color / totalWeight;
}

void main() {
  float ratio = resolution.x / resolution.y;
  vec2 fragCoord = g_uv * resolution;

  float roundness = 75.;

  // opening / closing animation
  vec2 paneCenter = vec2(resolution.x / 2., resolution.y / 2.);

  vec2 glassCoord = fragCoord - paneCenter;

  // glass refractions
  // size / {num} defines the roundness
  float inversedSDF =
      -sdf(glassCoord, size * 0.5, roundness / 2.) / min(size.x, size.y);

  float alpha = 1.0;
  vec3 glassColor = vec3(0.0);

  // shadow
  float shadowSDF = sdf(glassCoord, size * 0.5, roundness / 2.);

  float fill = step(shadowSDF, 0.);
  float curvature = 8.0;
  float falloff = 400.00;
  float outline = exp(-curvature * max(shadowSDF, 0.) / falloff);
  float shadow = max(fill, outline);
  shadow *= shadowIntensity;
  alpha = shadow;

  // smooth edges
  float aa = fwidth(inversedSDF);
  float edge = smoothstep(0., aa, inversedSDF);

  alpha = max(alpha, edge);

  if (edge > 0.0) {
    float distFromCenter = 1.0 - clamp(inversedSDF / 0.2, 0.0, 1.0);
    float distortion = 1.0 - sqrt(1.0 - pow(distFromCenter, 2.0));
    // the normalize(glassCoord) / {num} and clamp values get rid of the tear at
    // the middle that is present when the rectable is long and thin they can,
    // and SHOULD be removed if the size of the rectangle is somewhat balanced
    vec2 normalizedGlassCoord = clamp(normalize(glassCoord) / 5., -.1, .1);
    vec2 offset = distortion * normalizedGlassCoord * size * 0.5;
    vec2 glassColorCoord = fragCoord - offset;

    float blurIntensity = 1.2;
    float blurRadius = blurIntensity * (1.0 - distFromCenter * 0.5);
    glassColor = getBlurredColor(glassColorCoord, blurRadius) * (1. - shadow);
    glassColor *= 0.9;

    // highlight
    float hlDistFromEdge = inversedSDF + .1;
    float hlDistFromCenter = 0.05 - inversedSDF;
    float intersection = clamp(min(hlDistFromEdge, hlDistFromCenter), 0., 1.);

    vec2 scaledUv = (g_uv * 2. - 1.);
    scaledUv.y -= 0.1;
    scaledUv.x -= 0.5;
    float mask = min(-scaledUv.x, -scaledUv.y) * 5.;
    glassColor += clamp(vec3(intersection * mask) * 10., 0., 1.);

    // bright
    glassColor += vec3(0.05);

    glassColor *= edge;
  }

  gl_FragColor = vec4(glassColor, alpha);
}
