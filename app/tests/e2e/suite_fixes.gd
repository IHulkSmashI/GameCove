extends "res://tests/e2e/e2e_case.gd"
## Settings > Device > Fixes and the fix lifecycle in the running app, with the pad only
## (docs/FIXES.md). GameCove's real Fixes service and page, the real start pass and game
## session; the root helper is the lifecycle tests' FakeHelper (what each verb does on the
## system is proven by fixes/*/test.sh and fixes/lib/test.sh, gcfix update's rollback included):
##   - the four groups and the Recommended / Optional (+ Tested on hardware) badges, for this
##     setup's handheld, and a plain "nothing left" line where nothing is recommended
##   - reverse-on-obsolete: Gaming Mode waits (said once), Remove now with A in Desktop Mode,
##     History with Keep it anyway
##   - update with rollback: a failed update stays at the old revision, said once, Update now stays
##   - a withdrawn fix still in place: the start dialog over Home (B = Later), every start
##   - never during a game: nothing runs, nothing is shown until the game ends

const LifeTests := preload("res://tests/test_fix_lifecycle.gd")
const FixesSvc := preload("res://scripts/device/fixes.gd")
const FixData := preload("res://scripts/device/fix_data.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")
const HELPER := "/usr/libexec/gamecove/gamecove-fix"
const NOW := 1794268800   # 2026-11-10

var _n := 0


func fixes() -> Node:
	return main().fixes


