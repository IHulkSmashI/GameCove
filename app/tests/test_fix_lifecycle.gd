extends "res://tests/test_case.gd"
## The fix lifecycle (docs/FIXES.md): rule conditions, the signed definitions, and what GameCove
## does by itself to a fix it installed: reverse it when the system catches up or the fix is
## withdrawn, update it (the helper rolls back on failure), never during a game, never on a bad
## signature or an unknown schema, never on anything it didn't install. A fake helper keeps the
## state; nothing real runs, every file is under a temp folder.

const Cond := preload("res://scripts/device/fix_conditions.gd")
const FixData := preload("res://scripts/device/fix_data.gd")
const Life := preload("res://scripts/device/fix_lifecycle.gd")
const FixesSvc := preload("res://scripts/device/fixes.gd")
const Page := preload("res://scripts/ui/device/fixes_page.gd")
const TF := preload("res://scripts/ui/texts_fixes.gd")

const HELPER := "/usr/libexec/gamecove/gamecove-fix"


## Stands in for gamecove-fix (status / pkexec remove, update, install), curl and cosign.
class FakeHelper extends RefCounted:
	var calls: Array[String] = []
	## fix -> {"installed": bool, "os_fixed": bool, "rev": int (installed), "script": int, "hw": bool}
	var fixes := {}
	var pkexec_code := 0      # 127 = no agent, 126 = dismissed
	var update_fails := false # the helper's update exits 1 and leaves the old revision
	var remove_fails := false
	var cosign_code := 0
	var curl_code := 0
	var release := ""         # what curl "downloads" as fixes.json
	var data_dir := ""
	var packages := {}        # name -> version

	func _status(f: String) -> String:
		var x: Dictionary = fixes[f]
		var out := "applies=yes\ninstalled=%s\nos_fixed=%s\nhw=%s\nrevision=%d\n" % [
			"yes" if x["installed"] else "no", "yes" if x.get("os_fixed", false) else "no",
			"yes" if x.get("hw", true) else "no", int(x.get("script", 1))]
		if x["installed"]:
			out += "installed_revision=%d\n" % int(x.get("rev", 1))
			if x.has("conflict"):
				out += "conflict=%s\n" % ("yes" if x["conflict"] else "no")
		# as fixes/lib/gcfix.sh: without the part, a fix that isn't installed is not needed
		var state := "on" if x["installed"] else ("os-fixed" if x.get("os_fixed", false) else ("off" if x.get("hw", true) else "not-needed"))
		return out + "state=%s\n" % state

	func run(program: String, args: PackedStringArray) -> Dictionary:
		var a := Array(args)
		calls.append(" ".join([program] + a))
		if program == HELPER_PATH and a.size() == 2 and a[1] == "status":
			return {"code": 0, "out": _status(a[0])} if fixes.has(a[0]) else {"code": 65, "out": ""}
		if program == "pkexec" and a.size() == 3 and a[0] == HELPER_PATH and fixes.has(a[1]):
			if pkexec_code != 0:
				return {"code": pkexec_code, "out": ""}
			var x: Dictionary = fixes[a[1]]
			match a[2]:
				"remove":
					if remove_fails:
						return {"code": 1, "out": "%s: some changes could not be undone\n" % a[1]}
					x["installed"] = false
					return {"code": 0, "out": "removed\n"}
				"update":
					if update_fails:
						return {"code": 1, "out": "%s: the new version didn't work here; put back as it was\n" % a[1]}
					x["rev"] = int(x.get("script", 1))
					return {"code": 0, "out": "updated\n"}
				"install":
					x["installed"] = true
					x["rev"] = int(x.get("script", 1))
					return {"code": 0, "out": "installed\n"}
		if program == "pkexec" and a.size() == 4 and a[0] == FIX_SET_PATH and a[2] == "set" and a[3] == "refresh":
			refreshes += 1
			# the no-password rebuild: our override stands aside for a map InputPlumber ships itself
			for f in fixes:
				if fixes[f].has("conflict") and fixes[f].get("os_fixed", false) and refresh_resolves:
					fixes[f]["conflict"] = false
			return {"code": 0, "out": "override rebuilt from the updated stock file\n"}
		if program == "curl":
			if curl_code != 0:
				return {"code": curl_code, "out": ""}
			var out := a[a.find("-o") + 1] as String
			var f := FileAccess.open(out, FileAccess.WRITE)
			f.store_string("{}" if out.ends_with(".sigstore.json") else release)
			return {"code": 0, "out": ""}
		if program.ends_with("/cosign"):
			return {"code": cosign_code, "out": ""}
		if program == "rpm":
			var v: String = str(packages.get(a[a.size() - 1], ""))
			return {"code": 0 if v != "" else 1, "out": v if v != "" else "package %s is not installed" % a[a.size() - 1]}
		return {"code": 127, "out": ""}

	func spawn(_program: String, _args: PackedStringArray) -> int:
		return -1

	func ran(prefix: String) -> int:
		var n := 0
		for c in calls:
			if c.begins_with(prefix):
				n += 1
		return n

	const HELPER_PATH := "/usr/libexec/gamecove/gamecove-fix"
	const FIX_SET_PATH := "/usr/libexec/gamecove/gamecove-fix-set"
	var refreshes := 0
	var refresh_resolves := true


func _tmp(name_: String) -> String:
	var d := OS.get_user_data_dir().path_join("test_fix_life_" + name_)
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


