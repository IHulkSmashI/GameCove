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
	f.handler = func(cmd: String) -> Variant:
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
	var order: Array = f.calls.map(func(c): return str(c).get_slice(" ", 0))
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
