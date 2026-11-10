extends "res://tests/test_case.gd"
## GE-Proton: release parsing, installed builds, games set to one, install with
## the checksum check (curl, sha512sum and tar faked; files real under user://),
## removal, the Settings > Performance card. Nothing real runs or downloads.

const ProtonGE := preload("res://scripts/launch/proton_ge.gd")
const Card := preload("res://scripts/ui/settings/proton_card.gd")
const PerfPage := preload("res://scripts/ui/controls/perf_page.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const UIC := preload("res://tests/test_ui_controls.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const ExecSafe := preload("res://scripts/system/exec_safe.gd")

const BASE := "user://test_extras_proton"
const DL := "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/"
const HASH := "aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233aa11bb22cc33dd44ee55ff6600112233445566778899aabbccddeeff00112233"


static func release_json(tag := "GE-Proton10-26", host := DL) -> String:
	return JSON.stringify({"tag_name": tag, "published_at": "2026-11-05T10:00:00Z", "assets": [
		{"name": tag + ".sha512sum", "browser_download_url": host + tag + "/" + tag + ".sha512sum", "size": 160},
		{"name": tag + ".tar.gz", "browser_download_url": host + tag + "/" + tag + ".tar.gz", "size": 512000000}]})


func _rm(path: String) -> void:
	ProtonGE.remove_tree(path)


func _touch(path: String, text := "x") -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


static func _tool_vdf(internal: String) -> String:
	return "\"compatibilitytools\"\n{\n  \"compat_tools\"\n  {\n    \"%s\"\n    {\n      \"install_path\" \".\"\n      \"display_name\" \"%s\"\n    }\n  }\n}\n" % [internal, internal]


## home with Steam, GE-Proton10-25 (set for game 570), GE-Proton9-20, a CachyOS build.
func _home(name: String) -> Dictionary:
	var root := ProjectSettings.globalize_path(BASE).path_join(name)
	_rm(root)
	var home := root.path_join("home")
	var steam := home.path_join(".local/share/Steam")
	var cd := steam.path_join("compatibilitytools.d")
	for t in ["GE-Proton10-25", "GE-Proton9-20", "proton-cachyos-10.0-20260101"]:
		_touch(cd.path_join(t).path_join("compatibilitytool.vdf"), _tool_vdf(t))
	_touch(steam.path_join("config/config.vdf"), "\"InstallConfigStore\"\n{\n \"Software\"\n {\n  \"Valve\"\n  {\n   \"Steam\"\n   {\n    \"CompatToolMapping\"\n    {\n     \"570\"\n     {\n      \"name\" \"GE-Proton10-25\"\n      \"config\" \"\"\n      \"priority\" \"250\"\n     }\n     \"0\"\n     {\n      \"name\" \"proton_experimental\"\n     }\n    }\n   }\n  }\n }\n}\n")
	return {"root": root, "home": home, "steam": steam, "cd": cd}


## curl writes what was asked (the sha file holds HASH), sha512sum answers
## `digest`, tar unpacks a GE-Proton folder (or fails).
func _fake(digest := HASH, tar_ok := true, api := "") -> RefCounted:
	var f: RefCounted = Fake.new()
	f.handler = func(full: String) -> Variant:
		var cmd := plain(full)
		var a := cmd.split(" ")
		if cmd.begins_with("curl ") and cmd.ends_with(ProtonGE.API):
			return {"code": 0 if api != "" else 6, "out": api}
		if cmd.begins_with("curl ") and a.has("-o"):
			var out: String = a[a.find("-o") + 1]
			_touch(out, HASH + "  " + out.get_file().replace(".sha512sum", ".tar.gz") + "\n" if out.ends_with(".sha512sum") else "tarball")
			return {"code": 0, "out": ""}
		if cmd.begins_with("sha512sum "):
			return {"code": 0, "out": "%s  %s\n" % [digest, a[1]]}
		if cmd.begins_with("tar -xzf "):
			if not tar_ok:
				return {"code": 2, "out": "tar: Error"}
			var tag := a[2].get_file().trim_suffix(".tar.gz")
			_touch(a[4].path_join(tag).path_join("compatibilitytool.vdf"), _tool_vdf(tag))
			return {"code": 0, "out": ""}
		return null
	return f


## The command without the low-priority prefix (nice 19, ionice idle).
static func plain(cmd: String) -> String:
	return cmd.trim_prefix("nice -n 19 ionice -c 3 ").trim_prefix("nice -n 19 ")


func test_parse_release() -> void:
	var r := ProtonGE.parse_release(release_json())
	eq(r["tag"], "GE-Proton10-26", "tag")
	eq(r["tarball"], DL + "GE-Proton10-26/GE-Proton10-26.tar.gz", "tarball from the release page")
	eq(r["sha512"], DL + "GE-Proton10-26/GE-Proton10-26.sha512sum", "checksum file")
	eq(r["bytes"], 512000000, "size")
	eq(r["published"], "2026-11-05", "date")
	eq(ProtonGE.parse_release(release_json("GE-Proton10-26", "https://evil.example/")), {}, "files from anywhere else: refused")
	eq(ProtonGE.parse_release(release_json("Proton-11; rm")), {}, "odd tags refused")
	eq(ProtonGE.parse_release("nope"), {}, "not JSON")
	eq(ProtonGE.parse_sha(HASH + "  GE-Proton10-26.tar.gz\n"), HASH, "digest")
	eq(ProtonGE.parse_sha("abc  x"), "", "short digest refused")


func test_latest_over_the_api() -> void:
	var r := ProtonGE.latest(_fake(HASH, true, release_json()))
	eq(r["tag"], "GE-Proton10-26", "latest release")
	eq(ProtonGE.latest(_fake())["error"], "offline", "no answer")
	eq(ProtonGE.latest(_fake(HASH, true, "{}"))["error"], "bad_release", "odd answer")


func test_installed_and_games_using() -> void:
	var h := _home("installed")
	var b := ProtonGE.installed(h.cd)
	eq(b.map(func(x): return x["name"]), ["GE-Proton10-25", "GE-Proton9-20"], "GE builds only, newest first")
	eq(ProtonGE.games_using(h.steam, "GE-Proton10-25"), ["570"], "Dota 2 is set to it")
	eq(ProtonGE.games_using(h.steam, "GE-Proton9-20"), [], "nothing on the old one")
	eq(ProtonGE.compat_dir(h.home), h.cd, "Steam's compatibilitytools.d")
	eq(ProtonGE.compat_dir(h.root.path_join("nobody")), "", "no Steam, no folder")
	_rm(h.root)


func test_install_checks_the_checksum_first() -> void:
	var h := _home("install")
	var rel := ProtonGE.parse_release(release_json())
	var f := _fake()
	eq(ProtonGE.install(f, rel, h.cd), {"ok": true, "error": ""}, "installed")
	ok(FileAccess.file_exists(h.cd.path_join("GE-Proton10-26/compatibilitytool.vdf")), "unpacked into compatibilitytools.d")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join(ProtonGE.DOWNLOAD_DIR)), "download folder cleaned up")
	var order: Array = f.calls.map(func(c): return plain(str(c)).get_slice(" ", 0))
	ok(order.find("sha512sum") < order.find("tar"), "checked before unpacking")
	eq(ProtonGE.install(f, rel, h.cd)["error"], "exists", "twice: already there")
	var rel2 := ProtonGE.parse_release(release_json("GE-Proton10-27"))
	eq(ProtonGE.install(_fake(HASH.replace("a", "b")), rel2, h.cd)["error"], "checksum", "a mismatch never unpacks")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-27")), "nothing left behind")
	eq(ProtonGE.install(_fake(HASH, false), rel2, h.cd)["error"], "unpack", "tar failure")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-27")), "half-unpacked folder removed")
	eq(ProtonGE.install(f, rel2, "")["error"], "no_steam", "no Steam")
	_rm(h.root)