## An ROG Ally X with the stick wake-up fix as the helper reports it. opts: can_prompt, background,
## cosign (a cosign binary exists), installed, os_fixed, rev, script.
func _ally(name_: String, opts := {}) -> Array:
	var h := _tmp(name_)
	var r := FakeHelper.new()
	r.fixes["ally-controller-wakeup"] = {"installed": bool(opts.get("installed", true)), "os_fixed": bool(opts.get("os_fixed", false)),
		"rev": int(opts.get("rev", 1)), "script": int(opts.get("script", 1))}
	r.fixes["ally-fingerprint-drain"] = {"installed": false, "os_fixed": false}
	r.fixes["ally-mcu-powersave"] = {"installed": false, "os_fixed": false}
	r.fixes["ax210-d3cold"] = {"installed": false, "os_fixed": false, "hw": false}
	_write(h + "/root/proc/sys/kernel/osrelease", "6.17.7-ba25.fc43.x86_64\n")
	_write(h + "/root/etc/os-release", "NAME=\"Bazzite\"\nID=bazzite\nID_LIKE=\"fedora\"\nVERSION_ID=44\nOSTREE_VERSION='44.20261105.0'\n")
	_write(h + "/root/sys/class/dmi/id/bios_version", "RC72LA.312\n")
	_write(h + "/root/sys/class/firmware-attributes/asus-armoury/attributes/mcu_powersave/current_value", "0\n")
	_write(h + "/root/usr/bin/rpm", "")
	_write(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": ["ally-controller-wakeup"]}))
	if bool(opts.get("cosign", false)):
		_write(h + "/bin/cosign", "")
	var s: FixesSvc = FixesSvc.new()
	s.path_env = h + "/bin"
	s.now_unix = 1794268800
	s.setup({"runner": r, "home": h, "device": "asus-rog-ally-x", "sys_root": h + "/root",
		"can_prompt": bool(opts.get("can_prompt", true)), "background": bool(opts.get("background", false))})
	r.data_dir = s._data_dir()
	return [s, r, h]


func _notices(s: FixesSvc) -> Array:
	var got: Array = []
	s.lifecycle_notice.connect(func(text, tone): got.append([text, tone]))
	return got


## The built-in definitions as a release document, changed by `edit` (func(fixes_by_id)).
func _release(edit: Callable, schema := 1, serial := 1794268800) -> String:
	var doc := FixData.bundled()
	var by := {}
	for e in doc["fixes"]:
		by[e["id"]] = e
	edit.call(by)
	return JSON.stringify({"schema": schema, "serial": serial, "built": "2026-11-10", "fixes": by.values()})


# ------------------------------------------------------------ conditions

func test_versions_compare() -> void:
	eq(Cond.numbers("6.17.7-ba25.fc43.x86_64"), [6, 17, 7], "kernel release -> numbers")
	eq(Cond.numbers("v0.82.0"), [0, 82, 0], "a v prefix")
	eq(Cond.cmp_versions("6.17.7-ba25", "6.19"), -1)
	eq(Cond.cmp_versions("6.19.0", "6.19"), 0, "trailing zeros")
	eq(Cond.cmp_versions("44.20261105.0", "44.20261101"), 1, "Bazzite image versions")
	eq(Cond.cmp_versions("unknown", "6.19"), -2, "no number: can't tell")
	eq(Cond.compare("6.19.2", ">=6.19"), Cond.YES)
	eq(Cond.compare("6.18.9", ">=6.19"), Cond.NO)
	eq(Cond.compare("", ">=6.19"), Cond.UNKNOWN, "nothing read: unknown")
	eq(Cond.compare("6.19", "6.19"), Cond.UNKNOWN, "no operator: unknown")
	eq(Cond.compare("E1T91IMS.110", ">=E1T91IMS.10D", "msi"), Cond.YES, "MSI BIOS revisions are hex")
	eq(Cond.compare("E1T52IMS.110", ">=E1T91IMS.10D", "msi"), Cond.UNKNOWN, "another board: unknown")


func test_conditions_three_valued() -> void:
	var root := _tmp("cond")
	_write(root + "/proc/sys/kernel/osrelease", "6.19.3-ba01.fc44.x86_64\n")
	_write(root + "/etc/os-release", "ID=bazzite\nID_LIKE=\"fedora\"\nOSTREE_VERSION='45.20261201.0'\n")
	_write(root + "/sys/class/dmi/id/bios_version", "E1T91IMS.110\n")
	_write(root + "/usr/lib/udev/rules.d/50-ally-x-controller.rules", "ATTR{power/wakeup}=\"disabled\"\n")
	_write(root + "/sys/module/hid_msi/parameters/quirk", "1\n")
	_write(root + "/sys/devices/platform/x/value", "on\n")
	var f := Cond.gather(root)
	eq(f["kernel"], "6.19.3-ba01.fc44.x86_64")
	eq(f["os_id"], "bazzite")
	eq(f["os_version"], "45.20261201.0")
	eq(f["bios"], "E1T91IMS.110")
	f["tools"] = {"inputplumber": "0.83.1"}
	f["probe"] = {"os_fixed": Cond.YES}
	eq(Cond.evaluate({"kernel": ">=6.19"}, f), Cond.YES, "kernel")
	eq(Cond.evaluate({"kernel": ">=7.0"}, f), Cond.NO)
	eq(Cond.evaluate({"os": "bazzite"}, f), Cond.YES, "os id")
	eq(Cond.evaluate({"os": "fedora"}, f), Cond.YES, "ID_LIKE counts")
	eq(Cond.evaluate({"os": "steamos"}, f), Cond.NO)
	eq(Cond.evaluate({"os": "bazzite", "version": ">=45"}, f), Cond.YES, "image version")
	eq(Cond.evaluate({"os": "bazzite", "version": ">=46"}, f), Cond.NO)
	eq(Cond.evaluate({"bios": ">=E1T91IMS.10E", "scheme": "msi"}, f), Cond.YES, "BIOS, the maker's way")
	eq(Cond.evaluate({"tool": "inputplumber", "version": ">=0.83"}, f), Cond.YES, "package version")
	eq(Cond.evaluate({"tool": "hhd", "version": ">=3"}, f), Cond.UNKNOWN, "a package nobody asked about: unknown")
	eq(Cond.evaluate({"file": "/usr/lib/udev/rules.d/50-ally-x-controller.rules"}, f), Cond.YES, "file exists")
	eq(Cond.evaluate({"file": "/usr/lib/udev/rules.d/none.rules"}, f), Cond.NO)
	eq(Cond.evaluate({"file_contains": {"path": "/usr/lib/udev/rules.d/50-ally-x-controller.rules", "text": "power/wakeup"}}, f), Cond.YES)
	eq(Cond.evaluate({"sysfs_value": {"path": "/sys/devices/platform/x/value", "equals": "on"}}, f), Cond.YES, "sysfs value")
	eq(Cond.evaluate({"sysfs_value": {"path": "/sys/devices/platform/x/value", "equals": "off"}}, f), Cond.NO)
	eq(Cond.evaluate({"module": "hid_msi"}, f), Cond.YES, "module loaded")
	eq(Cond.evaluate({"module_param": {"module": "hid_msi", "param": "quirk", "equals": "1"}}, f), Cond.YES)
	eq(Cond.evaluate({"module_param": {"module": "hid_msi", "param": "other"}}, f), Cond.NO)
	eq(Cond.evaluate({"probe": "os_fixed"}, f), Cond.YES, "the fix's own probe")
	eq(Cond.evaluate({"probe": "hw_absent"}, f), Cond.UNKNOWN, "a probe that gave no answer")
	# unknown never turns into yes
	var unk := {"tool": "hhd", "version": ">=3"}
	eq(Cond.evaluate({"all": [{"kernel": ">=6.19"}, unk]}, f), Cond.UNKNOWN, "all with an unknown: unknown")
	eq(Cond.evaluate({"all": [{"kernel": ">=7.0"}, unk]}, f), Cond.NO, "all with a no: no")
	eq(Cond.evaluate({"any": [{"kernel": ">=7.0"}, unk]}, f), Cond.UNKNOWN, "any without a yes: unknown")
	eq(Cond.evaluate({"any": [{"kernel": ">=6.19"}, unk]}, f), Cond.YES, "any with a yes: yes")
	eq(Cond.evaluate({"not": unk}, f), Cond.UNKNOWN, "not unknown: unknown")
	eq(Cond.evaluate({"not": {"os": "steamos"}}, f), Cond.YES)
	eq(Cond.evaluate({"from_a_newer_gamecove": true}, f), Cond.UNKNOWN, "a rule this build doesn't know: unknown")
	eq(Cond.evaluate("kernel>=6", f), Cond.UNKNOWN, "not a rule: unknown")
	# paths: system folders only, never out of the root
	_write(root + "/home/user/secret", "x")
	eq(Cond.evaluate({"file": "/home/user/secret"}, f), Cond.UNKNOWN, "a path outside the allowed folders is never read")
	eq(Cond.evaluate({"file": "/usr/../home/user/secret"}, f), Cond.UNKNOWN, "no ..")
	eq(Cond.tools_in({"any": [{"tool": "inputplumber", "version": ">=1"}, {"not": {"tool": "hhd", "version": ">=1"}}]}), ["inputplumber", "hhd"], "tools a rule names")
	eq(Cond.parse_package_version("0.83.1"), "0.83.1", "rpm --qf")
	eq(Cond.parse_package_version("inputplumber 0.83.1-1"), "0.83.1-1", "pacman -Q")
	eq(Cond.parse_package_version("package hhd is not installed"), "", "not installed")


func test_every_shipped_rule_is_understood() -> void:
	# a rule the app can't evaluate would silently never fire: every leaf in the built-in
	# definitions must answer yes or no on a system where everything can be read
	var root := _tmp("shipped")
	_write(root + "/proc/sys/kernel/osrelease", "6.17.7\n")
	_write(root + "/etc/os-release", "ID=bazzite\nVERSION_ID=44\n")
	var f := Cond.gather(root)
	f["probe"] = {"os_fixed": Cond.NO, "hw_absent": Cond.NO}
	f["tools"] = {}
	for t in Cond.TOOL_PACKAGES:
		f["tools"][t] = "1.0"
	f["bios"] = "1.0"
	f["ec"] = "1.0"
	var n := 0
	for e in FixData.bundled()["fixes"]:
		var life: Dictionary = e["lifecycle"]
		for key in ["needed_when", "obsolete_when"]:
			if life[key] != null:
				n += 1
				ok(Cond.evaluate(life[key], f) != Cond.UNKNOWN, "%s %s: understood" % [e["id"], key])
		if e["kind"] in ["root", "file"]:
			ok(Cond.uses_probe(life["obsolete_when"]), e["id"] + ": can tell by itself when the system caught up")
	ok(n >= 12, "the shipped fixes carry rules")


# ------------------------------------------------------------ judge

func test_judge() -> void:
	var def := {"id": "x", "kind": "file", "revision": 2, "withdrawn": null,
		"lifecycle": {"needed_when": null, "obsolete_when": {"any": [{"probe": "os_fixed"}, {"kernel": ">=6.19"}]}}}
	var facts := {"root": "", "kernel": "6.17.0"}
	var on := {"installed": "yes", "os_fixed": "no", "revision": "2", "installed_revision": "2"}
	eq(Life.judge(def, on, facts)["action"], "", "installed, still needed: nothing")
	eq(Life.judge(def, on.merged({"os_fixed": "yes"}, true), facts)["action"], "retire", "the probe says the system does it: retire")
	eq(Life.judge(def, on, {"root": "", "kernel": "6.19.1"})["reason"], "native", "the kernel rule holds: retire, natively fixed")
	eq(Life.judge(def, on, {"root": "", "kernel": ""})["action"], "", "kernel unreadable: unknown, nothing")
	eq(Life.judge(def, on.merged({"os_fixed": "yes"}, true), facts, true)["action"], "", "keep the workaround anyway: nothing")
	# never anything GameCove didn't install: the same rule from the system or the user has no record
	var foreign := {"installed": "no", "os_fixed": "yes", "revision": "2"}
	eq(Life.judge(def, foreign, facts)["action"], "", "not installed by GameCove: never touched")
	eq(Life.judge(def, foreign, facts)["obsolete"], Cond.YES, "but known as not needed")
	eq(Life.judge(def, {}, {"root": "", "kernel": "6.19.1"})["action"], "", "no status answer: nothing")
	var w := def.merged({"withdrawn": {"date": "2026-11-10", "reason": "It broke resume on BIOS 320."}}, true)
	eq(Life.judge(w, on, facts)["reason"], "withdrawn", "withdrawn and installed: retire")
	eq(Life.judge(w, foreign, facts)["action"], "", "withdrawn, not installed: nothing to do")
	eq(Life.judge(def, on.merged({"installed_revision": "1"}, true), facts)["action"], "update", "an older revision installed: update")
	eq(Life.judge(def, {"installed": "yes", "os_fixed": "no"}, facts)["action"], "", "a helper from before revisions: no update")
	eq(Life.judge(def.merged({"kind": "power"}, true), on.merged({"os_fixed": "yes"}, true), facts)["action"], "", "settings have no lifecycle")


# ------------------------------------------------------------ reverse when the system catches up

func test_reverse_on_obsolete() -> void:
	var a := _ally("reverse", {"os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	var said := _notices(s)
	s.check_changes()
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "the fix's own undo ran, once")
	eq(r.ran("pkexec %s ally-fingerprint-drain" % HELPER), 0, "a fix that isn't installed is left alone")
	ok(not r.fixes["ally-controller-wakeup"]["installed"], "removed")
	eq(said.size(), 1, "said once")
	eq(said[0][0], "Your system now takes care of \"Sticks don't wake it\" itself, so GameCove removed its workaround.", "in plain words")
	var h := s.history()
	eq(h.size(), 1, "one History entry")
	eq(h[0]["action"], "removed")
	eq(h[0]["fix"], "ally-controller-wakeup")
	eq(s.choice("ally-controller-wakeup"), "off", "recorded as undone, so a repair doesn't put it back")
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]
	eq(row["group"], "retired", "listed under Not needed any more")
	ok(not row["can_apply"], "and never offered")
	# the next start: nothing more to do, nothing said again
	r.calls.clear()
	s.check_changes()
	eq(r.ran("pkexec"), 0, "second start: no helper call")
	eq(said.size(), 1, "not said again")
	# the record is on disk
	var disk: Dictionary = Life.load_state(a[2] + "/.local/share/gamecove/fixes-lifecycle.json")
	eq(Life.history(disk, "asus-rog-ally-x").size(), 1, "history saved")
	s.free()


func test_reverse_by_a_declared_rule() -> void:
	# Bazzite ships the same rule: the file rule in the fix's obsolete_when holds even when its probe says no
	var a := _ally("rule")
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	_write(a[2] + "/root/usr/lib/udev/rules.d/50-ally-x-controller.rules", "# bazzite\n")
	s.check_changes()
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "the declared rule retires it")
	s.free()


