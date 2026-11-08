extends RefCounted
## Every user-visible word about settings and game info lives here, so each
## control has exactly one plain line saying what it does and what it costs.

# ------------------------------------------------------------ settings

const GOALS := ["battery", "balanced", "smooth"]
const GOAL_LABELS := {"battery": "Longest battery", "balanced": "Balanced", "smooth": "Smoothest"}

## What each quick goal sets. Low latency is left alone: it's a feel choice.
const GOAL_PRESETS := {
	"battery": {"fps_limit": 30, "upscaler": "auto", "frame_gen": false},
	"balanced": {"fps_limit": 60, "upscaler": "auto", "frame_gen": false},
	"smooth": {"fps_limit": 0, "upscaler": "auto", "frame_gen": true},
}
## Power profile names to try for each goal, first match wins.
const GOAL_PROFILES := {
	"battery": ["battery", "power-saver", "low-power", "quiet"],
	"balanced": ["balanced"],
	"smooth": ["performance", "turbo"],
}

const FPS_LIMITS := [0, 30, 40, 45, 60, 90, 120]
const UPSCALERS := ["auto", "off", "fsr", "xess"]
const UPSCALER_LABELS := {"auto": "Auto", "off": "Off", "fsr": "FSR", "xess": "XeSS"}
const CHARGE_LIMITS := [60, 70, 80, 90, 100]
const REFRESH_RATES := [30, 40, 45, 48, 50, 60, 72, 90, 100, 120, 144]

const TITLES := {
	"goal": "Quick goal",
	"fps_limit": "Frame rate limit",
	"upscaler": "Upscaler",
	"frame_gen": "Frame generation",
	"low_latency": "Low latency",
	"profile": "Power profile",
	"tdp": "Power limit (TDP)",
	"charge_limit": "Charge limit",
	"fan": "Fan",
	"refresh": "Refresh rate",
	"screen_fps": "Frame rate limit",
	"claw8ex-gyro-accel": "Accelerometer",
}

## One line each: what it does, then what it costs.
const EXPLAIN := {
	"goal": "Sets frame rate, upscaling and frame generation in one go.",
	"fps_limit": "Stops the game drawing more frames than this. Lower saves battery and heat; too low feels choppy.",
	"upscaler": "Renders at a lower resolution and sharpens it back up. More fps and battery; the picture gets a little softer.",
	"frame_gen": "Adds generated frames between real ones so motion looks smoother. Adds a little input lag; needs about 40 fps to feel right.",
	"low_latency": "Keeps fewer frames waiting in line so controls feel snappier. Can cost a few fps.",
	"profile": "The system's preset power levels. Higher profiles run faster and drain the battery faster.",
	"tdp": "How many watts the chip may use. More watts: more fps, more heat and fan noise, shorter battery.",
	"charge_limit": "Stops charging at this level to slow battery wear. Costs some time away from the charger.",
	"fan": "How hard the fan works. Quiet runs warmer and may slow the chip; Max is loud but coolest.",
	"refresh": "How often the screen redraws. Lower saves battery; higher feels smoother.",
	"screen_fps": "Caps the frame rate of whatever is running right now. Lower saves battery; too low feels choppy.",
	"claw8ex-gyro-accel": "Off gives steadier aiming. On adds the tilt sensor too, for games that want it. Asks for your admin password.",
}

## Value-specific lines that replace the general one when that value is picked.
const EXPLAIN_VALUE := {
	"goal": {
		"battery": "Caps at 30 fps and upscales to stretch play time. Costs smoothness.",
		"balanced": "Caps at 60 fps: steady play with decent battery life.",
		"smooth": "No cap, frame generation on. Smoothest picture; costs battery and adds a little input lag.",
	},
	"upscaler": {
		"auto": "Picks the best upscaler for this chip. More fps; the picture gets a little softer.",
		"off": "Full resolution. Sharpest picture; costs the most power.",
		"fsr": "AMD FSR, works on any GPU. More fps; can shimmer on fine detail.",
		"xess": "Intel XeSS, best on Intel Arc. More fps; a small cost in sharpness.",
	},
}

const NOT_AVAILABLE := "Not available on this device yet"

# ------------------------------------------------------------ device fixes

