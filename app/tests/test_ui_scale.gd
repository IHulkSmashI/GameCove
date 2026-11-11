extends "res://tests/test_case.gd"
## Interface size: the layout each screen gets (ui_scale.gd), what the screen
## is (display_output.gd), and that every supported panel and the usual TVs
## keep text readable.

const UiScale := preload("res://scripts/ui/ui_scale.gd")
const DisplayOutput := preload("res://scripts/system/display_output.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const UiPrefs := preload("res://scripts/ui/ui_prefs.gd")
const Matrix := preload("res://tests/layout/matrix.gd")


func _hh(d: float) -> Dictionary:
	return {"kind": "handheld", "diagonal_in": d}


func test_handheld_panels_lay_out_by_their_glass() -> void:
	# a Steam Deck is the base layout
	eq(UiScale.layout_for(Vector2i(1280, 800), _hh(7.0)), Vector2i(1280, 800), "Deck LCD")
	eq(UiScale.layout_for(Vector2i(1280, 800), _hh(7.4)), Vector2i(1280, 800), "Deck OLED")
	# the same 7 inches at 1080p: the same layout, not a 1.6x bigger one with tiny text
	eq(UiScale.layout_for(Vector2i(1920, 1080), _hh(7.0)), Vector2i(1422, 800), "7 inch 1080p")
	eq(UiScale.layout_for(Vector2i(1920, 1080), _hh(5.5)), Vector2i(1422, 800), "5.5 inch 1080p: as big as it goes")
	# 8 inch 1920x1200 (Claw 8): unchanged, 1536x960
	eq(UiScale.layout_for(Vector2i(1920, 1200), _hh(8.0)), Vector2i(1536, 960), "Claw 8")
	# bigger, denser tablets: about the same layout, never a 2560 px wide one
	for case in [[Vector2i(2560, 1600), 8.8], [Vector2i(2560, 1600), 8.4], [Vector2i(2560, 1600), 10.95], [Vector2i(2880, 1800), 14.0]]:
		var l := UiScale.layout_for(case[0], _hh(case[1]))
		ok(l.x >= 1500 and l.x <= 1620, "%s at %s inches lays out about 1536 wide, got %s" % [case[0], case[1], l])


func test_gamescope_nested_resolution_keeps_the_physical_size() -> void:
	# an 8.8" 2560x1600 panel with the session at 1920x1200 or 1280x800: the
	# glass is the same size, so the layout is too
	var native := UiScale.layout_for(Vector2i(2560, 1600), _hh(8.8))
	var nested := UiScale.layout_for(Vector2i(1920, 1200), _hh(8.8))
	ok(absi(native.x - nested.x) <= 40, "nested 1920x1200 lays out like native: %s vs %s" % [nested, native])
	eq(UiScale.layout_for(Vector2i(1280, 800), _hh(8.8)), Vector2i(1280, 800), "nested 800p can't show more than 1280x800")


func test_tvs_get_the_ten_foot_layout_at_every_resolution() -> void:
	var tv := {"kind": "tv", "diagonal_in": 55.0}
	for win in [Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160)]:
		eq(UiScale.layout_for(win, tv), Vector2i(1422, 800), "TV at %s" % win)
	eq(UiScale.layout_for(Vector2i(1280, 720), tv), Vector2i(1422, 800), "720p TV: the layout never goes under 1280x800")
	eq(UiScale.layout_for(Vector2i(3840, 2400), tv), Vector2i(1280, 800), "16:10 4K")
	# a TV that doesn't say its size is still a TV
	eq(UiScale.layout_for(Vector2i(3840, 2160), {"kind": "tv", "diagonal_in": 0.0}), Vector2i(1422, 800), "unknown size")
	# ultrawide: the layout stops at 2:1 and sits centred with bars (like a console)
	eq(UiScale.layout_for(Vector2i(3440, 1440), tv), Vector2i(1600, 800), "21:9")
	eq(UiScale.layout_for(Vector2i(2560, 1080), tv), Vector2i(1600, 800), "21:9 1080p")
	eq(UiScale.layout_for(Vector2i(5120, 1440), tv), Vector2i(1600, 800), "32:9")
	ok(UiScale.boxed(Vector2i(3440, 1440)), "21:9 shows bars")
	ok(not UiScale.boxed(Vector2i(3840, 2160)) and not UiScale.boxed(Vector2i(1280, 800)) and not UiScale.boxed(Vector2i(1024, 768)), "16:9, 16:10 and 4:3 fill the screen")
	eq(UiScale.area(Vector2i(3440, 1440)), Vector2(2880, 1440), "the part of a 21:9 screen we use")


