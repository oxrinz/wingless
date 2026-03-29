precision highp float;

uniform vec4 color;
uniform vec2 size;
uniform vec2 quadPos;
uniform vec2 resolution;
uniform float time;

varying vec2 v_uv;

const float PI = 3.14159265358979;

void main() {
    vec2 fragCoord = v_uv * resolution;
    vec2 center = quadPos + size * 0.5;
    vec2 local = fragCoord - center;

    float r = min(size.x, size.y) * 0.5;
    float dist = length(local) / r;

    float outer = 0.78;
    float inner = 0.44;
    float ring = smoothstep(outer + 0.1, outer, dist) * smoothstep(inner - 0.1, inner, dist);

    float angle = atan(local.y, local.x);
    float spin = mod(time * 3.0, 2.0 * PI);
    float a = mod(angle + spin + 4.0 * PI, 2.0 * PI);

    float sweep = 1.5 * PI;
    float in_arc = step(a, sweep);
    float head_fade = smoothstep(0.0, 0.18, a);
    float tail_fade = 1.0 - a / sweep;

    float alpha = ring * in_arc * head_fade * tail_fade;
    gl_FragColor = vec4(color.rgb, color.a * alpha);
}
