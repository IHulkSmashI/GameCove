extends VBoxContainer
## The "Battery history" card's body (About this device): battery level over the last 7
## days as one line (battery_log.gd samples: game starts and ends, sleep, wake, charger),
## charging stretches tinted under it, then "Drain per game": watts on battery and hours a
## full charge lasts, most drain first. Read-only; built from the BatteryLog given.

const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")


## The line chart: x = time (7 days to now), y = percent 0-100. Recessive grid at 0 / 50 /
## 100 and one tick per day; a 2 px accent line with small dots at each event.
class Chart extends Control:
	var points: Array = []      # [[unix, percent, event], ...] oldest first
	var start := 0
	var end := 0
	const LEFT := 44.0
	const BOTTOM := 26.0

	func _init() -> void:
		name = "Chart"
		custom_minimum_size = Vector2(0, 170)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_data(pts: Array, from: int, to: int) -> void:
		points = pts
		start = from
		end = maxi(to, from + 1)
		queue_redraw()

	func _xy(t: int, pct: int) -> Vector2:
		var w := size.x - LEFT - 8.0
		var h := size.y - BOTTOM - 8.0
		return Vector2(LEFT + w * clampf(float(t - start) / float(end - start), 0.0, 1.0), 8.0 + h * (1.0 - clampf(pct / 100.0, 0.0, 1.0)))

	func _draw() -> void:
		var font: Font = ThemeLib.font("regular")
		var fs := 12
		var grid: Color = ThemeLib.soft(0.10)
		var ink: Color = ThemeLib.color("text_3")
		for pct in [0, 50, 100]:
			var y := _xy(start, pct).y
			draw_line(Vector2(LEFT, y), Vector2(size.x - 8.0, y), grid, 1.0)
			draw_string(font, Vector2(0, y + 4), "%d%%" % pct, HORIZONTAL_ALIGNMENT_RIGHT, LEFT - 8.0, fs, ink)
		var day := 86400
		var first := (start / day + 1) * day
		var t := first
		while t < end:
			var x := _xy(t, 0).x
			draw_line(Vector2(x, 8.0), Vector2(x, size.y - BOTTOM), Color(grid, grid.a * 0.6), 1.0)
			var label := Time.get_date_string_from_unix_time(t + int(Time.get_time_zone_from_system().get("bias", 0)) * 60).substr(5)
			draw_string(font, Vector2(x - 20, size.y - 6.0), label, HORIZONTAL_ALIGNMENT_CENTER, 40, fs, ink)
			t += day
		if points.is_empty():
			return
		# charging: from a plug event to the next unplug (or now)
		var charge: Color = Color(ThemeLib.tone("good"), 0.10)
		var plugged_at := -1
		for p in points:
			if str(p[2]) == "plug":
				plugged_at = int(p[0])
			elif str(p[2]) == "unplug" and plugged_at >= 0:
				_band(plugged_at, int(p[0]), charge)
				plugged_at = -1
		if plugged_at >= 0:
			_band(plugged_at, end, charge)
		var line := PackedVector2Array()
		for p in points:
			line.append(_xy(int(p[0]), int(p[1])))
		var accent: Color = ThemeLib.color("accent")
		if line.size() >= 2:
			draw_polyline(line, accent, 2.0, true)
		for v in line:
			draw_circle(v, 3.0, accent)

	func _band(a: int, b: int, col: Color) -> void:
		var x0 := _xy(a, 100).x
		var x1 := _xy(b, 100).x
		draw_rect(Rect2(x0, 8.0, maxf(1.0, x1 - x0), size.y - BOTTOM - 8.0), col)


var chart: Chart
var empty_label: Label
var table: GridContainer
var drain_empty: Label


## history: a BatteryLog (series(), drain_table()); now: unix seconds.
func setup(history: Object, now: int) -> void:
	name = "BatteryHistory"
	add_theme_constant_override("separation", 10)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(Kit.label(TS.HISTORY_LINE, "QuietLabel", true))
	var pts: Array = history.series(TS.CHART_DAYS) if history != null else []
	chart = Chart.new()
	chart.set_data(pts, now - TS.CHART_DAYS * 86400, now)
	chart.visible = not pts.is_empty()
	add_child(chart)
	if not pts.is_empty():
		var key := Kit.hbox(8)
		key.name = "Key"
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(14, 10)
		sw.color = Color(ThemeLib.tone("good"), 0.35)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		key.add_child(sw)
		key.add_child(Kit.label(TS.CHARGING, "CaptionLabel"))
		add_child(key)
	empty_label = Kit.label(TS.HISTORY_EMPTY, "QuietLabel", true)
	empty_label.name = "Empty"
	empty_label.visible = pts.is_empty()
	add_child(empty_label)
	var head := Kit.label(TS.DRAIN_TITLE, "")
	head.add_theme_font_override("font", ThemeLib.font("semibold"))
	add_child(head)
	var rows: Array = history.drain_table() if history != null else []
	drain_empty = Kit.label(TS.DRAIN_EMPTY, "QuietLabel", true)
	drain_empty.name = "DrainEmpty"
	drain_empty.visible = rows.is_empty()
	add_child(drain_empty)
	table = GridContainer.new()
	table.name = "Drain"
	table.columns = 3
	table.add_theme_constant_override("h_separation", 18)
	table.add_theme_constant_override("v_separation", 6)
	table.visible = not rows.is_empty()
	add_child(table)
	if rows.is_empty():
		return
	for h in TS.DRAIN_HEAD:
		var l := Kit.micro(h)
		l.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		table.add_child(l)
	for r in rows.slice(0, 8):
		var t := Kit.label(str(r["title"]))
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		t.clip_text = true
		table.add_child(t)
		var w := Kit.label("%s W" % TS.watts(float(r["watts"])), "MonoLabel")
		w.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		table.add_child(w)
		var hrs := float(r.get("hours", -1.0))
		var hl := Kit.label(("~%s h" % TS.hours(hrs)) if hrs > 0.0 else "-", "MonoLabel")
		hl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		table.add_child(hl)