func test_remove_only_unused_ge_builds() -> void:
	var h := _home("remove")
	eq(ProtonGE.remove(h.cd, "GE-Proton10-25", h.steam), "in_use", "a game is set to it")
	eq(ProtonGE.remove(h.cd, "proton-cachyos-10.0-20260101", h.steam), "not_found", "only GE builds")
	eq(ProtonGE.remove(h.cd, "../config", h.steam), "not_found", "nothing outside the folder")
	eq(ProtonGE.remove(h.cd, "GE-Proton9-20", h.steam), "", "removed")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton9-20")), "gone")
	ok(DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-25")), "the used one stays")
	_rm(h.root)


func test_card_check_install_remove() -> void:
	var h := _home("card")
	var c: VBoxContainer = Card.new()
	var changed := []
	c.on_changed = func(): changed.append(true)
	c.setup(_fake(HASH, true, release_json()), h.home)
	eq(c.rows.keys(), ["GE-Proton10-25", "GE-Proton9-20"], "installed builds listed")
	eq(c.rows["GE-Proton10-25"].value_label.text, TX.GE_ROW_IN_USE % [1, "game"], "how many games use it")
	eq(c.main_row.title_label.text, TX.GE_CHECK, "starts with Check")
	eq(c.main_row.hint_text(), TX.GE_CHECK_HINT, "one plain line")
	eq(c.focusables().size(), 3, "check row and both builds")
	var notes := []
	c.notice.connect(func(t, tone): notes.append([t, tone]))
	c.press_main()
	eq(c.main_row.title_label.text, TX.GE_INSTALL % "GE-Proton10-26", "found a newer one: Install")
	ok(c.main_row.hint_text().contains(" MB"), "says how big the download is")
	c.press_main()
	eq(notes[-1], [TX.GE_INSTALLED % "GE-Proton10-26", "good"], "installed")
	eq(changed.size(), 1, "Proton list refreshed")
	ok(c.rows.has("GE-Proton10-26"), "new build listed")
	ok(c._listed_once and c._listed.has("GE-Proton10-26"), "remembered as listed (it pops this once, not on later reads)")
	eq(c.main_row.value_label.text, TX.GE_HAVE_LATEST % "GE-Proton10-26", "up to date")
	c.remove("GE-Proton9-20")
	eq(notes[-1], [TX.GE_REMOVED % "GE-Proton9-20", "good"], "removed")
	c.remove("GE-Proton10-25")
	eq(notes[-1], [TX.GE_ERRORS["in_use"], "bad"], "in use: refused with the reason")
	c.free()
	var off: VBoxContainer = Card.new()
	off.setup(_fake(), h.root.path_join("nobody"))
	ok(off.find_child("GeNoSteam", true, false) != null, "no Steam: says so")
	eq(off.focusables(), [], "nothing to press")
	off.free()
	var down: VBoxContainer = Card.new()
	down.setup(_fake(), h.home)
	var n2 := []
	down.notice.connect(func(t, tone): n2.append(t))
	down.check()
	eq(n2, [TX.GE_ERRORS["offline"]], "offline says so")
	down.free()
	_rm(h.root)


func test_performance_page_has_the_card() -> void:
	var h := _home("page")
	var c: Node = UIC.fake()
	var page: VBoxContainer = PerfPage.new()
	page.setup("performance", {"controls": c, "proton_runner": _fake(), "proton_home": h.home}, null)
	page.on_shown()
	ok(page.proton_card != null, "GE-Proton card")
	ok(page.proton_card.main_row.button in page.focusables(), "in the focus chain")
	page.free()
	var page2: VBoxContainer = PerfPage.new()
	page2.setup("performance", {"controls": c}, null)
	page2.on_shown()
	ok(page2.proton_card == null, "under tests without fakes: nothing real read")
	page2.free()
	c.free()
	_rm(h.root)


# ---- review 3, medium 2: stalls, atomic install, leftovers ----------------------------------

func test_curl_gives_up_on_a_stall_and_speaks_only_https() -> void:
	var h := _home("stall")
	var f := _fake(HASH, true, release_json())
	ProtonGE.latest(f)
	ProtonGE.install(f, ProtonGE.parse_release(release_json()), h.cd)
	var curls: Array = f.calls.filter(func(c): return plain(str(c)).begins_with("curl "))
	eq(curls.size(), 3, "lookup, checksum, tarball")
	for c in curls:
		ok(" --speed-limit 1024 --speed-time 30 " in c, "stall limit: " + c)
		ok(" --proto =https --proto-redir =https " in c, "HTTPS only: " + c)
	_rm(h.root)


func test_unpack_goes_into_place_only_when_whole() -> void:
	var h := _home("atomic")
	var rel := ProtonGE.parse_release(release_json())
	var f := _fake()
	var seen := []
	var inner: Callable = f.handler
	f.handler = func(cmd: String) -> Variant:
		if plain(cmd).begins_with("tar -xzf "):
			var into: String = plain(cmd).split(" ")[4]
			seen.append(into)
			# while tar runs, Steam's folder has nothing of it yet
			ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-26")), "nothing half-unpacked where Steam looks")
		return inner.call(cmd)
	eq(ProtonGE.install(f, rel, h.cd), {"ok": true, "error": ""}, "installed")
	ok(seen[0].begins_with(h.cd.path_join(ProtonGE.DOWNLOAD_DIR)), "unpacked inside the download folder")
	ok(ProtonGE.complete(h.cd.path_join("GE-Proton10-26")), "then moved into place whole")
	ok(not ProtonGE.has_leftovers(h.cd), "download folder gone")
	# a tarball without compatibilitytool.vdf: never moved into place
	var bad := _fake()
	bad.handler = func(cmd: String) -> Variant:
		if plain(cmd).begins_with("tar -xzf "):
			var a := plain(cmd).split(" ")
			_touch(a[4].path_join("GE-Proton10-27/files/lib.so"))
			return {"code": 0, "out": ""}
		return f.handler.call(cmd) if not plain(cmd).begins_with("tar ") else null
	eq(ProtonGE.install(bad, ProtonGE.parse_release(release_json("GE-Proton10-27")), h.cd)["error"], "unpack", "no vdf: refused")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-27")), "nothing put where Steam looks")
	ok(not ProtonGE.has_leftovers(h.cd), "and nothing left")
	_rm(h.root)


func test_interrupted_leftovers_and_broken_builds() -> void:
	var h := _home("leftovers")
	# what a power cut leaves: a half unpack, a half removal, an old in-place half unpack
	_touch(h.cd.path_join(ProtonGE.DOWNLOAD_DIR).path_join("unpack/GE-Proton10-27/files/lib.so"))
	_touch(h.cd.path_join(ProtonGE.DOWNLOAD_DIR).path_join("removing/GE-Proton9-1/files/lib.so"))
	_touch(h.cd.path_join("GE-Proton10-20/files/lib.so"))
	eq(ProtonGE.installed(h.cd).map(func(b): return b["name"]), ["GE-Proton10-25", "GE-Proton9-20"], "never listed as installed")
	eq(ProtonGE.broken(h.cd), ["GE-Proton10-20"], "the broken one is found")
	ok(ProtonGE.has_leftovers(h.cd), "leftovers found")
	var c: VBoxContainer = Card.new()
	c.setup(_fake(HASH, true, release_json()), h.home)
	ok(not ProtonGE.has_leftovers(h.cd), "the next start cleans the download folder up")
	ok(c.rows.has("GE-Proton10-20"), "the broken build has a row")
	eq(c.rows["GE-Proton10-20"].value_label.text, TX.GE_BROKEN, "saying it didn't finish")
	eq(c.rows["GE-Proton10-20"].hint_text(), TX.GE_BROKEN_HINT, "and how to remove it")
	ok(c.rows["GE-Proton10-20"].button in c.focusables(), "reachable with the controller")
	var notes := []
	c.notice.connect(func(t, _tone): notes.append(t))
	c.remove("GE-Proton10-20")
	eq(notes[-1], TX.GE_REMOVED % "GE-Proton10-20", "removed from the UI")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton10-20")), "gone")
	ok(not c.rows.has("GE-Proton10-20"), "row gone")
	c.free()
	# an unfinished copy of the very version being installed is replaced
	_touch(h.cd.path_join("GE-Proton10-26/files/lib.so"))
	eq(ProtonGE.install(_fake(), ProtonGE.parse_release(release_json()), h.cd), {"ok": true, "error": ""}, "replaced")
	ok(ProtonGE.complete(h.cd.path_join("GE-Proton10-26")), "whole now")
	_rm(h.root)


func test_removal_moves_out_of_sight_first_and_stops_at_exit() -> void:
	var h := _home("remove_stop")
	var g := "test_ge_remove_%d" % Time.get_ticks_usec()
	for i in 20:
		_touch(h.cd.path_join("GE-Proton9-20/files/f%d" % i))
	ExecSafe.stop_group(g, 0)
	eq(ProtonGE.remove(h.cd, "GE-Proton9-20", h.steam, g), "", "removed from Steam's sight")
	ok(not DirAccess.dir_exists_absolute(h.cd.path_join("GE-Proton9-20")), "nothing left where Steam looks")
	ok(ProtonGE.has_leftovers(h.cd), "the delete stopped at exit; the rest waits")
	ExecSafe.clear_stopped(g)
	ok(ProtonGE.cleanup(h.cd), "next start finishes it")
	ok(not ProtonGE.has_leftovers(h.cd), "all gone")
	_rm(h.root)


# ---- review 3, low 5: behind a game ---------------------------------------------------------

func test_install_waits_for_the_game_and_runs_at_low_priority() -> void:
	var h := _home("lowprio")
	var f := _fake(HASH, true, release_json())
	var c: VBoxContainer = Card.new()
	c.setup(f, h.home)
	var playing := [true]
	c.game_running = func() -> bool: return playing[0]
	var notes := []
	c.notice.connect(func(t, tone): notes.append([t, tone]))
	c.check()
	f.calls.clear()
	c.press_main()
	eq(notes[-1], [TX.GE_ERRORS["game_running"], "bad"], "refused while a game runs, saying why")
	eq(f.calls.size(), 0, "nothing downloaded")
	playing[0] = false
	c.path_env = ""   # no ionice found: nice alone
	c.press_main()
	eq(notes[-1][1], "good", "installs once the game is closed")
	var heavy: Array = f.calls.filter(func(x): return plain(str(x)).get_slice(" ", 0) in ["curl", "sha512sum", "tar"])
	eq(heavy.size(), 4, "both downloads, the checksum and the unpack")
	for x in heavy:
		ok(str(x).begins_with("nice -n 19 "), "lowest CPU priority: " + x)
	c.free()
	eq(ProtonGE.priority_prefix("/nonexistent"), ["nice", "-n", "19"], "nice only without ionice")
	var bin: String = h.root.path_join("bin")
	_touch(bin.path_join("ionice"))
	eq(ProtonGE.priority_prefix(bin), ["nice", "-n", "19", "ionice", "-c", "3"], "idle disk priority with ionice")
	var f2 := _fake()
	ProtonGE.install(f2, ProtonGE.parse_release(release_json("GE-Proton10-30")), h.cd)
	ok(f2.calls.any(func(x): return str(x).begins_with("nice -n 19 ionice -c 3 tar -xzf ")), "the default is both")
	_rm(h.root)
