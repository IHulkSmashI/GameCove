extends RefCounted
## Display controls: brightness, refresh rate, frame limit, VRR, tearing,
## gamescope's upscaler, colour (vibrance, temperature, night light), HDR,
## ReShade screen effects, rotation, dim / screen-off timers.
## docs/CONTROLS.md "Display, audio and system" has the how and the sources.
##
## Everything gamescope does is a root-window atom (display/xatoms.gd); the rest
## is logind (brightness), the session's environment.d file (rotation,
## refresh-rate list, HDR at start) and a per-device store (values only
## GameCove keeps). Hooks run on the Controls worker, never on the UI thread.

const Ctl := preload("res://scripts/controls/control.gd")
const XAtoms := preload("res://scripts/controls/display/xatoms.gd")
const PanelInfo := preload("res://scripts/controls/display/panel.gd")
const SessionEnv := preload("res://scripts/controls/display/session_env.gd")
const Store := preload("res://scripts/controls/display/store.gd")
const Color2 := preload("res://scripts/controls/display/color.gd")
const Reshade := preload("res://scripts/controls/display/reshade.gd")
const T := preload("res://scripts/controls/display/texts_display.gd")
const Sysfs := preload("res://scripts/controls/display/sysfs.gd")

# gamescope root atoms (src/steamcompmgr.cpp, 89b9e6e)
const A_FPS_LIMIT := "GAMESCOPE_FPS_LIMIT"
const A_DYNAMIC_REFRESH := "GAMESCOPE_DYNAMIC_REFRESH"
const A_VRR_ENABLED := "GAMESCOPE_VRR_ENABLED"
const A_VRR_CAPABLE := "GAMESCOPE_VRR_CAPABLE"
const A_ALLOW_TEARING := "GAMESCOPE_ALLOW_TEARING"
const A_FILTER := "GAMESCOPE_NEW_SCALING_FILTER"   # GamescopeUpscaleFilter (main.hpp)
const A_SCALER := "GAMESCOPE_NEW_SCALING_SCALER"   # GamescopeUpscaleScaler
const A_SHARPNESS := "GAMESCOPE_SHARPNESS"         # 0 (sharpest) .. 20, default 2
const A_FSR_SHARPNESS := "GAMESCOPE_FSR_SHARPNESS" # older name, same value
const A_GAMUT := "GAMESCOPE_COLOR_SDR_GAMUT_WIDENESS"
const A_VIRTUAL_WHITE := "GAMESCOPE_DISPLAY_VIRTUAL_WHITE"
const A_NIGHT := "GAMESCOPE_COLOR_NIGHT_MODE"
const A_SUPPORTS_HDR := "GAMESCOPE_DISPLAY_SUPPORTS_HDR"
const A_HDR_ENABLED := "GAMESCOPE_DISPLAY_HDR_ENABLED"
const A_HDR_ITM := "GAMESCOPE_HDR_ITM_ENABLE"
const A_SDR_ON_HDR := "GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS"
const A_HDR_OUTPUT := "GAMESCOPE_HDR_OUTPUT_FEEDBACK"   # 1 while the output is PQ

const FILTERS := [
	{"value": 0, "label": "Linear"}, {"value": 1, "label": "Nearest"}, {"value": 2, "label": "FSR"},
	{"value": 3, "label": "NIS"}, {"value": 4, "label": "Pixel"},
]
const FILTER_SGSR := {"value": 5, "label": "SGSR"}
const SCALERS := [
	{"value": 0, "label": "Auto"}, {"value": 1, "label": "Integer"}, {"value": 2, "label": "Fit"},
	{"value": 3, "label": "Fill"}, {"value": 4, "label": "Stretch"},
]
const ROTATIONS := [
	{"value": "auto", "label": "Automatic"}, {"value": "normal", "label": "Normal"},
	{"value": "left", "label": "Left"}, {"value": "right", "label": "Right"},
	{"value": "upsidedown", "label": "Upside down"},
]
const SCHEDULES := [
	{"value": "manual", "label": "Off"}, {"value": "evening", "label": "8 PM to 7 AM"},
	{"value": "night", "label": "10 PM to 6 AM"},
]
const DIM_CHOICES := [
	{"value": 0, "label": "Never"}, {"value": 30, "label": "30 seconds"}, {"value": 60, "label": "1 minute"},
	{"value": 120, "label": "2 minutes"}, {"value": 300, "label": "5 minutes"},
]
const OFF_CHOICES := [
	{"value": 0, "label": "Never"}, {"value": 60, "label": "1 minute"}, {"value": 120, "label": "2 minutes"},
	{"value": 300, "label": "5 minutes"}, {"value": 600, "label": "10 minutes"},
]

