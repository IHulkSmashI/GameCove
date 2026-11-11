extends "res://tests/test_case.gd"
## The Fixes catalogue, the Fixes service (fake runner, temp home, fake sysfs)
## and the Fixes page. Nothing real runs.

const Traits := preload("res://scripts/device/traits.gd")
const FixesSvc := preload("res://scripts/device/fixes.gd")
const Page := preload("res://scripts/ui/device/fixes_page.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")
const Texts := preload("res://scripts/ui/texts.gd")

const HELPER := "/usr/libexec/gamecove/gamecove-fix"
const SET_HELPER := "/usr/libexec/gamecove/gamecove-fix-set"


func _repo() -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").simplify_path()


func _tmp(name_: String) -> String:
	var d := OS.get_user_data_dir().path_join("test_fixes_" + name_)
	_rm(d)
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _rm(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	d.include_hidden = true
	for f in d.get_files():
		d.remove(f)
	for s in d.get_directories():
		_rm(path.path_join(s))
	DirAccess.remove_absolute(path)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)


## A service for `device` with a fake runner answering `status` per fix.
func _svc(device: String, states: Dictionary, home := "") -> FixesSvc:
	var r := Fake.new()
	for fix in states:
		r.responses["%s %s status" % [HELPER, fix]] = {"code": 0, "out": "applies=yes\ninstalled=%s\nstate=%s\n" % ["yes" if states[fix] == "on" else "no", states[fix]]}
	r.responses["pkexec*"] = {"code": 0, "out": "installed\n"}
	var s: FixesSvc = FixesSvc.new()
	var h := home if home != "" else _tmp("home_" + device)
	s.setup({"runner": r, "home": h, "device": device, "sys_root": h + "/root"})
	return s


func _devices() -> Array:
	return JSON.parse_string(FileAccess.get_file_as_string("res://data/devices.json"))["devices"]


# ------------------------------------------------------------ catalogue

func test_catalogue_entries_are_complete_and_real() -> void:
	var cat := FixesSvc.load_catalogue("res://data/fixes.json")
	ok(cat.size() >= 14, "catalogue loaded")
	var ids := _devices().map(func(d): return d["id"])
	var seen := {}
	for e in cat:
		var id: String = e["id"]
		ok(not seen.has(id), id + ": unique")
		seen[id] = true
		for k in ["title", "line", "kind", "password", "sources"]:
			ok(e.has(k), "%s: has %s" % [id, k])
		ok(str(e["line"]).length() > 10 and str(e["line"]).length() <= 120, id + ": one plain line")
		ok(not (e["sources"] as Array).is_empty(), id + ": has a source")
		ok(e["kind"] in ["root", "file", "power", "app"], id + ": kind")
		if e["kind"] != "app":
			ok(FileAccess.file_exists(_repo().path_join("fixes/%s/fix.sh" % id)), id + ": fix folder exists")
			ok(FileAccess.file_exists(_repo().path_join("fixes/%s/test.sh" % id)), id + ": has test.sh")
		for key in ["auto", "optional"]:
			var sel: Variant = e.get(key, [])
			if not (sel is Array and sel.is_empty()):
				ok(not Traits.resolve(sel, _devices()).is_empty(), "%s: %s selector picks at least one handheld" % [id, key])
		for d in e.get("exclude", {}):
			ok(d in ids, "%s: excluded device %s is in devices.json" % [id, d])
		if e["kind"] == "file":
			# review S3-2: installing a udev rule / session file isn't a day-to-day setting: admin password
			ok(e["password"] == "admin", id + ": file fixes need the admin password")
			var src := FileAccess.get_file_as_string(_repo().path_join("fixes/%s/fix.sh" % id))
			ok(src.contains("gcfix.sh"), id + ": built on gcfix.sh")
			ok(not FileAccess.get_file_as_string(_repo().path_join("packaging/libexec/gamecove-fix-set")).contains(" " + id), id + ": not in gamecove-fix-set")
		if str(e.get("password", "admin")) == "none":
			ok(FileAccess.get_file_as_string(_repo().path_join("packaging/libexec/gamecove-fix-set")).contains(id), id + ": a no-password fix is allowed in gamecove-fix-set")
			# review L8: gamecove-fix-set has no on / off; such a fix is set from its own page, never Apply / Undo
			ok(e["kind"] == "app" or str(e.get("page", "fixes")) != "fixes", id + ": a no-password fix isn't an Apply / Undo row")
		if e["kind"] == "root":
			ok(e["password"] == "admin", id + ": root fixes need the admin password")


