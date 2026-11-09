extends RefCounted
## Audio controls through PipeWire's `wpctl` (display/wpctl.gd): volume, mute,
## sound output, microphone mute and microphone. Per-app volume isn't a single
## control; streams() / set_stream_volume() give the UI what it needs for a
## per-app list. Hooks run on the Controls worker.

const Ctl := preload("res://scripts/controls/control.gd")
const Wp := preload("res://scripts/controls/display/wpctl.gd")
const T := preload("res://scripts/controls/display/texts_display.gd")

## Volume never goes past 100 % (WirePlumber allows 150 %, which distorts
## handheld speakers).
const LIMIT := "1.0"


func setup(_ctx: Dictionary) -> void:
	pass


func controls() -> Array:
	return [
		_mk("audio.volume", {"kind": "slider", "min_value": 0.0, "max_value": 100.0, "step": 1.0, "unit": "%",
			"default_value": 50.0, "per_game": false},
			func(c): return _detect_node(c, "sinks"), func(c): return _read_vol(c, Wp.SINK), _write_volume),
		_mk("audio.mute", {"kind": "toggle", "default_value": false, "per_game": false},
			func(c): return _detect_node(c, "sinks"), func(c): return _read_muted(c, Wp.SINK),
			func(c, v): return _wp(c, ["set-mute", Wp.SINK, "1" if v else "0"])),
		_mk("audio.output", {"kind": "choice", "per_game": false},
			func(c): return _detect_list(c, "sinks"), func(c): return _default_name(c, "sinks"),
			func(c, v): return _set_default(c, "sinks", v)),
		_mk("audio.mic_mute", {"kind": "toggle", "default_value": false, "per_game": false},
			func(c): return _detect_node(c, "sources"), func(c): return _read_muted(c, Wp.SOURCE),
			func(c, v): return _wp(c, ["set-mute", Wp.SOURCE, "1" if v else "0"])),
		_mk("audio.input", {"kind": "choice", "per_game": false},
			func(c): return _detect_list(c, "sources"), func(c): return _default_name(c, "sources"),
			func(c, v): return _set_default(c, "sources", v)),
	]


func _mk(id: String, spec: Dictionary, d: Callable, r: Callable, w: Callable) -> RefCounted:
	var s := {"id": id, "title": T.title(id), "help": T.help(id), "group": "audio"}
	s.merge(spec, true)
	var c = Ctl.make(s, d, r, w)
	c.set_meta("provider", self)
	return c


# --- wpctl -------------------------------------------------------------------

func _run(c, args: Array) -> Dictionary:
	var runner = c.ctx.get("runner")
	if runner == null:
		return {"code": -1, "out": ""}
	return runner.run(Wp.WPCTL, PackedStringArray(args))


func _wp(c, args: Array) -> bool:
	return int(_run(c, args).get("code", -1)) == 0


## Parsed `wpctl status`, or null when wpctl isn't there / PipeWire isn't up.
func status(c) -> Variant:
	var r := _run(c, ["status"])
	if int(r.get("code", -1)) != 0:
		return null
	return Wp.parse_status(str(r.get("out", "")))


func _detect_node(c, kind: String) -> String:
	var st = status(c)
	if st == null:
		return T.NO_WPCTL
	if st[kind].is_empty():
		return T.NO_SINK if kind == "sinks" else T.NO_SOURCE
	return ""


func _detect_list(c, kind: String) -> String:
	var st = status(c)
	if st == null:
		return T.NO_WPCTL
	if st[kind].is_empty():
		return T.NO_SINK if kind == "sinks" else T.NO_SOURCE
	# Values are the device names: stable across reboots, unlike PipeWire ids.
	# Jacks with nothing plugged in aren't offered (they can't play or record; the
	# Claw's Headphones / Headset Microphone choices failed with nothing connected),
	# unless one is the default now.
	var unplugged := _unplugged(c, kind)
	var opts := []
	var seen := {}
	for n in st[kind]:
		if n["name"] in unplugged and not n["default"]:
			continue
		if not seen.has(n["name"]):
			seen[n["name"]] = true
			opts.append({"value": n["name"], "label": n["name"]})
	c.options = opts
	return ""


## Descriptions of sinks/sources whose jack is empty (pipewire-pulse's port availability);
## [] when pactl isn't there.
func _unplugged(c, kind: String) -> Array:
	var runner = c.ctx.get("runner")
	if runner == null:
		return []
	var r: Dictionary = runner.run("pactl", PackedStringArray(["-f", "json", "list", kind]))
	return Wp.parse_unplugged(str(r.get("out", ""))) if int(r.get("code", -1)) == 0 else []


func _read_vol(c, target: String) -> Variant:
	var r := _run(c, ["get-volume", target])
	var v := Wp.parse_volume(str(r.get("out", ""))) if int(r.get("code", -1)) == 0 else {}
	return roundf(clampf(float(v["volume"]), 0.0, 1.0) * 100.0) if v.has("volume") else null


func _read_muted(c, target: String) -> Variant:
	var r := _run(c, ["get-volume", target])
	var v := Wp.parse_volume(str(r.get("out", ""))) if int(r.get("code", -1)) == 0 else {}
	return v.get("muted")


func _write_volume(c, v) -> bool:
	var frac := clampf(float(v) / 100.0, 0.0, 1.0)
	return _wp(c, ["set-volume", "-l", LIMIT, Wp.SINK, "%.2f" % frac])


func _default_name(c, kind: String) -> Variant:
	var st = status(c)
	if st == null:
		return null
	for n in st[kind]:
		if n["default"]:
			return n["name"]
	return null


func _set_default(c, kind: String, name) -> bool:
	var st = status(c)
	if st == null:
		return false
	if name in _unplugged(c, kind):
		return false   # nothing plugged into that jack
	for n in st[kind]:
		if n["name"] == name:
			return _wp(c, ["set-default", str(n["id"])])
	return false


# --- per-app volume (for a per-app list in the UI) ------------------------------

## [{"id", "name"}] of apps playing or recording now. Worker only (runs wpctl).
func streams(ctx: Dictionary) -> Array:
	var r: Dictionary = ctx.runner.run(Wp.WPCTL, PackedStringArray(["status"])) if ctx.get("runner") != null else {}
	if int(r.get("code", -1)) != 0:
		return []
	return Wp.parse_status(str(r.get("out", "")))["streams"]


## Sets one app stream's volume (0-100 %). Worker only.
func set_stream_volume(ctx: Dictionary, stream_id: int, pct: float) -> bool:
	if ctx.get("runner") == null or stream_id <= 0:
		return false
	var r: Dictionary = ctx.runner.run(Wp.WPCTL, PackedStringArray(["set-volume", "-l", LIMIT, str(stream_id),
		"%.2f" % clampf(pct / 100.0, 0.0, 1.0)]))
	return int(r.get("code", -1)) == 0
