extends RefCounted
## Controller Controls: gyro, controller type, back buttons and extra buttons,
## Nintendo layout, desktop (mouse) mode, trackpad, rumble, deadzones, RGB.
## docs/CONTROLS.md ("Controller") has the per-device table.
##
## Backends (input/backend.gd), chosen on the device at detect time:
##   InputPlumber (Bazzite/SteamOS default): device-profile mappings, target
##     devices, ForceFeedback. RGB isn't in its D-Bus API, so RGB uses the kernel
##     LED nodes (input/leds.gd) through the no-password root action.
##   Handheld Daemon (when it runs instead): its settings, read from its schema,
##     so each handheld's own options appear as hhd defines them (rgb modes,
##     Legion Go gyro side, Ally deadzones and vibration, OneXPlayer vibration...).
## The Controller service (scripts/input/controller.gd: intercept, per-game
## layout files, its own page) stays; these controls write the same everyday
## layout file and ask it to refresh after a change.

const Ctl := preload("res://scripts/controls/control.gd")
const Backend := preload("res://scripts/controls/input/backend.gd")
const IpEdit := preload("res://scripts/controls/input/ip_edit.gd")
const Leds := preload("res://scripts/controls/input/leds.gd")
const Caps := preload("res://scripts/controls/input/caps.gd")
const Hhd := preload("res://scripts/controls/input/hhd_client.gd")
const Profile := preload("res://scripts/input/ip_profile.gd")
const Traits := preload("res://scripts/device/traits.gd")
const Rumble := preload("res://scripts/controls/input/rumble.gd")

const R_NONE := "Needs InputPlumber or Handheld Daemon running"
const R_HHD_ONLY := "Needs Handheld Daemon (InputPlumber has no such setting)"
const R_IP_ONLY := "Needs InputPlumber"
const R_NO_GYRO_IP := "InputPlumber sees no gyro on this handheld"
const R_GYRO_OLD_IP := "The gyro works, but InputPlumber %s can't switch it off; a newer InputPlumber can"
const R_GYRO_FIX := "Needs the gyro fix first (Device, Fixes)"
const R_GYRO_AIM := "Set gyro aiming in Steam's controller settings for the game"
const R_DEADZONE_IP := "InputPlumber has no deadzone setting; Steam's controller settings have one per game"
const R_NO_RGB := "This handheld has no RGB lights"
const R_LED_HELPER := "Needs GameCove's root helper (install GameCove's system part)"
const R_RGB_BACKEND := "No RGB driver here: needs Handheld Daemon or a kernel with this handheld's LED driver"
const R_NO_PAD := "This handheld has no trackpad"
const CLAW8EX_OVERRIDE := "/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml"
const FIX_SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"

const EMULATION_LABELS := {
	"default": "Handheld default", "deck": "Steam Deck", "ds5-edge": "DualSense Edge", "ds5": "DualSense",
	"xbox-elite": "Xbox Elite", "xbox-series": "Xbox Series", "xb360": "Xbox 360", "hori-steam": "Steam Controller (HORI)",
	"dualsense": "DualSense", "dualsense_edge": "DualSense Edge", "uinput": "Xbox", "xbox_elite": "Xbox Elite",
	"hori_steam": "Steam Controller", "disabled": "Paused", "hidden": "Hidden",
	"none": "No gamepad", "gamepad": "Generic gamepad",
}
## InputPlumber gamepad types offered (the rest stay reachable through a profile file).
const IP_EMULATION := ["default", "deck", "ds5-edge", "xbox-elite", "xbox-series", "ds5", "xb360"]
## InputPlumber target kinds that are one of the choices above under another name.
const EMULATION_ALIASES := {"deck-uhid": "deck"}
const EFFECT_LABELS := {
	"off": "Off", "disabled": "Off", "solid": "Solid", "pulse": "Pulse", "strobe": "Strobe", "rainbow": "Rainbow",
	"spiral": "Spiral", "cycle": "Colour cycle", "duality": "Two colours", "frostfire": "Frostfire",
	"oxp": "OneXPlayer styles", "aok": "AOKZOE styles",
}
const ORDINAL_PCT := {"low": 33.0, "medium": 66.0, "high": 100.0}
## Keys a back button may send (InputPlumber keyboard names).
const KEYS := ["KeyEsc", "KeyEnter", "KeySpace", "KeyTab", "KeyLeftShift", "KeyLeftCtrl", "KeyLeftAlt",
	"KeyW", "KeyA", "KeyS", "KeyD", "KeyQ", "KeyE", "KeyR", "KeyF", "KeyM", "KeyI", "Key1", "Key2", "Key3", "Key4"]
const BUTTON_LABELS := {
	"South": "A", "East": "B", "West": "X", "North": "Y", "Start": "Menu", "Select": "View", "Guide": "Guide",
	"QuickAccess": "Quick Access", "Keyboard": "Keyboard", "Screenshot": "Screenshot",
	"DPadUp": "D-pad up", "DPadDown": "D-pad down", "DPadLeft": "D-pad left", "DPadRight": "D-pad right",
	"LeftBumper": "LB", "RightBumper": "RB", "LeftTrigger": "LT", "RightTrigger": "RT",
	"LeftStick": "Left stick click", "RightStick": "Right stick click",
}

## Firmware resets some lights over sleep: after a resume these are applied again
## (5 s later, as HueSync does: github.com/honjow/HueSync src/index.tsx,
## RegisterForOnResumeFromSuspend). For whoever wires resume (main.gd's clock check).
const REAPPLY_AFTER_RESUME := ["controller.led_effect", "controller.led_color", "controller.led_color_2",
	"controller.led_brightness", "controller.led_speed"]
const RESUME_DELAY_S := 5.0