## main's Fixes service, set up again on a private root and home with a FakeHelper that knows
## `state` (fix -> FakeHelper entry). installed: what install-state.json lists.
func _rig(state: Dictionary, installed: Array, opts := {}) -> RefCounted:
	_n += 1
	var h := OS.get_user_data_dir().path_join("e2e_fixes_%d_%d" % [Time.get_ticks_usec(), _n])
	var r = LifeTests.FakeHelper.new()
	r.fixes = state.duplicate(true)
	_put(h + "/root/proc/sys/kernel/osrelease", "6.17.7-ba25.fc43.x86_64\n")
	_put(h + "/root/etc/os-release", "NAME=\"Bazzite\"\nID=bazzite\nVERSION_ID=44\nOSTREE_VERSION='44.20261105.0'\n")
	_put(h + "/root/usr/bin/rpm-ostree", "")
	_put(h + "/root/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value", "0\n")
	_put(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": installed}))
	if opts.has("release"):
		_put(h + "/bin/cosign", "")
		r.release = str(opts["release"])
	if main().fix_dialog != null and is_instance_valid(main().fix_dialog):
		main().fix_dialog.finish("later")
		await w.frames(2)
	var s: Node = fixes()
	s.path_env = h + "/bin"
	s.now_unix = NOW
	s.setup({"runner": r, "home": h, "device": device_id(), "sys_root": h + "/root",
		"can_prompt": bool(opts.get("can_prompt", false)), "background": opts.has("release")})
	r.data_dir = s._data_dir()
	return r


func _put(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


## The fixes the bundled list offers this setup's handheld, auto (Recommended) first.
func _offered() -> Array:
	var out: Array = []
	for e in fixes().entries():
		if str(e.get("kind", "")) in ["root", "file"]:
			out.append(str(e["id"]))
	return out


func _recommended() -> Array:
	return _offered().filter(func(id): return fixes().is_auto(id))


## Settings > Device > Fixes, the page's first button focused (the pad from there on).
func open_fixes() -> Control:
	main()._open_settings_category("device", "fixes")
	await w.frames(6)
	await w.idle()
	# the Device page's own Fixes panel (an earlier rebuild may leave a freed one behind by name)
	var dp: Control = main().settings.pages.get("device")
	var page: Control = dp.panels.get("fixes") if dp != null else null
	return page


func _toasts() -> Array:
	var got: Array = []
	main().toasts.shown.connect(func(t): got.append(t))
	return got


func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		out.append(_texts(c))
	return "\n".join(out)


## Presses down until `b` has focus, then A.
func _press_with_pad(b: Control) -> bool:
	if not await focus_on(b, 40):
		return false
	await a()
	await w.frames(4)
	await w.idle()
	return true


func test_groups_and_badges_for_this_handheld() -> void:
	var state := {}
	var rec := _recommended()
	var offered := _offered()
	for id in offered:
		state[id] = {"installed": false, "os_fixed": false}
	# the first Recommended fix applied at install, the rest waiting
	var installed: Array = rec.slice(0, 1)
	for id in installed:
		state[id]["installed"] = true
	await _rig(state, installed)
	fixes().refresh()
	var page := await open_fixes()
	ok(page != null and page.is_visible_in_tree(), "Settings > Device > Fixes opens")
	if page == null:
		return
	ok(page.svc("fixes") == fixes(), "the page shows main's own Fixes service")
	var t := _texts(page)
	ok(not t.contains("Suggested") and not t.contains("Extras") and not t.contains("Partial"), "only the owner's words")
	var listed: Array = fixes().rows().filter(func(r): return str(r.get("group", "")) != "").map(func(r): return str(r["id"]))
	for id in offered:
		var card: Control = page.find_child("Fix_" + id.validate_node_name(), true, false)
		# a fix whose part or base this unit lacks isn't listed (counted under "not needed on this unit")
		eq(card != null, id in listed, id + (" has a card" if id in listed else " isn't listed here"))
		if card == null:
			continue
		var lv: Control = card.find_child("Level", true, false)
		var want := "Recommended" if id in rec else "Optional"
		ok(lv != null and _texts(lv).strip_edges() == want, "%s badged %s" % [id, want])
		var tested: bool = fixes().rows().filter(func(r): return r["id"] == id)[0]["tested"]
		eq(card.find_child("Tested", true, false) != null, tested, id + ": Tested on hardware only when it was")
	if not installed.is_empty():
		ok(page.find_child("Group_applied", true, false) != null, "Applied group")
	if rec.size() > 1:
		ok(t.contains("Recommended for your %s" % page.call("_device_name")), "Recommended group names the handheld")
		ok(page.find_child("NothingLeft", true, false) == null, "something left: no all-done line")
	else:
		ok(page.find_child("NothingLeft", true, false) != null, "nothing recommended left: said in plain words")
	if offered.size() > rec.size():
		ok(page.find_child("Group_optional", true, false) != null, "Optional group")
	# every button can be reached with the pad
	for k in page.buttons:
		if str(k).begins_with("apply:"):
			ok(await focus_on(page.buttons[k], 40), "pad reaches " + str(k))
			break


func test_reverse_on_obsolete_waits_for_desktop_then_remove_now() -> void:
	# one that is harmless next to the system's own fix (a clash is shown over Home instead: the
	# withdrawn test and test_fix_lifecycle cover that)
	var rec := _recommended().filter(func(f): return str(fixes().entry(f).get("lifecycle", {}).get("both_active", "")) != "conflict")
	if rec.is_empty():
		ok(true, "no recommended fix on this handheld")
		return
	var id: String = rec[0]
	var state := {}
	for f in _offered():
		state[f] = {"installed": f == id, "os_fixed": f == id}
	var r = await _rig(state, [id])
	var said := _toasts()
	var shouted: Array = []
	fixes().attention_needed.connect(func(items): shouted.append(items))
	fixes().check_changes()
	await w.idle()
	await w.frames(4)
	eq(r.ran("pkexec %s %s remove" % [HELPER, id]), 0, "Gaming Mode: no prompt can show, so it waits")
	ok(said.size() >= 1 and said.any(func(x): return str(x).contains("Desktop Mode")), "said once, as a toast")
	eq(shouted.size(), 0, "a harmless wait is not shown over Home")
	fixes().check_changes()
	await w.idle()
	eq(said.filter(func(x): return str(x).contains("Desktop Mode")).size(), 1, "not said again at the next start")
	# Desktop Mode: Remove now on the card, with the pad
	fixes().can_prompt_override = true
	var page := await open_fixes()
	ok(page.buttons.has("pending:" + id), "the card offers Remove now")
	if not page.buttons.has("pending:" + id):
		return
	ok(await _press_with_pad(page.buttons["pending:" + id]), "A on Remove now")
	ok(await until(func(): return r.ran("pkexec %s %s remove" % [HELPER, id]) == 1, 4000), "the fix's own remove ran once")
	ok(not r.fixes[id]["installed"], "removed")
	page = await open_fixes()
	ok(page.find_child("History", true, false) != null, "History lists it")
	ok(page.buttons.has("keep:" + id), "with Keep it anyway")
	var row: Dictionary = fixes().rows().filter(func(x): return x["id"] == id)[0]
	eq(row["group"], "retired", "under Not needed any more")


func test_update_with_rollback() -> void:
	var rec := _recommended()
	if rec.is_empty():
		ok(true, "no recommended fix on this handheld")
		return
	var id: String = rec[0]
	var state := {}
	for f in _offered():
		state[f] = {"installed": f == id, "os_fixed": false, "rev": 1, "script": 2 if f == id else 1}
	var r = await _rig(state, [id], {"can_prompt": true})
	r.update_fails = true
	var said := _toasts()
	fixes().check_changes()
	await w.idle()
	await w.frames(4)
	eq(r.ran("pkexec %s %s update" % [HELPER, id]), 1, "the helper's update ran")
	ok(r.fixes[id]["installed"] and int(r.fixes[id]["rev"]) == 1, "failed: the old version stays, at its old revision")
	ok(said.any(func(x): return str(x).contains("put the old version back")), "said in plain words")
	eq(str(fixes().history()[0]["action"]), "update-failed", "History: update failed")
	var page := await open_fixes()
	ok(page.buttons.has("pending:" + id) and (page.buttons["pending:" + id] as Button).text == TF.UPDATE_NOW, "Update now stays on the card")
	eq(fixes().status_of(id), "applied", "still applied")
	r.calls.clear()
	fixes().check_changes()
	await w.idle()
	eq(r.ran("pkexec"), 0, "not retried at every start")
	# it works the second time, from the page
	r.update_fails = false
	if not page.buttons.has("pending:" + id):
		return
	ok(await _press_with_pad(page.buttons["pending:" + id]), "A on Update now")
	ok(await until(func(): return int(r.fixes[id]["rev"]) == 2, 4000), "updated to the new revision")


func test_withdrawn_fix_left_in_place_is_shown_at_start_never_over_a_game() -> void:
	var rec := _recommended()
	if rec.is_empty():
		ok(true, "no recommended fix on this handheld")
		return
	var id: String = rec[0]
	var state := {}
	for f in _offered():
		state[f] = {"installed": f == id, "os_fixed": false}
	var doc := FixData.bundled()
	for e in doc["fixes"]:
		if e["id"] == id:
			e["withdrawn"] = {"date": "2026-11-10", "reason": "It broke sleep on one BIOS."}
	var r = await _rig(state, [id], {"release": JSON.stringify({"schema": 1, "serial": NOW, "built": "2026-11-10", "fixes": doc["fixes"]})})
	main().show_screen("home")
	await w.frames(4)
	# a game is running: nothing runs, nothing is fetched, nothing is shown
	await start_game(GAME_A)
	r.calls.clear()
	fixes().check_changes()
	await w.idle()
	eq(r.ran("pkexec"), 0, "no helper call during a game")
	eq(r.ran("curl"), 0, "no download during a game")
	ok(main().fix_dialog == null or not is_instance_valid(main().fix_dialog), "nothing over the game")
	await end_game()
	ok(await until(func(): return r.ran("curl") >= 1, 4000), "the start pass runs when the game ends")
	ok(await until(func(): return main().fix_dialog != null and is_instance_valid(main().fix_dialog), 4000), "the withdrawn fix is shown over Home")
	if main().fix_dialog == null or not is_instance_valid(main().fix_dialog):
		return
	ok(_texts(main().fix_dialog).contains("one BIOS"), "with the reason")
	ok(_texts(main().fix_dialog).contains("Desktop Mode"), "and how to take it out (Gaming Mode)")
	eq(r.ran("pkexec %s %s remove" % [HELPER, id]), 0, "nothing removed without a prompt")
	await b()
	await w.frames(4)
	ok(main().fix_dialog == null or not is_instance_valid(main().fix_dialog), "B: Later")
	# the next start shows it again, until it's out or kept
	fixes()._attention_said = false
	fixes().check_changes()
	ok(await until(func(): return main().fix_dialog != null and is_instance_valid(main().fix_dialog), 4000), "again at the next start")
	if main().fix_dialog != null and is_instance_valid(main().fix_dialog):
		await a()   # Open Fixes (Gaming Mode: no Remove now on the card)
		await w.frames(6)
		eq(main().current, "settings", "A: Open Fixes")
		var page: Control = main().settings.pages["device"].panels.get("fixes")
		ok(page != null and page.is_visible_in_tree(), "on the Fixes page")