func test_odd_windows_stay_in_shape() -> void:
	# a portrait panel nobody rotated: a 5:4 box, not a 1280x2048 layout
	eq(UiScale.layout_for(Vector2i(800, 1280), {}), Vector2i(1280, 1024), "portrait")
	ok(UiScale.boxed(Vector2i(800, 1280)), "with bars")
	for win in [Vector2i(800, 1280), Vector2i(1024, 768), Vector2i(5120, 1440), Vector2i(3840, 2400), Vector2i(1366, 768)]:
		for scr in [{}, {"kind": "tv", "diagonal_in": 0.0}, {"kind": "monitor", "diagonal_in": 30.0}, {"kind": "handheld", "diagonal_in": 8.0}]:
			for id in UiScale.SIZES:
				var l := UiScale.layout_for(win, scr, id)
				var shape := float(l.x) / float(l.y)
				ok(l.x >= 1280 and l.y >= 800 and shape >= 1.24 and shape <= 2.01, "%s %s %s lays out %s" % [win, scr, id, l])


func test_desk_monitor_sits_between() -> void:
	var l := UiScale.layout_for(Vector2i(2560, 1440), {"kind": "monitor", "diagonal_in": 27.0})
	ok(l.x > 1422 and l.x <= 1600, "27 inch 1440p monitor: more room than a TV, got %s" % l)
	eq(UiScale.layout_for(Vector2i(1920, 1080), {"kind": "monitor", "diagonal_in": 24.0}), Vector2i(1422, 800), "24 inch 1080p")
	# a big, dense monitor: never rows wider than 1600 by itself
	eq(UiScale.layout_for(Vector2i(3840, 2160), {"kind": "monitor", "diagonal_in": 32.0}), Vector2i(1600, 900), "32 inch 4K")
	for d in DeviceScript.load_table():
		var panel: Variant = d.get("panel")
		if panel is Dictionary:
			var lw := UiScale.layout_for(Vector2i(int(panel["resolution"][0]), int(panel["resolution"][1])), {"kind": "handheld", "diagonal_in": float(panel["size_in"])})
			ok(lw.x <= 1600, "%s lays out %s" % [d["id"], lw])


func test_unknown_screen_keeps_the_half_rate_rule() -> void:
	eq(UiScale.layout_for(Vector2i(1280, 800), {}), Vector2i(1280, 800), "base")
	eq(UiScale.layout_for(Vector2i(1920, 1200), {}), Vector2i(1536, 960), "1920x1200")
	eq(UiScale.layout_for(Vector2i(1024, 768), {}), Vector2i(1280, 960), "smaller than the base: scaled down, 1280 wide")
	eq(load("res://scripts/main.gd").base_size_for(Vector2i(1920, 1200)), Vector2i(1536, 960), "main.gd's wrapper")


func test_interface_size_multiplies_and_offers_only_real_choices() -> void:
	var claw := _hh(8.0)
	var win := Vector2i(1920, 1200)
	ok(UiScale.scale_for(win, claw, "small") < UiScale.scale_for(win, claw, "default"), "small is smaller")
	ok(UiScale.scale_for(win, claw, "large") > UiScale.scale_for(win, claw, "default"), "large is larger")
	eq(UiScale.scale_for(win, claw, "largest"), 1.5, "largest stops at 1280x800")
	eq(UiScale.layout_for(win, claw, "largest"), Vector2i(1280, 800), "its layout")
	eq(UiScale.sizes_for(win, claw), ["small", "default", "large", "largest"] as Array[String], "a Claw 8 has all four")
	# a Steam Deck is already as large as it goes
	eq(UiScale.sizes_for(Vector2i(1280, 800), _hh(7.0)), ["small", "default"] as Array[String], "Deck: Small and Default")
	eq(UiScale.sizes_for(Vector2i(3840, 2160), {"kind": "tv", "diagonal_in": 55.0}), ["small", "default"] as Array[String], "TV: already the 10-foot size")
	for id in UiScale.SIZES:
		var l := UiScale.layout_for(Vector2i(1920, 1080), _hh(7.0), id)
		ok(l.x >= 1280 and l.y >= 800, "%s never lays out under 1280x800: %s" % [id, l])


func test_prefs_keep_the_size() -> void:
	var was: Dictionary = UiPrefs.values()
	var was_path: String = UiPrefs.path
	var path := OS.get_cache_dir().path_join("gamecove-test-uiscale-%d.cfg" % Time.get_ticks_usec())
	UiPrefs.path = path
	UiPrefs.set_values({"interface_size": "large"})
	UiPrefs.save_prefs()
	UiPrefs.set_values({"interface_size": "default"})
	UiPrefs.load_prefs()
	eq(UiPrefs.interface_size, "large", "saved and loaded")
	UiPrefs.set_values({"interface_size": "enormous"})
	eq(UiPrefs.interface_size, "default", "unknown ids fall back")
	DirAccess.remove_absolute(path)
	UiPrefs.path = was_path
	UiPrefs.set_values(was)


