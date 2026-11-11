extends "res://tests/e2e/e2e_case.gd"
## Cloud saves and Sleep at low battery in the running app: an Epic game's launch waits
## for its cloud save (legendary faked), a conflict asks first and B starts nothing, the
## game's end uploads, Settings has a Saves page, and a low battery on battery shows the
## 30 s warning any button cancels.

const TSaves := preload("res://scripts/ui/texts_saves.gd")
const EPIC := {"key": "epic:Min", "title": "Minecraft Dungeons", "store": "epic", "id": "Min", "installed": true,
	"art": {"cover": "", "hero": "", "logo": "", "icon": ""}, "info": {}}


## Fakes the store tools behind CloudSaves: `look` is what legendary's look prints.
func _fake(look: String) -> Array:
	var calls: Array = []
	var dir: String = str(w.home) + "/.config/legendary"
	DirAccess.make_dir_recursive_absolute(dir + "/metadata")
	for f in [["user.json", "{}"], ["metadata/Min.json", JSON.stringify({"metadata": {"customAttributes": {"CloudSaveFolder": {"value": "{InstallDir}/s"}}}})],
			["installed.json", JSON.stringify({"Min": {"save_path": w.home + "/MinSaves"}})]]:
		var fa := FileAccess.open(dir + "/" + f[0], FileAccess.WRITE)
		fa.store_string(f[1])
		fa.close()
	# the save the fake legendary talks about is really there: a sync time is dropped for an
	# empty save folder (a deleted prefix), and the end of a game would then ask, not upload
	DirAccess.make_dir_recursive_absolute(str(w.home) + "/MinSaves")
	var sv := FileAccess.open(str(w.home) + "/MinSaves/world.sav", FileAccess.WRITE)
	sv.store_string("progress")
	sv.close()
	var s: Node = main().saves
	s.entry_lookup = func(_k: String) -> Dictionary: return EPIC.merged({"config_dir": dir, "platform": "Windows", "prefix": ""})
	s.tools_lookup = func() -> Dictionary: return {"legendary": "/usr/bin/legendary", "heroic_flatpak": []}
	s.run = func(_p: String, args: PackedStringArray) -> Dictionary:
		calls.append(" ".join(args))
		if "--skip-upload" in args and "--skip-download" in args:
			return {"code": 0, "out": look}
		return {"code": 0, "out": ""}
	return calls


func test_epic_launch_waits_for_its_cloud_save() -> void:
	var calls := _fake("[cli] INFO: Checking \"Min\" (Min)\n[cli] INFO: Save game for \"Min\" is up to date, skipping...\n")
	main()._play(EPIC)
	eq(main().launch_overlay.status.text, TSaves.SYNC_LAUNCH, "the launch screen says it's getting the save")
	ok(await until(func(): return main()._launch_wait == "", 4000), "then the launch goes ahead")
	ok(calls.size() >= 1 and str(calls[0]).contains("sync-saves Min"), "legendary looked first")
	eq(main().saves.status(EPIC)["state"], "synced", "status: synced")
	main()._on_launch_cancelled(EPIC)
	await w.idle()


func _last_sync(t: int) -> void:
	var cfg := ConfigFile.new()
	cfg.load(main().saves.cfg_path)
	cfg.set_value("game:epic:Min", "last_sync", t)
	cfg.save(main().saves.cfg_path)


func test_a_conflict_asks_and_b_starts_nothing() -> void:
	var t := int(Time.get_unix_time_from_system())
	_last_sync(t - 7200)   # both sides changed since
	var look := "[cli] INFO: Checking \"Min\" (Min)\n[cli] INFO: Cloud save for \"Min\" is newer:\n[cli] INFO: - Cloud save date: %s\n[cli] INFO: - Local save date: %s\n" % [
		Time.get_datetime_string_from_unix_time(t - 60, true).replace("T", " "), Time.get_datetime_string_from_unix_time(t - 3600, true).replace("T", " ")]
	var calls := _fake(look)
	main()._play(EPIC)
	ok(await until(func(): return main().game_actions.sheet.is_open(), 4000), "the choice opens before the game starts")
	var rows: Array = main().game_actions.sheet.items
	eq(rows[0]["id"], "cloud", "the newest side first")
	eq(rows[0].get("value", ""), TSaves.NEWER, "and marked newer")
	eq(rows[-1]["id"], "later", "or play without syncing")
	eq(calls.size(), 1, "nothing downloaded while it asks")
	await b()
	await w.idle()
	eq(main()._launch_wait, "", "B: nothing waits")
	ok(main().playing.is_empty(), "and nothing starts")
	ok(not main().session.is_active(), "no session")


func test_the_end_of_a_game_uploads() -> void:
	var t := int(Time.get_unix_time_from_system())
	_last_sync(t - 7200)
	var calls := _fake("[cli] INFO: Checking \"Min\" (Min)\n[cli] INFO: Local save for \"Min\" is newer\n[cli] INFO: - Cloud save date: %s\n[cli] INFO: - Local save date: %s\n" % [
		Time.get_datetime_string_from_unix_time(t - 9000, true).replace("T", " "), Time.get_datetime_string_from_unix_time(t - 30, true).replace("T", " ")])
	main()._on_game_ended(EPIC)
	ok(await until(func(): return not main().saves.busy("epic:Min"), 4000), "the upload finishes")
	ok(str(calls[-1]).ends_with("--skip-download"), "an upload only")
	eq(main().saves.status(EPIC)["state"], "uploaded", "status: uploaded")


func test_settings_has_a_saves_page() -> void:
	var st: Control = main().settings
	ok(st.pages.has("saves"), "a Saves page")
	ok(st.cat_buttons.has("saves"), "in the category list")


func test_low_battery_warns_and_any_button_stays_awake() -> void:
	var slept := [0]
	var low: Node = main().low_battery
	low.suspend = func() -> void: slept[0] += 1
	low.settings = func() -> Dictionary: return {"on": true, "at": 5}
	low.suppressed = false
	# on battery for real: a fixture whose battery says "Charging" counts as on the charger
	low.charging_now = func() -> bool: return false
	low.plugged_now = func() -> bool: return false
	# start from a known healthy reading, whatever ran before: 80 % then 5 % is a sudden drop
	low.confirm_s = 0.2
	low._pct = 80
	low._unconfirmed = false
	low.warning = false
	power().battery_level.emit(5, false)
	await w.idle()
	# a sudden low reading (the fixture's battery is far above 5 %) waits for a second one
	ok(main().low_dialog == null, "one sudden low reading doesn't start the countdown")
	# the second look reads the battery itself (far above 5 % in the fixture): a glitch, still nothing
	await w.wait_s(0.6)
	await w.idle()
	ok(main().low_dialog == null, "and the battery read again says it was a glitch: no warning")
	eq(slept[0], 0, "no sleep")
	low._pct = 80
	power().battery_level.emit(5, false)
	await w.idle()
	ok(main().low_dialog != null and is_instance_valid(main().low_dialog), "the 30 s warning shows")
	await press(JOY_BUTTON_X)
	await w.idle()
	ok(main().low_dialog == null, "any button closes it")
	eq(slept[0], 0, "and it stays awake")
	low.settings = func() -> Dictionary: return {"on": false, "at": 5}
