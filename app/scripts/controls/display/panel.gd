extends RefCounted
## What this device's screen can do, from its devices.json row (via ctx.device)
## plus what the gamescope session tells us. Pure functions: tests pass rows.

const Traits := preload("res://scripts/device/traits.gd")

## What each screen needs comes from app/data/quirks.json, keyed by the panel and
## session traits in devices.json (not model ids), so a sibling with the same
## panel gets the same handling:
## - gamescope-known-refresh: gamescope ships a display script for this panel
##   (ValveSoftware/gamescope scripts/00-gamescope/displays/*.lua, 89b9e6e;
##   traits.panel.gamescope), so it switches refresh itself.
## - session-refresh-switching: gamescope-session-plus device-quirks sets
##   CUSTOM_REFRESH_RATES for this block (ONEXPLAYER X1 A / X1 i / X1 mini, G1).
## - software-brightness-hdr: gamescope drives the panel in HDR10 and the
##   backlight does nothing, so brightness is gamescope's SDR-on-HDR level
##   (ClawDeck screen.py, OXP 3 owners 2026-10).
## - software-brightness-in-pq: the backlight is ignored only while gamescope
##   outputs PQ: Legion Go 2's Samsung AMS881KB01-0 OLED (Rayekkk/LeGo2BrightnessFix
##   v1.0.0-v2.0.0); gamescope drops the level after suspend, so display.gd
##   re-applies it from the saved value.
## - hdr-switch-blocked: switching HDR at runtime is unsafe (its "reason" is shown).


static func gamescope_knows_refresh(r: Dictionary) -> bool:
	return Traits.has_quirk("gamescope-known-refresh", r)


static func session_switches_refresh(r: Dictionary) -> bool:
	return Traits.has_quirk("session-refresh-switching", r)


static func software_brightness(r: Dictionary) -> bool:
	return Traits.has_quirk("software-brightness-hdr", r)


static func software_brightness_in_pq(r: Dictionary) -> bool:
	return Traits.has_quirk("software-brightness-in-pq", r)


## "" when switching HDR is fine here, else the reason to show.
static func hdr_switch_blocked(r: Dictionary) -> String:
	return str(Traits.quirk("hdr-switch-blocked").get("reason", "")) if Traits.has_quirk("hdr-switch-blocked", r) else ""

## Never dim the backlight below this (some panels go fully black at 0).
const MIN_BRIGHTNESS_PCT := 5.0


## The devices.json row behind ctx.device: a Device node (its `profile`), a row
## Dictionary, or {"profile": row}. {} when unknown.
static func row(ctx: Dictionary) -> Dictionary:
	var d = ctx.get("device")
	if d is Dictionary:
		if d.has("profile") and d["profile"] is Dictionary:
			return d["profile"]
		return d
	if d is Object and is_instance_valid(d) and "profile" in d and d.profile is Dictionary:
		return d.profile
	return {}


static func device_id(ctx: Dictionary) -> String:
	return str(row(ctx).get("id", "unknown"))


## [min, max] Hz the panel runs at. The session's STEAM_DISPLAY_REFRESH_LIMITS
## (gamescope-session-plus device-quirks exports it) wins over the table.
## [] when unknown.
static func hz_range(r: Dictionary, session_limits := "") -> Array:
	var lim := _two_ints(session_limits)
	if lim.size() == 2 and lim[0] > 0 and lim[1] >= lim[0]:
		return lim
	var hz = r.get("panel_hz")
	if hz is Array and hz.size() == 2 and int(hz[0]) > 0 and int(hz[1]) >= int(hz[0]):
		return [int(hz[0]), int(hz[1])]
	return []


static func vrr_range(r: Dictionary) -> Array:
	var v = r.get("vrr_range")
	if v is Array and v.size() == 2:
		return [int(v[0]), int(v[1])]
	return []


## OLED panels are wide-gamut: gamescope's SDR gamut "native" end is 1.0 there.
static func wide_gamut(r: Dictionary) -> bool:
	var p = r.get("panel")
	return p is Dictionary and str(p.get("type", "")).to_upper() == "OLED"


static func is_generic(r: Dictionary) -> bool:
	return r.is_empty() or str(r.get("tier", "generic")) == "generic"


## Rates to list in CUSTOM_REFRESH_RATES for this panel. A panel with a VRR
## range accepts every whole rate inside it as a fixed mode; one without only
## gets its two ends (the modes it already has), so nothing can blank it.
static func custom_rates(r: Dictionary) -> Array:
	var hz := hz_range(r)
	if hz.is_empty() or hz[0] == hz[1]:
		return []
	var vrr := vrr_range(r)
	if vrr.is_empty():
		return [hz[0], hz[1]]
	var lo := maxi(hz[0], vrr[0])
	var hi := mini(hz[1], vrr[1])
	var out := []
	for i in range(lo, hi + 1):
		out.append(i)
	if not out.has(hz[1]):
		out.append(hz[1])
	return out


## Frame-limit choices: whole fractions of the top rate plus the usual caps.
static func fps_choices(max_hz: int) -> Array:
	var vals := {}
	for n in range(1, 9):
		if max_hz % n == 0 and max_hz / n >= 15:
			vals[max_hz / n] = true
	for v in [15, 20, 24, 30, 36, 40, 45, 48, 50, 60, 72, 90, 100, 120, 144]:
		if v <= max_hz:
			vals[v] = true
	var out := vals.keys()
	out.sort()
	return out


static func _two_ints(s: String) -> Array:
	var parts := s.split(",")
	if parts.size() != 2 or not parts[0].strip_edges().is_valid_int() or not parts[1].strip_edges().is_valid_int():
		return []
	return [parts[0].strip_edges().to_int(), parts[1].strip_edges().to_int()]
