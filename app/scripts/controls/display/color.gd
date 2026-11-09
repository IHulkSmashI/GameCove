extends RefCounted
## Colour maths for gamescope's colour atoms.

## 6500 K is the panel's own white (D65): no override.
const NEUTRAL_K := 6500
## Night light tint: an orange hue, like Steam's night mode. gamescope multiplies
## the output by HSV(hue, saturation * amount, 1) in linear light
## (src/color_helpers.cpp, calcColorTransform).
const NIGHT_HUE := 0.07
const NIGHT_SATURATION := 0.6


## CIE 1931 xy of daylight at `kelvin` (4000-25000 K), the CIE D-series
## formula; 6504 K gives D65 (0.3127, 0.3291).
static func kelvin_to_xy(kelvin: float) -> Vector2:
	var t := clampf(kelvin, 4000.0, 25000.0)
	var x: float
	if t <= 7000.0:
		x = -4.6070e9 / pow(t, 3) + 2.9678e6 / pow(t, 2) + 0.09911e3 / t + 0.244063
	else:
		x = -2.0064e9 / pow(t, 3) + 1.9018e6 / pow(t, 2) + 0.24748e3 / t + 0.237040
	var y := -3.0 * x * x + 2.870 * x - 0.275
	return Vector2(x, y)


## The value for GAMESCOPE_COLOR_NIGHT_MODE: [amount, hue, saturation].
static func night_mode(strength_pct: float) -> Array:
	var a := clampf(strength_pct / 100.0, 0.0, 1.0)
	if a <= 0.0:
		return [0.0, 0.0, 0.0]
	return [a, NIGHT_HUE, NIGHT_SATURATION]


## Night light schedules: [start minute, end minute] of the day.
const SCHEDULES := {"evening": [20 * 60, 7 * 60], "night": [22 * 60, 6 * 60]}


## Whether a schedule wants night light on at minute-of-day `m`.
static func night_due(schedule: String, m: int) -> bool:
	if not SCHEDULES.has(schedule):
		return false
	var s: int = SCHEDULES[schedule][0]
	var e: int = SCHEDULES[schedule][1]
	return (m >= s or m < e) if s > e else (m >= s and m < e)


## Seconds from minute-of-day `m` (and second `sec`) to the schedule's next
## switch, for one one-shot timer (nothing polls). -1 without a schedule.
static func seconds_to_next_switch(schedule: String, m: int, sec := 0) -> int:
	if not SCHEDULES.has(schedule):
		return -1
	var best := 24 * 3600
	for edge in SCHEDULES[schedule]:
		var d: int = (int(edge) - m) * 60 - sec
		if d <= 0:
			d += 24 * 3600
		best = mini(best, d)
	return best
