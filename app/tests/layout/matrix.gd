extends RefCounted
## The screens GameCove is checked on (docs/RESOLUTIONS.md has the table and
## the sources): every panel in data/devices.json, the TVs and monitors a
## docked handheld, a Steam Machine or a PC by the TV ends up on, ultrawides,
## gamescope running nested below the panel's own resolution, and two odd
## windows (4:3, a portrait panel nobody rotated).
##
## A row: {id, size: Vector2i (the window GameCove gets), screen: {kind,
## diagonal_in}, note, devices: [ids], ci: bool}. Rows that end up with the
## same layout and scale show the same thing; layouts() groups them.

const UiScale := preload("res://scripts/ui/ui_scale.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

## Screens that aren't a handheld's own panel. Sizes: common TV and monitor
## classes; diagonal 0 = the screen doesn't say (AV receiver, projector).
const EXTERNAL := [
	{"id": "tv-720p-32in", "size": [1280, 720], "kind": "tv", "in": 32.0, "note": "HD-ready TV, Deck dock's lowest mode"},
	{"id": "tv-768p-32in", "size": [1366, 768], "kind": "tv", "in": 32.0, "note": "older 1366x768 TV"},
	{"id": "tv-1080p-55in", "size": [1920, 1080], "kind": "tv", "in": 55.0, "note": "1080p TV; a 4K TV with the session at 1080p", "ci": true},
	{"id": "tv-1440p-55in", "size": [2560, 1440], "kind": "tv", "in": 55.0, "note": "4K TV with the session at 1440p (Steam Machine default for heavy games)"},
	{"id": "tv-4k-55in", "size": [3840, 2160], "kind": "tv", "in": 55.0, "note": "4K TV: Steam Machine, docked handheld", "ci": true},
	{"id": "tv-4k-unknown", "size": [3840, 2160], "kind": "tv", "in": 0.0, "note": "4K through an AV receiver or projector (no size in the EDID)"},
	{"id": "monitor-1080p-24in", "size": [1920, 1080], "kind": "monitor", "in": 24.0, "note": "desk monitor"},
	{"id": "monitor-1200p-24in", "size": [1920, 1200], "kind": "monitor", "in": 24.0, "note": "16:10 desk monitor"},
	{"id": "monitor-1440p-27in", "size": [2560, 1440], "kind": "monitor", "in": 27.0, "note": "desk monitor", "ci": true},
	{"id": "monitor-4k-32in", "size": [3840, 2160], "kind": "monitor", "in": 32.0, "note": "4K desk monitor"},
	{"id": "monitor-4k-16x10-30in", "size": [3840, 2400], "kind": "monitor", "in": 30.0, "note": "16:10 4K monitor"},
	{"id": "ultrawide-1080p-29in", "size": [2560, 1080], "kind": "monitor", "in": 29.0, "note": "21:9 monitor"},
	{"id": "ultrawide-1440p-34in", "size": [3440, 1440], "kind": "monitor", "in": 34.0, "note": "21:9 monitor"},
	{"id": "ultrawide-1440p-tv", "size": [3440, 1440], "kind": "tv", "in": 0.0, "note": "21:9 screen on a box that can't read its size", "ci": true},
	{"id": "superwide-1440p-49in", "size": [5120, 1440], "kind": "monitor", "in": 49.0, "note": "32:9 monitor"},
	{"id": "portable-1080p-15in", "size": [1920, 1080], "kind": "handheld", "in": 15.6, "note": "USB-C portable monitor, read up close"},
	{"id": "nested-1200p-on-8.8in", "size": [1920, 1200], "kind": "handheld", "in": 8.8, "note": "gamescope at 1920x1200 on a 2560x1600 8.8 inch panel"},
	{"id": "nested-800p-on-8in", "size": [1280, 800], "kind": "handheld", "in": 8.0, "note": "gamescope at 1280x800 on a 1920x1200 8 inch panel"},
	{"id": "window-4x3", "size": [1024, 768], "kind": "", "in": 0.0, "note": "no supported device has a 4:3 panel; a small window or VM"},
	{"id": "portrait-unrotated", "size": [800, 1280], "kind": "", "in": 0.0, "note": "a portrait-native panel (Deck LCD, many 7 and 8 inch ones) before gamescope rotates it"},
]
## Device panels always in the reduced (CI) run, by "<w>x<h>@<inches>".
const CI_PANELS := ["1280x800@7.0", "1920x1080@7.0", "1920x1200@8.0"]


static func rows() -> Array:
	var out := []
	var by_panel := {}
	for d in DeviceScript.load_table():
		var p: Variant = d.get("panel")
		if not p is Dictionary:
			continue
		var key := "%dx%d@%s" % [int(p["resolution"][0]), int(p["resolution"][1]), str(float(p["size_in"]))]
		if not by_panel.has(key):
			by_panel[key] = {"id": "panel-" + key.replace("@", "-").replace(".0", "") + "in",
				"size": Vector2i(int(p["resolution"][0]), int(p["resolution"][1])),
				"screen": {"kind": "handheld", "diagonal_in": float(p["size_in"])},
				"note": "", "devices": [], "ci": key in CI_PANELS}
			out.append(by_panel[key])
		by_panel[key]["devices"].append(str(d["id"]))
	out.sort_custom(func(a, b):
		if a["size"] != b["size"]:
			return a["size"].x * a["size"].y < b["size"].x * b["size"].y
		return a["screen"]["diagonal_in"] < b["screen"]["diagonal_in"])
	for e in EXTERNAL:
		out.append({"id": e["id"], "size": Vector2i(int(e["size"][0]), int(e["size"][1])),
			"screen": {"kind": e["kind"], "diagonal_in": float(e["in"])}, "note": e["note"], "devices": [],
			"ci": bool(e.get("ci", false))})
	for r in out:
		r["scale"] = UiScale.scale_for(r["size"], r["screen"])
		r["layout"] = UiScale.layout_for(r["size"], r["screen"])
	return out


static func row(id: String) -> Dictionary:
	for r in rows():
		if r["id"] == id:
			return r
	return {}


## Rows grouped by the layout they get: [{layout, scale (the sharpest row's),
## rows: [row, ...]}]. Rows of a group show the same thing, bigger or sharper.
## `ci_only`: the reduced set.
static func layouts(ci_only := false) -> Array:
	var out := []
	var seen := {}
	for r in rows():
		if ci_only and not r["ci"]:
			continue
		var key := str(r["layout"])
		if not seen.has(key):
			seen[key] = {"layout": r["layout"], "scale": r["scale"], "rows": []}
			out.append(seen[key])
		seen[key]["rows"].append(r)
		seen[key]["scale"] = maxf(float(seen[key]["scale"]), float(r["scale"]))
	return out


## The smallest text (layout px) readable on every row of a group: the row
## where a layout pixel looks smallest decides.
static func min_font_px(group: Dictionary) -> float:
	var need := 0.0
	for r in group["rows"]:
		var one := UiScale.text_arcmin(1.0, r["scale"], r["size"], r["screen"])
		if one > 0.0:
			need = maxf(need, UiScale.MIN_TEXT_ARCMIN / one)
	return need
