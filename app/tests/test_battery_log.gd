extends "res://tests/test_case.gd"
## Battery history (scripts/system/battery_log.gd) on a fixture battery under user://:
## samples only at events, a game's drain from its time on battery (sleep and the charger
## cut it), "Drains about X W, ~Y h" once there's enough, pruning, and the About card.

const Log := preload("res://scripts/system/battery_log.gd")
const TS := preload("res://scripts/ui/texts_saves.gd")
const History := preload("res://scripts/ui/device/battery_history.gd")
const BASE := "user://test_battery_log"


func _rm(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm(path.path_join(sub))
	DirAccess.remove_absolute(path)


func _put(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text + "\n")
	f.close()


## A battery at `pct` with energy_now `wh` (full 50 Wh) and the charger in or out.
func _bat(w: Dictionary, pct: int, wh: float, plugged := false) -> void:
	var b: String = w["root"] + "/sys/class/power_supply/BAT0/"
	_put(b + "type", "Battery")
	_put(b + "capacity", str(pct))
	_put(b + "energy_now", str(int(wh * 1e6)))
	_put(b + "energy_full", "50000000")
	_put(w["root"] + "/sys/class/power_supply/ADP1/type", "Mains")
	_put(w["root"] + "/sys/class/power_supply/ADP1/online", "1" if plugged else "0")


func _world(name: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(root)
	var w := {"root": root, "now": [1800000000]}
	var l: Node = Log.new()
	l.path = root.path_join("battery_history.json")
	l.load_data()
	l.sys_root = root
	l.clock = func() -> int: return int(w["now"][0])
	w["log"] = l
	return w


func _done(w: Dictionary) -> void:
	w["log"].free()
	_rm(w["root"])
	w.clear()


func _at(w: Dictionary, secs: int) -> void:
	w["now"][0] = int(w["now"][0]) + secs


func test_a_game_on_battery_gets_its_drain() -> void:
	var w := _world("drain")
	var l: Node = w["log"]
	_bat(w, 80, 40.0)
	l.game_started({"key": "epic:Min", "title": "Minecraft Dungeons", "store": "epic"})
	eq(l.data["samples"].size(), 1, "one sample at the start")
	_at(w, 1800)
	_bat(w, 70, 35.0)
	l.game_ended({"key": "epic:Min"})
	eq(l.data["samples"].size(), 2, "one at the end; nothing in between")
	var d: Dictionary = l.drain_for("epic:Min")
	ok(absf(float(d["watts"]) - 10.0) < 0.01, "5 Wh in half an hour = 10 W")
	ok(absf(float(d["hours"]) - 5.0) < 0.01, "50 Wh full / 10 W = 5 h")
	eq(TS.drain_line(d), "Drains about 10 W, ~5.0 h on a full charge", "the game page line")
	eq(l.drain_for("epic:Other"), {}, "a game with no data: nothing shown")
	# stored and read back
	var again: Node = Log.new()
	again.path = l.path
	again.load_data()
	eq(int(again.data["games"]["epic:Min"]["s"]), 1800, "kept in the file")
	again.free()
	_done(w)


func test_not_enough_time_shows_nothing() -> void:
	var w := _world("short")
	var l: Node = w["log"]
	_bat(w, 80, 40.0)
	l.game_started({"key": "gog:1", "title": "G"})
	_at(w, 600)
	_bat(w, 78, 39.0)
	l.game_ended({"key": "gog:1"})
	eq(l.drain_for("gog:1"), {}, "10 minutes isn't enough to say")
	eq(l.data["games"]["gog:1"]["s"], 600, "but it counts toward it")
	_done(w)


func test_the_charger_and_sleep_cut_the_stretch() -> void:
	var w := _world("cuts")
	var l: Node = w["log"]
	_bat(w, 90, 45.0)
	l.game_started({"key": "steam:1", "title": "S"})
	_at(w, 900)
	_bat(w, 85, 42.0, true)
	l.record("plug")
	eq(l.data["games"]["steam:1"]["wh"], 3.0, "battery used up to the plug")
	_at(w, 900)
	_bat(w, 95, 47.0, true)
	l.record("unplug")   # the file still says plugged: no stretch opens
	eq(l.data["open"], {}, "on the charger: no stretch")
	_bat(w, 95, 47.0, false)
	l.record("unplug")
	eq(l.data["open"]["wh"], 47.0, "unplugged during the game: a stretch opens")
	# a sleep we only notice at the wake: closed at the last level before it
	_at(w, 600)
	l.note_level(93)
	var slept := int(w["now"][0]) + 60
	l.slept_at = func() -> int: return slept
	_at(w, 4000)
	_bat(w, 90, 45.0)
	l.note_level(90)   # Power reports the level after the wake first
	l.record("resume")
	var g: Dictionary = l.data["games"]["steam:1"]
	eq(g["s"], 900 + 600, "the sleep isn't counted")
	ok(absf(float(g["wh"]) - 4.0) < 0.01, "2 % of 50 Wh before the sleep: 3 + 1 Wh")
	eq(l.data["open"]["t"], int(w["now"][0]), "a new stretch from the wake")
	l.game_ended({"key": "steam:1"})
	_done(w)


## Final review (Medium): GameCove crashed or the handheld lost power mid-game. The
## stretch left open in the file must not be charged to that game days later.
func test_an_open_stretch_does_not_survive_a_crash() -> void:
	var w := _world("crash")
	var l: Node = w["log"]
	_bat(w, 90, 45.0)
	l.game_started({"key": "steam:1", "title": "S"})
	ok(not l.data["open"].is_empty(), "a stretch is open and saved")
	# no "end": the app is gone. Two days later it starts again and the charger goes in.
	var again: Node = Log.new()
	again.path = l.path
	again.sys_root = w["root"]
	again.clock = l.clock
	again.load_data()
	eq(again.data["open"], {}, "the stretch a crash left open is dropped at the start")
	_at(w, 2 * 86400)
	_bat(w, 20, 10.0, true)
	again.record("plug")
	ok(not again.data["games"].has("steam:1"), "two days of standby aren't charged to the game")
	# and the next game starts clean
	_bat(w, 80, 40.0)
	again.game_started({"key": "steam:2", "title": "T"})
	_at(w, 1800)
	_bat(w, 70, 35.0)
	again.game_ended({"key": "steam:2"})
	eq(again.data["games"]["steam:2"]["s"], 1800, "the next game counts as usual")
	again.free()
	_done(w)


func test_no_battery_no_history_and_old_samples_go() -> void:
	var w := _world("prune")
	var l: Node = w["log"]
	l.record("start")
	eq(l.data["samples"].size(), 0, "no battery: nothing kept")
	_bat(w, 50, 25.0)
	for i in 5:
		l.record("plug")
		_at(w, 10 * 86400)
	l.record("unplug")
	ok(l.data["samples"].size() <= 4, "samples older than 30 days pruned")
	eq(l.series(7).size(), 1, "the last 7 days for the chart")
	eq(l.series(7)[0][2], "unplug", "with the event")
	# charge_now x voltage_min_design when there's no energy_now
	var b: String = w["root"] + "/sys/class/power_supply/BAT0/"
	DirAccess.remove_absolute(b + "energy_now")
	DirAccess.remove_absolute(b + "energy_full")
	_put(b + "charge_now", "2000000")
	_put(b + "charge_full", "4000000")
	_put(b + "voltage_min_design", "11000000")
	var r: Dictionary = l.read()
	ok(absf(float(r["wh"]) - 22.0) < 0.01 and absf(float(r["full_wh"]) - 44.0) < 0.01, "Wh from charge x voltage")
	_done(w)


func test_streams_dont_count_as_games() -> void:
	var w := _world("stream")
	var l: Node = w["log"]
	_bat(w, 80, 40.0)
	l.game_started({"key": "stream:pc:1", "title": "Stream", "store": "stream"})
	eq(l.data["open"], {}, "a stream opens no stretch")
	l.game_ended({})
	_done(w)


func test_history_card_shows_chart_and_table() -> void:
	var w := _world("card")
	var l: Node = w["log"]
	_bat(w, 80, 40.0)
	l.game_started({"key": "epic:Min", "title": "Minecraft Dungeons"})
	_at(w, 3600)
	_bat(w, 60, 30.0)
	l.game_ended({"key": "epic:Min"})
	var card: VBoxContainer = History.new()
	card.setup(l, int(w["now"][0]))
	ok(card.chart.visible and card.chart.points.size() == 2, "a chart of the two samples")
	ok(card.table.visible and not card.drain_empty.visible, "the drain table")
	eq((card.table.get_child(3) as Label).text, "Minecraft Dungeons", "the game's row")
	eq((card.table.get_child(4) as Label).text, "10 W", "its drain")
	eq((card.table.get_child(5) as Label).text, "~5.0 h", "a full charge")
	card.free()
	var empty: VBoxContainer = History.new()
	var w2 := _world("card_empty")
	empty.setup(w2["log"], int(w2["now"][0]))
	ok(empty.empty_label.visible and not empty.chart.visible, "nothing yet: says so")
	ok(empty.drain_empty.visible, "no games yet: says when they show up")
	empty.free()
	_done(w2)
	_done(w)