var ctx: Dictionary = {}
var be: Backend = Backend.new()
var row: Dictionary = {}
var hw: Dictionary = {}
## Last non-off hhd gyro mode (Legion Go: left / right / both), for gyro on.
var _hhd_imu_mode := "left"
## InputPlumber's target kinds as GameCove first found them (controller.emulation put-back).
var _ip_first_targets: Array = []
var _desktop_speed := IpEdit.DESKTOP_SPEED_DEFAULT


func setup(context: Dictionary) -> void:
	ctx = context
	be.setup(context)
	row = be.row
	hw = Caps.of(row)
	var tree := Engine.get_main_loop() as SceneTree
	var real := str(context.get("sys_root", "")) == ""   # never the autoload from a fixture context
	var svc: Node = tree.root.get_node_or_null("Controller") if real and tree != null and tree.root != null else null
	if svc != null and svc.has_method("refresh"):
		be.on_changed = Callable(svc, "refresh")


func controls() -> Array:
	var out: Array = [
		_gyro(), _gyro_source(), _gyro_accel(), _gyro_aim(),
		_emulation(), _paddles_as(),
	]
	for cap in hw["paddles"]:
		out.append(_button("paddle", cap, "Back button " + str(hw["paddles"][cap])))
	for cap in hw["extra_buttons"]:
		out.append(_button("button", cap, str(hw["extra_buttons"][cap])))
	out.append_array([
		_nintendo(), _desktop(), _desktop_speed_ctl(), _trackpad(),
		_rumble(), _rumble_strength(), _rumble_test(),
		_deadzone("left_stick", "ls_min", "Left stick deadzone"),
		_deadzone("right_stick", "rs_min", "Right stick deadzone"),
		_deadzone("left_trigger", "lt_min", "Left trigger deadzone"),
		_deadzone("right_trigger", "rt_min", "Right trigger deadzone"),
		_led_effect(), _led_color(false), _led_color(true), _led_brightness(), _led_speed(),
		_reset_layout(),
	])
	return out


func _make(spec: Dictionary, detect: Callable, read: Callable, write: Callable) -> RefCounted:
	spec["group"] = "controller"
	var c: RefCounted = Ctl.make(spec, detect, read, write)
	c.set_meta("provider", self)
	return c


## Controls probe (hwtest/controls_cli.gd): what to put back byte for byte afterwards.
## InputPlumber's live profile text; {} where hhd or nothing drives the controller.
func probe_snapshot() -> Dictionary:
	if be.controller_backend() != "inputplumber":
		return {}
	be.invalidate()
	var y := be.ip_profile_yaml()
	return {"ip_yaml": y} if y != "" else {}


func probe_restore(snap: Dictionary) -> bool:
	if not snap.has("ip_yaml"):
		return true
	be.invalidate()
	if be.ip_profile_yaml() == str(snap["ip_yaml"]):
		return true
	return be.ip_load_yaml(str(snap["ip_yaml"]))


static func _opts(values: Array, labels: Dictionary) -> Array:
	return values.map(func(v): return {"value": v, "label": str(labels.get(v, str(v).capitalize()))})


# ---- gyro ------------------------------------------------------------------------

func _gyro_hw_block() -> String:
	return Caps.gyro_block(row)


## hhd's gyro switch: ["imu"] / ["gyro"] (bool) or ["imu"] as a mode (Legion Go).
func _hhd_gyro() -> Dictionary:
	for k in ["imu", "gyro"]:
		var v: Variant = be.hhd_ctl([k])
		if v is bool:
			return {"path": [k], "kind": "bool"}
		if v is Dictionary and v.get("mode") is String:
			return {"path": [k, "mode"], "kind": "mode", "modes": Hhd.options_of(be.hhd_ctl_schema([k])) }
	return {}


func _ip_gyro_reason() -> String:
	# Older InputPlumber (0.78 on SteamOS 3.10, the ROG Ally) reports the IMU as the legacy
	# "Gamepad:Gyro" capability, and its profile matching ignores gamepad gyro source events
	# (src/config/mod.rs: "Gyro was defined for source event! TODO"), so the gyro reaches
	# games but can't be switched off from a profile; newer ones say "Gyroscope:<source>".
	if str(row.get("gyro", "")) == "fix":
		return R_GYRO_FIX
	if be.ip_caps().any(func(c): return str(c) == "Gamepad:Gyro"):
		return R_GYRO_OLD_IP % str(be.ip().get("version", "?"))
	return R_NO_GYRO_IP


func _gyro() -> RefCounted:
	return _make({"id": "controller.gyro", "title": "Gyro", "kind": "toggle", "default_value": true,
		"help": "Motion aiming for games and Steam Input. Off stops the gyro reaching games."},
		func(_c):
			var b := _gyro_hw_block()
			if b != "":
				return b
			match be.controller_backend():
				"inputplumber":
					return "" if not IpEdit.gyro_sources(be.ip_caps()).is_empty() else _ip_gyro_reason()
				"hhd":
					return "" if not _hhd_gyro().is_empty() else "Handheld Daemon has no gyro switch for this handheld"
			return R_NONE,
		func(_c):
			if be.controller_backend() == "hhd":
				var g := _hhd_gyro()
				var v: Variant = be.hhd_ctl(g["path"])
				if g["kind"] == "bool":
					return bool(v)
				if str(v) != "disabled":
					_hhd_imu_mode = str(v)
				return str(v) != "disabled"
			var src := IpEdit.gyro_sources(be.ip_caps())
			return not IpEdit.gyro_enabled_sources(be.ip_profile(), src).is_empty(),
		func(_c, v):
			if be.controller_backend() == "hhd":
				var g := _hhd_gyro()
				var want: Variant = v
				if g["kind"] == "mode":
					var modes: Array = g.get("modes", [])
					want = _hhd_imu_mode if v else "disabled"
					if not modes.is_empty() and not want in modes:
						return false
				var path: Array = ["controllers", be.hhd_key()] + g["path"]
				return be.hhd_set(Hhd.nest(path, want), [[path, want]])
			var src := IpEdit.gyro_sources(be.ip_caps())
			var cur := IpEdit.gyro_enabled_sources(be.ip_profile(), src)
			var on: Array = (cur if not cur.is_empty() else src) if v else []
			return be.ip_apply(func(p): return IpEdit.set_gyro_sources(p, src, on),
				func(p): return IpEdit.gyro_enabled_sources(p, src).size() == on.size()))