## gamescope-session-plus device-quirks sets CUSTOM_REFRESH_RATES for these
## (ONEXPLAYER X1 family, G1), so gamescope switches their refresh already.
const SESSION_QUIRK_REFRESH := [
	"onexplayer-x1-amd", "onexplayer-x1-intel", "onexplayer-x1-mini", "onexplayer-x1-pro",
	"onexplayer-g1-amd", "onexplayer-g1-intel",
]

const HDR_NITS_MIN := 20.0     # software brightness range (ClawDeck screen.py)
const HDR_NITS_MAX := 600.0
const SDR_DEFAULT_NITS := 203.0  # gamescope's default SDR-on-HDR level
const LOGIND := "org.freedesktop.login1"
const LOGIND_SESSION := "/org/freedesktop/login1/session/auto"

var _xa: RefCounted
var _store: RefCounted
var _store_ctx: Variant = null
var _gs_caps: Dictionary = {}


func setup(_ctx: Dictionary) -> void:
	pass


func controls() -> Array:
	return [
		_mk("display.brightness", {"kind": "slider", "min_value": PanelInfo.MIN_BRIGHTNESS_PCT, "max_value": 100.0,
			"step": 1.0, "unit": "%", "default_value": 50.0, "per_game": false},
			_detect_brightness, _read_brightness, _write_brightness),
		_mk("display.vrr", {"kind": "toggle", "default_value": false, "apply_order": 30},
			_detect_vrr, func(c): return int(_x(c).cardinal(A_VRR_ENABLED, 0)) == 1,
			func(c, v): return _x(c).set_cardinal(A_VRR_ENABLED, 1 if v else 0)),
		_mk("display.refresh_rate", {"kind": "slider", "min_value": 60.0, "max_value": 60.0, "step": 1.0,
			"unit": "Hz", "apply_order": 20}, _detect_refresh, _read_refresh, _write_refresh),
		_mk("display.refresh_unlock", {"kind": "toggle", "default_value": false, "per_game": false},
			_detect_unlock, func(c): return SessionEnv.get_value(c.ctx, "CUSTOM_REFRESH_RATES") != "", _write_unlock),
		_mk("display.fps_limit", {"kind": "choice", "default_value": 0, "apply_order": 10, "unit": "fps"},
			_detect_fps, func(c): return int(_x(c).cardinal(A_FPS_LIMIT, 0)),
			func(c, v): return _x(c).set_cardinal(A_FPS_LIMIT, int(v))),
		_mk("display.allow_tearing", {"kind": "toggle", "default_value": false},
			_detect_gamescope, func(c): return int(_x(c).cardinal(A_ALLOW_TEARING, 0)) == 1,
			func(c, v): return _x(c).set_cardinal(A_ALLOW_TEARING, 1 if v else 0)),
		_mk("display.upscale_filter", {"kind": "choice", "options": FILTERS.duplicate(), "default_value": 0},
			_detect_filter, func(c): return int(_x(c).cardinal(A_FILTER, 0)),
			func(c, v): return _x(c).set_cardinal(A_FILTER, int(v))),
		_mk("display.upscale_scaler", {"kind": "choice", "options": SCALERS, "default_value": 0},
			_detect_gamescope, func(c): return int(_x(c).cardinal(A_SCALER, 0)),
			func(c, v): return _x(c).set_cardinal(A_SCALER, int(v))),
		_mk("display.sharpness", {"kind": "slider", "min_value": 0.0, "max_value": 20.0, "step": 1.0,
			"default_value": 18.0}, _detect_gamescope, _read_sharpness,
			func(c, v): return _x(c).set_cardinal(A_SHARPNESS, 20 - int(v))),
		_mk("display.vibrance", {"kind": "slider", "min_value": 0.0, "max_value": 100.0, "step": 5.0,
			"unit": "%", "default_value": 0.0}, _detect_vibrance, _read_vibrance,
			func(c, v): return _x(c).set_float(A_GAMUT, float(v) / 100.0)),
		_mk("display.color_temp", {"kind": "slider", "min_value": 4500.0, "max_value": 9500.0, "step": 100.0,
			"unit": "K", "default_value": float(Color2.NEUTRAL_K), "per_game": false},
			_detect_gamescope, _read_color_temp, _write_color_temp),
		_mk("display.night_light", {"kind": "toggle", "default_value": false, "per_game": false},
			_detect_gamescope, func(c): return float(_x(c).float_value(A_NIGHT, 0.0)) > 0.0, _write_night),
		_mk("display.night_light_strength", {"kind": "slider", "min_value": 10.0, "max_value": 100.0,
			"step": 5.0, "unit": "%", "default_value": 50.0, "per_game": false, "requires": ["display.night_light"]},
			_detect_gamescope, func(c): return float(_st(c).get_value("night_strength", 50.0)), _write_night_strength),
		_mk("display.night_light_schedule", {"kind": "choice", "options": SCHEDULES, "default_value": "manual",
			"per_game": false}, _detect_gamescope,
			func(c): return str(_st(c).get_value("night_schedule", "manual")),
			func(c, v): return _st(c).set_value("night_schedule", v)),
		_mk("display.hdr", {"kind": "toggle", "default_value": false, "per_game": false},
			_detect_hdr, func(c): return int(_x(c).cardinal(A_HDR_ENABLED, 0)) == 1, _write_hdr),
		_mk("display.hdr_itm", {"kind": "toggle", "default_value": false, "requires": ["display.hdr"]},
			_detect_hdr_extra, func(c): return int(_x(c).cardinal(A_HDR_ITM, 0)) == 1,
			func(c, v): return _x(c).set_cardinal(A_HDR_ITM, 1 if v else 0)),
		_mk("display.sdr_brightness", {"kind": "slider", "min_value": 100.0, "max_value": 500.0, "step": 10.0,
			"unit": "nits", "default_value": SDR_DEFAULT_NITS, "per_game": false, "requires": ["display.hdr"]},
			_detect_sdr_brightness, func(c): return roundf(float(_x(c).float_value(A_SDR_ON_HDR, SDR_DEFAULT_NITS))),
			func(c, v): return _x(c).set_float(A_SDR_ON_HDR, float(v))),
		_mk("display.effect", {"kind": "choice", "options": [{"value": "", "label": "Off"}], "default_value": ""},
			_detect_effect, func(c): return _x(c).text(Reshade.ATOM_EFFECT), _write_effect),
		_mk("display.rotation", {"kind": "choice", "options": ROTATIONS, "default_value": "auto", "per_game": false},
			_detect_session, _read_rotation, _write_rotation),
		_mk("display.dim_after", {"kind": "choice", "options": DIM_CHOICES, "default_value": 60, "per_game": false},
			func(_c): return "", func(c): return int(_st(c).get_value("dim_after", 60)),
			func(c, v): return _st(c).set_value("dim_after", int(v))),
		_mk("display.screen_off_after", {"kind": "choice", "options": OFF_CHOICES, "default_value": 300,
			"per_game": false}, func(_c): return "", func(c): return int(_st(c).get_value("screen_off_after", 300)),
			func(c, v): return _st(c).set_value("screen_off_after", int(v))),
	]


