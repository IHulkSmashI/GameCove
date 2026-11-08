extends "res://tests/test_case.gd"
## OS detection, update parsers and the Updates state machine, against fixture
## roots and a fake runner. Nothing real runs.

const OsInfo := preload("res://scripts/system/os_info.gd")
const Parse := preload("res://scripts/system/update_parse.gd")
const UpdatesScript := preload("res://scripts/system/updates.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")

const HELPER := "/usr/bin/steamos-polkit-helpers/steamos-update"


func _root(name: String) -> String:
	return fixture("system/os/" + name)


func _upd(root_name: String, fake: RefCounted) -> Node:
	var u: Node = UpdatesScript.new()
	u.setup(fake, _root(root_name), fixture("system/home"))
	return u


func _f(name: String) -> String:
	return fixture("system/updates/" + name)


## Records every signal of an Updates instance.
class Spy:
	var checked: Array = []
	var finished: Array = []
	var progress: Array = []
	var changed := 0

	func _init(u: Node) -> void:
		u.checked.connect(func(k, r): checked.append([k, r]))
		u.finished.connect(func(k, ok, m): finished.append([k, ok, m]))
		u.progress.connect(func(k, p, l): progress.append([k, p, l]))
		u.changed.connect(func(_s): changed += 1)


# ---- os-release / detection ---------------------------------------------------

func test_parse_os_release_quotes_and_comments() -> void:
	var d := OsInfo.parse_os_release("# c\nID=bazzite\nNAME=\"Baz \\\"zite\\\"\"\nOSTREE_VERSION='43.1'\nBAD\n")
	eq(d.get("ID"), "bazzite")
	eq(d.get("NAME"), "Baz \"zite\"")
	eq(d.get("OSTREE_VERSION"), "43.1")
	ok(not d.has("BAD"), "line without = skipped")


func test_detect_bazzite_deck_applies_through_steam_helper() -> void:
	var o := OsInfo.detect(_root("bazzite_deck"))
	eq(o["family"], "bazzite")
	eq(o["backend"], "rpm-ostree")
	eq(o["apply_via"], "steamos-update")
	eq(o["version"], "43.20261101.0")
	eq(o["variant"], "bazzite-deck")
	eq(o["image"], "ghcr.io/ublue-os/bazzite-deck")
	eq(o["notes_url"], "https://github.com/ublue-os/bazzite/releases")


func test_detect_bazzite_before_first_gaming_mode_avoids_os_update() -> void:
	# os-update restarts graphical.target the first time it runs: use rpm-ostree.
	var o := OsInfo.detect(_root("bazzite_fresh"))
	eq(o["apply_via"], "rpm-ostree")


func test_detect_bazzite_desktop_and_silverblue_use_rpm_ostree() -> void:
	var b := OsInfo.detect(_root("bazzite_desktop"))
	eq(b["family"], "bazzite")
	eq(b["apply_via"], "rpm-ostree")
	eq(b["variant"], "bazzite")
	var f := OsInfo.detect(_root("fedora_silverblue"))
	eq(f["family"], "fedora-atomic")
	eq(f["backend"], "rpm-ostree")
	eq(f["variant"], "silverblue")


func test_detect_steamos_and_other() -> void:
	var s := OsInfo.detect(_root("steamos"))
	eq(s["family"], "steamos")
	eq(s["backend"], "steamos-update")
	eq(s["version"], "3.7.13 (20250630.1)")
	var a := OsInfo.detect(_root("arch"))
	eq(a["family"], "other")
	eq(a["backend"], "none")


# ---- parsers --------------------------------------------------------------------

