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

varying vec2 local;

void vertex() {
	local = VERTEX / rect_size;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV) * COLOR;
	float a = smoothstep(fade_left_from, fade_left_to, local.x);
	a *= 1.0 - smoothstep(fade_bottom_from, 1.0, local.y);
	a *= mix(0.35, 1.0, smoothstep(0.0, fade_top, local.y));
	c.a *= a;
	COLOR = c;
}