## Every panel in devices.json and every screen in the layout matrix: the
## smallest label (12 px) stays readable from where that screen is used.
func test_every_supported_screen_keeps_text_readable() -> void:
	var seen := 0
	for d in DeviceScript.load_table():
		var panel: Variant = d.get("panel")
		if not panel is Dictionary:
			continue
		var win := Vector2i(int(panel["resolution"][0]), int(panel["resolution"][1]))
		var scr := _hh(float(panel["size_in"]))
		var a := UiScale.text_arcmin(12.0, UiScale.scale_for(win, scr), win, scr)
		ok(a >= UiScale.MIN_TEXT_ARCMIN, "%s: 12 px text is %.1f arc minutes (min %.1f)" % [d["id"], a, UiScale.MIN_TEXT_ARCMIN])
		seen += 1
	ok(seen > 40, "checked the device table (%d panels)" % seen)
	for row in Matrix.rows():
		var scr: Dictionary = row["screen"]
		if float(scr.get("diagonal_in", 0.0)) <= 0.0:
			continue
		var win: Vector2i = row["size"]
		var a := UiScale.text_arcmin(12.0, UiScale.scale_for(win, scr), win, scr)
		ok(a >= UiScale.MIN_TEXT_ARCMIN, "%s: 12 px text is %.1f arc minutes" % [row["id"], a])


func test_old_rule_was_too_small_on_a_4k_tv() -> void:
	# what this replaced: 3840x2160 laid out at 2076x1168 (1.85x), 8 arc minutes from the couch
	var tv := {"kind": "tv", "diagonal_in": 55.0}
	var win := Vector2i(3840, 2160)
	ok(UiScale.text_arcmin(12.0, 1.85, win, tv) < UiScale.MIN_TEXT_ARCMIN, "the half-rate rule fails the TV check")
	ok(UiScale.text_arcmin(12.0, UiScale.scale_for(win, tv), win, tv) >= 11.0, "the TV rule passes it")


# ---- what the screen is -----------------------------------------------------------

func _edid(w_cm: int, h_cm: int) -> PackedByteArray:
	var e := PackedByteArray()
	e.resize(128)
	e.fill(0)
	for i in range(1, 7):
		e[i] = 0xFF
	e[21] = w_cm
	e[22] = h_cm
	return e


func _drm(connectors: Dictionary) -> String:
	var root := OS.get_cache_dir().path_join("gamecove-test-drm-%d" % Time.get_ticks_usec())
	for name in connectors:
		var c: Dictionary = connectors[name]
		var dir := root + "/sys/class/drm/" + str(name)
		DirAccess.make_dir_recursive_absolute(dir)
		for k in ["status", "enabled"]:
			if c.has(k):
				var f := FileAccess.open(dir + "/" + k, FileAccess.WRITE)
				f.store_string(str(c[k]) + "\n")
				f.close()
		if c.has("edid"):
			var f2 := FileAccess.open(dir + "/edid", FileAccess.WRITE)
			f2.store_buffer(c["edid"])
			f2.close()
	DirAccess.make_dir_recursive_absolute(root + "/sys/class/drm/card1")
	DirAccess.make_dir_recursive_absolute(root + "/sys/class/drm/renderD128")
	return root