func test_rpm_ostree_status_booted_and_staged() -> void:
	var s := Parse.rpm_ostree_status(FileAccess.get_file_as_string(_f("rpm_ostree_status.json")))
	eq(s["booted"]["version"], "43.20261101.0")
	ok(s["staged"].is_empty(), "nothing staged")
	eq(s["booted"]["image"], "ghcr.io/ublue-os/bazzite-deck:stable")
	var t := Parse.rpm_ostree_status(FileAccess.get_file_as_string(_f("rpm_ostree_status_staged.json")))
	eq(t["staged"]["version"], "43.20261105.0")
	eq(t["cached"]["version"], "43.20261105.0")
	eq(Parse.rpm_ostree_status("not json")["booted"], {})


func test_rpm_ostree_check() -> void:
	var a := Parse.rpm_ostree_check(0, FileAccess.get_file_as_string(_f("rpm_ostree_check_available.txt")))
	ok(a["available"], "available")
	eq(a["version"], "43.20261105.0")
	ok(a["digest"].begins_with("sha256:"), "digest")
	var n := Parse.rpm_ostree_check(77, FileAccess.get_file_as_string(_f("rpm_ostree_check_none.txt")))
	ok(not n["available"] and n["error"] == "", "77 = none")
	var e := Parse.rpm_ostree_check(1, "error: Transaction in progress: upgrade\n")
	eq(e["error"], "error: Transaction in progress: upgrade")


func test_steamos_check_codes() -> void:
	ok(not Parse.steamos_check(7, "")["available"], "7 = none")
	var a := Parse.steamos_check(0, "Update available: 3.7.15\n")
	ok(a["available"], "0 = available")
	eq(a["version"], "3.7.15")
	ok(Parse.steamos_check(1, "boom")["error"] != "", "other = error")


func test_progress_percent() -> void:
	eq(Parse.progress_percent("47%"), 47.0)
	eq(Parse.progress_percent("Receiving objects: 45% (12/30)"), 45.0)
	eq(Parse.progress_percent("[3/12] Fetching ostree chunk"), 25.0)
	eq(Parse.progress_percent("Staging deployment...done"), -1.0)


func test_fwupd_updates() -> void:
	var r := Parse.fwupd_updates(0, FileAccess.get_file_as_string(_f("fwupd_updates.json")))
	ok(r["available"], "one device has a release")
	eq(r["devices"].size(), 1)
	var d: Dictionary = r["devices"][0]
	eq(d["current"], "E1T91IMS.10C")
	eq(d["version"], "E1T91IMS.10E")
	ok(d["needs_reboot"] and d["trusted"], "flags")
	var none := Parse.fwupd_updates(2, "No updatable devices\n")
	ok(not none["available"] and none["error"] == "", "exit 2 = nothing to do")
	ok(Parse.fwupd_updates(1, "Failed to connect to daemon")["error"] != "", "error")


func test_flatpak_updates_skip_header() -> void:
	var s := Parse.flatpak_updates(FileAccess.get_file_as_string(_f("flatpak_system.txt")), "system")
	eq(s.size(), 2)
	eq(s[0]["id"], "org.mozilla.firefox")
	eq(s[0]["version"], "144.0")
	eq(s[1]["installation"], "system")
	eq(Parse.flatpak_updates("", "user"), [])


# ---- state machine ----------------------------------------------------------------

func _bazzite_fake(status_file := "rpm_ostree_status.json") -> RefCounted:
	var f: RefCounted = Fake.new()
	f.responses["rpm-ostree status --json"] = {"code": 0, "file": _f(status_file)}
	f.responses["rpm-ostree upgrade --check"] = {"code": 0, "file": _f("rpm_ostree_check_available.txt")}
	return f


func test_nothing_runs_until_asked() -> void:
	var f: RefCounted = Fake.new()
	var u := _upd("bazzite_deck", f)
	eq(u.phase("os"), "idle")
	eq(f.calls.size(), 0)
	u.free()


