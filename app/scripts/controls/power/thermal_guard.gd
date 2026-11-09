extends RefCounted
## Temperature guard for the time thermald is held (ported from ClawDeck thermal.py, same author,
## GPL-3.0; ClawDeck docs/HARDWARE-FINDINGS.md §21). On Intel, thermald puts the firmware's power
## limits back every few seconds, so Power holds it (power-tune thermald:hold) while GameCove sets
## a TDP below the firmware's. That also takes away thermald's own temperature control, so while
## it is held Power reads the package temperature every CHECK_S seconds and calls check():
##   above TRIP_C    -> trips: the TDP steps down STEP_W
##   while tripped   -> another STEP_W per check until under CLEAR_C, never below the floor
##   stepped, cool   -> under RECOVER_C for RECOVER_CHECKS checks in a row: +STEP_W back toward
##                      your limit, again every RECOVER_CHECKS checks, until it is back at it
## The SoC's own limit (TCC) and the EC's fan control stay active the whole time. Pure logic:
## the caller reads the temperature and applies the watts.

const TRIP_C := 95.0
const CLEAR_C := 90.0
const STEP_W := 2
const CHECK_S := 10.0
const RECOVER_C := 80.0
const RECOVER_CHECKS := 3

var tripped := false
var stepped_w := -1     # the TDP the guard brought it down to (-1: not stepped)
var temp_c := -1.0
var cool := 0


## One check. Returns the watts it stepped to (down or back up), or -1 when it left the TDP alone.
## set_tdp / raise_tdp: Callable(watts: int) -> bool; limit_w: your limit (-1 = don't step back up).
func check(t: float, current_w: int, floor_w: int, set_tdp: Callable, limit_w := -1, raise_tdp: Callable = Callable()) -> int:
	temp_c = t
	if t < 0.0 or current_w < 0:
		return -1
	if not tripped:
		if t <= TRIP_C:
			return _recover(t, current_w, limit_w, raise_tdp if raise_tdp.is_valid() else set_tdp)
		tripped = true
	if t < CLEAR_C:
		tripped = false
		return -1
	var w := maxi(floor_w, current_w - STEP_W)
	if w >= current_w:
		return -1
	if not bool(set_tdp.call(w)):
		return -1
	stepped_w = w
	cool = 0
	return w


func _recover(t: float, current_w: int, limit_w: int, up: Callable) -> int:
	if stepped_w < 0 or limit_w < 0:
		return -1
	if t >= RECOVER_C:
		cool = 0
		return -1
	cool += 1
	if cool < RECOVER_CHECKS:
		return -1
	cool = 0
	var w := mini(limit_w, maxi(current_w, stepped_w) + STEP_W)
	if not bool(up.call(w)):
		return -1
	stepped_w = -1 if w >= limit_w else w
	return w


## The user set a TDP, or the power was reverted: the step no longer applies.
func reset() -> void:
	tripped = false
	stepped_w = -1
	cool = 0


func status() -> Dictionary:
	return {"temp_c": temp_c, "tripped": tripped, "stepped_w": stepped_w}
