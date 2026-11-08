extends "res://scripts/ui/settings/page.gd"
## Performance: overlay level (PerfMonitor) with what this system can and
## can't measure, and the achievement rarity fetch (Achievements).

## Where the screen keeps prefs no service stores itself.
const PREFS_PATH := "user://settings.cfg"


func _connect() -> void:
	var p := svc("perf")
	if p != null and p.has_signal("overlay_changed"):
		p.overlay_changed.connect(func(level):
			if rows.has("overlay"):
				rows["overlay"].set_value_quiet(int(level)))


func build() -> void:
	var p := svc("perf")
	var box := add_card("While you play", "gauge", "The overlay sits on top of the game. Change it here or in the quick menu.")
	if p == null or not p.has_method("set_overlay_level"):
		box.add_child(SKit.note(TS.OVERLAY_MISSING, "info", "OverlayMissing"))
	else:
		var caps: Dictionary = p.capabilities() if p.has_method("capabilities") else {}
		if p.overlay_supported():
			var r := choice(box, "overlay", TS.OVERLAY, [0, 1, 2, 3], level_names(p), clampi(int(p.overlay_level()), 0, 3), by_value(TS.OVERLAY_HELP), "gauge")
			r.changed.connect(func(v):
				if not p.set_overlay_level(int(v)):
					notify("Couldn't change the overlay.", "bad")
					r.set_value_quiet(int(p.overlay_level())))
		else:
			box.add_child(SKit.note(TS.OVERLAY_MISSING, "info", "OverlayMissing"))
		if bool(caps.get("fps_needs_overlay", false)):
			box.add_child(SKit.note(TS.FPS_NEEDS_OVERLAY, "warn", "FpsNeedsOverlay"))
		var srcs: Dictionary = caps.get("sources", {})
		if not srcs.is_empty():
			box.add_child(_measures(srcs))

	var a := svc("achievements")
	if a != null and "fetch_rarity" in a:
		var ach := add_card("Achievements", "star")
		var t := toggle(ach, "fetch_rarity", TS.RARITY, bool(a.fetch_rarity), by_value(TS.RARITY_HELP), "star")
		t.changed.connect(func(v): set_rarity(a, bool(v)))


static func level_names(_p: Object) -> Array:
	return TS.OVERLAY_LABELS


## "Measures here: frame rate, power, temperatures" from capabilities().sources.
static func _measures(srcs: Dictionary) -> Label:
	var names := {"fps": "frame rate", "package_w": "power", "cpu_load": "CPU load", "gpu_load": "GPU load", "cpu_temp": "temperatures", "battery_w": "battery drain"}
	var have: Array = []
	var miss: Array = []
	for k in names:
		(have if str(srcs.get(k, "")) != "" else miss).append(names[k])
	var text := "Measured here: %s." % ", ".join(have) if not have.is_empty() else "Nothing can be measured here yet."
	if not miss.is_empty() and not have.is_empty():
		text += " Not available: %s." % ", ".join(miss)
	var l := Kit.label(text, "QuietLabel", true)
	l.name = "Measures"
	return l


static func set_rarity(a: Object, on: bool, path := PREFS_PATH) -> void:
	a.fetch_rarity = on
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value("achievements", "fetch_rarity", on)
	cfg.save(path)


## Puts the saved choice back on the service (the settings screen calls this
## once at start).
static func restore_rarity(a: Object, path := PREFS_PATH) -> void:
	if a == null or not "fetch_rarity" in a:
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) == OK and cfg.has_section_key("achievements", "fetch_rarity"):
		a.fetch_rarity = bool(cfg.get_value("achievements", "fetch_rarity"))