func test_bazzite_check_then_apply_via_helper_stages() -> void:
	var f := _bazzite_fake()
	var u := _upd("bazzite_deck", f)
	var spy := Spy.new(u)
	ok(u.check("os"), "check starts")
	eq(u.phase("os"), "available")
	eq(spy.checked[0][1]["version"], "43.20261105.0")
	eq(spy.checked[0][1]["notes_url"], "https://github.com/ublue-os/bazzite/releases")
	# helper prints NN%; afterwards rpm-ostree shows the staged deployment
	f.responses[HELPER] = {"code": 0, "file": _f("steam_helper_upgrade.txt")}
	f.handler = func(cmd):
		if cmd == "rpm-ostree status --json" and f.called(HELPER):
			return {"code": 0, "file": _f("rpm_ostree_status_staged.json")}
		return null
	ok(u.apply_update(), "apply starts")
	ok(f.called(HELPER), "Gaming Mode's helper used")
	ok(not f.calls.has("rpm-ostree upgrade"), "not rpm-ostree upgrade")
	eq(u.phase("os"), "staged")
	eq(spy.finished.back(), ["os", true, ""])
	ok(spy.progress.any(func(p): return p[1] == 47.0), "progress reported")
	ok(u.state()["reboot_needed"], "reboot needed")
	eq(u.state()["os"]["staged_version"], "43.20261105.0")
	f.handler = Callable()   # the handler holds f: break the cycle
	u.free()


func test_helper_exit_zero_without_staged_deployment_is_an_error() -> void:
	# Bazzite's os-update exits 0 when uupd fails.
	var f := _bazzite_fake()
	var u := _upd("bazzite_deck", f)
	var spy := Spy.new(u)
	u.check("os")
	f.responses[HELPER] = {"code": 0, "out": "uupd failed\n"}
	u.apply("os")
	eq(u.phase("os"), "error")
	eq(spy.finished.back(), ["os", false, "uupd failed"])
	u.free()


func test_fresh_bazzite_applies_with_rpm_ostree() -> void:
	var f := _bazzite_fake()
	var u := _upd("bazzite_fresh", f)
	u.check("os")
	f.responses["rpm-ostree upgrade"] = {"code": 0, "file": _f("rpm_ostree_upgrade.txt")}
	f.handler = func(cmd):
		if cmd == "rpm-ostree status --json" and f.calls.has("rpm-ostree upgrade"):
			return {"code": 0, "file": _f("rpm_ostree_status_staged.json")}
		return null
	u.apply("os")
	ok(f.calls.has("rpm-ostree upgrade"), "rpm-ostree upgrade ran")
	ok(not f.called(HELPER), "os-update never called before Gaming Mode's first run")
	eq(u.phase("os"), "staged")
	f.handler = Callable()
	u.free()


func test_apply_refused_while_game_runs_and_when_nothing_available() -> void:
	var f := _bazzite_fake()
	var u := _upd("bazzite_deck", f)
	var spy := Spy.new(u)
	ok(not u.apply("os"), "nothing checked yet")
	eq(spy.finished.back(), ["os", false, "not_available"])
	u.check("os")
	u.set_game_running(true)
	ok(not u.apply("os"), "refused")
	eq(spy.finished.back(), ["os", false, "game_running"])
	eq(u.phase("os"), "available")
	ok(not f.called(HELPER), "nothing ran")
	ok(not u.reboot(), "no reboot during a game")
	u.set_game_running(false)
	ok(u.apply("os"), "allowed after the game")
	u.free()


func test_already_staged_reads_as_staged() -> void:
	var f := _bazzite_fake("rpm_ostree_status_staged.json")
	var u := _upd("bazzite_deck", f)
	var spy := Spy.new(u)
	u.check("os")
	eq(u.phase("os"), "staged")
	ok(not spy.checked[0][1]["available"], "the staged one is the update")
	ok(spy.checked[0][1]["staged"], "staged flag")
	u.free()


