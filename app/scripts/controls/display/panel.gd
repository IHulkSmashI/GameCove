extends RefCounted
## What this device's screen can do, from its devices.json row (via ctx.device)
## plus what the gamescope session tells us. Pure functions: tests pass rows.

## Panels gamescope already knows the refresh rates of: it ships a display
## script for them (ValveSoftware/gamescope scripts/00-gamescope/displays/*.lua,
## 89b9e6e: valve.steamdeck.lcd/oled, asus.rogally.lcd, asus.rogallyx20.oled,
## gpd.win4.lcd, lenovo.legiongo.lcd, lenovo.legiongo2.oled,
## lenovo.legiongos.lcd, onexplayer.f1.oled, zotac.zone.oled). Only rows whose
## panel is the one those scripts match (same maker, size and resolution).
const GAMESCOPE_KNOWN_REFRESH := [
	"steam-deck-lcd", "steam-deck-oled", "asus-rog-ally", "asus-rog-ally-x", "asus-rog-xbox-ally-x20",
	"gpd-win-4", "lenovo-legion-go", "lenovo-legion-go-2", "lenovo-legion-go-2-z2",
	"lenovo-legion-go-s-z2go", "lenovo-legion-go-s-z1e", "onexplayer-onexfly-f1", "zotac-zone",
]

## Screens where gamescope drives the panel in HDR10 and the backlight does
## nothing, so brightness is gamescope's SDR-on-HDR level (ClawDeck screen.py,
## OXP3 owners' reports 2026-10).
const SOFTWARE_BRIGHTNESS := ["onexplayer-3"]

## Screens that ignore the backlight only while gamescope outputs PQ (HDR):
## Legion Go 2's Samsung AMS881KB01-0 OLED is driven over eDP AUX luminance in
## PQ, so writes to amdgpu_bl0 do nothing and brightness has to be the
## SDR-on-HDR level (Rayekkk/LeGo2BrightnessFix, release notes v1.0.0-v2.0.0;
## gamescope publishes PQ output as GAMESCOPE_HDR_OUTPUT_FEEDBACK = 1). The same
## plugin found gamescope drops that level after suspend or a session restart,
## so it's re-applied from the saved value when read (display.gd).
const SOFTWARE_BRIGHTNESS_IN_PQ := ["lenovo-legion-go-2", "lenovo-legion-go-2-z2"]

## Screens where switching HDR on/off at runtime is unsafe, with the reason
## shown. ONEXPLAYER 3: the screen stays off until a long power press or a
## second reboot (ClawDeck screen.py, reported by owners 2026-10).
const HDR_SWITCH_BLOCKED := {
	"onexplayer-3": "Switching HDR can turn this screen off until a reboot",
}

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