func test_auto_lists_match_devices_json_fixes() -> void:
	var cat := FixesSvc.load_catalogue("res://data/fixes.json")
	for d in _devices():
		var want: Array = []
		for e in cat:
			if e["kind"] in ["root", "file"] and Traits.fix_auto(e, d):
				want.append(e["id"])
		var have: Array = d["fixes"].duplicate()
		want.sort()
		have.sort()
		eq(have, want, d["id"] + ": devices.json fixes = catalogue auto list")


# ------------------------------------------------------------ service

func test_entries_per_device() -> void:
	var s := _svc("msi-claw-8-ex", {})
	var ids := s.entries().map(func(e): return e["id"])
	for f in ["claw8ex-buttons", "claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup", "quiet", "ax210-d3cold"]:
		ok(f in ids, "Claw 8 EX lists " + f)
	ok("claw-wifi-d3cold" in ids and not s.is_auto("claw-wifi-d3cold"), "8 EX: Intel Claw Wi-Fi fix offered (shared with the other Intel Claws)")
	ok(s.why("claw-kbd-wakeup").contains("controller msi-claw"), "why: the shared controller")
	ok(not "fan" in ids and not "charge-limit" in ids, "fan / charge limit stay on the Power page")
	ok(not "gpd-fingerprint" in ids, "other makers' fixes don't show")
	ok(s.is_auto("claw-kbd-wakeup") and not s.is_auto("ax210-d3cold"), "auto vs optional")
	ok(ids.find("ax210-d3cold") > ids.find("claw8ex-gyro"), "auto fixes first")
	s.free()
	s = _svc("msi-claw-a1m", {})
	ids = s.entries().map(func(e): return e["id"])
	ok("claw-wifi-d3cold" in ids and not s.is_auto("claw-wifi-d3cold"), "A1M: optional Wi-Fi fix")
	s.free()
	s = _svc("asus-rog-ally", {})
	ids = s.entries().map(func(e): return e["id"])
	ok("ally-fingerprint-drain" in ids and "ally-mcu-powersave" in ids and not "ally-controller-wakeup" in ids, "original Ally")
	s.free()
	s = _svc("unknown", {})
	eq(s.entries().map(func(e): return e["id"]), [], "unknown hardware: no device fixes, not even the * ones")
	s.free()


func test_status_words() -> void:
	var s := _svc("msi-claw-8-ex", {"claw8ex-buttons": "on", "claw8ex-vrr": "restart", "claw8ex-gyro": "off",
		"claw-kbd-wakeup": "os-fixed", "ax210-d3cold": "not-needed"})
	eq(s.status_of("claw8ex-buttons"), "checking", "before refresh")
	s.refresh()
	eq(s.status_of("claw8ex-buttons"), "applied", "on -> applied")
	eq(s.status_of("claw8ex-vrr"), "restart", "restart")
	eq(s.status_of("claw8ex-gyro"), "needed", "auto + off -> needed")
	eq(s.status_of("claw-kbd-wakeup"), "os-fixed", "os-fixed")
	eq(s.status_of("ax210-d3cold"), "not-needed", "not-needed")
	eq(s.status_of("quiet"), "applied", "quiet is on by default")
	var c := s.counts()
	eq(c["applied"], 3, "applied count (buttons, vrr, quiet)")
	eq(c["available"], 1, "available count")
	eq(c["os-fixed"], 1, "os-fixed count")
	s.free()
	s = _svc("msi-claw-a1m", {"claw-wifi-d3cold": "off"})
	s.refresh()
	eq(s.status_of("claw-wifi-d3cold"), "available", "optional + off -> available")
	eq(s.status_of("claw-kbd-wakeup"), "unknown", "no answer -> unknown")
	var row: Dictionary = s.rows().filter(func(r): return r["id"] == "claw-kbd-wakeup")[0]
	ok(row["can_check"] and not row["can_apply"], "unknown: only Check again")
	s.free()


func test_parse_status() -> void:
	eq(FixesSvc.parse_status("applies=yes\nstate=on\nnote=a=b\n"), {"applies": "yes", "state": "on", "note": "a=b"})
	eq(FixesSvc.parse_status(""), {})