func test_rpm_ostree_up_to_date_and_error() -> void:
	var f: RefCounted = Fake.new()
	f.responses["rpm-ostree status --json"] = {"code": 0, "file": _f("rpm_ostree_status.json")}
	f.responses["rpm-ostree upgrade --check"] = {"code": 77, "file": _f("rpm_ostree_check_none.txt")}
	var u := _upd("fedora_silverblue", f)
	u.check("os")
	eq(u.phase("os"), "up_to_date")
	f.responses["rpm-ostree upgrade --check"] = {"code": 1, "out": "error: Authorization required\n"}
	u.check("os")
	eq(u.phase("os"), "error")
	eq(u.state()["os"]["error"], "error: Authorization required")
	u.free()


func test_steamos_flow() -> void:
	var f: RefCounted = Fake.new()
	f.responses[HELPER + " check"] = {"code": 7, "out": ""}
	var u := _upd("steamos", f)
	var spy := Spy.new(u)
	u.check("os")
	eq(u.phase("os"), "up_to_date")
	f.responses[HELPER + " check"] = {"code": 0, "out": "Update available: 3.7.15\n"}
	u.check("os")
	eq(spy.checked.back()[1]["version"], "3.7.15")
	f.responses[HELPER] = {"code": 0, "out": "10%\n100%\n"}
	u.apply("os")
	eq(u.phase("os"), "staged")
	ok(not f.called("rpm-ostree"), "no rpm-ostree on SteamOS")
	eq(u.phase("firmware"), "unsupported")
	u.free()


func test_unsupported_os() -> void:
	var u := _upd("arch", Fake.new())
	var spy := Spy.new(u)
	eq(u.phase("os"), "unsupported")
	ok(not u.check("os"), "no check")
	ok(not u.apply("os"), "no apply")
	eq(spy.finished.back(), ["os", false, "unsupported"])
	u.free()


func test_firmware_check_and_apply() -> void:
	var f: RefCounted = Fake.new()
	f.responses["fwupdmgr refresh"] = {"code": 2, "out": "Metadata is up to date\n"}
	f.responses["fwupdmgr get-updates --json --no-unreported-check --no-metadata-check"] = {"code": 0, "file": _f("fwupd_updates.json")}
	f.responses["fwupdmgr update*"] = {"code": 0, "out": "Writing…  42%\nSuccessfully installed firmware\n"}
	var u := _upd("bazzite_deck", f)
	var spy := Spy.new(u)
	u.check("firmware")
	eq(u.phase("firmware"), "available")
	eq(spy.checked[0][1]["devices"][0]["name"], "System Firmware")
	u.apply("firmware")
	ok(f.calls.has("fwupdmgr update a45df35ac0e948ee180fe216a5f703f32dda163f --assume-yes --no-reboot-check"), "updates that device")
	eq(u.phase("firmware"), "staged")
	ok(u.state()["reboot_needed"], "capsule needs a reboot")
	u.free()


func test_flatpak_check_and_apply_both_installations() -> void:
	var f: RefCounted = Fake.new()
	f.responses["flatpak remote-ls --updates --user --columns=application,name,version,branch,origin"] = {"code": 0, "file": _f("flatpak_user.txt")}
	f.responses["flatpak remote-ls --updates --system --columns=application,name,version,branch,origin"] = {"code": 0, "file": _f("flatpak_system.txt")}
	f.responses["flatpak update*"] = {"code": 0, "out": "Updating 1/2…\n"}
	var u := _upd("bazzite_deck", f)
	u.check("flatpak")
	eq(u.phase("flatpak"), "available")
	eq(u.state()["flatpak"]["pending"].size(), 3)
	u.apply("flatpak")
	ok(f.calls.has("flatpak update --user --noninteractive -y"), "user")
	ok(f.calls.has("flatpak update --system --noninteractive -y"), "system")
	eq(u.phase("flatpak"), "up_to_date")
	u.free()


func test_check_updates_checks_every_supported_kind() -> void:
	var f := _bazzite_fake()
	var u := _upd("bazzite_deck", f)
	u.check_updates()
	ok(f.called("rpm-ostree upgrade --check"), "os")
	ok(f.called("fwupdmgr get-updates"), "firmware")
	ok(f.called("flatpak remote-ls"), "flatpak")
	u.free()