func _rm(dir: String) -> void:
	for d in DirAccess.get_directories_at(dir):
		_rm(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func test_connector_names() -> void:
	eq(DisplayOutput.connector_type("card1-eDP-1"), "eDP", "panel")
	eq(DisplayOutput.connector_type("card0-HDMI-A-1"), "HDMI-A", "HDMI")
	eq(DisplayOutput.connector_type("card1-DP-3"), "DP", "DisplayPort / USB-C")
	eq(DisplayOutput.connector_type("card1-DSI-1"), "DSI", "Deck LCD")
	eq(DisplayOutput.connector_type("card1"), "", "the card itself")
	eq(DisplayOutput.connector_type("renderD128"), "", "render node")
	eq(DisplayOutput.connector_type("card1-Writeback-1"), "", "writeback")
	eq(DisplayOutput.connector_type("version"), "", "a file")


func test_edid_size() -> void:
	ok(absf(DisplayOutput.edid_diagonal_in(_edid(121, 68)) - 54.6) < 0.2, "121 x 68 cm is a 55 inch TV")
	ok(absf(DisplayOutput.edid_diagonal_in(_edid(60, 34)) - 27.2) < 0.2, "60 x 34 cm is a 27 inch monitor")
	eq(DisplayOutput.edid_diagonal_in(_edid(0, 0)), 0.0, "a projector leaves it out")
	eq(DisplayOutput.edid_diagonal_in(PackedByteArray([1, 2, 3])), 0.0, "short")
	var bad := _edid(60, 34)
	bad[1] = 0
	eq(DisplayOutput.edid_diagonal_in(bad), 0.0, "not an EDID")


func test_handheld_on_its_own_panel() -> void:
	var root := _drm({"card1-eDP-1": {"status": "connected", "enabled": "enabled", "edid": _edid(17, 11)},
		"card1-DP-1": {"status": "disconnected", "enabled": "disabled"}})
	var s := DisplayOutput.current(root, {"size_in": 8.0, "resolution": [1920, 1200]}, false)
	eq(s["kind"], "handheld", "kind")
	eq(s["diagonal_in"], 8.0, "the device table's size wins over the panel's EDID")
	eq(s["external"], false, "not external")
	# an unlisted handheld: the panel's own word
	var s2 := DisplayOutput.current(root, null, false)
	eq(s2["kind"], "handheld", "unknown handheld, EDID believed")
	ok(absf(float(s2["diagonal_in"]) - 7.97) < 0.1, "17 x 11 cm")
	_rm(root)


func test_handheld_docked_to_a_tv_or_monitor() -> void:
	var root := _drm({"card1-eDP-1": {"status": "connected", "enabled": "enabled"},
		"card1-DP-2": {"status": "connected", "enabled": "enabled", "edid": _edid(121, 68)}})
	var s := DisplayOutput.current(root, {"size_in": 7.0, "resolution": [1280, 800]}, false)
	eq(s["kind"], "tv", "the TV wins over the panel")
	eq(s["external"], true, "external")
	eq(UiScale.layout_for(Vector2i(3840, 2160), s), Vector2i(1422, 800), "docked Deck on a 4K TV: 10-foot layout")
	_rm(root)
	root = _drm({"card1-eDP-1": {"status": "connected", "enabled": "enabled"},
		"card1-HDMI-A-1": {"status": "connected", "enabled": "enabled", "edid": _edid(60, 34)}})
	eq(DisplayOutput.current(root, {"size_in": 7.0}, false)["kind"], "monitor", "a 27 inch screen is a desk monitor")
	_rm(root)
	root = _drm({"card1-eDP-1": {"status": "connected", "enabled": "enabled"},
		"card1-DP-1": {"status": "connected", "enabled": "enabled", "edid": _edid(34, 19)}})
	var p := DisplayOutput.current(root, {"size_in": 7.0}, false)
	eq(p["kind"], "handheld", "a 15.6 inch portable monitor is read up close")
	ok(float(p["diagonal_in"]) > 15.0, "with its own size")
	_rm(root)
	# plugged in but switched off by the compositor: still the panel
	root = _drm({"card1-eDP-1": {"status": "connected", "enabled": "enabled"},
		"card1-HDMI-A-1": {"status": "connected", "enabled": "disabled", "edid": _edid(121, 68)}})
	eq(DisplayOutput.current(root, {"size_in": 7.0}, false)["kind"], "handheld", "a disabled output doesn't count")
	_rm(root)


func test_a_box_with_no_panel_is_on_a_tv() -> void:
	var root := _drm({"card1-HDMI-A-1": {"status": "connected", "enabled": "enabled", "edid": _edid(0, 0)}})
	eq(DisplayOutput.current(root, null, true)["kind"], "tv", "Steam Machine through an AV receiver")
	_rm(root)
	eq(DisplayOutput.current("/nonexistent-gamecove", null, true)["kind"], "tv", "nothing readable: still a TV")
	eq(DisplayOutput.current("/nonexistent-gamecove", null, false)["kind"], "", "an unknown handheld: the half-rate rule")
	eq(DisplayOutput.current("/nonexistent-gamecove", {"size_in": 8.0}, false)["kind"], "handheld", "a known one: its panel")


func test_apply_follows_the_window_and_the_override() -> void:
	var w := Window.new()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	UiScale.override_window = Vector2i(3840, 2160)
	var was: Dictionary = UiScale.override_screen
	UiScale.override_screen = {"kind": "tv", "diagonal_in": 65.0}
	ok(UiScale.apply(w, null), "changed")
	eq(w.content_scale_size, Vector2i(1422, 800), "TV layout")
	eq(UiScale.last_scale, 2.7, "2.7 screen pixels per layout pixel")
	ok(not UiScale.apply(w, null), "nothing to do the second time")
	UiScale.override_window = Vector2i(1920, 1080)   # gamescope switched the nested resolution
	ok(not UiScale.apply(w, null), "same layout at 1080p")
	eq(UiScale.last_scale, 1.35, "at 1.35x")
	UiScale.override_screen = was
	UiScale.override_window = Vector2i.ZERO
	w.free()