func test_a_failed_removal_is_reported_and_not_retried_every_start() -> void:
	var a := _ally("removefail", {"os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.remove_fails = true
	var said := _notices(s)
	s.check_changes()
	ok(r.fixes["ally-controller-wakeup"]["installed"], "still there")
	eq(s.history()[0]["action"], "remove-failed", "History says it failed")
	ok(said[0][0].contains("couldn't remove"), "said so")
	eq(s.choice("ally-controller-wakeup"), "", "not recorded as undone")
	r.calls.clear()
	s.check_changes()
	eq(r.ran("pkexec"), 0, "not tried again by itself on the next start")
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]
	eq(row["pending"], "retire", "the page keeps Remove now")
	r.remove_fails = false
	ok(s.run_pending("ally-controller-wakeup"), "Remove now")
	ok(not r.fixes["ally-controller-wakeup"]["installed"], "removed by hand")
	s.free()


func test_gaming_mode_waits_for_desktop() -> void:
	var a := _ally("gaming", {"os_fixed": true, "can_prompt": false})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	var said := _notices(s)
	s.check_changes()
	eq(r.ran("pkexec"), 0, "Gaming Mode can't ask for the password: no pkexec at all")
	ok(r.fixes["ally-controller-wakeup"]["installed"], "nothing changed")
	eq(said.size(), 1, "said once that it waits")
	ok(said[0][0].contains("Desktop Mode"), "names Desktop Mode")
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]
	eq(row["pending"], "retire", "the row says it waits")
	eq(row["group"], "applied", "still listed as applied")
	s.check_changes()
	eq(said.size(), 1, "next start in Gaming Mode: not said again")
	eq(s.history().size(), 0, "nothing happened yet, so nothing in History")
	# the next start in Desktop Mode does it
	s.can_prompt_override = true
	s.check_changes()
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "Desktop Mode: removed")
	eq(s.history()[0]["action"], "removed")
	s.free()


