extends "res://tests/test_case.gd"
## Display controls (providers/display.gd) against fake gamescope / logind /
## sysfs trees.

const Env := preload("res://tests/fixtures/ctl_display/env.gd")
const DisplayProvider := preload("res://scripts/controls/providers/display.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const XAtoms := preload("res://scripts/controls/display/xatoms.gd")
const PanelInfo := preload("res://scripts/controls/display/panel.gd")
const ColorMath := preload("res://scripts/controls/display/color.gd")
const SessionEnv := preload("res://scripts/controls/display/session_env.gd")
const Reshade := preload("res://scripts/controls/display/reshade.gd")
const T := preload("res://scripts/controls/display/texts_display.gd")

const BACKLIGHT := {
	"sys/class/backlight/amdgpu_bl0/max_brightness": "3000\n",
	"sys/class/backlight/amdgpu_bl0/brightness": "1500\n",
	"sys/class/backlight/amdgpu_bl0/type": "raw\n",
	"sys/class/backlight/acpi_video0/max_brightness": "100\n",
	"sys/class/backlight/acpi_video0/brightness": "10\n",
	"sys/class/backlight/acpi_video0/type": "firmware\n",
}


## {id: control} detected and read against `s` (from Env.make).
func _controls(s: Dictionary) -> Dictionary:
	var out := {}
	for c in DisplayProvider.new().controls():
		c.ctx = s.ctx
		c.detect()
		c.read()
		out[c.id] = c
	return out


func _redetect(c) -> void:
	c.detect()
	c.read()


# --- encoding helpers ---------------------------------------------------------

func test_float_bits_round_trip() -> void:
	eq(XAtoms.float_to_bits(1.0), 1065353216, "1.0 bit pattern (vibrantDeck's sample)")
	eq(XAtoms.bits_to_float(1065353216), 1.0, "decoded")
	ok(absf(XAtoms.bits_to_float(XAtoms.float_to_bits(0.3127)) - 0.3127) < 1e-6, "round trip")


func test_parse_dump_and_text() -> void:
	var d := XAtoms.parse_dump("GAMESCOPE_FPS_LIMIT = 40\nGAMESCOPE_RESHADE_EFFECT = \"gamecove/crt-lottes.fx\"\n_NET_SUPPORTED = 1, 2\n\tWM_HINTS stuff = x\nnot an atom\n")
	eq(d.get("GAMESCOPE_FPS_LIMIT"), "40", "cardinal")
	eq(XAtoms.parse_text(d.get("GAMESCOPE_RESHADE_EFFECT")), "gamecove/crt-lottes.fx", "text")
	eq(XAtoms.parse_cardinals(d.get("_NET_SUPPORTED")), [1, 2], "list")
	eq(d.size(), 3, "continuation and junk lines skipped")


func test_one_xprop_dump_serves_a_detect_burst() -> void:
	var s := Env.make("burst", "steam-deck-lcd")
	var r = ControlsScript.new()
	r.sync_mode = true
	r.setup(s.ctx)
	r.register_provider(DisplayProvider.new())
	r.detect_all()
	var dumps: int = s.fake.calls.filter(func(x): return x == "xprop -root -notype").size()
	ok(dumps <= 2, "detect_all shares the root dump (%d dumps)" % dumps)
	r.free()


# --- outside gamescope ------------------------------------------------------------

func test_outside_gamescope_reasons() -> void:
	var s := Env.make("nogs", "msi-claw-8-ex")
	s.fake.props.clear()
	var c := _controls(s)
	for id in ["display.fps_limit", "display.vrr", "display.refresh_rate", "display.upscale_filter",
			"display.vibrance", "display.night_light", "display.hdr", "display.effect", "display.allow_tearing"]:
		eq(c[id].reason, T.NO_GAMESCOPE, id)
		ok(not c[id].write(1 if c[id].kind != "toggle" else true), id + " refuses writes")
	ok(c["display.dim_after"].available, "dim timer is GameCove's own")
	eq(c["display.brightness"].reason, T.NO_BACKLIGHT, "no backlight in this tree")


# --- refresh rate -----------------------------------------------------------------

func test_refresh_rate_known_panel() -> void:
	var s := Env.make("deck", "steam-deck-lcd")
	var c := _controls(s)
	var rr = c["display.refresh_rate"]
	ok(rr.available, "gamescope knows the Deck LCD's rates: " + rr.reason)
	eq([rr.min_value, rr.max_value], [40.0, 60.0], "range from devices.json")
	eq(rr.value, 60.0, "unset = panel max")
	ok(rr.write(50), "write 50")
	eq(s.fake.props["GAMESCOPE_DYNAMIC_REFRESH"], "50", "atom set")
	ok(rr.write(75), "clamped write")
	eq(s.fake.props["GAMESCOPE_DYNAMIC_REFRESH"], "0", "top rate hands back to gamescope (0)")
	ok(rr.write(10), "clamped low")
	eq(s.fake.props["GAMESCOPE_DYNAMIC_REFRESH"], "40", "never under the panel minimum")


func test_refresh_session_limits_win() -> void:
	var s := Env.make("limits", "onexplayer-onexfly-f1", {}, {"STEAM_DISPLAY_REFRESH_LIMITS": "40,120"})
	var rr = _controls(s)["display.refresh_rate"]
	eq([rr.min_value, rr.max_value], [40.0, 120.0], "device-quirks' exported range")


func test_refresh_unlock_flow_claw() -> void:
	var s := Env.make("claw", "msi-claw-8-ex", Env.SESSION)
	var c := _controls(s)
	eq(c["display.refresh_rate"].reason, T.NEEDS_UNLOCK, "gamescope doesn't know this panel")
	var un = c["display.refresh_unlock"]
	ok(un.available, "unlock offered: " + un.reason)
	eq(un.value, false, "off")
	ok(un.write(true), "unlock")
	var rates := SessionEnv.get_value(s.ctx, "CUSTOM_REFRESH_RATES").split(",")
	eq(rates[0], "60", "starts at the panel minimum")
	eq(rates[-1], "120", "ends at the panel maximum")
	eq(rates.size(), 61, "every whole rate inside the VRR range")
	_redetect(c["display.refresh_rate"])
	eq(c["display.refresh_rate"].reason, T.RESTART_PENDING, "needs a session restart")
	# next session: gamescope-session-plus exported our list
	s.ctx.env["CUSTOM_REFRESH_RATES"] = ",".join(rates)
	_redetect(c["display.refresh_rate"])
	ok(c["display.refresh_rate"].available, "refresh works after restart")
	_redetect(un)
	ok(un.available and un.value == true, "unlock still ours and on")
	ok(un.write(false), "lock again")
	ok(not FileAccess.file_exists(SessionEnv.path(s.ctx)), "empty env file removed")


func test_refresh_unlock_non_vrr_panel_only_ends() -> void:
	eq(PanelInfo.custom_rates(Env.row("ayaneo-flip")), [60, 120], "no VRR: only the two modes it has")
	eq(PanelInfo.custom_rates(Env.row("ayaneo-2")), [], "single-rate panel")
	var s := Env.make("ayaneo2", "ayaneo-2", Env.SESSION)
	var c := _controls(s)
	eq(c["display.refresh_unlock"].reason, T.NO_PANEL_RANGE, "nothing to unlock")
	eq(c["display.refresh_rate"].reason, T.NO_PANEL_RANGE, "one rate")


func test_refresh_unlock_reasons() -> void:
	var s := Env.make("deck2", "steam-deck-oled", Env.SESSION)
	eq(_controls(s)["display.refresh_unlock"].reason, T.ALREADY_KNOWN, "gamescope knows the Deck OLED")
	var x1 := Env.make("x1", "onexplayer-x1-mini", Env.SESSION)
	eq(_controls(x1)["display.refresh_unlock"].reason, T.ALREADY_KNOWN, "device-quirks covers the X1 mini")
	var nos := Env.make("nosession", "msi-claw-8-ex")
	eq(_controls(nos)["display.refresh_unlock"].reason, T.NO_SESSION, "no gamescope-session-plus")
	var gen := Env.make("generic", "unknown-thing", Env.SESSION)
	gen.ctx.device = {"id": "generic-amd", "tier": "generic", "panel_hz": [60, 120]}
	eq(_controls(gen)["display.refresh_unlock"].reason, T.UNKNOWN_DEVICE, "never on a guessed panel")


# --- frame limit / VRR / tearing ----------------------------------------------------

func test_fps_limit_choices_and_write() -> void:
	var s := Env.make("fps", "steam-deck-lcd")
	var f = _controls(s)["display.fps_limit"]
	var vals: Array = f.options.map(func(o): return o["value"])
	eq(vals[0], 0, "Off first")
	ok(vals.has(30) and vals.has(15) and vals.has(60), "fractions of 60")
	ok(not vals.has(72), "nothing above the panel")
	ok(f.write(30), "write")
	eq(s.fake.props["GAMESCOPE_FPS_LIMIT"], "30", "atom")
	eq(f.read(), 30, "read back")
	ok(not f.write(37), "not a choice")
	s.fake.frozen.append("GAMESCOPE_FPS_LIMIT")
	ok(not f.write(40), "gamescope didn't take it: false")


func test_vrr_capability() -> void:
	var deck := Env.make("vrr_deck", "steam-deck-lcd")
	eq(_controls(deck)["display.vrr"].reason, T.NO_VRR, "Deck LCD has no VRR")
	var ally := Env.make("vrr_ally", "asus-rog-ally")
	var v = _controls(ally)["display.vrr"]
	ok(v.available, "VRR range in the table")
	ok(v.write(true), "on")
	eq(ally.fake.props["GAMESCOPE_VRR_ENABLED"], "1", "atom")
	ally.fake.props["GAMESCOPE_VRR_CAPABLE"] = "0"
	_redetect(v)
	eq(v.reason, T.NO_VRR, "gamescope's own answer wins (e.g. external screen)")
	deck.fake.props["GAMESCOPE_VRR_CAPABLE"] = "1"
	var dv = _controls(deck)["display.vrr"]
	ok(dv.available, "capable external screen on a Deck")


func test_allow_tearing() -> void:
	var s := Env.make("tear", "lenovo-legion-go")
	var t = _controls(s)["display.allow_tearing"]
	ok(t.write(true), "on")
	eq(s.fake.props["GAMESCOPE_ALLOW_TEARING"], "1", "atom")
	eq(t.read(), true, "read")
	ok(t.write(false), "off")
	eq(t.read(), false, "read off")


# --- upscaler -------------------------------------------------------------------------

func test_upscaler_filter_scaler_sharpness() -> void:
	var s := Env.make("ups", "msi-claw-8-ex", {"usr/bin/gamescope": "binary"})
	var c := _controls(s)
	var f = c["display.upscale_filter"]
	ok(f.options.any(func(o): return o["label"] == "SGSR"), "SGSR offered when gamescope has it")
	eq(f.value, 0, "default linear")
	ok(f.write(2), "FSR")
	eq(s.fake.props["GAMESCOPE_NEW_SCALING_FILTER"], "2", "FSR = 2 (GamescopeUpscaleFilter)")
	ok(c["display.upscale_scaler"].write(1), "integer")
	eq(s.fake.props["GAMESCOPE_NEW_SCALING_SCALER"], "1", "INTEGER = 1")
	var sh = c["display.sharpness"]
	eq(sh.value, 18.0, "gamescope default 2 shows as 18")
	ok(sh.write(15), "sharpness")
	eq(s.fake.props["GAMESCOPE_SHARPNESS"], "5", "inverted for gamescope (0 = sharpest)")
	s.fake.gamescope_strings = ["GAMESCOPE_RESHADE_EFFECT"]
	var old := Env.make("ups_old", "msi-claw-8-ex", {"usr/bin/gamescope": "binary"})
	old.fake.gamescope_strings = ["GAMESCOPE_RESHADE_EFFECT"]
	var of = _controls(old)["display.upscale_filter"]
	ok(not of.options.any(func(o): return o["value"] == 5), "no SGSR on an older gamescope")
	ok(not of.write(5), "SGSR refused there")


# --- colour ---------------------------------------------------------------------------

func test_vibrance_defaults_per_panel() -> void:
	var oled := Env.make("vib_oled", "steam-deck-oled")
	var v = _controls(oled)["display.vibrance"]
	eq(v.default_value, 100.0, "OLED: native gamut is the top")
	eq(v.value, 100.0, "unset reads as default")
	var ips := Env.make("vib_ips", "msi-claw-8-ex")
	var vi = _controls(ips)["display.vibrance"]
	eq(vi.default_value, 0.0, "sRGB panel: native is 0")
	ok(vi.write(50), "write")
	ok(absf(ips.fake.float_prop("GAMESCOPE_COLOR_SDR_GAMUT_WIDENESS")[0] - 0.5) < 1e-6, "float 0.5")
	eq(vi.read(), 50.0, "read back")


func test_color_temperature() -> void:
	var s := Env.make("temp", "steam-deck-lcd")
	var t = _controls(s)["display.color_temp"]
	eq(t.value, 6500.0, "neutral")
	ok(t.write(5000), "warm")
	var xy: Array = s.fake.float_prop("GAMESCOPE_DISPLAY_VIRTUAL_WHITE")
	eq(xy.size(), 2, "x, y")
	ok(absf(xy[0] - 0.3457) < 0.002 and absf(xy[1] - 0.3586) < 0.002, "D50 white: %s" % [xy])
	var t2 = _controls(s)["display.color_temp"]
	eq(t2.value, 5000.0, "remembered (store) while the atom is set")
	ok(t2.write(6500), "neutral")
	ok(not s.fake.props.has("GAMESCOPE_DISPLAY_VIRTUAL_WHITE"), "6500 K removes the override")


func test_kelvin_math() -> void:
	var d65 := ColorMath.kelvin_to_xy(6504)
	ok(absf(d65.x - 0.3127) < 0.001 and absf(d65.y - 0.3291) < 0.001, "6504 K is D65: %s" % d65)
	ok(ColorMath.kelvin_to_xy(9000).x < d65.x, "cooler is bluer")
	eq(ColorMath.night_mode(0), [0.0, 0.0, 0.0], "off is identity")


func test_night_light() -> void:
	var s := Env.make("night", "lenovo-legion-go")
	var c := _controls(s)
	var n = c["display.night_light"]
	var st = c["display.night_light_strength"]
	eq(n.value, false, "off")
	ok(st.write(80), "strength while off")
	ok(not s.fake.props.has("GAMESCOPE_COLOR_NIGHT_MODE"), "doesn't turn it on")
	ok(n.write(true), "on")
	var v: Array = s.fake.float_prop("GAMESCOPE_COLOR_NIGHT_MODE")
	ok(absf(v[0] - 0.8) < 1e-5 and absf(v[1] - ColorMath.NIGHT_HUE) < 1e-5, "amount 0.8, orange hue: %s" % [v])
	ok(st.write(30), "strength while on")
	ok(absf(s.fake.float_prop("GAMESCOPE_COLOR_NIGHT_MODE")[0] - 0.3) < 1e-5, "applied at once")
	ok(n.write(false), "off")
	eq(s.fake.float_prop("GAMESCOPE_COLOR_NIGHT_MODE")[0], 0.0, "amount 0")
	eq(st.requires, ["display.night_light"], "strength depends on night light")


func test_night_schedule_math() -> void:
	ok(ColorMath.night_due("evening", 23 * 60), "23:00 in 20-07")
	ok(ColorMath.night_due("evening", 6 * 60 + 59), "06:59")
	ok(not ColorMath.night_due("evening", 12 * 60), "noon")
	ok(not ColorMath.night_due("manual", 23 * 60), "manual never")
	eq(ColorMath.seconds_to_next_switch("night", 21 * 60 + 59, 30), 30, "30 s to 22:00")
	eq(ColorMath.seconds_to_next_switch("night", 6 * 60, 0), 16 * 3600, "at 06:00 the next is 22:00")
	eq(ColorMath.seconds_to_next_switch("manual", 0), -1, "no schedule")


# --- HDR --------------------------------------------------------------------------------

func test_hdr_supported_screen() -> void:
	var s := Env.make("hdr", "lenovo-legion-go-2", Env.SESSION)
	eq(_controls(s)["display.hdr"].reason, T.NO_HDR, "gamescope says no HDR")
	s.fake.props["GAMESCOPE_DISPLAY_SUPPORTS_HDR"] = "1"
	var c := _controls(s)
	var h = c["display.hdr"]
	ok(h.available, "HDR panel")
	ok(h.write(true), "on")
	eq(s.fake.props["GAMESCOPE_DISPLAY_HDR_ENABLED"], "1", "atom")
	eq(SessionEnv.read(s.ctx), {"ENABLE_GAMESCOPE_HDR": "1", "ENABLE_GAMESCOPE_WSI": "1"}, "kept for next session")
	ok(c["display.hdr_itm"].write(true), "ITM")
	eq(s.fake.props["GAMESCOPE_HDR_ITM_ENABLE"], "1", "ITM atom")
	var sdr = c["display.sdr_brightness"]
	eq(sdr.value, 203.0, "gamescope's default SDR level")
	ok(sdr.write(300), "SDR nits")
	ok(absf(s.fake.float_prop("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")[0] - 300.0) < 1e-3, "float nits")
	ok(h.write(false), "off")
	ok(not FileAccess.file_exists(SessionEnv.path(s.ctx)), "session env cleaned")


func test_oxp3_hdr_never_switched_and_brightness_in_software() -> void:
	var s := Env.make("oxp3", "onexplayer-3", BACKLIGHT)
	s.fake.props["GAMESCOPE_DISPLAY_SUPPORTS_HDR"] = "1"
	var c := _controls(s)
	eq(c["display.hdr"].reason, PanelInfo.HDR_SWITCH_BLOCKED["onexplayer-3"], "HDR switch blocked")
	ok(not c["display.hdr"].write(false), "and refused")
	ok(not s.fake.props.has("GAMESCOPE_DISPLAY_HDR_ENABLED"), "never touched")
	eq(c["display.sdr_brightness"].reason, T.USE_BRIGHTNESS, "one brightness control only")
	var b = c["display.brightness"]
	ok(b.available, "brightness through gamescope")
	ok(b.write(50), "50 %")
	ok(absf(s.fake.float_prop("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")[0] - 310.0) < 1e-3, "20 + 0.5 * 580 nits")
	ok(not s.fake.calls.any(func(x): return "SetBrightness" in x), "backlight left alone (it does nothing here)")
	eq(b.read(), 50.0, "read back")


# --- brightness ----------------------------------------------------------------------------

func test_brightness_backlight_via_logind() -> void:
	var s := Env.make("bl", "steam-deck-lcd", BACKLIGHT)
	var b = _controls(s)["display.brightness"]
	ok(b.available, b.reason)
	eq(b.value, 50.0, "1500 / 3000")
	eq(b.per_game, false, "not per game")
	ok(b.write(80), "write")
	ok(s.fake.calls.has("busctl --system call org.freedesktop.login1 /org/freedesktop/login1/session/auto org.freedesktop.login1.Session SetBrightness ssu backlight amdgpu_bl0 2400"), "logind call on the raw backlight")
	eq(b.read(), 80.0, "read back")
	ok(b.write(0), "zero asked")
	eq(FileAccess.get_file_as_string(s.root + "/sys/class/backlight/amdgpu_bl0/brightness"), "150", "floor 5 %, never black")


func test_brightness_fallback_direct_write() -> void:
	var s := Env.make("bl2", "msi-claw-8-ex", BACKLIGHT)
	s.fake.logind_ok = false
	var b = _controls(s)["display.brightness"]
	ok(b.write(30), "falls back to the file")
	eq(FileAccess.get_file_as_string(s.root + "/sys/class/backlight/amdgpu_bl0/brightness"), "900", "written")


func test_find_backlight_prefers_raw() -> void:
	var root := Env.tree("bl3", BACKLIGHT)
	eq(DisplayProvider.find_backlight(root), "amdgpu_bl0", "raw beats firmware")
	var only := Env.tree("bl4", {"sys/class/backlight/intel_backlight/max_brightness": "0\n"})
	eq(DisplayProvider.find_backlight(only), "", "max 0 is not a backlight")


# --- ReShade effect ---------------------------------------------------------------------

func test_effect_bundled_and_user_shaders() -> void:
	var s := Env.make("fx", "steam-deck-oled", {"home/deck/.local/share/gamescope/reshade/Shaders/MyCRT.fx": "x",
		"home/deck/.local/share/gamescope/reshade/Shaders/pack/Glow.fx": "x",
		"home/deck/.local/share/gamescope/reshade/Shaders/notes.txt": "x",
		"usr/share/gamescope/reshade/Shaders/System.fx": "x"})
	var e = _controls(s)["display.effect"]
	var vals: Array = e.options.map(func(o): return o["value"])
	eq(vals.slice(0, 3), ["", "gamecove/crt-lottes.fx", "gamecove/scanlines.fx"], "Off, then ours")
	ok(vals.has("MyCRT.fx") and vals.has("pack/Glow.fx") and vals.has("System.fx"), "user and system effects: %s" % [vals])
	ok(not vals.has("notes.txt"), "only .fx")
	eq(e.value, "", "off")
	ok(e.write("gamecove/crt-lottes.fx"), "CRT on")
	var dir: String = s.ctx.home.path_join(".local/share/gamescope/reshade/Shaders/gamecove")
	ok(FileAccess.file_exists(dir.path_join("crt-lottes.fx")) and FileAccess.file_exists(dir.path_join("ReShade.fxh")), "bundled files installed")
	ok("PUBLIC DOMAIN" in FileAccess.get_file_as_string(dir.path_join("crt-lottes.fx")), "licence header kept")
	eq(s.fake.props["GAMESCOPE_RESHADE_EFFECT"], "\"gamecove/crt-lottes.fx\"", "effect atom")
	eq(s.fake.props["GAMESCOPE_RESHADE_TECHNIQUE_IDX"], "0", "first technique")
	eq(e.read(), "gamecove/crt-lottes.fx", "read back")
	ok(e.write(""), "off")
	ok(not s.fake.props.has("GAMESCOPE_RESHADE_EFFECT"), "removed")


func test_effect_needs_reshade_build() -> void:
	var s := Env.make("fx_old", "steam-deck-oled", {"usr/bin/gamescope": "bin"})
	s.fake.gamescope_strings = []
	eq(_controls(s)["display.effect"].reason, T.NO_RESHADE, "old gamescope")


func test_bundled_shader_licences() -> void:
	var files: Dictionary = preload("res://scripts/controls/display/reshade_shaders.gd").FILES
	ok("CC0-1.0" in files["ReShade.fxh"], "ReShade.fxh is CC0")
	ok("PUBLIC DOMAIN" in files["crt-lottes.fx"] and "Timothy Lottes" in files["crt-lottes.fx"], "Lottes credit")
	ok("GPL-3.0" in files["scanlines.fx"], "ours")
	for name in files:
		ok("technique" in files[name] or name.ends_with(".fxh"), name + " has a technique")


# --- rotation / session env ---------------------------------------------------------------

func test_rotation_writes_session_env() -> void:
	var s := Env.make("rot", "ayaneo-air-plus", Env.SESSION)
	var r = _controls(s)["display.rotation"]
	eq(r.value, "auto", "default")
	ok(r.write("left"), "left")
	eq(SessionEnv.get_value(s.ctx, "ORIENTATION"), "left", "ORIENTATION for gamescope-session-plus")
	ok(FileAccess.get_file_as_string(SessionEnv.path(s.ctx)).begins_with("# Written by GameCove"), "marked as ours")
	ok(not r.write("sideways"), "not a choice")
	ok(r.write("auto"), "auto")
	ok(not FileAccess.file_exists(SessionEnv.path(s.ctx)), "back to the device's own")
	var nos := Env.make("rot2", "ayaneo-air-plus")
	eq(_controls(nos)["display.rotation"].reason, T.NO_SESSION, "needs the session")


func test_session_env_rejects_unsafe_values() -> void:
	var s := Env.make("envsafe", "steam-deck-lcd")
	ok(not SessionEnv.set_values(s.ctx, {"ORIENTATION": "left; rm -rf ~"}), "shell text refused")
	ok(not SessionEnv.set_values(s.ctx, {"BAD KEY": "1"}), "bad key refused")
	ok(SessionEnv.set_values(s.ctx, {"CUSTOM_REFRESH_RATES": "60,90,120"}), "list ok")
	eq(SessionEnv.read(s.ctx), {"CUSTOM_REFRESH_RATES": "60,90,120"}, "read")


# --- timers / store -------------------------------------------------------------------------

func test_dim_timers_stored_per_device() -> void:
	var s := Env.make("dim", "steam-deck-lcd")
	var c := _controls(s)
	eq(c["display.dim_after"].value, 60, "default 1 min")
	ok(c["display.dim_after"].write(120), "2 min")
	ok(c["display.screen_off_after"].write(600), "10 min")
	var cfg := ConfigFile.new()
	cfg.load(s.ctx.config_path)
	eq(cfg.get_value("display@steam-deck-lcd", "dim_after"), 120, "per-device section")
	s.ctx.device = Env.row("asus-rog-ally")
	var other := _controls(s)
	eq(other["display.dim_after"].value, 60, "another handheld keeps its own")


# --- registry integration ---------------------------------------------------------------------

func test_registry_apply_order_and_snapshot() -> void:
	var s := Env.make("reg", "asus-rog-ally")
	var r = ControlsScript.new()
	r.sync_mode = true
	r.setup(s.ctx)
	r.register_provider(DisplayProvider.new())   # provider reference dropped right away
	r.detect_all()
	ok(r.control("display.vrr").available, "controls outlive the provider object")
	var snap: Dictionary = r.snapshot()
	ok(snap.has("display.fps_limit") and snap.has("display.upscale_filter"), "per-game ones saved")
	ok(not snap.has("display.brightness") and not snap.has("display.rotation"), "device-wide ones not")
	s.fake.calls.clear()
	r.apply({"display.fps_limit": 40, "display.refresh_rate": 90, "display.vrr": true})
	var sets: Array = s.fake.calls.filter(func(x): return "-set" in x).map(func(x): return x.get_slice(" ", 3))
	eq(sets, ["GAMESCOPE_VRR_ENABLED", "GAMESCOPE_DYNAMIC_REFRESH", "GAMESCOPE_FPS_LIMIT"], "VRR, then refresh, then frame limit")
	r.free()


func test_every_control_has_words_and_unique_ids() -> void:
	var ids := {}
	for p in [DisplayProvider.new(), preload("res://scripts/controls/providers/audio.gd").new(),
			preload("res://scripts/controls/providers/system.gd").new()]:
		for c in p.controls():
			ok(not ids.has(c.id), "unique " + c.id)
			ids[c.id] = true
			ok(c.title != "" and c.title != c.id and c.help != "", "words for " + c.id)
			ok(c.group in ControlsScript.GROUPS, "group of " + c.id)
			ok(c.id.begins_with(c.group + "."), "id dotted by group: " + c.id)


## Every handheld in devices.json: detection never crashes, every unavailable
## control says why, refresh stays inside the panel's range, brightness never 0.
func test_every_device_row() -> void:
	for row in Env.all_rows():
		var id: String = row["id"]
		var s := Env.make("matrix", id, BACKLIGHT.merged(Env.SESSION))
		s.fake.props["GAMESCOPE_DISPLAY_SUPPORTS_HDR"] = "1"
		var c := _controls(s)
		for cid in c:
			ok(c[cid].available or c[cid].reason != "", "%s %s has a reason" % [id, cid])
		var rr = c["display.refresh_rate"]
		var hz := PanelInfo.hz_range(row)
		if rr.available:
			eq([rr.min_value, rr.max_value], [float(hz[0]), float(hz[1])], id + " refresh range")
			rr.write(1)
			ok(int(s.fake.props["GAMESCOPE_DYNAMIC_REFRESH"]) >= hz[0], id + " refresh floor")
		var b = c["display.brightness"]
		if b.available:
			b.write(0)
			if id in PanelInfo.SOFTWARE_BRIGHTNESS:
				ok(s.fake.float_prop("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")[0] > 20.0, id + " HDR floor")
			else:
				ok(int(FileAccess.get_file_as_string(s.root + "/sys/class/backlight/amdgpu_bl0/brightness")) >= 150, id + " backlight floor")
		var fps = c["display.fps_limit"]
		var top: int = hz[1] if not hz.is_empty() else 60
		ok(fps.options.all(func(o): return int(o["value"]) <= top), id + " frame limits within the panel")


func test_legion_go_2_brightness_follows_pq_and_survives_suspend() -> void:
	var s := Env.make("lego2", "lenovo-legion-go-2", BACKLIGHT)
	var b = _controls(s)["display.brightness"]
	eq(b.get_meta("mode"), "backlight", "SDR output: the backlight works")
	s.fake.props["GAMESCOPE_HDR_OUTPUT_FEEDBACK"] = "1"
	var c := _controls(s)
	b = c["display.brightness"]
	eq(b.get_meta("mode"), "hdr", "PQ output: the panel ignores amdgpu_bl0")
	eq(c["display.sdr_brightness"].reason, T.USE_BRIGHTNESS, "no second slider")
	ok(b.write(40), "40 %")
	var nits: float = s.fake.float_prop("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")[0]
	s.fake.props.erase("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")   # gamescope dropped it (suspend)
	var again = _controls(s)["display.brightness"]
	eq(again.value, 40.0, "re-read after resume")
	eq(s.fake.float_prop("GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS")[0], nits, "level put back")
