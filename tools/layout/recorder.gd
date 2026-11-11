extends RefCounted
## Hooked into the screenshot tools (tools/screenshots/shoot*.gd and, through
## them, tools/showcase/*.gd; inert unless LAYOUT_ROW is set): puts the app on one row of
## app/tests/layout/matrix.gd, runs app/tests/layout/layout_checks.gd on every
## shot and writes what it found as JSON.
##
## Env: LAYOUT_ROW (matrix row id; its window size and screen), LAYOUT_OUT
## (folder for <set>.json and, with LAYOUT_RENDER=1, the PNGs),
## LAYOUT_RENDER=1 (a real window from --resolution: the shots are drawn too;
## without it the run is headless and only measures), LAYOUT_FORM
## ("console" | "desktop": check the wording for a device that isn't a handheld).

const Matrix := preload("res://tests/layout/matrix.gd")
const Checks := preload("res://tests/layout/layout_checks.gd")
const UiScale := preload("res://scripts/ui/ui_scale.gd")
const Words := preload("res://scripts/ui/words.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

static var row: Dictionary = {}
static var group: Dictionary = {}
static var render := false
static var out_dir := ""
static var shots: Dictionary = {}
static var order: Array = []


## True when this run measures only (headless): the caller skips drawing.
static func measuring() -> bool:
	return not row.is_empty() and not render


static func begin() -> void:
	# the pictures show a handheld whatever machine draws them (a build box has no battery)
	DeviceScript.assume_battery = true
	var ml := Engine.get_main_loop()
	if ml is SceneTree and (ml as SceneTree).root.get_node_or_null("Device") != null:
		(ml as SceneTree).root.get_node("Device").detect()
	var id := OS.get_environment("LAYOUT_ROW")
	if id == "":
		return
	row = Matrix.row(id)
	if row.is_empty():
		push_error("LAYOUT_ROW %s is not in tests/layout/matrix.gd" % id)
		return
	for g in Matrix.layouts():
		if g["layout"] == row["layout"]:
			group = g
	render = OS.get_environment("LAYOUT_RENDER") == "1"
	out_dir = OS.get_environment("LAYOUT_OUT")
	UiScale.override_screen = row["screen"]
	if DisplayServer.get_name() == "headless":
		UiScale.override_window = row["size"]
		render = false
	var form := OS.get_environment("LAYOUT_FORM")
	if form != "":
		Words.use(false, false, "Steam Machine" if form == "console" else "")
		Words.install()


static func ctx() -> Dictionary:
	return {"scale": float(group.get("scale", 1.0)), "min_font_px": Matrix.min_font_px(group) if not group.is_empty() else 0.0}


static func check(root: Window, name: String) -> void:
	if row.is_empty():
		return
	var res: Dictionary = Checks.scan(root, ctx())
	var view := root.get_visible_rect().size
	if Vector2i(view) != row["layout"] and (Vector2(row["layout"]) - view).length() > 2.0:
		res["problems"].append({"kind": "layout", "node": "", "text": "", "detail": "window lays out %s, the matrix says %s" % [view, row["layout"]]})
	if not Words.handheld:
		for t in _texts(root):
			if t.findn("handheld") >= 0 and t.find("Handheld Daemon") < 0:
				res["problems"].append({"kind": "wording", "node": "", "text": t.left(80), "detail": "says handheld on a device that isn't one"})
	shots[name] = res
	if not name in order:
		order.append(name)


static func _texts(n: Node) -> Array:
	var out := []
	if n is CanvasItem and not (n as CanvasItem).visible:
		return out
	if n is Label:
		out.append((n as Label).atr((n as Label).text))
	elif n is Button:
		out.append((n as Button).atr((n as Button).text))
	elif n is RichTextLabel:
		out.append((n as RichTextLabel).get_parsed_text())
	for c in n.get_children():
		out.append_array(_texts(c))
	return out


static func save(set_name: String) -> void:
	if row.is_empty() or out_dir == "":
		return
	DirAccess.make_dir_recursive_absolute(out_dir)
	var total := 0
	for k in shots:
		total += (shots[k]["problems"] as Array).size()
	var doc := {"row": row["id"], "size": [row["size"].x, row["size"].y], "layout": [row["layout"].x, row["layout"].y],
		"scale": group.get("scale", row["scale"]), "set": set_name, "shots": shots, "order": order, "problems": total}
	var f := FileAccess.open(out_dir.path_join(set_name + ".json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(doc, " "))
	f.close()
	print("layout %s %s: %d shots, %d problems" % [row["id"], set_name, shots.size(), total])