## Fixes from devices.json "fixes" that the Device section lists, by folder
## name under fixes/. Fan and charge limit live in Power, so they're not here.
const DEVICE_FIXES := {
	"claw8ex-buttons": {
		"title": "MSI buttons",
		"explain": "Makes the two MSI buttons next to the screen work: left opens the Steam menu, right opens Quick Access. Also sets up the M1 / M2 back buttons.",
		"after": "Works right away, no restart.",
	},
	"claw8ex-vrr": {
		"title": "Smooth screen down to 30 fps",
		"explain": "VRR (variable refresh rate) makes the screen wait for each new frame, so games stay smooth when fps drops. Out of the box it stops working under 48 fps; this takes it down to 30.",
		"after": "Needs a restart to kick in.",
	},
	"claw8ex-gyro": {
		"title": "Gyro aiming",
		"explain": "Turns on the motion sensor so you can aim by tilting the Claw, in games that support gyro through Steam. Downloads the sensor's firmware straight from MSI.",
		"after": "Needs a cold boot: shut down fully, then turn it back on.",
	},
}
const HIDDEN_FIXES := ["fan", "charge-limit"]

const FIXES_HEADER := "Device fixes"
const FIXES_INTRO := "Fixes for things that don't work out of the box on this handheld. Install and Remove ask for your admin password, and every change can be undone."

## What the helper's `state=` means, in words.
const FIX_STATES := {
	"on": "On",
	"off": "Off",
	"restart": "Restart needed",
	"partial": "Partly working",
	"not-needed": "Not needed",
	"unsupported": "Not supported here",
	"other-override": "Another fix is in place",
	"n/a": "Doesn't apply",
	"checking": "Checking…",
	"working": "Working…",
	"unknown": "Couldn't check",
}
## Shown under the explanation for states where you can't install.
const FIX_STATE_NOTES := {
	"not-needed": "This system already handles it, so there's nothing to fix.",
	"unsupported": "Your screen isn't one we've checked, so we won't touch it.",
	"other-override": "Something else already changed this setting. Remove that first if you want ours.",
	"n/a": "This fix isn't for this exact model.",
	"unknown": "The fix helper didn't answer. Is GameCove fully installed?",
}

const STEAM_TITLE := "Switch to Steam Gaming Mode"
const STEAM_EXPLAIN := "Closes GameCove and starts Steam's own full-screen mode. Save first: anything running here closes."
const STEAM_CONFIRM := "Press again to switch"
const STEAM_CONFIRM_LINE := "Sure? Press A again to switch to Steam, or move away to cancel."
const STEAM_SWITCHING := "Switching to Steam…"
const STEAM_FAILED := "Couldn't start the switch to Steam. Is gamecove-session-select installed?"
const NO_PASSWORD := "No admin password given, so nothing changed."
## Gaming Mode has no password prompt, so installs and removes need the desktop.
const NEEDS_DESKTOP := "Nothing changed: this needs your admin password, and Gaming Mode can't ask for it. Switch to Desktop Mode, open GameCove there and try again."
const ASKS_PASSWORD := "Enter your admin password if asked."


static func fix_working(fix: String, verb: String) -> String:
	return "%s %s… enter your admin password if asked (Desktop Mode only)." % ["Installing" if verb == "install" else "Removing", fix_title(fix).to_lower()]


static func accel_result(on: bool, ok: bool, code: int) -> String:
	if ok:
		return "Accelerometer %s. Recalibrate the gyro in Steam's controller settings." % ("on" if on else "off")
	if code == 126 or code == 127:
		return NO_PASSWORD
	return "Couldn't change the accelerometer; it kept its old setting."


static func fix_title(fix: String) -> String:
	return DEVICE_FIXES.get(fix, {}).get("title", fix.capitalize())


static func fix_explain(fix: String) -> String:
	var d: Dictionary = DEVICE_FIXES.get(fix, {})
	if d.is_empty():
		return "A fix for this device from GameCove's fixes folder."
	return "%s %s" % [d["explain"], d["after"]]


static func fix_state(state: String, fix := "") -> String:
	if state == "restart" and fix == "claw8ex-gyro":
		return "Cold boot needed"
	return FIX_STATES.get(state, state.capitalize())


## The line after Install / Remove finishes (`ok` false: it failed with `code`).
static func fix_result(fix: String, verb: String, ok: bool, code: int, detail := "") -> String:
	var title := fix_title(fix)
	if ok:
		if verb == "install":
			return "%s installed. %s" % [title, DEVICE_FIXES.get(fix, {}).get("after", "")]
		return "%s removed.%s" % [title, "" if fix == "claw8ex-buttons" else " Restart to finish."]
	if code == 126 or code == 127:
		return NEEDS_DESKTOP
	return "Couldn't %s %s%s." % [verb, title.to_lower(), ": " + detail if detail != "" else ""]


static func explain(setting: String, value: Variant = null) -> String:
	var per: Dictionary = EXPLAIN_VALUE.get(setting, {})
	if value != null and per.has(value):
		return per[value]
	return EXPLAIN.get(setting, "")


static func fps_label(fps: int) -> String:
	return "No limit" if fps <= 0 else "%d fps" % fps


