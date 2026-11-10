// Rounded corners for art drawn by a TextureRect (stretch: scale), plus a
// pan/zoom used for the focused tile's small parallax shift. One cheap
// fragment pass; no screen texture.
shader_type canvas_item;

uniform vec2 size = vec2(150.0, 225.0);
uniform float radius = 12.0;
uniform vec2 pan = vec2(0.0);
uniform float zoom = 1.0;
// Fraction of the texture shown on each axis (cover-crop when the card's
// aspect differs from the art's), and where the crop sits (0.5 = centre).
uniform vec2 crop = vec2(1.0);
uniform vec2 crop_at = vec2(0.5);

// The vertex colour (modulate) alone. In fragment() COLOR is already the
// texture at UV times it, so multiplying a fresh sample by COLOR would square
// every pixel: darker, crushed art.
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	vec2 uv = (UV - 0.5) * crop / zoom + crop_at + pan;
	vec4 c = texture(TEXTURE, clamp(uv, vec2(0.0), vec2(1.0))) * tint;
	vec2 p = (UV - 0.5) * size;
	vec2 q = abs(p) - size * 0.5 + radius;
	float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
	c.a *= clamp(0.5 - d, 0.0, 1.0);
	COLOR = c;
}