## Which motion sensor feeds the gyro where there are several (Legion Go: one per
## detachable controller).
func _gyro_source() -> RefCounted:
	return _make({"id": "controller.gyro_source", "title": "Gyro sensor", "kind": "choice", "default_value": "both",
		"requires": ["controller.gyro"],
		"help": "Which controller's motion sensor aims.",
		"options": _opts(["left", "right", "center", "both"], {"left": "Left controller", "right": "Right controller", "center": "Body", "both": "Both"})},
		func(c):
			var b := _gyro_hw_block()
			if b != "":
				return b
			match be.controller_backend():
				"inputplumber":
					var src := IpEdit.gyro_sources(be.ip_caps())
					if src.size() < 2:
						return "This handheld has one gyro" if not src.is_empty() else _ip_gyro_reason()
					var vals: Array = src.map(func(s): return str(s).to_lower()) + ["both"]
					c.options = _opts(vals, {"left": "Left controller", "right": "Right controller", "center": "Body", "both": "All"})
					return ""
				"hhd":
					var g := _hhd_gyro()
					if g.get("kind", "") != "mode":
						return "This handheld has one gyro"
					var modes: Array = (g["modes"] as Array).filter(func(m): return m != "disabled")
					c.options = _opts(modes, Hhd.labels_of(be.hhd_ctl_schema(["imu"])))
					return ""
			return R_NONE,
		func(_c):
			if be.controller_backend() == "hhd":
				var v := str(be.hhd_ctl(_hhd_gyro()["path"]))
				return v if v != "disabled" else _hhd_imu_mode
			var src := IpEdit.gyro_sources(be.ip_caps())
			var on := IpEdit.gyro_enabled_sources(be.ip_profile(), src)
			if on.is_empty():
				return null
			return "both" if on.size() == src.size() else str(on[0]).to_lower(),
		func(_c, v):
			if be.controller_backend() == "hhd":
				_hhd_imu_mode = str(v)
				var path: Array = ["controllers", be.hhd_key()] + _hhd_gyro()["path"]
				return be.hhd_set(Hhd.nest(path, v), [[path, v]])
			var src := IpEdit.gyro_sources(be.ip_caps())
			var on: Array = src.duplicate() if v == "both" else src.filter(func(s): return str(s).to_lower() == v)
			if on.is_empty():
				return false
			return be.ip_apply(func(p): return IpEdit.set_gyro_sources(p, src, on),
				func(p): return IpEdit.gyro_enabled_sources(p, src).size() == on.size()))


## MSI Claw 8 EX: the gyro fix can add the accelerometer too (restarts InputPlumber).
func _gyro_accel() -> RefCounted:
	return _make({"id": "controller.gyro_accel", "title": "Accelerometer", "kind": "toggle", "default_value": false,
		"per_game": false, "needs_root": true, "requires": ["controller.gyro"],
		"help": "Off gives steadier aiming. On adds the tilt sensor for games that want it."},
		func(_c):
			var gyro_fix := {}
			for e in Traits.load_fixes():
				if str(e.get("id", "")) == "claw8ex-gyro":
					gyro_fix = e
			if not Traits.fix_auto(gyro_fix, row):
				return "Only on the MSI Claw 8 EX"
			var f := str(ctx.get("sys_root", "")) + CLAW8EX_OVERRIDE
			if not FileAccess.file_exists(f) or not "gyro_3d" in FileAccess.get_file_as_string(f):
				return R_GYRO_FIX
			return "",
		func(_c): return "accel_3d" in FileAccess.get_file_as_string(str(ctx.get("sys_root", "")) + CLAW8EX_OVERRIDE),
		func(_c, v):
			var r: Dictionary = ctx["runner"].run("pkexec", PackedStringArray([FIX_SET_HELPER, "claw8ex-gyro", "set", "accel-on" if v else "accel-off"]))
			be.invalidate()
			return int(r.get("code", -1)) == 0 and ("accel_3d" in FileAccess.get_file_as_string(str(ctx.get("sys_root", "")) + CLAW8EX_OVERRIDE)) == v)


## Neither InputPlumber nor hhd turns gyro into mouse/joystick: Steam Input does
## (it gets raw motion from the Steam Deck / DualSense the backend emulates).
## Shown greyed with where to find it.
func _gyro_aim() -> RefCounted:
	return _make({"id": "controller.gyro_aim", "title": "Gyro as mouse or joystick", "kind": "choice",
		"per_game": false, "options": _opts(["steam"], {"steam": "Steam Input"}), "default_value": "steam",
		"help": "Sensitivity, activation button and style live in Steam's controller settings."},
		func(_c):
			var b := _gyro_hw_block()
			return b if b != "" else R_GYRO_AIM,
		func(_c): return "steam",
		func(_c, _v): return false)


# ---- controller type ----------------------------------------------------------------

## hhd's emulation switch: "controller_mode" (most) or "xinput" (Legion Go / Go S).
func _hhd_mode_key() -> String:
	for k in ["controller_mode", "xinput"]:
		var v: Variant = be.hhd_ctl([k])
		if v is Dictionary and v.get("mode") is String:
			return k
	return ""


