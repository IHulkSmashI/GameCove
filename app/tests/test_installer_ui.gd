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
const TI := preload("res://scripts/ui/installer/texts_installer.gd")

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


func test_the_page_scrolls_with_room_for_the_focus_glow() -> void:
	# Godot's follow_focus leaves the focused card flush with the area's edge, which cut
	# the Easy card's glow at 1280x800 (layout harness); FocusScroll keeps room around it.
	var s := _screen(F.target("other"))
	ok(not s.scroll.follow_focus, "Godot's follow_focus is off")
	ok(s.scroll.get_children(true).any(func(c): return c.name == "FocusScroll"), "FocusScroll follows the focus")
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
	eq(s.plan.step, "stores", "Easy offers store sign-in first (the welcome card promises it)")
	eq(s.skip_button.text, "Skip for now", "one press to skip")
	s.skip_step()
	eq(s.plan.step, "art", "Easy asks for game art (no key ships with GameCove)")
	eq(s.skip_button.text, "Skip, use Steam art only")
	ok(s.skip_button.visible, "skippable")
	s.skip_step()
	eq(s.plan.step, "summary", "then the summary")
	eq(s.next_button.text, "Install")
	var rows: Array = s.focusables()
	eq(rows.size(), 7, "one row per option step")
	_free(s)


## A DevicePhoto stand-in: one cached maker image for every device.
class OnePhoto extends RefCounted:
	signal photo_ready(device_id: String, path: String)
	var path := ""
	var asked: Array = []
	func photo_for(id: String) -> Dictionary:
		asked.append(id)
		return {"path": path, "credit": {"kind": "maker", "maker": "MSI", "page_url": "https://www.msi.com/", "url": ""}}
	func prefetch(_id: String) -> bool:
		return false


## The Detected handheld card shows the real photo DevicePhoto has cached (with
## its credit), as About this device does, and the drawing without one.
func test_welcome_shows_the_cached_device_photo() -> void:
	var s := _screen(F.target("bazzite"))
	ok(s.body.find_child("DevicePicture", true, false) != null, "no photo service: the drawing")
	ok(s.body.find_child("DevicePhoto", true, false) == null, "and no photo")
	_free(s)
	var png := ProjectSettings.globalize_path("user://test_installer_ui_photo.png")
	var img := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.fill_rect(Rect2i(8, 6, 48, 20), Color(0.2, 0.3, 0.8))
	img.save_png(png)
	var ph := OnePhoto.new()
	ph.path = png
	var d := ProjectSettings.globalize_path("user://test_installer_ui")
	var r := Fake.new()
	r.handler = func(_cmd: String): return {"code": 0, "out": ""}
	var dev := F.claw()
	var t := F.target("bazzite")
	var inst: Node = Service.new()
	inst.setup(r, Paths.for_home(d + "/home", d + "/root"), t, "/opt/gc/gamecove.x86_64")
	var svc := F.services(dev, F.FakeSetup.new(), F.Recorder.new(), d + "/power.cfg")
	svc["photo"] = ph
	var s2 := Screen.create(svc, t, Plan.start(t, dev.profile, {"theme": "cove"}), inst)
	_keep.append(s2)
	var view: Node = s2.body.find_child("DevicePhoto", true, false)
	ok(view != null, "the cached photo replaces the drawing")
	ok(s2.body.find_child("DevicePicture", true, false) == null, "no drawing then")
	ok(ph.asked.has(str(dev.profile.get("id", ""))), "asked for this handheld's photo")
	if view != null:
		eq(view.credit.text, "Image: MSI", "with the maker's credit")
	_free(s2)
	DirAccess.remove_absolute(png)


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
	# every fix carries its badge: Recommended (only those are preselected), and Tested on hardware on the Claw 8 EX
	var badges = s.body.find_child("Badges_claw8ex-gyro", true, false)
	ok(badges != null and badges.find_child("Level", true, false) != null, "the gyro fix says Recommended")
	ok(badges.find_child("Tested", true, false) != null, "and Tested on hardware (docs/TESTING-HARDWARE.md, device 1)")
	ok(s.body.find_child("Badges_claw-kbd-wakeup", true, false).find_child("Tested", true, false) == null, "a fix we didn't run on this model has no Tested badge")
	ok("claw8ex-gyro" in s.plan.choices["fixes"], "Recommended fixes are preselected")
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


