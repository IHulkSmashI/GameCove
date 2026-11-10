extends Node
## "Sleep at low battery": on battery at or below the level the user picked (Power >
## Battery, power.low_battery_sleep / power.low_battery_sleep_at, off by default), asks for a
## 30 s warning (main.gd shows ui/low_battery_dialog.gd over whatever is in front); when
## nobody presses a button, the handheld sleeps (`systemctl suspend`, logind).
## Driven by Power's existing 15 s check (its battery_level and source_changed signals): no
## timer of its own. Pressing a button (or waking it up again) holds the warning off until the
## level drops REWARN_DROP more, the charger goes in or the level climbs back above the line,
## so it doesn't nag at every percent.

signal warn_requested(percent: int)
## The charger went in while the warning showed: close it.
signal warn_cancelled
## About to sleep (battery history records it first).
signal sleeping

## Percent the battery must drop after a cancel (or a wake) before the warning comes back.
const REWARN_DROP := 2

## func() -> {"on": bool, "at": int} (the two controls; tests swap it).
var settings: Callable = func() -> Dictionary: return {"on": false, "at": 5}
## func() -> bool: on the charger now.
var plugged_now: Callable = func() -> bool: return false
## func() -> void: puts the handheld to sleep (tests swap it).
## Started and left (OS.create_process passes argv untouched): no worker task that
## the app's exit would have to wait for.
var suspend: Callable = func() -> void:
	OS.create_process("systemctl", PackedStringArray(["suspend"]))

var warning := false
var suppressed := false
var _pct := -1
var _held_at := -1   # the level when the warning was held off


## Power: its level and charger events; controls: the registry the two settings live in.
func setup(power: Object, controls: Object) -> void:
	if controls != null and controls.has_method("value"):
		settings = func() -> Dictionary:
			var on: Variant = controls.value("power.low_battery_sleep")
			var at: Variant = controls.value("power.low_battery_sleep_at")
			return {"on": on == true, "at": int(at) if at != null else 5}
	if power == null:
		return
	if "plugged" in power:
		plugged_now = func() -> bool: return bool(power.plugged)
	if power.has_signal("battery_level"):
		power.battery_level.connect(on_level)
	if power.has_signal("source_changed"):
		power.source_changed.connect(on_source)
	if power.has_method("battery_percent"):
		_pct = int(power.battery_percent())


static func should_warn(pct: int, plugged: bool, on: bool, at: int, held_off: bool, showing: bool) -> bool:
	return on and not plugged and pct >= 0 and pct <= clampi(at, 3, 10) and not held_off and not showing


func on_level(pct: int, plugged: bool) -> void:
	_pct = pct
	var s: Dictionary = settings.call()
	if pct > int(s.get("at", 5)) or (suppressed and _held_at >= 0 and pct <= _held_at - REWARN_DROP):
		suppressed = false
	_check(plugged)


func on_source(plugged: bool) -> void:
	if plugged:
		suppressed = false
		if warning:
			warning = false
			warn_cancelled.emit()
		return
	_check(false)


func _check(plugged: bool) -> void:
	var s: Dictionary = settings.call()
	if should_warn(_pct, plugged, bool(s.get("on", false)), int(s.get("at", 5)), suppressed, warning):
		warning = true
		warn_requested.emit(_pct)


## A button was pressed during the warning: stay awake.
func cancel() -> void:
	warning = false
	suppressed = true
	_held_at = _pct


## The warning ran out: sleep, unless the charger came in meanwhile.
func confirm() -> void:
	warning = false
	if plugged_now.call():
		return
	suppressed = true   # after the wake, the same low level shouldn't put it straight back to sleep
	_held_at = _pct
	sleeping.emit()
	suspend.call()