func _mk(id: String, spec: Dictionary, d: Callable, r: Callable, w: Callable) -> RefCounted:
	var s := {"id": id, "title": T.title(id), "help": T.help(id), "group": "display"}
	s.merge(spec, true)
	var c = Ctl.make(s, d, r, w)
	c.set_meta("provider", self)   # keeps this provider alive as long as its controls
	return c


func _x(c) -> RefCounted:
	if _xa == null or not is_same(_xa.ctx, c.ctx):
		_xa = XAtoms.new(c.ctx)
	return _xa


func _st(c) -> RefCounted:
	if _store == null or not is_same(_store_ctx, c.ctx):
		_store = Store.new(c.ctx, "display", PanelInfo.device_id(c.ctx))
		_store_ctx = c.ctx
	return _store


func _row(c) -> Dictionary:
	return PanelInfo.row(c.ctx)


func _detect_gamescope(c) -> String:
	return "" if _x(c).running() else T.NO_GAMESCOPE


func _detect_session(c) -> String:
	return "" if SessionEnv.supported(c.ctx) else T.NO_SESSION


# --- gamescope binary features (checked once, with grep: no big file read here) ---

func _gs_has(c, needle: String) -> bool:
	if _gs_caps.has(needle):
		return _gs_caps[needle]
	var bin := str(c.ctx.get("sys_root", "")) + "/usr/bin/gamescope"
	var found := true   # unknown build: assume a current gamescope
	if FileAccess.file_exists(bin) and c.ctx.get("runner") != null:
		var r: Dictionary = c.ctx.runner.run("grep", PackedStringArray(["-q", "-a", "-F", needle, bin]))
		found = int(r.get("code", 1)) == 0
	elif needle == "sgsr)":
		found = false   # SGSR is new (2026); offer it only when we can see it
	_gs_caps[needle] = found
	return found


