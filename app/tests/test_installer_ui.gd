extends "res://tests/test_case.gd"
## The installer screen with fakes, outside the tree: every page builds, Easy
## and Custom navigation, summary edits, store sign-in with clipboard capture,
## the run reaching Done, and the first-run flow skipping installer steps.

const Screen := preload("res://scripts/ui/installer/installer_screen.gd")
const SignIn := preload("res://scripts/ui/installer/store_signin.gd")
const Plan := preload("res://scripts/installer/plan.gd")
const Service := preload("res://scripts/installer/installer_service.gd")
const Paths := preload("res://scripts/installer/paths.gd")
const UserFiles := preload("res://scripts/installer/user_files.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const F := preload("res://tests/fixtures/installer/fakes.gd")
const SetupFlow := preload("res://scripts/ui/setup/setup_flow.gd")

var _keep: Array = []


func _screen(t: Dictionary, setup: Object = null) -> Control:
	var d := ProjectSettings.globalize_path("user://test_installer_ui")
	UserFiles.remove_tree(d, ProjectSettings.globalize_path("user://"))
	DirAccess.make_dir_recursive_absolute(d)
	var r := Fake.new()
	r.handler = func(cmd: String): return {"code": 1, "out": ""} if cmd.begins_with("pgrep") else {"code": 0, "out": ""}
	var dev := F.claw()
	var st: Object = setup if setup != null else F.FakeSetup.new()
	var p := Plan.start(t, dev.profile, {"theme": "cove"})
	var inst: Node = Service.new()
	inst.setup(r, Paths.for_home(d + "/home", d + "/root"), t, "/opt/gc/gamecove.x86_64")
	var s := Screen.create(F.services(dev, st, F.Recorder.new(), d + "/power.cfg"), t, p, inst)
	_keep.append(s)
	return s


func _free(s: Control) -> void:
	_keep.erase(s)
	s.free()


func test_every_page_builds() -> void:
	var s := _screen(F.target("bazzite"))
	for step in ["welcome", "startup", "steam", "stores", "device", "look", "art", "extras", "summary", "maintenance", "uninstall", "finish"]:
		s.plan.step = step
		s.show_step()
		ok(s.page_title.text != "", step + " has a title")
		ok(s.rail.get_child_count() > 0, step + " rail")
	_free(s)


func test_welcome_shows_device_and_modes() -> void:
	var s := _screen(F.target("bazzite"))
	eq(s.page_title.text, "CHOOSE HOW TO SET UP GAMECOVE")
	ok(s.body.find_child("DeviceName", true, false).text.begins_with("MSI CLAW 8 EX"))
	ok("Bazzite 43" in s.body.find_child("Facts", true, false).text)
	var easy: Button = s.body.find_child("Card_mode_easy", true, false)
	ok(easy.selected, "Easy is the default")
	eq(s.focusables()[0], easy)
	easy.pressed.emit()
	eq(s.plan.step, "art", "Easy asks for game art (no key ships with GameCove)")
	eq(s.skip_button.text, "Skip, use Steam art only")
	ok(s.skip_button.visible, "skippable")
	s.skip_step()
	eq(s.plan.step, "summary", "then the summary")
	eq(s.next_button.text, "Install")
	var rows: Array = s.focusables()
	eq(rows.size(), 7, "one row per option step")
	_free(s)


func test_custom_walk_and_choices() -> void:
	var s := _screen(F.target("bazzite"))
	s.pick_mode("custom")
	eq(s.plan.step, "startup")
	var steam_card: Button = s.body.find_child("Card_startup_steam", true, false)
	steam_card.pressed.emit()
	eq(s.plan.choices["startup"], "steam")
	ok(s.body.find_child("Card_startup_steam", true, false).selected, "redrawn as chosen")
	ok(s.nav_note.get_child_count() == 1, "switch-back note")
	s.next_step()
	eq(s.plan.step, "steam")
	ok(s.body.find_child("SteamWarning", true, false) != null, "Steam control warning shown")
	var mode = s.body.find_child("steam_mode", true, false)
	mode.step(1)
	eq(s.plan.choices["steam_mode"], "gamepadui")
	s.next_step()
	eq(s.plan.step, "stores")
	ok(s.body.find_child("Heroic", true, false) != null, "Heroic sign-ins reused")
	s.next_step()
	eq(s.plan.step, "device")
	var gyro = s.body.find_child("fix_claw8ex-gyro", true, false)
	gyro.step(1)
	ok(not "claw8ex-gyro" in s.plan.choices["fixes"], "gyro fix off")
	ok(s.body.find_child("charge_limit", true, false) != null, "charge limit slider on the Claw")
	s.skip_step()
	eq(s.plan.step, "look")
	eq(s.plan.choices["fixes"], [], "skip = no fixes")
	s.next_step()
	eq(s.plan.step, "art")
	ok(s.art_step != null and s.body.find_child("SteamGridDB", true, false) == null, "the guided Game art step")
	s.art_step.submit("0123456789abcdef0123456789abcdef")
	eq(s.plan.choices["steamgriddb_key"], "0123456789abcdef0123456789abcdef", "checked key kept in the plan")
	s.next_step()
	eq(s.plan.step, "extras")
	ok(s.body.find_child("steamgriddb_key", true, false) == null, "no bare key row in Extras any more")
	ok(s.save_extra("ggdeals_key", "AbCdEf123456"))
	s.next_step()
	eq(s.plan.step, "summary")
	s.edit("startup")
	eq(s.plan.step, "startup")
	s.next_step()
	eq(s.plan.step, "summary", "back to the summary after an edit")
	_free(s)


func test_install_runs_to_done() -> void:
	var setup := F.FakeSetup.new()
	var s := _screen(F.target("bazzite"), setup)
	s.pick_mode("easy")
	s.skip_step()
	s.next_step()
	eq(s.plan.step, "done", "the run finished synchronously with the fake runner")
	eq(s.next_button.text, "Restart now")
	ok(s.body.find_child("WaitingFixes", true, false) != null, "fixes wait for the reboot")
	ok(s.body.find_child("ColdBoot", true, false) != null, "gyro cold boot note")
	ok(setup.done.has("done"), "first-run setup marked done")
	ok(s.installer.results.has("pending"))
	_free(s)


func test_blocked_without_package() -> void:
	var t := F.target("bazzite", {"package": ""})
	var s := _screen(t)
	ok(s.body.find_child("NoPackage", true, false) != null)
	s.plan.step = "summary"
	s.show_step()
	ok(s.next_button.disabled, "no install without the download")
	_free(s)


func test_signin_clipboard_capture() -> void:
	var setup := F.FakeSetup.new()
	var s := _screen(F.target("bazzite"), setup)
	s.plan.step = "stores"
	s.show_step()
	var opened := []
	s.open_sign_in("gog")
	var si: Control = s.sign_in
	si.open_url = func(u): opened.append(u)
	var clip := ["nothing useful"]
	si.read_clipboard = func() -> String: return clip[0]
	eq(si.state, "waiting")
	si.open_page()
	eq(opened, ["https://example.test/login/gog"])
	ok(not si.check_clipboard(), "random clipboard text isn't sent")
	clip[0] = "https://embed.gog.com/on_login_success?origin=client&code=abc123"
	ok(si.check_clipboard(), "a copied address finishes the sign-in")
	ok("finish gog https://embed.gog.com/on_login_success?origin=client&code=abc123" in setup.calls)
	eq(s.plan.step, "stores")
	ok(SignIn.looks_like_code("epic", "{\"authorizationCode\": \"x\"}"))
	ok(not SignIn.looks_like_code("amazon", "https://amazon.com/"))
	_free(s)


func test_maintenance_and_uninstall_pages() -> void:
	var t := F.target("bazzite", {"installed": true, "maintenance": true, "update_available": true,
		"release": {"tag": "v0.3.0", "version": "0.3.0"}, "state": {"version": "0.2.0", "method": "rpm-ostree", "fixes": ["claw8ex-vrr"]}})
	var s := _screen(t)
	eq(s.plan.step, "maintenance")
	ok(s.body.find_child("maint_update", true, false).title_label.text.ends_with("v0.3.0"))
	s.maintenance("uninstall")
	eq(s.plan.step, "uninstall")
	eq(s.next_button.text, "Remove GameCove")
	ok(s.body.find_child("remove_fixes", true, false) != null)
	ok(s.body.find_child("keep_settings", true, false) != null)
	_free(s)


func test_art_step_on_the_desktop() -> void:
	var s := _screen(F.target("bazzite"))
	s.pick_mode("easy")
	eq(s.plan.step, "art")
	var a: Control = s.art_step
	ok(a.find_child("OpenHere", true, false) != null, "Open the page here on the desktop")
	var opened: Array = []
	a.open_url = func(u): opened.append(u)
	a.open_button.pressed.emit()
	eq(opened, ["https://www.steamgriddb.com/profile/preferences/api"], "SteamGridDB's API page")
	eq(a.mode, "direct", "no LAN in tests: the QR opens SteamGridDB directly")
	ok(a.buttons.all(func(b): return b in s.focusables()), "every button reachable with the controller")
	var clip := ["hello"]
	a.read_clipboard = func() -> String: return clip[0]
	ok(not a.check_clipboard(), "random clipboard text isn't sent")
	clip[0] = "fedcba9876543210fedcba9876543210"
	s.services["http"].route(load("res://scripts/library/art/sgdb.gd").check_url(), {"code": 401, "text": '{"success":false}'})
	ok(a.check_clipboard(), "a copied key is picked up when the window gets focus back")
	eq(a.state, "wrong", "SteamGridDB said no")
	eq(s.plan.choices["steamgriddb_key"], "", "a wrong key isn't kept")
	s.services["http"].route(load("res://scripts/library/art/sgdb.gd").check_url(), {"text": '{"success":true}'})
	a.submit(clip[0])
	eq(s.plan.choices["steamgriddb_key"], clip[0], "kept once it works")
	ok("fills in missing art when it starts" in a.status.text, "art fill happens at first start")
	s.next_step()
	eq(s.plan.step, "summary")
	ok(s.body.find_child("sum_art", true, false).value_label.text == "Your SteamGridDB key", "summary row")
	_free(s)


class FirstRunSetup extends RefCounted:
	var done := {"welcome": true, "theme": true, "stores": true, "steamgriddb": true, "keys": true}
	var skipped := {}

	func is_done(s: String) -> bool:
		return done.has(s)

	func is_skipped(s: String) -> bool:
		return skipped.has(s)

	func complete(s: String) -> bool:
		done[s] = true
		return true

	func skip(s: String) -> bool:
		skipped[s] = true
		return true


func test_first_run_flow_skips_installer_steps() -> void:
	var f: Control = SetupFlow.new()
	f.services = {"setup": FirstRunSetup.new()}
	f.skip_finished = true
	eq(f.following("welcome"), "fixes", "Look, Stores, Game art and Keys were done by the installer")
	f.skip_finished = false
	eq(f.following("welcome"), "theme", "reopened from Settings: every step")
	f.free()
