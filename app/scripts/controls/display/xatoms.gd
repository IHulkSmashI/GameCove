extends RefCounted
## gamescope root-window properties ("atoms") for the display / system
## controls, through `xprop` and ctx.runner (run(program, args) -> {code, out}).
##
## Control hooks already run on the Controls worker thread, so these calls block
## that worker, never the UI: this *is* the async path for anything the UI
## triggers (the Gamescope autoload's *_async variants call back on the main
## thread, which a hook can't wait for). Command lines come from the Gamescope
## service's static builders, so both speak to gamescope the same way.
##
## Reads share one `xprop -root -notype` dump for CACHE_MS: Controls.detect_all()
## reads every display control in a burst, and that's one process, not twenty.
## Any write drops the cache.
##
## Atom names and value encodings: ValveSoftware/gamescope src/steamcompmgr.cpp
## (handle_property_notify, init_xwayland_ctx; commit 89b9e6e, 2026-11-07).
## Floats travel as the 32-bit pattern of an IEEE float in a CARDINAL
## (gamescope's bit_cast<float>; vibrantDeck and ClawDeck screen.py do the same).

const Gamescope := preload("res://scripts/gamescope/gamescope.gd")

const XPROP := "xprop"
const CACHE_MS := 750

var ctx: Dictionary = {}
var _props: Dictionary = {}
var _props_at := -1000000


func _init(context: Dictionary = {}) -> void:
	ctx = context


## Environment value; ctx.env (tests) wins over the real environment.
func env(name: String) -> String:
	var e: Dictionary = ctx.get("env", {})
	return str(e[name]) if e.has(name) else OS.get_environment(name)


## True inside a gamescope session (gamescope-session-plus exports
## GAMESCOPE_WAYLAND_DISPLAY; any gamescope publishes GAMESCOPE_FOCUSABLE_APPS).
func running() -> bool:
	if env("GAMESCOPE_WAYLAND_DISPLAY") != "":
		return true
	return props().has("GAMESCOPE_FOCUSABLE_APPS")


## {atom: raw text after " = "} for every root property. Cached briefly.
func props() -> Dictionary:
	var now := Time.get_ticks_msec()
	if now - _props_at < CACHE_MS:
		return _props
	_props = {}
	var r := _run(PackedStringArray(["-root", "-notype"]))
	if int(r.get("code", -1)) == 0:
		_props = parse_dump(str(r.get("out", "")))
	_props_at = now
	return _props


func invalidate() -> void:
	_props_at = -1000000


func has(atom: String) -> bool:
	return props().has(atom)


## CARDINAL values of a root atom, [] when unset or not numbers.
func cardinals(atom: String) -> Array:
	return parse_cardinals(str(props().get(atom, "")))


## First CARDINAL value, or `fallback` when unset.
func cardinal(atom: String, fallback: Variant = null) -> Variant:
	var v := cardinals(atom)
	return v[0] if v.size() > 0 else fallback


## The atom's values decoded as floats ([] when unset).
func floats(atom: String) -> Array:
	var out := []
	for v in cardinals(atom):
		out.append(bits_to_float(int(v)))
	return out


func float_value(atom: String, fallback: Variant = null) -> Variant:
	var v := floats(atom)
	return v[0] if v.size() > 0 else fallback


## A text atom ("" when unset).
func text(atom: String) -> String:
	return parse_text(str(props().get(atom, "")))


## Sets a CARDINAL atom and reads it back. True when gamescope holds the value.
func set_cardinals(atom: String, values: Array) -> bool:
	invalidate()
	var r := _run(Gamescope.set_args("root", atom, values))
	if int(r.get("code", -1)) != 0:
		return false
	var back := _run(Gamescope.get_args(atom))
	if int(back.get("code", -1)) != 0:
		return false
	var want := []
	for v in values:
		want.append(int(v))
	return Gamescope.parse_values(str(back.get("out", "")), atom) == want


## Sets a CARDINAL atom without reading it back: for one-shot requests that
## gamescope deletes once handled (GAMESCOPECTRL_REQUEST_SCREENSHOT).
func send_cardinal(atom: String, value: int) -> bool:
	invalidate()
	return int(_run(Gamescope.set_args("root", atom, [value])).get("code", -1)) == 0


func set_cardinal(atom: String, value: int) -> bool:
	return set_cardinals(atom, [value])


func set_floats(atom: String, values: Array) -> bool:
	var bits := []
	for f in values:
		bits.append(float_to_bits(float(f)))
	return set_cardinals(atom, bits)


func set_float(atom: String, value: float) -> bool:
	return set_floats(atom, [value])


## Sets an 8-bit text atom (gamescope reads these with XGetTextProperty).
func set_text(atom: String, value: String) -> bool:
	invalidate()
	var r := _run(PackedStringArray(["-root", "-f", atom, "8u", "-set", atom, value]))
	return int(r.get("code", -1)) == 0


## Removes a root atom (gamescope then uses its built-in default).
func remove(atom: String) -> bool:
	invalidate()
	var r := _run(PackedStringArray(["-root", "-remove", atom]))
	return int(r.get("code", -1)) == 0


func _run(args: PackedStringArray) -> Dictionary:
	var runner = ctx.get("runner")
	if runner == null:
		return {"code": -1, "out": ""}
	return runner.run(XPROP, args)


# --- Encoding (static: tests check them directly) ---

static func float_to_bits(f: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, f)
	return b.decode_u32(0)


static func bits_to_float(i: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, i & 0xFFFFFFFF)
	return b.decode_float(0)


## `xprop -root -notype` output -> {atom: raw value}.
static func parse_dump(out: String) -> Dictionary:
	var d := {}
	for line in out.split("\n"):
		var i := line.find(" = ")
		if i <= 0 or line.begins_with("\t") or line.begins_with(" "):
			continue
		var name := line.substr(0, i).strip_edges()
		if name.is_valid_ascii_identifier():
			d[name] = line.substr(i + 3).strip_edges()
	return d


static func parse_cardinals(raw: String) -> Array:
	var out := []
	if raw == "":
		return out
	for part in raw.split(","):
		var p := part.strip_edges()
		if not p.is_valid_int():
			return []
		out.append(p.to_int())
	return out


static func parse_text(raw: String) -> String:
	var s := raw.strip_edges()
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2).c_unescape()
	return s
