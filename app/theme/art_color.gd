extends RefCounted
## Colour picked from game art, and the generated colours for games without art.
## Pure functions on Images and Colors, so they're cheap to test.

const Themes := preload("res://theme/themes.gd")


## The most vibrant colour in an image: hue buckets weighted by saturation and
## brightness, then the average colour of the heaviest bucket. Works on any
## size but is meant for the tiny (~48 px) copy the art cache already makes.
## Returns Color(0, 0, 0, 0) when the image is basically grey.
static func vibrant(img: Image) -> Color:
	if img == null or img.is_empty():
		return Color(0, 0, 0, 0)
	var src := img
	if src.get_width() > 64 or src.get_height() > 64:
		src = img.duplicate()
		var s := 64.0 / maxf(src.get_width(), src.get_height())
		src.resize(maxi(1, int(src.get_width() * s)), maxi(1, int(src.get_height() * s)), Image.INTERPOLATE_BILINEAR)
	if src.is_compressed():
		src.decompress()
	const BUCKETS := 18
	var weight := PackedFloat32Array()
	weight.resize(BUCKETS)
	var sums: Array[Color] = []
	for i in BUCKETS:
		sums.append(Color(0, 0, 0, 0))
	var total := 0.0
	for y in src.get_height():
		for x in src.get_width():
			var c := src.get_pixel(x, y)
			var sat := c.s
			var val := c.v
			if val < 0.18 or sat < 0.22:
				continue
			# Favour saturated mid-bright pixels; very bright ones are often sky/UI.
			var w := sat * sat * (1.0 - absf(val - 0.7))
			var b := int(c.h * BUCKETS) % BUCKETS
			weight[b] += w
			sums[b] += Color(c.r * w, c.g * w, c.b * w, w)
			total += w
	if total <= 0.0001:
		return Color(0, 0, 0, 0)
	var best := 0
	for i in BUCKETS:
		if weight[i] > weight[best]:
			best = i
	# Neighbouring buckets belong to the same colour.
	var acc := sums[best] + sums[(best + 1) % BUCKETS] * 0.5 + sums[(best + BUCKETS - 1) % BUCKETS] * 0.5
	if acc.a <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(acc.r / acc.a, acc.g / acc.a, acc.b / acc.a, 1.0)


## Turns a picked art colour into an accent that works with this theme:
## readable as text on `surface` (>= 4.5:1) and vivid enough to glow. Grey or
## missing colours give the theme's own accent.
static func accent_for(picked: Color, tokens: Dictionary) -> Color:
	if picked.a <= 0.0 or picked.s < 0.2:
		return tokens["accent"]
	var dark := int(tokens.get("dark", 1)) == 1
	var surface: Color = tokens["surface"]
	var h := picked.h
	var s := clampf(picked.s, 0.45, 0.80)
	var v := clampf(picked.v, 0.85, 1.0) if dark else clampf(picked.v, 0.30, 0.55)
	var c := Color.from_hsv(h, s, v)
	var ink := Color(0.03, 0.035, 0.045)
	for i in 30:
		if Themes.contrast(c, surface) >= 4.5 and (not dark or Themes.contrast(c, ink) >= 4.7):
			break
		if dark:
			s = maxf(0.25, s - 0.04)
			v = minf(1.0, v + 0.03)
		else:
			v = maxf(0.08, v - 0.04)
		c = Color.from_hsv(h, s, v)
	return c


## The far end of a primary gradient that starts at `a`: the hue turned toward
## violet (the theme's accent_2 side), adjusted until `on` text still reads at
## 4.5:1, so a label anywhere on the gradient stays readable.
static func gradient_end(a: Color, on: Color, tokens: Dictionary) -> Color:
	var v2: Color = tokens.get("accent_2", Color("#7000FF"))
	var h := fposmod(a.h + 0.13, 1.0)
	# Cyan and teal art turn toward the theme's violet; warm art just shifts hue.
	if a.h > 0.40 and a.h < 0.62:
		h = lerpf(a.h, v2.h if v2.h > a.h else v2.h + 1.0, 0.85)
		h = fposmod(h, 1.0)
	var c := Color.from_hsv(h, clampf(a.s * 0.75, 0.3, 0.8), a.v)
	var light_text := Themes.luminance(on) > 0.5
	for i in 40:
		if Themes.contrast(on, c) >= 4.6:
			break
		c = c.darkened(0.04) if light_text else c.lightened(0.04)
	return c


## Dark or light text for an accent fill, whichever reads better.
static func on_color(fill: Color) -> Color:
	var dark := Color(0.03, 0.035, 0.045)
	var light := Color("#FFFFFF")
	return dark if Themes.contrast(fill, dark) >= Themes.contrast(fill, light) else light


## Two colours for a game without art, picked from its key so they never change
## between runs: a deep base and a brighter partner about 40 degrees away.
static func fallback_colors(key: String) -> Array[Color]:
	var hsh := _stable_hash(key)
	var hue := float(hsh % 360) / 360.0
	var shift := (0.09 + float((hsh / 360) % 7) * 0.012) * (1.0 if (hsh / 2520) % 2 == 0 else -1.0)
	var a := Color.from_hsv(hue, 0.62, 0.36)
	var b := Color.from_hsv(fposmod(hue + shift, 1.0), 0.55, 0.78)
	return [a, b]


## Two colours for a desktop app's card, from its icon's vibrant colour: the
## same hue, dark and muted, so the icon is the only bright thing on the card
## (Steam Big Picture and Android's adaptive icons do the same). Grey or
## unknown icons get a neutral slate. Never the random fallback hues.
static func app_card_colors(icon_color: Color) -> Array[Color]:
	if icon_color.a <= 0.0:
		return [Color(0.11, 0.12, 0.14), Color(0.2, 0.21, 0.24)]
	var sat := minf(icon_color.s, 0.6)
	var a := Color.from_hsv(icon_color.h, sat * 0.75, 0.2)
	var b := Color.from_hsv(icon_color.h, sat * 0.85, 0.38)
	return [a, b]


## djb2: String.hash() can change between Godot versions; this can't.
static func _stable_hash(s: String) -> int:
	var h := 5381
	for ch in s.to_utf8_buffer():
		h = ((h << 5) + h + ch) & 0x7FFFFFFF
	return h
