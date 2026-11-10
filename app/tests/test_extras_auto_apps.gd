extends "res://tests/test_case.gd"
## "Update apps by themselves": Updates' opt-in automatic Flatpak update (off by
## default, never while a game runs, Background lookups respected, at most daily,
## lowest CPU and disk priority) and its switch on the Updates page. Fake runner,
## fixture root; nothing real runs.

const UpdatesScript := preload("res://scripts/system/updates.gd")
const UpdatesPanel := preload("res://scripts/ui/device/updates_panel.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const SettingsFileScript := preload("res://scripts/system/settings_file.gd")

const PREFS := "user://test_extras_auto_apps.cfg"
const CACHE := "user://test_extras_auto_apps_cache"


func _fake(user_file := "flatpak_user.txt") -> RefCounted:
	var f: RefCounted = Fake.new()
	f.responses["flatpak remote-ls --updates --user --columns=application,name,version,branch,origin"] = {"code": 0, "file": fixture("system/updates/" + user_file)} if user_file != "" else {"code": 0, "out": ""}
	f.responses["flatpak remote-ls --updates --system --columns=application,name,version,branch,origin"] = {"code": 0, "out": ""}
	f.responses["nice -n 19 flatpak update*"] = {"code": 0, "out": "Updating 1/1…\n"}
	return f


func _upd(f: RefCounted, background := true) -> Node:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	var cache := ProjectSettings.globalize_path(CACHE)
	DirAccess.remove_absolute(cache.path_join(UpdatesScript.AUTO_STAMP))
	var u: Node = UpdatesScript.new()
	u.prefs_path = PREFS
	u.cache_dir = cache
	u.background_override = background
	u.setup(f, fixture("system/os/bazzite_deck"), fixture("system/home"))
	return u


func _done(u: Node) -> void:
	u.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREFS))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE).path_join(UpdatesScript.AUTO_STAMP))


func test_off_by_default() -> void:
	var f := _fake()
	var u := _upd(f)
	ok(not u.auto_apps(), "off until you turn it on")
	eq(u.maybe_auto_update_apps(), "off", "does nothing")
	ok(not f.called("flatpak"), "no flatpak call")
	eq(u.state()["auto_apps"], false, "state says so")
	_done(u)


func test_turning_it_on_updates_quietly_once_a_day() -> void:
	var f := _fake()
	var u := _upd(f)
	u.set_auto_apps(true)
	ok(f.called("flatpak remote-ls --updates --user"), "checked")
	ok(f.calls.has("nice -n 19 flatpak update --user --noninteractive -y"), "updated at the lowest priority")
	ok(not f.called("flatpak update"), "never at normal priority")
	eq(u.phase("flatpak"), "up_to_date", "done")
	ok(FileAccess.file_exists(ProjectSettings.globalize_path(CACHE).path_join(UpdatesScript.AUTO_STAMP)), "stamped")
	eq(u.maybe_auto_update_apps(), "not_due", "not again today")
	ok(bool(SettingsFileScript.load_cfg(PREFS).get_value("updates", "auto_apps", false)), "saved")
	_done(u)


func test_never_while_a_game_runs_and_after_it_ends() -> void:
	var f := _fake()
	var u := _upd(f)
	u.set_game_running(true)
	u.set_auto_apps(true)
	eq(u.maybe_auto_update_apps(), "game_running", "waits for the game")
	ok(not f.called("nice"), "nothing ran")
	u.set_game_running(false)
	ok(f.called("nice -n 19 flatpak update"), "runs when the game ends")
	_done(u)


func test_background_lookups_off_means_no() -> void:
	var f := _fake()
	var u := _upd(f, false)
	u.set_auto_apps(true)
	eq(u.maybe_auto_update_apps(), "privacy", "respects Background lookups")
	ok(not f.called("flatpak"), "no network")
	_done(u)


func test_nothing_pending_just_stamps() -> void:
	var f := _fake("")
	var u := _upd(f)
	u.set_auto_apps(true)
	ok(not f.called("nice"), "nothing to update")
	eq(u.phase("flatpak"), "up_to_date", "up to date")
	eq(u.maybe_auto_update_apps(), "not_due", "checked today")
	_done(u)


func test_updates_page_switch() -> void:
	var f := _fake()
	var u := _upd(f)
	var p: Control = UpdatesPanel.build({"updates": u})
	ok(p.buttons.has("auto_apps"), "switch on the Apps card")
	var row: Node = p.buttons["auto_apps"].get_parent()
	while row != null and not row.has_method("hint_text"):
		row = row.get_parent()
	ok(row != null and row.hint_text() == TX.AUTO_APPS_HELP[false], "one plain line saying what Off means")
	ok(p.buttons["auto_apps"] in p.focusables(), "in the focus chain")
	p.free()
	_done(u)
