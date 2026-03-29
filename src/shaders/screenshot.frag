precision highp float;
uniform sampler2D scene;
uniform vec4 sel;
uniform vec2 resolution;
varying vec2 v_uv;

void main() {
    vec4 col = texture2D(scene, v_uv);

    bool in_x = v_uv.x >= sel.x && v_uv.x <= sel.z;
    bool in_y = v_uv.y >= sel.y && v_uv.y <= sel.w;
    bool inside = in_x && in_y;

    float bw = 2.0 / resolution.x;
    float bh = 2.0 / resolution.y;
    bool on_border = inside && (
        v_uv.x < sel.x + bw || v_uv.x > sel.z - bw ||
        v_uv.y < sel.y + bh || v_uv.y > sel.w - bh
    );

    vec3 result;
    if (on_border) {
        result = vec3(1.0);
    } else if (inside) {
        result = col.rgb;
    } else {
        result = col.rgb * 0.45;
    }

    gl_FragColor = vec4(result, 1.0);
}