# --- brightness -------------------------------------------------------------

## The backlight to drive: raw (GPU) first, then platform, then firmware (ACPI).
static func find_backlight(sys_root: String) -> String:
	var base := sys_root + "/sys/class/backlight"
	var best := ""
	var best_rank := 99
	for n in Sysfs.entries(base):
		var dir := base.path_join(n)
		if _read_int(dir.path_join("max_brightness")) <= 0:
			continue
		var rank: int = {"raw": 0, "platform": 1, "firmware": 2}.get(_read_text(dir.path_join("type")), 3)
		if rank < best_rank:
			best = n
			best_rank = rank
	return best


func _bright_mode(c) -> String:
	var id := PanelInfo.device_id(c.ctx)
	if _x(c).running():
		if id in PanelInfo.SOFTWARE_BRIGHTNESS:
			return "hdr"
		if id in PanelInfo.SOFTWARE_BRIGHTNESS_IN_PQ and int(_x(c).cardinal(A_HDR_OUTPUT, 0)) == 1:
			return "hdr"
	return "backlight" if find_backlight(str(c.ctx.get("sys_root", ""))) != "" else ""


func _detect_brightness(c) -> String:
	var mode := _bright_mode(c)
	c.set_meta("mode", mode)
	return "" if mode != "" else T.NO_BACKLIGHT


func _read_brightness(c) -> Variant:
	if c.get_meta("mode", "") == "hdr":
		var saved = _st(c).get_value("hdr_brightness")
		if not _x(c).has(A_SDR_ON_HDR) and saved != null:
			# gamescope forgot it (suspend, session restart): put it back.
			_write_brightness(c, saved)
		var nits := float(_x(c).float_value(A_SDR_ON_HDR, SDR_DEFAULT_NITS))
		return roundf(clampf((nits - HDR_NITS_MIN) / (HDR_NITS_MAX - HDR_NITS_MIN) * 100.0, PanelInfo.MIN_BRIGHTNESS_PCT, 100.0))
	var dir := _bl_dir(c)
	var mx := _read_int(dir.path_join("max_brightness"))
	if mx <= 0:
		return null
	return roundf(clampf(_read_int(dir.path_join("brightness")) * 100.0 / mx, 0.0, 100.0))


