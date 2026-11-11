extends "res://tests/test_case.gd"
## True-scale device drawings: every row's art exists, carries the ids the
## controller page needs, and has the outline of its shell ("bodies" in
## devices.json) at Device.UNITS_PER_MM (docs/DEVICES.md, Drawings).

const Buttons := preload("res://scripts/device/buttons.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const ART := "res://assets/devices/art/"
const TOL := 0.03

const STANDARD := ["part-body", "part-screen", "btn-South", "btn-East", "btn-North", "btn-West",
	"btn-DPad", "btn-DPadUp", "btn-DPadDown", "btn-DPadLeft", "btn-DPadRight",
	"axis-LeftStick", "btn-LeftStick", "axis-RightStick", "btn-RightStick",
	"btn-LeftBumper", "btn-RightBumper", "btn-LeftTrigger", "btn-RightTrigger", "btn-Select", "btn-Start"]


func _bodies() -> Dictionary:
	return DeviceScript.load_doc().get("bodies", {})


static func _num(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## The ids a row's drawing must have: standard parts, one per physical special
## button (first non-combo entry per glyph, deduplicated by capability),
## back buttons, trackpads and dials.
static func required_ids(row: Dictionary, body: Dictionary) -> Array:
	var out := STANDARD.duplicate()
	var prof: Dictionary = Buttons.profile(row["id"])
	var glyphs := {}
	for s in prof.get("special", []):
		if s["press"] == "combo" or glyphs.has(s["glyph"]):
			continue
		glyphs[s["glyph"]] = true
		var id := "btn-" + str(s["capability"])
		if not id in out and not str(s["capability"]) in body.get("absent_buttons", []):
			out.append(id)
	for cap in prof.get("paddles", {}):
		out.append("btn-" + str(cap))
	var pads := int(prof.get("trackpads", 0))
	if pads >= 1:
		out.append("pad-Right")
	if pads >= 2:
		out.append("pad-Left")
	if int(prof.get("dials", 0)) >= 2:
		out.append_array(["dial-Left", "dial-Right"])
	return out


## Bounding box [x0, y0, x1, y1] of the element with `id` (rect or absolute path).
static func bbox(svg: String, id: String) -> Array:
	var at := svg.find("id=\"%s\"" % id)
	if at < 0:
		return []
	var start := svg.rfind("<", at)
	var tag := svg.substr(start, svg.find(">", at) - start + 1)
	if tag.begins_with("<rect"):
		var x := _attr(tag, "x")
		var y := _attr(tag, "y")
		return [x, y, x + _attr(tag, "width"), y + _attr(tag, "height")]
	var d := tag.substr(tag.find(" d=\"") + 4)
	d = d.substr(0, d.find("\""))
	var re := RegEx.create_from_string("[MLHQCZ]|-?[0-9.]+")
	var xs: Array = []
	var ys: Array = []
	var cmd := ""
	var nums: Array = []
	for m in re.search_all(d + " Z"):
		var t := m.get_string()
		if t.is_valid_float():
			nums.append(float(t))
			continue
		if cmd == "H":
			xs.append_array(nums)
		else:
			for i in range(0, nums.size() - 1, 2):
				xs.append(nums[i])
				ys.append(nums[i + 1])
		cmd = t
		nums = []
	if xs.is_empty() or ys.is_empty():
		return []
	return [xs.min(), ys.min(), xs.max(), ys.max()]


static func _attr(tag: String, name: String) -> float:
	var m := RegEx.create_from_string(" %s=\"([-0-9.]+)\"" % name).search(tag)
	return float(m.get_string(1)) if m != null else 0.0


static func _union(a: Array, b: Array) -> Array:
	if a.is_empty():
		return b
	if b.is_empty():
		return a
	return [minf(a[0], b[0]), minf(a[1], b[1]), maxf(a[2], b[2]), maxf(a[3], b[3])]


func _close(actual: float, expected: float, what: String) -> void:
	ok(absf(actual - expected) <= expected * TOL, "%s: %.1f, expected %.1f (+-3%%)" % [what, actual, expected])


func test_every_row_has_its_drawing_and_buttons() -> void:
	var bodies := _bodies()
	for row in DeviceScript.load_table():
		var art := str(row.get("art", ""))
		if art == "generic":
			ok(row["id"].ends_with("-family") or row.get("tier", "") == "family", row["id"] + " only unknown-model rows use the generic drawing")
			continue
		ok(bodies.has(art), "%s: art %s has a body record" % [row["id"], art])
		var body: Dictionary = bodies.get(art, {})
		ok(row["id"] in body.get("models", []), "%s listed in body %s" % [row["id"], art])
		var path := ART + art + ".svg"
		ok(FileAccess.file_exists(path), path + " exists")
		var svg := FileAccess.get_file_as_string(path)
		if DeviceScript.form_of(row) != "handheld":
			# a box for the TV: an outline, no screen or controls to point at
			ok(svg.contains("id=\"part-body\""), "%s has part-body" % art)
			ok(not svg.contains("id=\"btn-South\""), "%s draws no controls it doesn't have" % art)
			continue
		for id in required_ids(row, body):
			ok(svg.contains("id=\"%s\"" % id), "%s (%s) has %s" % [art, row["id"], id])


func test_bodies_are_sourced_and_drawn_to_scale() -> void:
	var u: float = DeviceScript.UNITS_PER_MM
	var ids := []
	for row in DeviceScript.load_table():
		ids.append(row["id"])
	for art in _bodies():
		var b: Dictionary = _bodies()[art]
		ok(not b.get("source", []).is_empty(), art + " has a source")
		for m in b.get("models", []):
			ok(m in ids, "%s: model %s is a devices.json row" % [art, m])
		for k in ["w_mm", "h_mm", "d_mm", "screen_in"]:
			if k == "screen_in" and str(b.get("form", "")) == "console":
				ok(b.get(k) == null, art + " is a box: no screen size")
				continue
			ok(_num(b.get(k)) or b.get(k) == "unverified", "%s.%s is a number or \"unverified\"" % [art, k])
		var svg := FileAccess.get_file_as_string(ART + art + ".svg")
		var core := bbox(svg, "part-body")
		ok(not core.is_empty(), art + " part-body bbox")
		if core.is_empty():
			continue
		var outline := _union(_union(core, bbox(svg, "part-controller-left")), bbox(svg, "part-controller-right"))
		if _num(b["h_mm"]):
			_close(outline[3] - outline[1], b["h_mm"] * u, art + " height at scale")
		if _num(b["w_mm"]):
			_close(outline[2] - outline[0], b["w_mm"] * u, art + " width at scale")
			if _num(b["h_mm"]):
				_close((outline[2] - outline[0]) / (outline[3] - outline[1]), float(b["w_mm"]) / b["h_mm"], art + " aspect")
		if _num(b.get("core_w_mm")):
			_close(core[2] - core[0], b["core_w_mm"] * u, art + " tablet width at scale")


func test_no_orphan_drawings() -> void:
	var bodies := _bodies()
	for f in DirAccess.get_files_at(ART.trim_suffix("/")):
		if f.ends_with(".svg"):
			ok(f in ["generic.svg", "generic-box.svg"] or bodies.has(f.get_basename()), f + " belongs to a body record")


func test_body_for() -> void:
	eq(float(DeviceScript.body_for("msi-claw-8-ex").get("w_mm", 0)), 321.0, "Claw 8 EX width")
	eq(DeviceScript.body_for("steam-deck-oled"), DeviceScript.body_for("steam-deck-lcd"), "one shell, one record")
	eq(DeviceScript.body_for("msi-claw-family"), {}, "generic")
	eq(float(DeviceScript.body_for("valve-steam-machine").get("w_mm", 0)), 156.0, "Steam Machine width")


func test_boxes_have_their_own_drawings() -> void:
	eq(DeviceScript.picture_for("valve-steam-machine"), ART + "steam-machine.svg", "Steam Machine")
	ok(FileAccess.file_exists(ART + "generic-box.svg"), "the drawing for an unknown PC by the TV")
	var row := DeviceScript.fallback_row({"sys_vendor": "AZW", "product_name": "SER8"}, "AMD Ryzen 7 8845HS", {}, DeviceScript.load_doc().get("cpus", []), false)
	eq(DeviceScript.art_path(str(row["art"])), ART + "generic-box.svg", "an unknown box gets it")
	var hh := DeviceScript.fallback_row({"sys_vendor": "Contoso", "product_name": "Pocket"}, "AMD Ryzen 7 8840U", {}, DeviceScript.load_doc().get("cpus", []), true)
	eq(DeviceScript.art_path(str(hh["art"])), ART + "generic.svg", "an unknown handheld keeps the handheld")