func _emulation() -> RefCounted:
	return _make({"id": "controller.emulation", "title": "Controller type", "kind": "choice", "default_value": "default",
		"apply_order": 20, "options": _opts(IP_EMULATION, EMULATION_LABELS),
		"help": "What games see. Steam Deck and DualSense carry gyro and trackpads; Xbox works everywhere."},
		func(c):
			match be.controller_backend():
				"inputplumber":
					var vals: Array = IP_EMULATION.duplicate()
					var now := _ip_emulation_now()
					if not now in vals:
						vals.append(now)   # what another tool set (hori-steam, gamepad...): shown, not lost
					c.options = _opts(vals, EMULATION_LABELS)
					c.default_value = "default"
					return ""
				"hhd":
					var k := _hhd_mode_key()
					if k == "":
						return "Handheld Daemon has no controller type for this handheld"
					var node: Variant = be.hhd_ctl_schema([k])
					var modes := Hhd.options_of(node)
					if modes.is_empty():
						modes = [str(be.hhd_ctl([k, "mode"]))]
					var labels := EMULATION_LABELS.duplicate()
					labels.merge(Hhd.labels_of(node), true)
					c.options = _opts(modes, labels)
					# hhd's own default mode (its schema), else its first: "default" is InputPlumber's word
					var dflt: Variant = node.get("default") if node is Dictionary else null
					c.default_value = str(dflt) if dflt != null and str(dflt) in modes else str(modes[0])
					return ""
			return R_NONE,
		func(_c):
			if be.controller_backend() == "hhd":
				return str(be.hhd_ctl([_hhd_mode_key(), "mode"]))
			return _ip_emulation_now(),
		func(_c, v):
			if be.controller_backend() == "hhd":
				var path: Array = ["controllers", be.hhd_key(), _hhd_mode_key(), "mode"]
				return be.hhd_set(Hhd.nest(path, v), [[path, v]])
			var conf := be.ip_config_targets()
			if v == "default":
				if conf.is_empty():
					return false
				return be.ip_apply(func(p):
						var q := Profile.normalize(p)
						q["target_devices"] = conf.duplicate()
						return q,
					func(p): return p.get("target_devices") is Array and p["target_devices"] == conf)
			# the exact list GameCove first found when it is that choice again (deck-uhid
			# stays deck-uhid, mouse and keyboard stay): a put-back restores what was there
			var want := str(v)
			var base := conf
			if _ip_first_targets.size() > 0 and emulation_choice(_ip_first_targets, conf) == want:
				want = IpEdit.gamepad_target({"target_devices": _ip_first_targets})
				base = _ip_first_targets
			return be.ip_apply(func(p): return IpEdit.set_gamepad_target(p, want, base),
				func(p): return IpEdit.gamepad_target(p) == want))


## InputPlumber's live target kinds when it lists them, else the profile's.
func _ip_targets_now() -> Array:
	var live: Array = be.ip_live_targets()
	if not live.is_empty():
		return live
	var p: Dictionary = be.ip_profile()
	return p["target_devices"] if p.get("target_devices") is Array else []


## The controller.emulation value for what InputPlumber emulates now; the first list seen
## is kept so writing that choice again puts the very same targets back.
func _ip_emulation_now() -> String:
	var t := _ip_targets_now()
	if _ip_first_targets.is_empty() and not t.is_empty():
		_ip_first_targets = t.duplicate()
	return emulation_choice(t, be.ip_config_targets())


## "default" only when the targets are the device config's own; else the gamepad kind as a
## GameCove choice (deck-uhid is a Steam Deck too). Kinds outside IP_EMULATION come back
## as themselves (detect adds them as options) rather than a wrong "default".
static func emulation_choice(targets: Array, conf: Array) -> String:
	if targets.is_empty() or (not conf.is_empty() and targets == conf):
		return "default"
	var g := IpEdit.gamepad_target({"target_devices": targets})
	if g == "":
		return "default" if conf.is_empty() else "none"
	return EMULATION_ALIASES.get(g, g)


# ---- buttons ------------------------------------------------------------------------

func _paddles_as() -> RefCounted:
	return _make({"id": "controller.paddles_as", "title": "Back buttons", "kind": "choice", "default_value": "steam_input",
		"options": _opts(["steam_input"], {"steam_input": "Steam Input"}),
		"help": "What the back buttons do as a group (Handheld Daemon)."},
		func(c):
			if hw["paddles"].is_empty():
				return "This handheld has no back buttons"
			match be.controller_backend():
				"inputplumber":
					return "With InputPlumber each back button is set on its own"
				"hhd":
					var p := _hhd_paddles_path()
					if p.is_empty():
						return "Not with this controller type (Handheld Daemon)"
					var node: Variant = be.hhd_ctl_schema(p)
					var vals := Hhd.options_of(node)
					if vals.is_empty():
						vals = [str(be.hhd_ctl(p))]
					c.options = _opts(vals, Hhd.labels_of(node))
					return ""
			return R_NONE,
		func(_c): return str(be.hhd_ctl(_hhd_paddles_path())),
		func(_c, v):
			var path: Array = ["controllers", be.hhd_key()] + _hhd_paddles_path()
			return be.hhd_set(Hhd.nest(path, v), [[path, v]]))


func _hhd_paddles_path() -> Array:
	var k := _hhd_mode_key()
	if k == "":
		return []
	var mode := str(be.hhd_ctl([k, "mode"]))
	return [k, mode, "paddles_as"] if be.hhd_ctl([k, mode, "paddles_as"]) is String else []


func _button_options(cap: String) -> Array:
	var vals: Array = ["", "disabled"]
	for b in Profile.BUTTONS:
		if b != cap and not b.contains("Paddle"):
			vals.append(b)
	vals.append_array(["mouse:Left", "mouse:Right"])
	vals.append_array(KEYS)
	var labels := BUTTON_LABELS.duplicate()
	labels.merge({"": "As itself", "disabled": "Off", "mouse:Left": "Mouse left click", "mouse:Right": "Mouse right click"})
	for k in KEYS:
		labels[k] = "Key " + str(k).trim_prefix("Key")
	return _opts(vals, labels)