func test_no_password_given_changes_nothing() -> void:
	var a := _ally("dismissed", {"os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.pkexec_code = 126
	var said := _notices(s)
	s.check_changes()
	ok(r.fixes["ally-controller-wakeup"]["installed"], "still installed")
	eq(s.history().size(), 0, "nothing in History")
	eq(said.size(), 1, "told that it waits")
	eq(s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]["pending"], "retire")
	s.free()


func test_never_touches_what_gamecove_did_not_install() -> void:
	# the user (or the system) has the same rule; GameCove's helper has no record of it
	var a := _ally("foreign", {"installed": false, "os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	s.check_changes()
	s.refresh()
	eq(r.ran("pkexec"), 0, "no helper call")
	eq(s.history().size(), 0)
	eq(s.status_of("ally-controller-wakeup"), "os-fixed", "shown as fixed by the system")
	ok(not s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]["can_apply"], "and not offered")
	s.free()


func test_never_during_a_game() -> void:
	var a := _ally("game", {"os_fixed": true, "background": true, "cosign": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.release = _release(func(_by): pass)
	s.set_game_running(true)
	r.calls.clear()
	eq(s.start_lifecycle(true), "game_running", "a pass asked for during a game is put off")
	eq(s.maybe_fetch_data(true), "game_running", "no download during a game either")
	s.check_changes()
	eq(r.ran("pkexec"), 0, "no helper call while the game runs")
	eq(r.ran("curl"), 0, "no network while the game runs")
	eq(r.ran(HELPER), 0, "not even a status check")
	ok(r.fixes["ally-controller-wakeup"]["installed"], "untouched")
	s.set_game_running(false)
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "it runs when the game ends")
	s.free()


func test_a_game_starting_holds_what_is_left() -> void:
	var a := _ally("midgame", {"os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.fixes["ally-fingerprint-drain"] = {"installed": true, "os_fixed": true}
	_write(a[2] + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": ["ally-controller-wakeup", "ally-fingerprint-drain"]}))
	# the game starts while the first removal runs
	var started := [false]
	s.lifecycle_notice.connect(func(_t, _tone):
		if not started[0]:
			started[0] = true
			s.set_game_running(true))
	s.check_changes()
	eq(r.ran("pkexec %s" % HELPER), 1, "only the change already running finished")
	s.set_game_running(false)
	eq(r.ran("pkexec %s" % HELPER), 2, "the rest ran after the game")
	s.free()


# ------------------------------------------------------------ update, with rollback

func test_update_to_a_new_revision() -> void:
	var a := _ally("update", {"rev": 1, "script": 2})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	var said := _notices(s)
	s.check_changes()
	eq(r.ran("pkexec %s ally-controller-wakeup update" % HELPER), 1, "the helper's update ran")
	eq(r.fixes["ally-controller-wakeup"]["rev"], 2, "now at the script's revision")
	eq(s.history()[0]["action"], "updated")
	ok(said[0][0].contains("updated"), "said once")
	r.calls.clear()
	s.check_changes()
	eq(r.ran("pkexec"), 0, "up to date: nothing more")
	s.free()


func test_update_failure_rolls_back_and_says_so() -> void:
	var a := _ally("rollback", {"rev": 1, "script": 2})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.update_fails = true   # the helper put the old files back and exited 1 (fixes/lib/test.sh proves that part)
	var said := _notices(s)
	s.check_changes()
	ok(r.fixes["ally-controller-wakeup"]["installed"], "the old version is still in place")
	eq(r.fixes["ally-controller-wakeup"]["rev"], 1, "at its old revision")
	eq(s.history()[0]["action"], "update-failed", "History: failed, rolled back")
	ok(s.history()[0]["detail"].contains("put back as it was"), "with the helper's reason")
	eq(said[0][1], "warn")
	ok(said[0][0].contains("put the old version back"), "said in plain words")
	eq(s.status_of("ally-controller-wakeup"), "applied", "still applied")
	r.calls.clear()
	s.check_changes()
	eq(r.ran("pkexec"), 0, "not retried at every start")
	eq(s.rows().filter(func(x): return x["id"] == "ally-controller-wakeup")[0]["pending"], "update", "Update now stays on the page")
	s.free()


func test_exit_code_alone_is_not_believed() -> void:
	# the helper said ok but the fix's own status still shows the old revision
	var a := _ally("verify", {"rev": 1, "script": 2})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	s.commands.runner = _LyingRunner.new(r)
	s.check_changes()
	eq(s.history()[0]["action"], "update-failed", "verified by status, not by the exit code")
	ok(r.calls.has("pkexec (lied)"), "the helper was asked")
	s.free()


class _LyingRunner extends RefCounted:
	var inner: FakeHelper
	func _init(r: FakeHelper) -> void:
		inner = r
	func run(program: String, args: PackedStringArray) -> Dictionary:
		if program == "pkexec":
			inner.calls.append("pkexec (lied)")
			return {"code": 0, "out": "updated\n"}
		return inner.run(program, args)
	func spawn(_p: String, _a: PackedStringArray) -> int:
		return -1


# ------------------------------------------------------------ the signed definitions

func test_release_is_used_only_when_cosign_accepts_it() -> void:
	var a := _ally("sig", {"background": true, "cosign": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.release = _release(func(by): by["ally-controller-wakeup"]["withdrawn"] = {"date": "2026-11-10", "reason": "It stopped the power button waking the Ally."})
	r.cosign_code = 1   # a bad signature
	s.check_changes()
	eq(s.data_result, "bad", "cosign refused it")
	eq(r.ran("pkexec"), 0, "a failed signature never makes GameCove act")
	ok(r.fixes["ally-controller-wakeup"]["installed"], "the fix stays")
	ok(not FileAccess.file_exists(r.data_dir.path_join("fixes.json")), "the download isn't kept")
	ok(not FileAccess.file_exists(r.data_dir.path_join("fixes.json.part")), "nor its part file")
	ok(s.entry("ally-controller-wakeup")["withdrawn"] == null, "the built-in definition stays in charge")
	ok(r.calls.any(func(c): return c.contains("verify-blob") and c.contains("fixes\\.yml@refs/heads/main") and c.contains("token.actions.githubusercontent.com")), "checked against the workflow's identity")
	s.free()


func test_unknown_schema_is_ignored() -> void:
	var a := _ally("schema", {"background": true, "cosign": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.release = _release(func(by): by["ally-controller-wakeup"]["withdrawn"] = {"date": "2026-11-10", "reason": "Withdrawn in a newer format."}, 2)
	s.check_changes()
	eq(s.data_result, "schema", "properly signed, but another schema")
	eq(r.ran("pkexec"), 0, "never acted on")
	ok(not FileAccess.file_exists(r.data_dir.path_join("fixes.json")), "not kept")
	eq(FixData.parse("{\"schema\": 1.5, \"fixes\": []}"), {}, "1.5 isn't 1")
	eq(FixData.parse("{\"schema\": \"1\", \"fixes\": []}"), {}, "a string isn't 1")
	eq(FixData.parse("[1]"), {}, "not a document")
	s.free()


func test_no_cosign_no_download_and_privacy_switch() -> void:
	var a := _ally("nocosign", {"background": true, "cosign": false})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	s.check_changes()
	eq(s.data_result, "no-cosign", "no way to check a signature here")
	eq(r.ran("curl"), 0, "so nothing is downloaded")
	s.free()
	a = _ally("privacy", {"background": false, "cosign": true})
	s = a[0]
	r = a[1]
	s.check_changes()
	eq(r.ran("curl"), 0, "Background lookups off: no request")
	eq(s.maybe_fetch_data(), "privacy")
	s.free()
	a = _ally("daily", {"background": true, "cosign": true})
	s = a[0]
	r = a[1]
	r.release = _release(func(_by): pass)
	s.check_changes()
	eq(r.ran("curl"), 2, "the file and its signature bundle")
	eq(s.data_result, "verified")
	s.check_changes()
	eq(r.ran("curl"), 2, "at most once a day")
	s.now_unix += 25 * 3600
	s.check_changes()
	eq(r.ran("curl"), 4, "again the next day")
	ok(r.calls.any(func(c): return c.begins_with("curl --proto =https --proto-redir =https") and c.contains("--max-filesize") and c.ends_with("/releases/download/fixes/fixes.json")), "https only, size-capped, from the fixes release")
	s.free()


func test_offline_keeps_the_built_in_definitions() -> void:
	var a := _ally("offline", {"background": true, "cosign": true, "os_fixed": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.curl_code = 6
	s.check_changes()
	eq(s.data_result, "offline")
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "the built-in rules still work offline")
	s.free()


func test_withdrawn_fix_is_reversed_and_no_longer_offered() -> void:
	var a := _ally("withdrawn", {"background": true, "cosign": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.release = _release(func(by):
		by["ally-controller-wakeup"]["withdrawn"] = {"date": "2026-11-10", "reason": "It stopped the power button waking the Ally."}
		by["ally-mcu-powersave"]["withdrawn"] = {"date": "2026-11-10", "reason": "Controller lost after sleep on MCU 320."})
	var said := _notices(s)
	s.check_changes()
	eq(s.data_result, "verified")
	eq(r.ran("pkexec %s ally-controller-wakeup remove" % HELPER), 1, "the withdrawn fix is reversed at this pass")
	eq(said[0][0], "GameCove removed its \"Sticks don't wake it\" workaround: It stopped the power button waking the Ally.", "with the reason")
	eq(s.history()[0]["reason"], "withdrawn")
	s.refresh()
	eq(s.status_of("ally-mcu-powersave"), "retired", "a withdrawn fix that isn't installed is no longer offered")
	ok(not s.apply("ally-mcu-powersave"), "and can't be applied")
	eq(r.ran("pkexec %s ally-mcu-powersave" % HELPER), 0)
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "ally-mcu-powersave")[0]
	eq(row["withdrawn"], "Controller lost after sleep on MCU 320.", "the page shows why")
	# an older (replayed) release can't bring it back
	r.release = _release(func(_by): pass, 1, 1794268800 - 86400)
	s.now_unix += 25 * 3600
	s.check_changes()
	eq(s.data_result, "older", "an older file than the one held is refused")
	ok(s.entry("ally-mcu-powersave")["withdrawn"] != null, "still withdrawn")
	s.free()


func test_release_is_data_only() -> void:
	var built: Array = FixData.bundled()["fixes"]
	var remote := {"schema": 1, "fixes": [
		{"id": "ally-controller-wakeup", "kind": "app", "password": "none", "auto": "*", "optional": "*", "page": "power",
			"revision": 5, "changes": [{"type": "file", "target": "/etc/shadow", "detail": "nope nope nope"}],
			"lifecycle": {"needed_when": null, "obsolete_when": {"kernel": ">=6.19"}}, "title": 7, "line": "A better line for it."},
		{"id": "brand-new-root-fix", "kind": "root", "title": "x", "line": "y", "sources": ["z"]},
		{"id": "advice-new", "kind": "advice", "title": "BIOS 320 needed", "line": "Update the BIOS to 320 for sleep to work.",
			"optional": "controller:asus-ally-x", "sources": ["https://example.com/bios"], "breaks": "sleep"},
		"junk"]}
	var m := FixData.merge(built, FixData.parse(JSON.stringify(remote)))
	var e: Dictionary = m.filter(func(x): return x["id"] == "ally-controller-wakeup")[0]
	var b: Dictionary = built.filter(func(x): return x["id"] == "ally-controller-wakeup")[0]
	eq(e["kind"], "file", "kind comes from GameCove itself")
	eq(e["password"], "admin", "so does the password rule")
	eq(e["auto"], b["auto"], "and who it is offered to")
	eq(e["optional"], b["optional"])
	eq(e["page"], "fixes")
	eq(e["changes"], b["changes"], "and what it changes")
	eq(e["lifecycle"]["obsolete_when"], {"kernel": ">=6.19"}, "lifecycle rules do come from the release")
	eq(e["line"], "A better line for it.", "and words")
	eq(e["title"], b["title"], "a field of the wrong type is skipped")
	ok(e["newer_revision"], "a newer revision is only announced")
	ok(m.filter(func(x): return x["id"] == "brand-new-root-fix").is_empty(), "the release can't add a fix that runs anything")
	var adv: Array = m.filter(func(x): return x["id"] == "advice-new")
	eq(adv.size(), 1, "it can add advice")
	eq(adv[0]["changes"], [], "which changes nothing")
	eq(adv[0]["default"], "advice-only")


func test_tool_rule_hides_advice() -> void:
	var h := _tmp("advice")
	var r := FakeHelper.new()
	_write(h + "/root/usr/bin/rpm", "")
	_write(h + "/root/etc/os-release", "ID=bazzite\n")
	var s: FixesSvc = FixesSvc.new()
	s.setup({"runner": r, "home": h, "device": "asus-rog-xbox-ally-x", "sys_root": h + "/root", "can_prompt": false, "background": false})
	r.packages["steamos-powerbuttond"] = "3.2"
	s.check_changes()
	var rows := s.rows().filter(func(x): return x["id"] == "advice-xbox-ally-power-button")
	eq(rows.size(), 1, "old powerbuttond: the advice shows")
	eq(rows[0]["status"], "advice")
	ok(not rows[0]["can_apply"] and not rows[0]["can_undo"], "advice has nothing to apply")
	ok(not s.apply("advice-xbox-ally-power-button"), "and can't be applied")
	r.packages["steamos-powerbuttond"] = "3.4"
	_write(h + "/root/proc/sys/kernel/osrelease", "6.18.0\n")   # a system update
	s.check_changes()
	ok(s.rows().filter(func(x): return x["id"] == "advice-xbox-ally-power-button").is_empty(), "powerbuttond 3.4: the advice is gone")
	s.free()


# ------------------------------------------------------------ keep the workaround anyway, and the page

class FakeDevice extends Object:
	func display_name() -> String: return "ROG Ally X"
	func support_level() -> String: return "partial"


func _texts(n: Node) -> String:
	var out := PackedStringArray()
	if n is Label or n is Button:
		out.append(n.text)
	for c in n.get_children():
		out.append(_texts(c))
	return "\n".join(out)


func test_keep_the_workaround_anyway() -> void:
	var a := _ally("keep")
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	_write(a[2] + "/root/usr/lib/udev/rules.d/50-ally-x-controller.rules", "# bazzite\n")
	s.check_changes()
	ok(not r.fixes["ally-controller-wakeup"]["installed"], "removed by the rule")
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	var t := _texts(p)
	ok(t.contains("History"), "History on the page")
	ok(t.contains("Removed Sticks don't wake it: your system does it itself now."), "what happened, in plain words")
	ok(p.buttons.has("keep:ally-controller-wakeup"), "with Keep it anyway")
	ok(t.contains("Not needed any more"), "the group")
	eq(p.hints_for(p.buttons["keep:ally-controller-wakeup"])[0], ["A", "Keep it anyway"], "the hint names it")
	p.press("ally-controller-wakeup", "keep")
	ok(s.kept("ally-controller-wakeup"), "remembered")
	eq(r.ran("pkexec %s ally-controller-wakeup install" % HELPER), 1, "applied again")
	ok(r.fixes["ally-controller-wakeup"]["installed"], "back in place")
	eq(s.choice("ally-controller-wakeup"), "on")
	ok(_texts(p).contains("you kept it"), "History says so")
	ok(not p.buttons.has("keep:ally-controller-wakeup"), "the button is gone")
	r.calls.clear()
	s.check_changes()
	eq(r.ran("pkexec"), 0, "and GameCove no longer removes it by itself")
	ok(_texts(p).contains(TF.KEPT_NOTE), "the card says why it stays")
	# Undo by hand lifts the keep
	s.undo("ally-controller-wakeup")
	ok(not s.kept("ally-controller-wakeup"), "Undo lifts it")
	p.free()
	dev.free()
	s.free()


func test_page_shows_a_waiting_removal() -> void:
	var a := _ally("pagewait", {"os_fixed": true, "can_prompt": false})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	s.check_changes()
	s.refresh()
	var dev := FakeDevice.new()
	var p: Control = Page.build({"fixes": s, "device": dev})
	ok(_texts(p).contains(TF.PENDING_RETIRE), "says it waits for Desktop Mode")
	ok(p.buttons.has("pending:ally-controller-wakeup"), "Remove now")
	ok(not p.buttons.has("undo:ally-controller-wakeup"), "instead of Undo")
	eq((p.buttons["pending:ally-controller-wakeup"] as Button).text, "Remove now")
	r.pkexec_code = 127
	p.press("ally-controller-wakeup", "pending")
	ok(r.fixes["ally-controller-wakeup"]["installed"], "Gaming Mode: the helper couldn't ask, nothing changed")
	r.pkexec_code = 0
	p.press("ally-controller-wakeup", "pending")
	ok(not r.fixes["ally-controller-wakeup"]["installed"], "with a password prompt: removed")
	ok(p.find_child("History", true, false) != null, "and History shows it")
	# Recommended / Optional badges and the groups
	var t := _texts(p)
	ok(t.contains("Recommended for your ROG Ally X"), "Recommended group names the device")
	ok(t.contains("Optional"), "Optional group")
	var lv: Control = p.find_child("Fix_ally-fingerprint-drain", true, false).find_child("Level", true, false)
	ok(lv != null and _texts(lv).contains("Recommended"), "a Recommended badge")
	var lo: Control = p.find_child("Fix_ally-mcu-powersave", true, false).find_child("Level", true, false)
	ok(lo != null and _texts(lo).contains("Optional"), "an Optional badge")
	ok(not t.contains("Suggested") and not t.contains("Extras"), "only the two words")
	p.free()
	dev.free()
	s.free()


## An MSI Claw 8 EX with the face-button fix installed, after an InputPlumber update that ships
## its own map for the board (os_fixed) while ours still names our map (conflict). stale: our
## override was built from the old stock file, so the no-password rebuild runs at start.
func _claw(name_: String, opts := {}) -> Array:
	var h := _tmp(name_)
	var r := FakeHelper.new()
	r.refresh_resolves = bool(opts.get("refresh_resolves", true))
	r.fixes["claw8ex-buttons"] = {"installed": true, "os_fixed": bool(opts.get("os_fixed", true)), "conflict": bool(opts.get("conflict", true))}
	for f in ["claw8ex-vrr", "claw8ex-gyro", "claw-kbd-wakeup", "claw-wifi-d3cold"]:
		r.fixes[f] = {"installed": false, "os_fixed": false}
	_write(h + "/root/proc/sys/kernel/osrelease", "6.17.7-ba25.fc43.x86_64\n")
	_write(h + "/root/etc/os-release", "NAME=\"Bazzite\"\nID=bazzite\nVERSION_ID=44\nOSTREE_VERSION='44.20261105.0'\n")
	_write(h + "/root/usr/bin/rpm-ostree", "")
	_write(h + "/root/sys/module/xe/version", "0\n")
	_write(h + "/root" + FixesSvc.IP_STOCK, "capability_map_id: claw8ex_upstream\n")
	var sha := "0000" if bool(opts.get("stale", true)) else FileAccess.get_sha256(h + "/root" + FixesSvc.IP_STOCK)
	_write(h + "/root" + FixesSvc.IP_OVERRIDE, "# GameCove override of %s\n# stock-sha256: %s\ncapability_map_id: gamecove_claw8ex\n" % [FixesSvc.IP_STOCK, sha])
	_write(h + "/.local/share/gamecove/install-state.json", JSON.stringify({"fixes": ["claw8ex-buttons"]}))
	var s: FixesSvc = FixesSvc.new()
	s.path_env = h + "/bin"
	s.now_unix = 1794268800
	s.setup({"runner": r, "home": h, "device": "msi-claw-8-ex", "sys_root": h + "/root",
		"can_prompt": bool(opts.get("can_prompt", false)), "background": false})
	return [s, r, h]


func _attention(s: FixesSvc) -> Array:
	var got: Array = []
	s.attention_needed.connect(func(items): got.append(items))
	return got


func test_a_clash_the_no_password_rebuild_settles_is_not_shouted() -> void:
	# InputPlumber now ships the Claw 8 EX map: the start's no-password rebuild drops our map from
	# the override (fixes/lib/claw8ex-common.sh), so nothing is in the system's way any more; the
	# real removal of our two files still waits for Desktop Mode, said once like any other
	var a := _claw("clash_settled")
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	var said := _notices(s)
	var loud := _attention(s)
	s.check_changes()
	eq(r.refreshes, 1, "the no-password rebuild ran at start")
	eq(r.ran("pkexec %s " % HELPER), 0, "no admin helper call in Gaming Mode")
	ok(not s.harmful("claw8ex-buttons"), "standing aside: not harmful")
	eq(loud.size(), 0, "no start dialog")
	eq(said.size(), 1, "the wait is said once")
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "claw8ex-buttons")[0]
	eq(row["pending"], "retire", "Remove now stays on the page")
	ok(not row["harmful"], "and the card isn't red")
	s.free()


func test_a_clash_that_stays_is_shown_at_every_start() -> void:
	# the rebuild couldn't settle it (or no rebuild was due): both maps at once, so the start says
	# so over the home screen each time, never only in History, until it is out
	var a := _claw("clash_stays", {"refresh_resolves": false})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	var said := _notices(s)
	var loud := _attention(s)
	s.check_changes()
	eq(r.refreshes, 1, "the rebuild ran first, and the pass waited for it")
	ok(s.harmful("claw8ex-buttons"), "in the system's way")
	eq(loud.size(), 1, "shown at start")
	eq(loud[0].size(), 1)
	eq(loud[0][0]["id"], "claw8ex-buttons")
	eq(loud[0][0]["reason"], "native")
	eq(said.size(), 0, "no toast on top of the dialog")
	var row: Dictionary = s.rows().filter(func(x): return x["id"] == "claw8ex-buttons")[0]
	ok(row["harmful"], "the card says it is in the way")
	eq(s.counts()["harmful"], 1, "and the summary counts it")
	s.check_changes()
	eq(loud.size(), 1, "once per GameCove run")
	# the next GameCove start (a new service on the same data folder) says it again
	var h: String = a[2]
	var s2: FixesSvc = FixesSvc.new()
	s2.path_env = h + "/bin"
	s2.now_unix = 1794268800
	s2.setup({"runner": r, "home": h, "device": "msi-claw-8-ex", "sys_root": h + "/root", "can_prompt": false, "background": false})
	var loud2 := _attention(s2)
	s2.check_changes()
	eq(loud2.size(), 1, "next start: shown again")
	# Desktop Mode: removed at start, so nothing left to show
	var s3: FixesSvc = FixesSvc.new()
	s3.path_env = h + "/bin"
	s3.now_unix = 1794268800
	s3.setup({"runner": r, "home": h, "device": "msi-claw-8-ex", "sys_root": h + "/root", "can_prompt": true, "background": false})
	var loud3 := _attention(s3)
	s3.check_changes()
	eq(r.ran("pkexec %s claw8ex-buttons remove" % HELPER), 1, "Desktop Mode takes it out")
	eq(loud3.size(), 0, "and there is nothing to show")
	eq(s3.attention().size(), 0)
	s.free()
	s2.free()
	s3.free()


func test_kept_or_harmless_never_shouts() -> void:
	var a := _claw("clash_kept", {"refresh_resolves": false})
	var s: FixesSvc = a[0]
	s.refresh()
	s.keep("claw8ex-buttons")
	var loud := _attention(s)
	s.check_changes()
	eq(loud.size(), 0, "Keep it anyway: no dialog")
	s.free()
	# a harmless one (the same udev rule twice) waits quietly, said once
	var b := _ally("harmless_wait", {"os_fixed": true, "can_prompt": false})
	var s2: FixesSvc = b[0]
	var loud2 := _attention(s2)
	s2.check_changes()
	eq(loud2.size(), 0, "harmless: no dialog")
	ok(not s2.harmful("ally-controller-wakeup"))
	s2.free()


func test_a_withdrawn_fix_left_in_place_is_shown_at_start() -> void:
	var a := _ally("withdrawn_loud", {"can_prompt": false, "background": true, "cosign": true})
	var s: FixesSvc = a[0]
	var r: FakeHelper = a[1]
	r.release = _release(func(by): by["ally-controller-wakeup"]["withdrawn"] = {"date": "2026-11-10", "reason": "It stopped the controller waking on one BIOS."})
	var loud := _attention(s)
	s.check_changes()
	eq(loud.size(), 1, "shown at start")
	eq(loud[0][0]["reason"], "withdrawn")
	ok(TF.attention_line(loud[0][0]).contains("one BIOS"), "with the reason")
	s.free()


func test_attention_dialog() -> void:
	var D = load("res://scripts/ui/fix_attention_dialog.gd")
	var items := [{"id": "claw8ex-buttons", "title": "MSI buttons", "reason": "native", "withdrawn": ""}]
	var d: Control = D.new()
	d.build(items, false)
	ok(_texts(d).contains("Our MSI buttons fix is in your system's way"), "names the fix")
	ok(_texts(d).contains("Desktop Mode"), "Gaming Mode: says where it can be done")
	ok(not d.buttons.has("remove"), "no Remove now where no prompt can show")
	eq(d.default_button(), d.buttons["open"], "A opens the Fixes page")
	var got: Array = []
	d.decided.connect(func(c): got.append(c))
	d.finish("open")
	eq(got, ["open"])
	d.free()
	var d2: Control = D.new()
	d2.build(items + [{"id": "x", "title": "Old fix", "reason": "withdrawn", "withdrawn": "It broke sleep."}], true)
	ok(d2.buttons.has("remove"), "Desktop Mode: Remove now")
	eq(d2.default_button(), d2.buttons["remove"])
	ok(_texts(d2).contains("2 of our fixes"), "two at once")
	ok(_texts(d2).contains("It broke sleep."), "the withdrawn reason")
	d2.free()

