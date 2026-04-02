uniform vec2 size;
uniform vec2 quadPos;
uniform float roundness;
uniform float fillAmount;
uniform int fillDirection;
uniform float refractionBand;
uniform float blurAmount;
varying vec2 v_uv;

const float interiorDarken = 0.6;
const float brightness = 0.12;

void main() {
  vec2 fragCoord = v_uv * resolution;
  vec2 paneCenter = quadPos + size * 0.5;
  vec2 glassCoord = fragCoord - paneCenter;

  float panelSDF = sdf(glassCoord, size * 0.5, roundness);
  float inversedSDF = -panelSDF / min(size.x, size.y);

  float shadow =
      max(step(panelSDF, 0.0), exp(-8.0 * max(panelSDF, 0.0) / 400.0)) *
      interiorDarken;

  float aa = fwidth(inversedSDF);
  float edge = smoothstep(-aa * 0.5, aa * 0.5, inversedSDF);
  float alpha = edge;
  vec3 glassColor = vec3(0.0);

  if (edge > 0.0) {
    vec2 grad;
    float gradMag;
    sdfGrad(glassCoord, size * 0.5, roundness, refractionBand * 0.5, grad,
            gradMag);

    vec2 rimGrad;
    float rimGradMag;
    sdfGrad(glassCoord, size * 0.5, roundness, 0.5, rimGrad, rimGradMag);

    float t = clamp(1.0 + panelSDF / (refractionBand * 2.0), 0.0, 1.0);
    float distortion = pow(t, 5.0);
    vec2 glassColorCoord = fragCoord - distortion * grad * refractionBand * 1.2;

    float blurRadius = blurAmount * (1.0 - t);
    glassColor = getBlurredColor(glassColorCoord, blurRadius) * (1.0 - shadow);
    glassColor *= 0.9;

    vec2 hl = glassRimHighlight(panelSDF, rimGrad, rimGradMag);
    glassColor += edge * (hl.x + hl.y);

    glassColor += vec3(brightness);

    if (fillDirection > 0 && fillAmount > 0.0) {
      vec2 localUV = (glassCoord + size * 0.5) / size;
      float ft;
      if (fillDirection == 1)
        ft = localUV.y;
      else if (fillDirection == 2)
        ft = 1.0 - localUV.y;
      else if (fillDirection == 3)
        ft = localUV.x;
      else
        ft = 1.0 - localUV.x;

      float fillMask = 1.0 - step(fillAmount, ft);
      glassColor = mix(glassColor, vec3(1.), fillMask * 0.45);
    }

    glassColor *= edge;
  }

  gl_FragColor = vec4(glassColor, alpha);
}