## One remappable button (a back paddle or an extra special button). InputPlumber only.
func _button(kind: String, cap: String, title: String) -> RefCounted:
	return _make({"id": "controller.%s.%s" % [kind, cap], "title": title, "kind": "choice", "default_value": "",
		"options": _button_options(cap), "help": "What this button sends."},
		func(_c):
			match be.controller_backend():
				"inputplumber":
					return "" if ("Gamepad:Button:" + cap) in be.ip_caps() else "InputPlumber doesn't report this button"
				"hhd":
					return "Handheld Daemon sets the back buttons together (Back buttons)" if kind == "paddle" else R_IP_ONLY
			return R_NONE,
		func(_c):
			var t := IpEdit.button_target(be.ip_profile(), cap)
			return t if t == "" or IpEdit.valid_button_target(t) else null,
		func(_c, v):
			if not IpEdit.valid_button_target(str(v)):
				return false
			var stock := be.ip_stock_profile()
			return be.ip_apply(func(p): return IpEdit.set_button(p, cap, str(v), stock),
				func(p): return IpEdit.button_target(p, cap) == str(v)))


func _nintendo() -> RefCounted:
	return _make({"id": "controller.nintendo_layout", "title": "Swap A/B and X/Y", "kind": "toggle", "default_value": false,
		"help": "Nintendo layout: confirm on the right button."},
		func(_c):
			match be.controller_backend():
				"inputplumber":
					return ""
				"hhd":
					return "" if be.hhd_ctl(["nintendo_mode"]) is bool else "Handheld Daemon has no layout swap for this handheld"
			return R_NONE,
		func(_c):
			if be.controller_backend() == "hhd":
				return bool(be.hhd_ctl(["nintendo_mode"]))
			return IpEdit.nintendo(be.ip_profile()),
		func(_c, v):
			if be.controller_backend() == "hhd":
				var path: Array = ["controllers", be.hhd_key(), "nintendo_mode"]
				return be.hhd_set(Hhd.nest(path, v), [[path, v]])
			return be.ip_apply(func(p): return IpEdit.set_nintendo(p, v), func(p): return IpEdit.nintendo(p) == v))


# ---- desktop mode / trackpad ------------------------------------------------------------

func _desktop() -> RefCounted:
	return _make({"id": "controller.desktop_mode", "title": "Mouse mode", "kind": "toggle", "default_value": false,
		"per_game": false,
		"help": "Right stick moves the pointer, right trigger clicks, left trigger right-clicks."},
		func(_c):
			match be.controller_backend():
				"inputplumber":
					return ""
				"hhd":
					return "Handheld Daemon has no mouse mode; use the touchpad or Steam's desktop layout"
			return R_NONE,
		func(_c): return IpEdit.desktop_speed(be.ip_profile()) > 0,
		func(_c, v):
			var gp := _current_gamepad_target()
			return be.ip_apply(func(p): return IpEdit.set_desktop(p, v, _desktop_speed, gp),
				func(p): return (IpEdit.desktop_speed(p) > 0) == v))


func _current_gamepad_target() -> String:
	var t := IpEdit.gamepad_target(be.ip_profile())
	if t != "":
		return t
	for x in be.ip_config_targets():
		if str(x) in IpEdit.GAMEPAD_TARGETS:
			return str(x)
	return "xbox-elite"


func _desktop_speed_ctl() -> RefCounted:
	return _make({"id": "controller.desktop_speed", "title": "Mouse mode speed", "kind": "slider",
		"min_value": 200.0, "max_value": 3000.0, "step": 100.0, "unit": "px/s", "default_value": float(IpEdit.DESKTOP_SPEED_DEFAULT),
		"per_game": false, "requires": ["controller.desktop_mode"], "help": "How fast the pointer moves."},
		func(_c): return "" if be.controller_backend() == "inputplumber" else (R_IP_ONLY if be.controller_backend() == "hhd" else R_NONE),
		func(_c):
			var s := IpEdit.desktop_speed(be.ip_profile())
			if s > 0:
				_desktop_speed = s
			return float(_desktop_speed),
		func(_c, v):
			_desktop_speed = int(v)
			if IpEdit.desktop_speed(be.ip_profile()) == 0:
				return true   # used when mouse mode goes on
			var gp := _current_gamepad_target()
			return be.ip_apply(func(p): return IpEdit.set_desktop(p, true, int(v), gp),
				func(p): return IpEdit.desktop_speed(p) == int(v)))


## hhd's touchpad setting under the controller section: a mode (Legion Go, GPD)
## or a multiple (Legion Go S).
func _hhd_pad() -> Dictionary:
	var v: Variant = be.hhd_ctl(["touchpad"])
	if v is Dictionary and v.get("mode") is String:
		return {"path": ["touchpad", "mode"], "node": be.hhd_ctl_schema(["touchpad"])}
	if v is String:
		return {"path": ["touchpad"], "node": be.hhd_ctl_schema(["touchpad"])}
	return {}