func _write_brightness(c, v) -> bool:
	var pct := maxf(float(v), PanelInfo.MIN_BRIGHTNESS_PCT)
	if c.get_meta("mode", "") == "hdr":
		if not _x(c).set_float(A_SDR_ON_HDR, roundf(HDR_NITS_MIN + pct / 100.0 * (HDR_NITS_MAX - HDR_NITS_MIN))):
			return false
		_st(c).set_value("hdr_brightness", pct)
		return true
	var name := find_backlight(str(c.ctx.get("sys_root", "")))
	if name == "":
		return false
	var dir := _bl_dir(c)
	var mx := _read_int(dir.path_join("max_brightness"))
	var raw := clampi(roundi(mx * pct / 100.0), 1, mx)
	# logind lets the active session set its own backlight: no root, no prompt.
	var r: Dictionary = c.ctx.runner.run("busctl", PackedStringArray(["--system", "call", LOGIND, LOGIND_SESSION,
		"org.freedesktop.login1.Session", "SetBrightness", "ssu", "backlight", name, str(raw)]))
	if int(r.get("code", -1)) == 0:
		return true
	# Some images make the file writable for the seat user instead.
	var f := FileAccess.open(dir.path_join("brightness"), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(str(raw))
	f.close()
	return true


func _bl_dir(c) -> String:
	var sr := str(c.ctx.get("sys_root", ""))
	return sr + "/sys/class/backlight/" + find_backlight(sr)


# --- refresh rate / frame limit / VRR -----------------------------------------

func _hz(c) -> Array:
	var x := _x(c)
	var custom: String = x.env("CUSTOM_REFRESH_RATES")
	var hz := PanelInfo.hz_range(_row(c), x.env("STEAM_DISPLAY_REFRESH_LIMITS"))
	if custom != "" and not hz.is_empty():
		var vals := []
		for p in custom.split(","):
			if p.strip_edges().is_valid_int():
				vals.append(p.strip_edges().to_int())
		if vals.size() >= 2:
			vals.sort()
			return [vals[0], vals[-1]]
	return hz


func _refresh_known(c) -> bool:
	var id := PanelInfo.device_id(c.ctx)
	return id in PanelInfo.GAMESCOPE_KNOWN_REFRESH or id in SESSION_QUIRK_REFRESH or _x(c).env("CUSTOM_REFRESH_RATES") != ""


func _detect_refresh(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	var hz := _hz(c)
	if hz.is_empty() or hz[0] == hz[1]:
		return T.NO_PANEL_RANGE
	if not _refresh_known(c):
		return T.RESTART_PENDING if SessionEnv.get_value(c.ctx, "CUSTOM_REFRESH_RATES") != "" else T.NEEDS_UNLOCK
	c.min_value = float(hz[0])
	c.max_value = float(hz[1])
	c.default_value = float(hz[1])
	return ""


func _read_refresh(c) -> Variant:
	var v := int(_x(c).cardinal(A_DYNAMIC_REFRESH, 0))
	return c.max_value if v <= 0 else clampf(float(v), c.min_value, c.max_value)


func _write_refresh(c, v) -> bool:
	# The panel's top rate is gamescope's default: 0 hands control back to it.
	var hz := int(v)
	return _x(c).set_cardinal(A_DYNAMIC_REFRESH, 0 if hz >= int(c.max_value) else hz)


func _detect_unlock(c) -> String:
	if not SessionEnv.supported(c.ctx):
		return T.NO_SESSION
	var r := _row(c)
	if PanelInfo.is_generic(r):
		return T.UNKNOWN_DEVICE
	var id := str(r.get("id", ""))
	var ours := SessionEnv.get_value(c.ctx, "CUSTOM_REFRESH_RATES")
	var envv: String = _x(c).env("CUSTOM_REFRESH_RATES")
	if id in PanelInfo.GAMESCOPE_KNOWN_REFRESH or id in SESSION_QUIRK_REFRESH or (envv != "" and envv != ours):
		return T.ALREADY_KNOWN
	if PanelInfo.custom_rates(r).is_empty():
		return T.NO_PANEL_RANGE
	return ""


func _write_unlock(c, v) -> bool:
	var rates := PanelInfo.custom_rates(_row(c))
	var val := ",".join(PackedStringArray(rates.map(func(i): return str(i)))) if v else ""
	return SessionEnv.set_values(c.ctx, {"CUSTOM_REFRESH_RATES": val})


func _detect_fps(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	var hz := _hz(c)
	var top: int = hz[1] if not hz.is_empty() else 60
	var opts := [{"value": 0, "label": "Off"}]
	for f in PanelInfo.fps_choices(top):
		opts.append({"value": f, "label": "%d fps" % f})
	c.options = opts
	return ""


func _detect_vrr(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	var capable = _x(c).cardinal(A_VRR_CAPABLE)
	if capable != null:
		return "" if int(capable) == 1 else T.NO_VRR
	return "" if not PanelInfo.vrr_range(_row(c)).is_empty() else T.NO_VRR


# --- upscaler -------------------------------------------------------------------

func _detect_filter(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	var opts := FILTERS.duplicate()
	if _gs_has(c, "sgsr)"):
		opts.append(FILTER_SGSR)
	c.options = opts
	return ""


func _read_sharpness(c) -> Variant:
	var v = _x(c).cardinal(A_SHARPNESS)
	if v == null:
		v = _x(c).cardinal(A_FSR_SHARPNESS, 2)
	return float(20 - clampi(int(v), 0, 20))


# --- colour -----------------------------------------------------------------------

## Vibrance is vibrantDeck's approach (libvibrant/vibrantDeck main.py:
## GAMESCOPE_COLOR_SDR_GAMUT_WIDENESS, float bits, 0.0-1.0, read back with
## xprop -root), with the default taken from gamescope's own colour code so an
## untouched OLED isn't shown as "0".
func _detect_vibrance(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	# gamescope's untouched default: native gamut, which is 1.0 on wide-gamut
	# (OLED) panels and 0.0 on sRGB ones (color_helpers.cpp buildSDRColorimetry).
	c.default_value = 100.0 if PanelInfo.wide_gamut(_row(c)) else 0.0
	return ""


func _read_vibrance(c) -> Variant:
	var f = _x(c).float_value(A_GAMUT)
	if f == null or float(f) < 0.0:
		return c.default_value
	return roundf(clampf(float(f), 0.0, 1.0) * 100.0)


func _read_color_temp(c) -> Variant:
	if _x(c).floats(A_VIRTUAL_WHITE).size() < 2:
		return float(Color2.NEUTRAL_K)
	return float(_st(c).get_value("color_temp", Color2.NEUTRAL_K))


func _write_color_temp(c, v) -> bool:
	var k := int(v)
	var ok: bool
	if k == Color2.NEUTRAL_K:
		ok = _x(c).remove(A_VIRTUAL_WHITE)
	else:
		var xy := Color2.kelvin_to_xy(k)
		ok = _x(c).set_floats(A_VIRTUAL_WHITE, [xy.x, xy.y])
	if ok:
		_st(c).set_value("color_temp", k)
	return ok


func _write_night(c, v) -> bool:
	var strength := float(_st(c).get_value("night_strength", 50.0)) if v else 0.0
	return _x(c).set_floats(A_NIGHT, Color2.night_mode(strength))


func _write_night_strength(c, v) -> bool:
	if not _st(c).set_value("night_strength", float(v)):
		return false
	if float(_x(c).float_value(A_NIGHT, 0.0)) > 0.0:
		return _x(c).set_floats(A_NIGHT, Color2.night_mode(float(v)))
	return true


# --- HDR ----------------------------------------------------------------------------

func _hdr_supported(c) -> bool:
	return int(_x(c).cardinal(A_SUPPORTS_HDR, 0)) == 1


func _detect_hdr(c) -> String:
	var id := PanelInfo.device_id(c.ctx)
	if PanelInfo.HDR_SWITCH_BLOCKED.has(id):
		return PanelInfo.HDR_SWITCH_BLOCKED[id]
	return _detect_hdr_extra(c)


func _detect_hdr_extra(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	return "" if _hdr_supported(c) else T.NO_HDR


func _detect_sdr_brightness(c) -> String:
	var id := PanelInfo.device_id(c.ctx)
	if id in PanelInfo.SOFTWARE_BRIGHTNESS or (id in PanelInfo.SOFTWARE_BRIGHTNESS_IN_PQ and int(_x(c).cardinal(A_HDR_OUTPUT, 0)) == 1):
		return T.USE_BRIGHTNESS
	return _detect_hdr_extra(c)


func _write_hdr(c, v) -> bool:
	if not _x(c).set_cardinal(A_HDR_ENABLED, 1 if v else 0):
		return false
	# Games only send HDR through gamescope's WSI layer, which the session
	# turns on at start (gamescope-session-plus: ENABLE_GAMESCOPE_HDR + _WSI).
	if SessionEnv.supported(c.ctx):
		var s := "1" if v else ""
		SessionEnv.set_values(c.ctx, {"ENABLE_GAMESCOPE_HDR": s, "ENABLE_GAMESCOPE_WSI": s})
	return true


# --- ReShade effect -------------------------------------------------------------------

func _detect_effect(c) -> String:
	if not _x(c).running():
		return T.NO_GAMESCOPE
	if not _gs_has(c, Reshade.ATOM_EFFECT):
		return T.NO_RESHADE
	c.options = Reshade.options(c.ctx)
	return ""


func _write_effect(c, v) -> bool:
	var rel := str(v)
	var x := _x(c)
	if rel == "":
		return x.remove(Reshade.ATOM_EFFECT)
	if Reshade.is_bundled(rel) and not Reshade.install_bundled(c.ctx):
		return false
	if not x.set_cardinal(Reshade.ATOM_TECHNIQUE, 0):
		return false
	return x.set_text(Reshade.ATOM_EFFECT, rel) and x.text(Reshade.ATOM_EFFECT) == rel


# --- rotation -----------------------------------------------------------------------------

func _read_rotation(c) -> Variant:
	var v := SessionEnv.get_value(c.ctx, "ORIENTATION")
	return v if v in ["normal", "left", "right", "upsidedown"] else "auto"


func _write_rotation(c, v) -> bool:
	return SessionEnv.set_values(c.ctx, {"ORIENTATION": "" if v == "auto" else str(v)})


# --- small file helpers ---------------------------------------------------------------------

static func _read_text(path: String) -> String:
	return Sysfs.read_text(path)


static func _read_int(path: String) -> int:
	return Sysfs.read_int(path)