## Final review, high 9: save backups have their own switch, with how many and how big; it only shows
## with "Keep my settings" off, starts off, and the text says what really happens.
func test_uninstall_asks_about_save_backups_separately() -> void:
	var t := F.target("bazzite", {"installed": true, "maintenance": true, "state": {"version": "0.2.0", "method": "rpm-ostree", "fixes": []}})
	var s := _screen(t)
	var user: String = ProjectSettings.globalize_path("user://test_installer_ui/userdata/GameCove")
	s.installer.user_dir = user
	for g in ["epic_a", "gog_b"]:
		DirAccess.make_dir_recursive_absolute(user + "/saves/backups/" + g)
		FileAccess.open(user + "/saves/backups/%s/20261110-120000.json" % g, FileAccess.WRITE).store_string("{}")
		FileAccess.open(user + "/saves/backups/%s/20261110-120000-0.tar.gz" % g, FileAccess.WRITE).store_string("save")
	FileAccess.open(user + "/saves/backups/epic_a/20261110-130000.json", FileAccess.WRITE).store_string("{}")
	s.maintenance("uninstall")
	ok(s.body.find_child("remove_save_backups", true, false) == null, "kept settings: no question about backups")
	ok(s.body.find_child("keep_settings", true, false)._hint.visible, "what a switch does is shown without focusing it")
	var keep: Node = s.body.find_child("keep_settings", true, false)
	keep.step(1)
	eq(s.plan.choices["keep_settings"], false, "settings off")
	var row: Node = s.body.find_child("remove_save_backups", true, false)
	ok(row != null, "the save-backups switch shows")
	eq(s.plan.choices["remove_save_backups"], false, "and starts off")
	ok(row._hint.visible, "the count and size are on screen before Remove is pressed")
	var hint := str(row.hint_text())
	ok(hint.contains("3 save backups of 2 games") and hint.contains("KB") and hint.contains(user + "/saves/backups"), "says how many, how big and where: " + hint)
	var off_line := str(s.body.find_child("keep_settings", true, false).hint_text())
	ok(off_line.contains("Art we changed in Steam goes back") and off_line.contains("save backups stay unless"), "the Off line says what happens: " + off_line)
	ok(not off_line.contains("downloads are deleted too"), "the old line is gone")
	row.step(1)
	eq(s.plan.choices["remove_save_backups"], true, "turned on by the user")
	ok(str(s.body.find_child("remove_save_backups", true, false).hint_text()).contains("deleted for good"), "says it can't be undone")
	s.body.find_child("keep_settings", true, false).step(1)
	eq(s.plan.choices["remove_save_backups"], false, "keeping settings again forgets the delete choice")
	ok(s.body.find_child("remove_save_backups", true, false) == null, "and hides the switch")
	_free(s)


func test_art_step_on_the_desktop() -> void:
	var s := _screen(F.target("bazzite"))
	s.pick_mode("easy")
	s.next_step()
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


## Custom's 11 steps fit a 1280 px top bar: only the current step is named,
## the rest are status dots. Easy keeps every name.
func test_rail_compact_with_many_steps() -> void:
	var s := _screen(F.target("bazzite"))
	s.plan.set_mode("custom")
	s.plan.step = "art"
	s.show_step()
	var named := []
	for p in s.rail.get_children():
		var l: Label = p.find_child("Text", true, false)
		if l.visible:
			named.append(String(p.name))
	eq(named, ["Step_art"], "Custom: only the current step keeps its name")
	ok(s.rail.get_combined_minimum_size().x < 700.0, "the rail fits beside the lockup at 1280 px")
	s.plan.set_mode("easy")
	s.plan.step = "art"
	s.show_step()
	ok(s.rail.get_children().all(func(p): return p.find_child("Text", true, false).visible), "Easy names every step")
	_free(s)