func test_auto_applied_comes_from_the_installer_record() -> void:
	var h := _tmp("record")
	_write(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": ["claw-kbd-wakeup"]}))
	var s := _svc("msi-claw-a1m", {"claw-kbd-wakeup": "on", "claw-wifi-d3cold": "on"}, h)
	s.refresh()
	var rows := {}
	for r in s.rows():
		rows[r["id"]] = r
	ok(rows["claw-kbd-wakeup"]["auto_applied"], "installed by the installer and on: Applied by GameCove")
	ok(not rows["claw-wifi-d3cold"]["auto_applied"], "optional fix the user applied: not auto")
	ok(rows["claw-kbd-wakeup"]["can_undo"] and not rows["claw-kbd-wakeup"]["can_apply"], "applied: Undo")
	s.free()


func test_apply_and_undo_use_the_right_helper() -> void:
	var s := _svc("msi-claw-8-ex", {"claw-kbd-wakeup": "off", "claw8ex-vrr": "on"})
	var r: Object = s.commands.runner
	var got := []
	s.action_finished.connect(func(f, v, okk, m): got.append([f, v, okk, m]))
	s.refresh()
	ok(s.apply("claw-kbd-wakeup"), "apply starts")
	ok(r.calls.has("pkexec %s claw-kbd-wakeup install" % HELPER), "file fix: the admin helper (review S3-2)")
	ok(s.undo("claw8ex-vrr"), "undo starts")
	ok(r.calls.has("pkexec %s claw8ex-vrr remove" % HELPER), "root fix: gamecove-fix remove")
	eq(got.size(), 2, "both finished")
	eq(got[0][3], "Volume buttons don't wake it applied.", "plain result line")
	ok(got[1][3].begins_with("Smooth screen down to 30 fps undone"), "undo line")
	eq(s.choice("claw8ex-vrr"), "off", "the Undo is remembered per device")
	eq(r.calls.filter(func(c): return c == "%s claw-kbd-wakeup status" % HELPER).size(), 2, "status checked again after the action")
	ok(not s.act("nope", "apply"), "unknown fix refused")
	# review L8: Power-page entries are set through their Power controls; their helper takes no on / off
	for f in ["fan", "charge-limit"]:
		for v in ["apply", "undo", "check"]:
			ok(not s.act(f, v), "%s %s refused on the Fixes service" % [f, v])
	ok(r.calls.filter(func(c): return c.contains(" set on") or c.contains(" set off")).is_empty(), "never sends set on / off")
	ok(not s.act("claw-kbd-wakeup", "explode"), "unknown verb refused")
	s.free()


func test_failed_action_messages() -> void:
	var s := _svc("msi-claw-8-ex", {"claw8ex-gyro": "off"})
	var r: Object = s.commands.runner
	r.responses["pkexec*"] = {"code": 127, "out": ""}
	var got := []
	s.action_finished.connect(func(f, v, okk, m): got.append([okk, m]))
	s.apply("claw8ex-gyro")
	eq(got[0], [false, TF.NEEDS_DESKTOP], "no polkit agent: says use Desktop Mode")
	r.responses["pkexec*"] = {"code": 1, "out": "claw8ex-gyro: firmware download failed\n"}
	s.apply("claw8ex-gyro")
	eq(got[1][1], "Couldn't apply gyro aiming: firmware download failed.", "the helper's last line")
	eq(s.choice("claw8ex-gyro"), "", "a failure is not remembered as a choice")
	s.free()


func test_quiet_fix() -> void:
	var h := _tmp("quiet")
	var s := _svc("msi-claw-8-ex", {}, h)
	var root := h + "/root"
	_write(root + "/sys/devices/cpu_atom/cpus", "2-13\n")
	for c in range(2, 10):
		DirAccess.make_dir_recursive_absolute(root + "/sys/devices/system/cpu/cpu%d/cache/index3" % c)
	eq(s.efficiency_cores(), [10, 11, 12, 13], "LP-E cores: Atom cores without L3 (Claw 8 EX layout)")
	var on := s.quiet_commands(true, 4242, [4242, 4243])
	eq(on[0], ["taskset", ["-a", "-p", "-c", "10,11,12,13", "4242"]], "every thread to the LP-E cores")
	eq(on[1], ["renice", ["-n", "10", "-p", "4242", "4243"]], "nice 10")
	var off := s.quiet_commands(false, 4242, [4242])
	eq(off[0][1][3], "0-%d" % (OS.get_processor_count() - 1), "back on every core")
	eq(off[1][1][1], "0", "nice 0")
	_rm(root + "/sys/devices/cpu_atom")
	eq(s.efficiency_cores(), [], "AMD: no E-cores")
	eq(s.quiet_commands(true, 1, [1]).size(), 1, "AMD: only the priority changes")
	eq(FixesSvc.parse_cpus("0-1,4,6-7"), [0, 1, 4, 6, 7])
	var r: Object = s.commands.runner
	s.set_game_running(true)
	ok(r.calls.any(func(c): return c.begins_with("renice -n 10")), "game start: GameCove steps back")
	s.set_game_running(false)
	ok(r.calls.any(func(c): return c.begins_with("renice -n 0")), "game end: back to normal")
	r.calls.clear()
	s.undo("quiet")
	eq(s.status_of("quiet"), "available", "undo: off")
	s.set_game_running(true)
	ok(not r.calls.any(func(c): return c.begins_with("renice")), "off: nothing moves")
	s.apply("quiet")
	ok(r.calls.any(func(c): return c.begins_with("renice -n 10")), "turned on mid-game: applies at once")
	s.free()


func test_what_changed() -> void:
	var h := _tmp("changes")
	var s := _svc("onexplayer-onexfly-f1", {"onexfly-touch": "on"}, h)
	var root := h + "/root"
	_write(root + "/proc/sys/kernel/osrelease", "7.2.8-ogc5.1.fc44.x86_64\n")
	_write(root + "/etc/os-release", "NAME=\"Bazzite\"\nVERSION_ID=44\nOSTREE_VERSION='44.20261105'\n")
	var first := s.check_changes()
	ok(first["first_run"], "first start")
	eq(first["changed"], [], "nothing to compare")
	eq(s.system_snapshot()["os"], "Bazzite 44.20261105", "OSTREE_VERSION wins")
	_write(root + "/proc/sys/kernel/osrelease", "7.3.1-ogc1.fc45.x86_64\n")
	var r: Object = s.commands.runner
	r.responses["%s onexfly-touch status" % HELPER] = {"code": 0, "out": "applies=yes\ninstalled=yes\nos_fixed=yes\nstate=on\n"}
	var again := s.check_changes()
	ok(not again["first_run"], "second start")
	eq(again["changed"].size(), 1, "kernel changed")
	eq(again["changed"][0]["what"], "Kernel")
	eq(again["changed"][0]["to"], "7.3.1-ogc1.fc45.x86_64")
	ok(r.calls.has("%s onexfly-touch status" % HELPER), "every fix checked again")
	eq(s.now_os_fixed(), ["onexfly-touch"], "a fix the system now does itself")
	eq(s.check_changes()["changed"], [], "third start: nothing new")
	s.free()


func test_texts_fall_back_to_the_catalogue() -> void:
	eq(Texts.fix_title("claw-kbd-wakeup"), "Volume buttons don't wake it", "title from fixes.json")
	ok(Texts.fix_explain("onexfly-touch").contains("touch"), "explain from fixes.json")
	eq(Texts.fix_title("claw8ex-buttons"), "MSI buttons", "existing texts win")
	eq(Texts.fix_state("os-fixed"), "Fixed by the system")


# ------------------------------------------------------------ page

func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		out.append(_texts(c))
	return "\n".join(out)


class FakeDevice extends Object:
	var level := "full"
	func display_name() -> String: return "MSI Claw 8 EX AI+"
	func support_level() -> String: return level


func test_page_shows_every_fix_with_status_and_actions() -> void:
	var h := _tmp("page")
	_write(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": ["claw8ex-buttons", "claw-kbd-wakeup"]}))
	var s := _svc("msi-claw-8-ex", {"claw8ex-buttons": "on", "claw8ex-vrr": "off", "claw8ex-gyro": "restart",
		"claw-kbd-wakeup": "on", "ax210-d3cold": "not-needed"}, h)
	s.refresh()
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	var t := _texts(p)
	for want in ["MSI buttons", "Volume buttons don't wake it", "Applied by GameCove", "Needed", "Not needed",
			"Restart to finish", "MSI Claw 8 EX AI+", "GameCove applies this one at install",
			"Apply and Undo ask for your admin password: use Desktop Mode."]:
		ok(t.contains(want), "shows " + want)
	ok(p.buttons.has("undo:claw8ex-buttons"), "applied: Undo")
	ok(p.buttons.has("apply:claw8ex-vrr"), "needed: Apply")
	ok(p.buttons.has("undo:claw8ex-gyro"), "restart pending: Undo")
	ok(not p.buttons.has("apply:ax210-d3cold") and not p.buttons.has("undo:ax210-d3cold"), "not needed: no button")
	ok(p.find_child("Fix_ax210-d3cold", true, false).focus_mode == Control.FOCUS_ALL, "a card without buttons takes focus (scroll)")
	ok(p.find_child("Count_applied", true, false) != null, "summary counts")
	ok(p.focus_chain().size() >= 6, "focus chain covers every fix")
	eq(p.hints_for(p.buttons["apply:claw8ex-vrr"])[0], ["A", "Apply"], "hint names the action")
	# pressing Apply runs the helper, the page rebuilds and toasts the result
	var toasts := []
	p.toast_requested.connect(func(text, _i, tone): toasts.append([text, tone]))
	ok(p.buttons["apply:claw8ex-vrr"].pressed.get_connections().size() > 0, "Apply is wired")
	p.press("claw8ex-vrr", "apply")
	ok(s.commands.runner.calls.has("pkexec %s claw8ex-vrr install" % HELPER), "Apply -> gamecove-fix install")
	eq(toasts.size(), 1, "one toast")
	eq(toasts[0][1], "good", "good tone")
	ok(toasts[0][0].contains("restart"), "says a restart finishes it")
	p.free()
	dev.free()
	s.free()


## CI e2e (seed 60): after Apply / Undo rebuilt the cards, the settings screen still
## pointed focus at the freed Undo button. The page now says it rebuilt, so the host relinks.
func test_page_says_when_it_rebuilt() -> void:
	var h := _tmp("rebuilt")
	var s := _svc("msi-claw-8-ex", {"claw8ex-buttons": "on", "claw8ex-vrr": "off"}, h)
	s.refresh()
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	var n := [0]
	p.rebuilt.connect(func(): n[0] += 1)
	p.press("claw8ex-vrr", "apply")
	ok(n[0] >= 1, "rebuilt emitted after an action")
	p.free()
	dev.free()
	s.free()


func test_page_shows_os_fixed_and_changes() -> void:
	var h := _tmp("page2")
	var s := _svc("asus-rog-ally-x", {"ally-controller-wakeup": "os-fixed", "ally-fingerprint-drain": "off", "ally-mcu-powersave": "off"}, h)
	s.refresh()
	s.last_changes = {"first_run": false, "changed": [{"key": "os", "what": "System", "from": "Bazzite 44", "to": "Bazzite 45"}]}
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	var t := _texts(p)
	ok(t.contains("Already fixed by the system"), "os-fixed chip")
	ok(t.contains("Your system already does this"), "os-fixed note")
	ok(t.contains("System: Bazzite 44 → Bazzite 45"), "what changed")
	ok(p.buttons.has("apply:ally-mcu-powersave"), "optional fix: Apply")
	ok(t.contains("Optional"), "optional fixes say so")
	ok(t.contains("admin password"), "file fixes: the admin password note (review S3-2)")
	p.free()
	dev.free()
	s.free()


func test_page_shows_why_a_fix_is_unavailable() -> void:
	# review S1-3: the helper's reason= shows on the card, and there is no Apply
	var h := _tmp("page_reason")
	var s := _svc("asus-rog-ally", {"ally-fingerprint-drain": "off"}, h)
	s.commands.runner.responses["%s ally-mcu-powersave status" % HELPER] = {"code": 0,
		"out": "applies=yes\ninstalled=no\nos_fixed=no\nhw=yes\nreason=not available: controller MCU firmware 318 is older than 319\nstate=unsupported\n"}
	s.refresh()
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	ok(_texts(p).contains("older than 319"), "reason shown")
	ok(not p.buttons.has("apply:ally-mcu-powersave"), "no Apply")
	p.free()
	dev.free()
	s.free()


func test_stale_inputplumber_override_is_rebuilt_at_start() -> void:
	# review S1-4: an OS update changed the stock file our override shadows
	var h := _tmp("ip_stale")
	var s := _svc("msi-claw-8-ex", {}, h)
	var root := h + "/root"
	DirAccess.make_dir_recursive_absolute(root + "/usr/share/inputplumber/devices")
	DirAccess.make_dir_recursive_absolute(root + "/etc/inputplumber/devices.d")
	var stock := root + FixesSvc.IP_STOCK
	var f := FileAccess.open(stock, FileAccess.WRITE)
	f.store_string("version: 1\ncapability_map_id: claw2\n")
	f.close()
	var o := FileAccess.open(root + FixesSvc.IP_OVERRIDE, FileAccess.WRITE)
	o.store_string("# GameCove override of %s\n# Delete this file...\n# stock-sha256: %s\nversion: 1\n" % [FixesSvc.IP_STOCK, FileAccess.get_sha256(stock)])
	o.close()
	ok(not FixesSvc.ip_override_stale(root), "current override")
	s.data_dir = h + "/data"
	s.check_changes()
	ok(not s.commands.runner.calls.any(func(c): return "refresh" in c), "nothing run while current")
	f = FileAccess.open(stock, FileAccess.WRITE)
	f.store_string("version: 2\ncapability_map_id: claw2\nnew_field: x\n")
	f.close()
	ok(FixesSvc.ip_override_stale(root), "stale after the stock file changed")
	s.check_changes()
	ok(s.commands.runner.calls.has("pkexec %s claw8ex-buttons set refresh" % FixesSvc.FIX_SET_HELPER), "rebuilt through the no-password entry")
	ok("inputplumber" in s.last_changes["changed"].map(func(c): return c["key"]), "shows in what changed")
	# someone else's override is never touched
	o = FileAccess.open(root + FixesSvc.IP_OVERRIDE, FileAccess.WRITE)
	o.store_string("# mine\nversion: 1\n")
	o.close()
	ok(not FixesSvc.ip_override_stale(root), "foreign override ignored")
	s.free()


func test_vrr_line_is_put_back_after_a_steamos_update() -> void:
	# a SteamOS update brings back Valve's /etc/default/grub without the VRR fix's line (fixes/claw8ex-vrr set refresh)
	var h := _tmp("vrr_update")
	var s := _svc("msi-claw-8-ex", {}, h)
	var root := h + "/root"
	DirAccess.make_dir_recursive_absolute(root + "/var/lib/gamecove/fixes/claw8ex-vrr")
	DirAccess.make_dir_recursive_absolute(root + "/etc/default")
	var m := FileAccess.open(root + FixesSvc.VRR_MANIFEST, FileAccess.WRITE)
	m.store_string("file /etc/firmware/edid/gamecove-csw0801-30-120.bin\ngrubline /etc/default/grub\nfile /etc/atomic-update.conf.d/gamecove-claw8ex-vrr.conf\n")
	m.close()
	var g := FileAccess.open(root + FixesSvc.GRUB_DEFAULT, FileAccess.WRITE)
	g.store_string("GRUB_CMDLINE_LINUX_DEFAULT=\"quiet\"\nGRUB_CMDLINE_LINUX_DEFAULT=\"${GRUB_CMDLINE_LINUX_DEFAULT} gamecove.vrr=1\"  # GameCove claw8ex-vrr\n")
	g.close()
	s.data_dir = h + "/data"
	ok(not FixesSvc.vrr_line_lost(root), "line in place")
	s.check_changes()
	ok(not s.commands.runner.calls.any(func(c): return "claw8ex-vrr" in c), "nothing run while the line is there")
	g = FileAccess.open(root + FixesSvc.GRUB_DEFAULT, FileAccess.WRITE)
	g.store_string("GRUB_CMDLINE_LINUX_DEFAULT=\"quiet amd_iommu=off\"\n")
	g.close()
	ok(FixesSvc.vrr_line_lost(root), "lost after the update")
	s.check_changes()
	ok(s.commands.runner.calls.has("pkexec %s claw8ex-vrr set refresh" % FixesSvc.FIX_SET_HELPER), "put back through the no-password entry")
	# a Bazzite install (kernel argument through rpm-ostree, no grub line in its record) is never touched
	m = FileAccess.open(root + FixesSvc.VRR_MANIFEST, FileAccess.WRITE)
	m.store_string("file /etc/firmware/edid/gamecove-csw0801-30-120.bin\nmarker gamecove.vrr=1\n")
	m.close()
	ok(not FixesSvc.vrr_line_lost(root), "Bazzite install: nothing to put back")
	s.free()


func test_page_empty_states() -> void:
	var s := _svc("unknown", {})
	var dev := FakeDevice.new()
	dev.level = "generic"
	var p: Control = Page.build({"fixes": s, "device": dev})
	ok(_texts(p).contains(TF.GENERIC_LINE), "unknown hardware says so")
	eq(p.focus_chain(), [], "nothing to focus")
	p.free()
	dev.free()
	s.free()
	var p2: Control = Page.build({})
	ok(_texts(p2).contains(TF.NO_FIXES_TITLE), "no service: empty state, no crash")
	p2.free()
