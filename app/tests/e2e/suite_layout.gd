extends "res://tests/e2e/e2e_case.gd"
## The layout checks themselves (app/tests/layout/layout_checks.gd), in the live app because they need a running tree: each kind of finding is reported
## for a control that has the problem and not for one that doesn't. Without this the harness could go
## quiet and nobody would notice.

const Checks := preload("res://tests/layout/layout_checks.gd")


func _scan(host: Control, scale := 1.0) -> Array:
	var root: Window = w.tree.root
	var out: Array = []
	for p in Checks.scan(root, {"scale": scale, "min_font_px": 0.0}).get("problems", []):
		if host.is_ancestor_of(root.get_node_or_null(NodePath(str(p["node"])))) or str(p["node"]).contains(str(host.name)):
			out.append(p)
	return out


func _kinds(problems: Array, node_name: String) -> Array:
	var k: Array = []
	for p in problems:
		if str(p["node"]).ends_with("/" + node_name):
			k.append(p["kind"])
	return k


func _bitmap(px: int) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_empty(px, px, false, Image.FORMAT_RGBA8))


func test_blurry_bitmaps_and_what_is_not_blurry() -> void:
	var root: Window = w.tree.root
	var host := Control.new()
	host.name = "LayoutChecksHost"
	root.add_child(host)
	var soft := TextureRect.new()
	soft.name = "Soft"
	soft.texture = _bitmap(64)
	soft.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	soft.stretch_mode = TextureRect.STRETCH_SCALE
	soft.size = Vector2(60, 60)
	host.add_child(soft)
	var crisp := TextureRect.new()    # nearest filtering: a QR code
	crisp.name = "Crisp"
	crisp.texture = _bitmap(64)
	crisp.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	crisp.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	crisp.stretch_mode = TextureRect.STRETCH_SCALE
	crisp.size = Vector2(60, 60)
	crisp.position = Vector2(0, 0)
	host.add_child(crisp)
	var capped := Button.new()    # a 54 px icon a button draws 18 px wide
	capped.name = "Capped"
	capped.icon = _bitmap(54)
	capped.add_theme_constant_override("icon_max_width", 18)
	capped.size = Vector2(40, 30)
	host.add_child(capped)
	var uncapped := Button.new()
	uncapped.name = "Uncapped"
	uncapped.icon = _bitmap(54)
	uncapped.size = Vector2(80, 60)
	host.add_child(uncapped)
	await w.frames(2)
	var found := _scan(host, 2.7)
	ok("blurry" in _kinds(found, "Soft"), "a 64 px bitmap drawn 60 px wide at 2.7x is reported")
	ok(not ("blurry" in _kinds(found, "Crisp")), "a nearest-filtered bitmap (QR code) is not")
	ok(not ("blurry" in _kinds(found, "Capped")), "an icon the button draws at 18 px is judged at 18 px")
	ok("blurry" in _kinds(found, "Uncapped"), "the same icon drawn at its own size is reported")
	host.free()


func test_a_control_outside_the_window_is_reported() -> void:
	var root: Window = w.tree.root
	var host := Control.new()
	host.name = "LayoutChecksHost2"
	root.add_child(host)
	var l := Label.new()
	l.name = "Off"
	l.text = "Quick menu"
	l.position = Vector2(5000, 5000)
	host.add_child(l)
	var inside := Label.new()
	inside.name = "On"
	inside.text = "Home"
	inside.position = Vector2(2, 2)
	host.add_child(inside)
	await w.frames(2)
	var found := _scan(host)
	ok("outside" in _kinds(found, "Off"), "text far outside the window is reported")
	ok(not ("outside" in _kinds(found, "On")), "text inside is not")
	host.free()