func _trackpad() -> RefCounted:
	return _make({"id": "controller.trackpad", "title": "Trackpad", "kind": "choice", "default_value": "default",
		"options": _opts(["default", "off"], {}),
		"help": "What the trackpad does in games."},
		func(c):
			var backend: String = be.controller_backend()
			if backend == "inputplumber":
				var pads := IpEdit.pads(be.ip_caps())
				if pads.is_empty():
					return R_NO_PAD
				var vals: Array = ["default", "off"]
				if pads == ["CenterPad"]:
					vals = ["default", "RightPad", "LeftPad", "off"]
				c.options = _opts(vals, {"default": "As the handheld sends it", "RightPad": "Steam right trackpad",
					"LeftPad": "Steam left trackpad", "off": "Off"})
				return ""
			if backend == "hhd":
				var hp := _hhd_pad()
				if hp.is_empty():
					return R_NO_PAD if int(hw["trackpads"]) == 0 else "Handheld Daemon has no trackpad setting here"
				var vals := Hhd.options_of(hp["node"])
				if vals.is_empty():
					vals = [str(be.hhd_ctl(hp["path"]))]
				c.options = _opts(vals, Hhd.labels_of(hp["node"]))
				return ""
			return R_NO_PAD if int(hw["trackpads"]) == 0 else R_NONE,
		func(_c):
			if be.controller_backend() == "hhd":
				return str(be.hhd_ctl(_hhd_pad()["path"]))
			var pads := IpEdit.pads(be.ip_caps())
			return IpEdit.pad_mode(be.ip_profile(), pads[0]) if not pads.is_empty() else null,
		func(_c, v):
			if be.controller_backend() == "hhd":
				var path: Array = ["controllers", be.hhd_key()] + _hhd_pad()["path"]
				return be.hhd_set(Hhd.nest(path, v), [[path, v]])
			var pads := IpEdit.pads(be.ip_caps())
			return be.ip_apply(func(p):
					var q: Dictionary = p
					for pad in pads:
						q = IpEdit.set_pad_mode(q, pad, "default" if v != "off" and pad != pads[0] else str(v))
					return q,
				func(p): return IpEdit.pad_mode(p, pads[0]) == str(v)))


# ---- rumble (input/rumble.gd: InputPlumber, hhd and the controller firmware's own strength) ----

var _rumble_impl: RefCounted = null


func _rumble_ctl() -> RefCounted:
	if _rumble_impl == null:
		_rumble_impl = Rumble.new(be)
	return _rumble_impl


func _rumble() -> RefCounted:
	return _rumble_ctl().toggle()


func _rumble_strength() -> RefCounted:
	return _rumble_ctl().strength()


func _rumble_test() -> RefCounted:
	return _rumble_ctl().test()


# ---- deadzones (hhd "Deadzones & Vibration": the ROG Ally family) ---------------------------

func _deadzone(name: String, key: String, title: String) -> RefCounted:
	return _make({"id": "controller.deadzone_" + name, "title": title, "kind": "slider",
		"min_value": 0.0, "max_value": 50.0, "step": 2.0, "unit": "%", "default_value": 5.0,
		"help": "How far it moves before it counts."},
		func(c):
			match be.controller_backend():
				"inputplumber":
					return R_DEADZONE_IP
				"hhd":
					var node: Variant = be.hhd_ctl_schema(["limits", "manual", key])
					if not (be.hhd_ctl(["limits"]) is Dictionary) or not (node is Dictionary or be.hhd_ctl(["limits", "manual", key]) != null):
						return "Handheld Daemon has no deadzone setting for this handheld"
					if node is Dictionary:
						c.min_value = float(node.get("min", 0))
						c.max_value = minf(50.0, float(node.get("max", 50)))
						c.step = float(node.get("step", 2))
						c.default_value = float(node.get("default", 5))
					return ""
			return R_NONE,
		func(c):
			if str(be.hhd_ctl(["limits", "mode"])) != "manual":
				return c.default_value
			var v: Variant = be.hhd_ctl(["limits", "manual", key])
			return float(v) if v != null else c.default_value,
		func(_c, v):
			var iv := int(v)
			var path: Array = ["controllers", be.hhd_key(), "limits", "manual", key]
			return be.hhd_set({"controllers": {be.hhd_key(): {"limits": {"mode": "manual", "manual": {key: iv}}}}},
				[[path, iv], [["controllers", be.hhd_key(), "limits", "mode"], "manual"]]))


# ---- RGB ----------------------------------------------------------------------------------

func _rgb_block() -> String:
	match be.rgb_backend():
		"hhd":
			return ""
		"sysfs":
			# root-only nodes (the Ally's ally:rgb:joystick_rings is 0644) need the
			# no-password root action; world-writable ones (the Claw's hid-msi) don't
			var n: Dictionary = be.leds()[0]
			if not Leds.direct_capable(n) and not FileAccess.file_exists(str(ctx.get("sys_root", "")) + FIX_SET_HELPER):
				return R_LED_HELPER
			return ""
	return R_NO_RGB if not hw["rgb"] else R_RGB_BACKEND


## hhd: the rgb mode node and the current mode's settings.
func _hhd_rgb_node() -> Variant:
	return Hhd.schema_node(be.hhd_settings(), ["rgb", "handheld", "mode", "mode"])