## Typing a code or a key in the installer and in first-run setup is the same
## on-screen keyboard as everywhere: pinned by its foot, with Paste, and what
## was typed goes back to whoever asked.
func test_installer_and_setup_ask_with_the_keyboard() -> void:
	var s := _screen(F.target("bazzite"))
	var got: Array = []
	s.ask_text("Sign-in code", "", func(t): got.append(t))
	var k: PanelContainer = s.keyboard
	ok(k.visible, "installer: the keyboard opens")
	ok(k.paste_button.visible and k.keep_case, "installer: codes can be pasted, case kept")
	eq(k.field.text, "Sign-in code", "installer: it says what it wants")
	eq(k.anchor_bottom, 1.0, "installer: pinned to the foot of the screen")
	eq(k.grow_vertical, Control.GROW_DIRECTION_BEGIN, "installer: growing upward")
	ok(k.offset_right - k.offset_left >= 10 * k.KEY.x + 9 * k.GAP + 48, "installer: wide enough for its keys")
	k.type("a")
	k.shift_button.pressed.emit()
	k.type("b")
	k.close()
	eq(got, ["aB"], "installer: the text goes back")
	_free(s)
	var f: Control = SetupFlow.new()
	f.setup({"setup": FirstRunSetup.new()})
	var got2: Array = []
	f.ask_text("API key", "x", func(t): got2.append(t))
	ok(f.keyboard.visible and f.keyboard.paste_button.visible, "setup: the keyboard opens for a key")
	eq(f.keyboard.text, "x", "setup: with what was there")
	ok(f.keyboard.offset_right - f.keyboard.offset_left >= 10 * f.keyboard.KEY.x + 9 * f.keyboard.GAP + 48, "setup: wide enough for its keys")
	f.keyboard.symbols_button.pressed.emit()
	f.keyboard.keys[1][1].pressed.emit()
	f.keyboard.close()
	eq(got2, ["x@"], "setup: the text goes back")
	f.free()


## Owner item: Easy never offered Epic / GOG / Amazon sign-in although the welcome card promises it.
## The store step is in Easy now: skippable with one press, Continue focused, stores that are
## already signed in (Heroic's sign-ins included) shown as done, and the summary names them.
func test_easy_offers_store_sign_in() -> void:
	var setup := F.FakeSetup.new()
	var s := _screen(F.target("bazzite"), setup)
	eq(s.plan.steps(), ["welcome", "stores", "art", "summary", "progress", "done"], "Easy: stores after welcome, before Game art")
	s.pick_mode("easy")
	eq(s.plan.step, "stores", "the store step")
	for store in ["epic", "gog", "amazon"]:
		ok(s.body.find_child("Card_store_" + store, true, false) != null, store + " has a card")
	ok(s.skip_button.visible and s.skip_button.text == TI.SKIP_STORES, "Skip for now")
	eq(s.next_button.text, TI.NEXT, "and Continue")
	ok(_has_text(s.nav_note, "Settings > Stores"), "says where to sign in later, with a controller")
	eq(s.rail.get_child_count(), 6, "six step pills")
	ok(s.rail.get_children().all(func(p): return p.find_child("Text", true, false).visible), "Easy still names every step")
	setup.status["gog"]["signed_in"] = true   # e.g. signed in through Heroic before
	s.show_step()
	var want_done: Array = ["gog"]
	for store in want_done:
		ok(s.body.find_child("Card_store_" + store, true, false).selected, store + " is already signed in: shown as done")
	s.open_sign_in("epic")
	ok(s.sign_in != null, "signing in works from Easy")
	s.go("stores")
	s.next_step()
	eq(s.plan.step, "art", "Continue moves on")
	s.skip_step()
	eq(s.plan.step, "summary")
	ok(s.body.find_child("sum_stores", true, false) != null, "the summary has the stores line")
	_free(s)
	# one press on Skip for now, from a fresh start
	var s2 := _screen(F.target("bazzite"))
	s2.pick_mode("easy")
	s2.skip_step()
	eq(s2.plan.step, "art", "Skip for now: straight to Game art")
	s2.skip_step()
	eq(s2.plan.summary()[2]["value"], "skipped", "the summary knows stores were skipped")
	_free(s2)
	var screen_src := FileAccess.get_file_as_string("res://scripts/ui/installer/installer_screen.gd")
	ok(screen_src.contains("plan.step == \"stores\" and plan.mode == \"easy\""), "Easy's store step starts with the focus on Continue")
	ok(TI.MODE_EASY_LINE.contains("sign in to Epic, GOG and Amazon"), "the Easy card says so")


func _has_text(n: Node, part: String) -> bool:
	if (n is Label or n is Button) and str(n.text).contains(part):
		return true
	for c in n.get_children():
		if _has_text(c, part):
			return true
	return false