static func charge_label(pct: int) -> String:
	return "Off (charge to 100%)" if pct >= 100 else "%d%%" % pct


## Settings after picking a quick goal: the goal's preset over the old values.
static func apply_goal(settings: Dictionary, goal: String) -> Dictionary:
	var out := settings.duplicate()
	out["goal"] = goal
	out.merge(GOAL_PRESETS.get(goal, {}), true)
	return out


## The power profile that matches a goal, or "" if this device has none.
static func goal_profile(goal: String, profiles: Array) -> String:
	for name in GOAL_PROFILES.get(goal, []):
		if name in profiles:
			return name
	return ""


## Refresh rates this panel can do, from its [min, max] Hz in devices.json.
static func refresh_rates(panel_hz: Array) -> Array:
	if panel_hz.size() != 2:
		return []
	var out := REFRESH_RATES.filter(func(hz): return hz >= panel_hz[0] and hz <= panel_hz[1])
	for hz in panel_hz:
		if int(hz) not in out:
			out.append(int(hz))
	out.sort()
	return out


# ------------------------------------------------------------ game info

static func format_hours(h: Variant) -> String:
	if h == null or float(h) <= 0.0:
		return "—"
	var f := float(h)
	if f < 10.0 and not is_equal_approx(f, roundf(f)):
		return "%.1f h" % f
	return "%d h" % roundi(f)


## Short time-to-beat badge for tiles ("12 h"), "" when unknown.
static func ttb_badge(info: Dictionary) -> String:
	var t: Variant = info.get("time_to_beat")
	if typeof(t) != TYPE_DICTIONARY:
		return ""
	for k in ["main_h", "extra_h", "complete_h"]:
		if t.get(k) != null and float(t[k]) > 0.0:
			return format_hours(t[k])
	return ""


## {"text": String, "tone": "good|warn|bad"}, or {} when there's nothing to say.
static func anticheat_badge(info: Dictionary) -> Dictionary:
	var a: Variant = info.get("anticheat")
	if typeof(a) != TYPE_DICTIONARY:
		return {}
	match a.get("status", "unknown"):
		"works":
			return {"text": "Anti-cheat OK", "tone": "good"}
		"blocked":
			return {"text": "Anti-cheat blocked", "tone": "warn"}
		"denied":
			return {"text": "Linux denied", "tone": "bad"}
	return {}


static func ttb_line(info: Dictionary) -> String:
	var t: Variant = info.get("time_to_beat")
	if typeof(t) != TYPE_DICTIONARY:
		return "Time to beat: no data yet"
	var line := "Main story %s  ·  Main + extras %s  ·  100%% %s" % [
		format_hours(t.get("main_h")), format_hours(t.get("extra_h")), format_hours(t.get("complete_h"))]
	var n := int(t.get("count", 0)) if t.get("count") != null else 0
	if n > 0:
		line += "  ·  from %d %s" % [n, "player" if n == 1 else "players"]
	return line


static func anticheat_line(info: Dictionary) -> String:
	var a: Variant = info.get("anticheat")
	if typeof(a) != TYPE_DICTIONARY:
		return "Anti-cheat: none listed"
	var names: Array = a.get("anticheats", [])
	var which := " (%s)" % ", ".join(names) if not names.is_empty() else ""
	match a.get("status", "unknown"):
		"works":
			return "Anti-cheat%s works on Linux." % which
		"blocked":
			return "Anti-cheat%s doesn't allow Linux yet. Online play may not work." % which
		"denied":
			return "Anti-cheat%s: the developer blocks Linux. Online play won't work here." % which
	return "Anti-cheat%s: no reports yet." % which


const PROTONDB := {
	"platinum": "runs perfectly out of the box",
	"gold": "runs perfectly after small tweaks",
	"silver": "runs with minor issues",
	"bronze": "runs, but with real problems",
	"borked": "doesn't start or isn't playable",
}


static func protondb_line(info: Dictionary) -> String:
	var tier: Variant = info.get("protondb")
	if tier == null or not PROTONDB.has(tier):
		return "ProtonDB: no rating yet"
	return "ProtonDB %s: %s" % [String(tier).capitalize(), PROTONDB[tier]]


static func last_played_text(ts: int, now: int) -> String:
	if ts <= 0:
		return "Not played yet"
	var days := int((now - ts) / 86400)
	if days <= 0:
		return "Played today"
	if days == 1:
		return "Played yesterday"
	if days < 30:
		return "Played %d days ago" % days
	return "Played %s" % Time.get_date_string_from_unix_time(ts)


static func playtime_text(minutes: int) -> String:
	if minutes <= 0:
		return ""
	if minutes < 60:
		return "%d min played" % minutes
	return "%s played" % format_hours(minutes / 60.0)