func _hhd_rgb_mode() -> String:
	return str(Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode", "mode"]))


func _hhd_rgb_children(mode: String) -> Dictionary:
	var node: Variant = Hhd.dig(_hhd_rgb_node(), ["modes", mode, "children"])
	if node is Dictionary:
		return node
	var cur: Variant = Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode", mode])
	var out := {}
	if cur is Dictionary:
		for k in cur:
			out[k] = {}
	return out


func _hhd_rgb_modes() -> Array:
	var modes := Hhd.options_of(_hhd_rgb_node())
	if modes.is_empty():
		var m: Variant = Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode"])
		if m is Dictionary:
			modes = m.keys().filter(func(k): return k != "mode")
			if not _hhd_rgb_mode() in modes:
				modes.append(_hhd_rgb_mode())
	return modes


static func _gc_effect(hhd_mode: String) -> String:
	return "off" if hhd_mode == "disabled" else hhd_mode


static func _hhd_effect(effect: String) -> String:
	return "disabled" if effect == "off" else effect


func _hhd_rgb_set(mode: String, values: Dictionary) -> bool:
	var base := ["rgb", "handheld", "mode"]
	var patch := {"rgb": {"handheld": {"mode": {"mode": mode}}}}
	var checks: Array = [[base + ["mode"], mode]]
	if not values.is_empty():
		patch["rgb"]["handheld"]["mode"][mode] = values
		for k in values:
			checks.append([base + [mode, k], values[k]])
	return be.hhd_set(patch, checks)


func _snap(node: Variant, v: float) -> int:
	if not (node is Dictionary):
		return int(roundf(v))
	var st := float(node.get("step", 1))
	var lo := float(node.get("min", 0))
	var hi := float(node.get("max", 100))
	if st > 0:
		v = lo + roundf((v - lo) / st) * st
	return int(clampf(v, lo, hi))


static func _ordinal(pct: float, options: Array) -> String:
	var best := ""
	var dist := 1e9
	for o in options:
		var d := absf(float(ORDINAL_PCT.get(o, 66.0)) - pct)
		if d < dist:
			dist = d
			best = str(o)
	return best


func _led_effect() -> RefCounted:
	return _make({"id": "controller.led_effect", "title": "Lights", "kind": "choice", "default_value": "solid",
		"apply_order": 5, "options": _opts(["off", "solid"], EFFECT_LABELS),
		"help": "Stick ring lighting."},
		func(c):
			var b := _rgb_block()
			if b != "":
				return b
			if be.rgb_backend() == "hhd":
				var modes := _hhd_rgb_modes()
				if modes.is_empty():
					return R_RGB_BACKEND
				c.options = _opts(modes.map(func(m): return _gc_effect(str(m))), EFFECT_LABELS)
			else:
				c.options = _opts(Leds.effects_of(be.leds()[0]), EFFECT_LABELS)
			return "",
		func(_c):
			if be.rgb_backend() == "hhd":
				return _gc_effect(_hhd_rgb_mode())
			return Leds.effect_of(be.leds()[0]),
		func(_c, v):
			if be.rgb_backend() == "hhd":
				return _hhd_rgb_set(_hhd_effect(str(v)), {})
			var n: Dictionary = be.leds()[0]
			if v == "off":
				return be.led_apply("off", func(ls): return Leds.effect_of(ls[0]) == "off")
			var pct := Leds.brightness_pct(n)
			var kern := Leds.kernel_effect(n, str(v))
			var spec := Leds.spec("all", Leds.color_of(n), pct if pct > 0.0 else 100.0, kern, Leds.speed_pct(n) if kern != "" and kern != "monocolor" else -1.0)
			return be.led_apply(spec, func(ls): return Leds.effect_of(ls[0]) == str(v)))


func _led_color(second: bool) -> RefCounted:
	var id := "controller.led_color_2" if second else "controller.led_color"
	return _make({"id": id, "title": "Second colour" if second else "Light colour", "kind": "color",
		"default_value": "#00aaff" if second else "#ff6a00", "apply_order": 4,
		"requires": ["controller.led_effect"], "help": "The second zone or the second colour of two-colour effects." if second else "Colour of the stick rings."},
		func(c):
			var b := _rgb_block()
			if b != "":
				return b
			if be.rgb_backend() == "hhd":
				var key := "hue2" if second else "hue"
				for m in _hhd_rgb_modes():
					if _hhd_rgb_children(str(m)).has(key):
						return ""
				return "Not on this handheld" if second else "Handheld Daemon has no colour setting here"
			if second:
				if be.leds().size() < 2:
					return "This handheld's lights have one zone"
				c.title = "Second zone colour"
			return "",
		func(_c):
			if be.rgb_backend() == "hhd":
				var mode := _hhd_rgb_mode()
				var cur: Variant = Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode", mode])
				var key := "hue2" if second else "hue"
				if not (cur is Dictionary) or not cur.has(key):
					return null
				var sat := float(cur.get("saturation", 100)) / 100.0
				return "#" + Color.from_hsv(float(cur[key]) / 360.0, clampf(sat, 0.0, 1.0), 1.0).to_html(false)
			var ls: Array = be.leds()
			return "#" + Leds.color_of(ls[1] if second else ls[0]).to_html(false),
		func(_c, v):
			var col := Color.html(str(v))
			if be.rgb_backend() == "hhd":
				var key := "hue2" if second else "hue"
				var mode := _hhd_rgb_mode()
				if not _hhd_rgb_children(mode).has(key):
					if second:
						return false
					mode = "solid"   # the current effect has no colour: show it solid
				var ch := _hhd_rgb_children(mode)
				var vals := {key: _snap(ch.get(key), col.h * 360.0)}
				if ch.has("saturation"):
					vals["saturation"] = _snap(ch.get("saturation"), col.s * 100.0)
				return _hhd_rgb_set(mode, vals)
			var ls: Array = be.leds()
			var n: Dictionary = ls[1] if second else ls[0]
			var zone := "1" if second else ("0" if ls.size() > 1 else "all")
			var pct := Leds.brightness_pct(n)
			var kern := Leds.kernel_effect(n, Leds.effect_of(n))
			var spec := Leds.spec(zone, col, pct if pct > 0.0 else 100.0, kern)
			return be.led_apply(spec, func(after):
				var m: Dictionary = after[1] if second else after[0]
				return _close(Leds.color_of(m), col)))


## Colours read back through a 0-100 channel (Legion rings) land within a step.
static func _close(a: Color, b: Color) -> bool:
	return absi(a.r8 - b.r8) <= 3 and absi(a.g8 - b.g8) <= 3 and absi(a.b8 - b.b8) <= 3


func _led_brightness() -> RefCounted:
	return _make({"id": "controller.led_brightness", "title": "Light brightness", "kind": "slider",
		"min_value": 0.0, "max_value": 100.0, "step": 1.0, "unit": "%", "default_value": 50.0, "apply_order": 3,
		"requires": ["controller.led_effect"], "help": "0 turns the lights off."},
		func(_c):
			var b := _rgb_block()
			if b != "":
				return b
			if be.rgb_backend() == "hhd":
				for m in _hhd_rgb_modes():
					var ch := _hhd_rgb_children(str(m))
					if ch.has("brightness") or ch.has("brightnessd"):
						return ""
				return "Handheld Daemon has no brightness setting here"
			return "",
		func(_c):
			if be.rgb_backend() == "hhd":
				var mode := _hhd_rgb_mode()
				if mode == "disabled":
					return 0.0
				var cur: Variant = Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode", mode])
				if cur is Dictionary and cur.get("brightness") != null:
					return float(cur["brightness"])
				if cur is Dictionary and cur.get("brightnessd") is String:
					return float(ORDINAL_PCT.get(cur["brightnessd"], 66.0))
				return null
			return Leds.brightness_pct(be.leds()[0]),
		func(_c, v):
			var pct := float(v)
			if be.rgb_backend() == "hhd":
				if pct <= 0.0:
					return _hhd_rgb_set("disabled", {}) if "disabled" in _hhd_rgb_modes() else false
				var mode := _hhd_rgb_mode()
				if mode == "disabled":
					mode = "solid"
				var ch := _hhd_rgb_children(mode)
				if ch.has("brightness"):
					return _hhd_rgb_set(mode, {"brightness": _snap(ch["brightness"], pct)})
				if ch.has("brightnessd"):
					var opts := Hhd.options_of(ch["brightnessd"])
					return _hhd_rgb_set(mode, {"brightnessd": _ordinal(pct, opts if not opts.is_empty() else ["low", "medium", "high"])})
				return false
			# brightness only: on/off is the effect (enabled); a world-writable node (the
			# Claw's hid-msi) takes the exact value without root and without turning on
			if Leds.set_brightness_direct(be.leds(), pct):
				be.invalidate()
				return absf(Leds.brightness_pct(be.leds()[0]) - pct) <= 1.0
			if pct <= 0.0:
				return be.led_apply("off", func(ls): return Leds.brightness_pct(ls[0]) == 0.0 or Leds.effect_of(ls[0]) == "off")
			var n: Dictionary = be.leds()[0]
			var kern := Leds.kernel_effect(n, Leds.effect_of(n))
			var spec := Leds.spec("all", Leds.color_of(n), pct, kern)
			return be.led_apply(spec, func(ls): return absf(Leds.brightness_pct(ls[0]) - pct) <= 1.0))


func _led_speed() -> RefCounted:
	return _make({"id": "controller.led_speed", "title": "Effect speed", "kind": "slider",
		"min_value": 0.0, "max_value": 100.0, "step": 10.0, "unit": "%", "default_value": 50.0, "apply_order": 2,
		"requires": ["controller.led_effect"], "help": "For pulse, rainbow and other moving effects."},
		func(_c):
			var b := _rgb_block()
			if b != "":
				return b
			if be.rgb_backend() == "hhd":
				for m in _hhd_rgb_modes():
					var ch := _hhd_rgb_children(str(m))
					if ch.has("speed") or ch.has("speedd"):
						return ""
				return "This handheld's effects have a fixed speed"
			var n0: Dictionary = be.leds()[0]
			if Leds.speed_pct(n0) < 0.0:
				return "This handheld's effects have a fixed speed"
			# speed is 0644 root on hid-msi: only the root action can set it
			if not Leds.writable(str(n0["path"]) + "/speed") and not FileAccess.file_exists(str(ctx.get("sys_root", "")) + FIX_SET_HELPER):
				return R_LED_HELPER
			return "",
		func(_c):
			if be.rgb_backend() == "hhd":
				var cur: Variant = Hhd.dig(be.hhd_state(), ["rgb", "handheld", "mode", _hhd_rgb_mode()])
				if cur is Dictionary and cur.get("speed") != null:
					return float(cur["speed"])
				if cur is Dictionary and cur.get("speedd") is String:
					return float(ORDINAL_PCT.get(cur["speedd"], 66.0))
				return null
			var s := Leds.speed_pct(be.leds()[0])
			return s if s >= 0.0 else null,
		func(_c, v):
			if be.rgb_backend() == "hhd":
				var mode := _hhd_rgb_mode()
				var ch := _hhd_rgb_children(mode)
				if ch.has("speed"):
					return _hhd_rgb_set(mode, {"speed": _snap(ch["speed"], float(v))})
				if ch.has("speedd"):
					var opts := Hhd.options_of(ch["speedd"])
					return _hhd_rgb_set(mode, {"speedd": _ordinal(float(v), opts if not opts.is_empty() else ["low", "medium", "high"])})
				return false   # the current effect doesn't move
			var n: Dictionary = be.leds()[0]
			var eff := Leds.effect_of(n)
			var kern := Leds.kernel_effect(n, eff)
			if kern == "" or eff in ["off", "solid"]:
				return false
			var spec := Leds.spec("all", Leds.color_of(n), Leds.brightness_pct(n), kern, float(v))
			return be.led_apply(spec, func(ls): return absf(Leds.speed_pct(ls[0]) - float(v)) <= 5.0))


# ---- reset ---------------------------------------------------------------------------------

func _reset_layout() -> RefCounted:
	return _make({"id": "controller.reset_layout", "title": "Reset controller layout", "kind": "action", "per_game": false,
		"help": "Removes GameCove's button, gyro, trackpad and controller-type changes."},
		func(_c): return "" if be.controller_backend() == "inputplumber" else (R_IP_ONLY if be.controller_backend() == "hhd" else R_NONE),
		func(_c): return null,
		func(_c, _v): return be.ip_apply(func(p): return IpEdit.reset(p),
			func(p): return not _mapping_has_ours(p)))


static func _mapping_has_ours(p: Dictionary) -> bool:
	var m: Variant = p.get("mapping")
	return m is Array and (m as Array).any(func(x): return x is Dictionary and str(x.get("name", "")).begins_with("GameCove"))
