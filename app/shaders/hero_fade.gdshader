// Crisp hero art that dissolves into the blurred backdrop behind it: alpha
// fades out toward the left (where text sits) and toward the bottom (where
// the shelves start). Works with any TextureRect stretch mode because the
// mask uses the rect's own coordinates, not the texture's UVs.
shader_type canvas_item;

uniform vec2 rect_size = vec2(1280.0, 520.0);
uniform float fade_left_from = 0.10;
uniform float fade_left_to = 0.55;
uniform float fade_bottom_from = 0.50;
uniform float fade_top = 0.10;
// Inside a rounded frame: corner radius in px (0 = no frame).
uniform float frame_radius = 0.0;
// Readability shade behind text on the left: the art darkens toward
// shade_color.rgb by shade_color.a at the left edge, to nothing at shade_to
// (the art itself stays at full brightness everywhere else).
uniform vec4 shade_color = vec4(0.0, 0.0, 0.0, 0.0);
uniform float shade_to = 0.55;

varying vec2 local;

void vertex() {
	local = VERTEX / rect_size;
}

void fragment() {
	// COLOR already holds texture(TEXTURE, UV) times the modulate: sampling
	// again and multiplying would square every pixel (darker, crushed art).
	vec4 c = COLOR;
	c.rgb = mix(c.rgb, shade_color.rgb, shade_color.a * (1.0 - smoothstep(0.0, shade_to, local.x)));
	float a = smoothstep(fade_left_from, fade_left_to, local.x);
	a *= 1.0 - smoothstep(fade_bottom_from, 1.0, local.y);
	a *= mix(0.35, 1.0, smoothstep(0.0, fade_top, local.y));
	if (frame_radius > 0.0) {
		vec2 p = (local - 0.5) * rect_size;
		vec2 q = abs(p) - rect_size * 0.5 + frame_radius;
		float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - frame_radius;
		a *= clamp(0.5 - d, 0.0, 1.0);
	}
	c.a *= a;
	COLOR = c;
}
