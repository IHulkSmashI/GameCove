extends "res://tests/test_case.gd"
## Steam's local files: appmanifest state and progress, VDF write round-trip with
## backups, launch options and compatibility tool edits (refused while Steam runs).

const Acf := preload("res://scripts/steam/acf.gd")
const VDF := preload("res://scripts/launch/vdf.gd")
const VdfWriter := preload("res://scripts/steam/vdf_writer.gd")
const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const Steam := preload("res://scripts/library/stores/steam.gd")
const TempTree := preload("res://tests/fixtures/stores/temp_tree.gd")

const STEAM := ".local/share/Steam"


func _data(rel: String) -> String:
	return fixture("stores/data/" + rel)


func _temp_home(name: String) -> String:
	var home := TempTree.temp_dir(name)
	TempTree.copy_tree(_data("steamhome"), home)
	return home


func test_acf_downloading_manifest() -> void:
	var m := Acf.parse_file(_data("acf/appmanifest_downloading.acf"))
	eq(m["appid"], "620", "appid")
	eq(m["flags"], 1026, "flags")
	ok(not Acf.is_installed(m["flags"]), "a first install isn't installed")
	ok(Acf.is_busy(m["flags"]), "busy while downloading")
	eq(Acf.state_name(m["flags"]), "downloading", "state")
	eq(Acf.progress(m), {"bytes_done": 2500000, "bytes_total": 10000000}, "download phase")


func test_acf_staging_and_flags() -> void:
	var m := Acf.parse_file(_data("acf/appmanifest_staging.acf"))
	eq(Acf.progress(m), {"bytes_done": 6000000, "bytes_total": 12000000}, "staging after download")
	eq(Acf.state_name(m["flags"]), "downloading", "staging counts as downloading")
	var old := Acf.parse_file(_data("acf/appmanifest_noflags.acf"))
	ok(Acf.is_installed(old["flags"]), "no StateFlags: installed")
	eq(Acf.state_name(Acf.FULLY_INSTALLED | Acf.UPDATE_REQUIRED), "update_required", "update required")
	eq(Acf.state_name(Acf.FULLY_INSTALLED | Acf.VALIDATING), "verifying", "verifying")
	eq(Acf.state_name(Acf.FULLY_INSTALLED | Acf.UPDATE_PAUSED | Acf.UPDATE_REQUIRED), "paused", "paused")
	eq(Acf.state_name(Acf.UNINSTALLING), "uninstalling", "uninstalling")
	eq(Acf.state_name(Acf.UNINSTALLED), "not_installed", "uninstalled")
	eq(Acf.parse("garbage"), {}, "not a manifest")


func test_steam_scan_marks_first_install_not_installed() -> void:
	var games := Steam.scan(_data("steamhome"))
	var by_id := {}
	for g in games:
		by_id[g["id"]] = g
	ok(by_id.has("620") and by_id.has("440"), "both games listed")
	ok(not by_id.has("2805730"), "Proton isn't a game")
	eq(by_id["620"]["installed"], false, "downloading game not installed")
	eq(by_id["620"]["busy"], true, "downloading game busy")
	eq(by_id["440"]["installed"], true, "installed game")
	ok(str(by_id["440"]["install_path"]).ends_with("steamapps/common/Team Fortress 2"), "install path")


func test_vdf_dump_round_trip() -> void:
	var text := FileAccess.get_file_as_string(_data("steamhome/" + STEAM + "/config/loginusers.vdf"))
	var d := VDF.parse(text)
	var again := VDF.parse(VdfWriter.dump(d))
	eq(again, d, "parse(dump(parse(x))) == parse(x)")
	eq(str(again["users"]["76561197972611406"]["PersonaName"]), "Player \"One\"", "quotes survive")
	var tricky := {"a": {"path": "C:\\Games\\x", "multi": "line1\nline2\ttab"}}
	eq(VDF.parse(VdfWriter.dump(tricky)), tricky, "backslash, newline, tab survive")


func test_vdf_save_keeps_original_and_backup() -> void:
	var dir := TempTree.temp_dir("vdf_save")
	var path := dir.path_join("config.vdf")
	DirAccess.copy_absolute(_data("steamhome/" + STEAM + "/config/config.vdf"), path)
	var first := FileAccess.get_file_as_string(path)
	eq(VdfWriter.save(path, {"A": {"b": "1"}}), OK, "first save")
	eq(FileAccess.get_file_as_string(path + VdfWriter.ORIGINAL_SUFFIX), first, "original kept")
	eq(FileAccess.get_file_as_string(path + VdfWriter.BACKUP_SUFFIX), first, "backup of previous")
	eq(VdfWriter.save(path, {"A": {"b": "2"}}), OK, "second save")
	eq(FileAccess.get_file_as_string(path + VdfWriter.ORIGINAL_SUFFIX), first, "original never overwritten")
	eq(VDF.parse_file(path + VdfWriter.BACKUP_SUFFIX), {"A": {"b": "1"}}, "backup is the previous version")
	eq(VdfWriter.restore_backup(path), OK, "restore")
	eq(VDF.parse_file(path), {"A": {"b": "1"}}, "restored")
	ok(not FileAccess.file_exists(path + ".gamecove.tmp"), "no temp file left")
	TempTree.remove_tree(dir)


func test_steam_running_from_pid_file() -> void:
	var home := _data("steamhome")
	ok(SteamConfig.is_running(home, _data("proc")), "pid 4242 is steam")
	ok(not SteamConfig.is_running(home, _data("proc/none")), "no such process")
	ok(not SteamConfig.is_running("/nonexistent", _data("proc")), "no pid file")


func test_current_user_is_most_recent() -> void:
	var root := _data("steamhome/" + STEAM)
	eq(SteamConfig.current_user_dir(root), root.path_join("userdata/12345678"), "MostRecent account")
	eq(SteamConfig.launch_options(root.path_join("userdata/12345678"), "620"), "PROTON_LOG=1 \"%command%\" -novid", "launch options read")
	eq(SteamConfig.compat_tool(root, "440"), "GE-Proton10-25", "per-game tool")
	eq(SteamConfig.compat_tool(root, "620"), "", "no per-game tool: Steam default")


func test_set_launch_options_round_trip() -> void:
	var home := _temp_home("steam_lo")
	var root := home.path_join(STEAM)
	var user := root.path_join("userdata/12345678")
	var no_proc := home.path_join("noproc")
	eq(SteamConfig.set_launch_options(home, user, "440", "gamemoderun %command% \"-x y\"", _data("proc")), ERR_BUSY, "refused while Steam runs")
	eq(SteamConfig.set_launch_options(home, user, "440", "gamemoderun %command% \"-x y\"", no_proc), OK, "written when stopped")
	eq(SteamConfig.launch_options(user, "440"), "gamemoderun %command% \"-x y\"", "read back")
	eq(VDF.get_ci(VDF.find_ci(VDF.parse_file(SteamConfig.localconfig_path(user)), "440"), "Playtime"), "5", "other keys kept")
	ok(FileAccess.file_exists(SteamConfig.localconfig_path(user) + VdfWriter.BACKUP_SUFFIX), "backup written")
	eq(SteamConfig.set_launch_options(home, user, "999", "-dx11", no_proc), OK, "new app entry")
	eq(SteamConfig.launch_options(user, "999"), "-dx11", "new app read back")
	eq(SteamConfig.set_launch_options(home, user, "620", "", no_proc), OK, "clear")
	eq(SteamConfig.launch_options(user, "620"), "", "cleared")
	TempTree.remove_tree(home)


func test_set_compat_tool_round_trip() -> void:
	var home := _temp_home("steam_ct")
	var root := home.path_join(STEAM)
	var no_proc := home.path_join("noproc")
	eq(SteamConfig.set_compat_tool(home, root, "620", "proton_experimental", _data("proc")), ERR_BUSY, "refused while running")
	eq(SteamConfig.set_compat_tool(home, root, "620", "proton_experimental", no_proc), OK, "set")
	eq(SteamConfig.compat_tool(root, "620"), "proton_experimental", "read back")
	var entry := VDF.find_ci(VDF.find_ci(VDF.parse_file(SteamConfig.config_path(root)), "CompatToolMapping"), "620")
	eq(entry, {"name": "proton_experimental", "config": "", "priority": "250"}, "Steam's entry shape")
	eq(SteamConfig.set_compat_tool(home, root, "440", "", no_proc), OK, "back to default")
	eq(SteamConfig.compat_tool(root, "440"), "", "removed")
	eq(SteamConfig.compat_tool(root, "0"), "proton_9", "global default untouched")
	eq(str(VDF.find_ci(VDF.parse_file(SteamConfig.config_path(root)), "Steam").get("AutoUpdateWindowEnabled")), "0", "other settings kept")
	TempTree.remove_tree(home)


func test_tool_names_and_local_tools() -> void:
	eq(SteamConfig.valve_tool_name("Proton 9.0"), "proton_9", "Proton 9.0")
	eq(SteamConfig.valve_tool_name("Proton Experimental"), "proton_experimental", "experimental")
	eq(SteamConfig.valve_tool_name("Proton Hotfix"), "proton_hotfix", "hotfix")
	eq(SteamConfig.valve_tool_name("Proton EasyAntiCheat Runtime"), "", "not a Proton build")
	var root := _data("steamhome/" + STEAM)
	var tools := SteamConfig.local_tools([root.path_join("compatibilitytools.d")], [{"name": "Proton 9.0", "path": "/p9"}])
	eq(tools.size(), 2, "valve + custom")
	eq(tools[0]["id"], "proton_9", "valve first")
	eq(tools[1]["id"], "GE-Proton10-25", "custom from compatibilitytool.vdf")
	eq(tools[1]["source"], "custom", "source")


func test_vdf_strict_parse() -> void:
	eq(VDF.parse_strict("\"a\"\n{\n\t\"b\"\t\t\"1\"\n\t\"c\" { \"d\" \"2\" }\n}\n"), {"a": {"b": "1", "c": {"d": "2"}}}, "clean file")
	eq(VDF.parse_strict("// comment\n\"a\" { }\n"), {"a": {}}, "comments and empty blocks")
	eq(VDF.parse_strict("\"a\" { \"b\" \"1\""), null, "missing closing brace")
	eq(VDF.parse_strict("\"a\" { \"b\" \"1\" } }"), null, "extra closing brace")
	eq(VDF.parse_strict("\"a\" { \"b\" \"1 }"), null, "unclosed string")
	eq(VDF.parse_strict("\"a\" { \"b\" }"), null, "key without a value")
	eq(VDF.parse_strict("\"a\" { { \"b\" \"1\" } }"), null, "block without a key")
	eq(VDF.parse_strict("\"a\" { \"b\" \"1\" \"b\" \"2\" }"), null, "the same key twice (writing back would drop one)")
	eq(VDF.parse_strict("\"a\""), null, "a lone key")
	var text := FileAccess.get_file_as_string(_data("steamhome/" + STEAM + "/config/config.vdf"))
	eq(VDF.parse_strict(text), VDF.parse(text), "Steam's own file parses strictly")


## A localconfig.vdf that is cut off or broken is never written back.
func test_broken_steam_files_are_never_written() -> void:
	var home := _temp_home("steam_broken")
	var root := home.path_join(STEAM)
	var user := root.path_join("userdata/12345678")
	var no_proc := home.path_join("noproc")
	var path := SteamConfig.localconfig_path(user)
	var full := FileAccess.get_file_as_string(path)
	var cut := full.substr(0, full.length() - 4)   # loses closing braces, as a half-written file would
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(cut)
	f.close()
	eq(SteamConfig.set_launch_options(home, user, "440", "-dx11", no_proc), ERR_PARSE_ERROR, "cut-off file refused")
	eq(FileAccess.get_file_as_string(path), cut, "file left exactly as it was")
	ok(not FileAccess.file_exists(path + VdfWriter.BACKUP_SUFFIX), "nothing written at all")
	var cpath := SteamConfig.config_path(root)
	var ctext := FileAccess.get_file_as_string(cpath)
	f = FileAccess.open(cpath, FileAccess.WRITE)
	f.store_string(ctext + "\n\"extra\" { \"x\" \"1\" ")
	f.close()
	eq(SteamConfig.set_compat_tool(home, root, "620", "proton_9", no_proc), ERR_PARSE_ERROR, "trailing garbage refused")
	eq(VdfWriter.save(path, {"a": {"b": "1"}}), ERR_FILE_UNRECOGNIZED, "a file we can't put back byte for byte is never replaced")
	eq(FileAccess.get_file_as_string(path), cut, "still left exactly as it was")
	eq(VdfWriter.save(home.path_join("new.vdf"), {"a": {"b": "1"}}), OK, "a sane tree saves to a new file")
	TempTree.remove_tree(home)


## Reads and writes of Steam's settings files go through a thread when the
## backend is in the tree; the UI gets the value through a callback.
func test_backend_async_reads() -> void:
	var Backend = load("res://scripts/steam/steam_backend.gd")
	var home := _temp_home("steam_async")
	var b: Node = Backend.new()
	b.steam_root = home.path_join(STEAM)
	b.home = home
	var got := []
	b.launch_options_async("620", func(v): got.append(["lo", v]))
	b.compat_tool_async("440", func(v): got.append(["ct", v]))
	b.compat_tools_async(func(v): got.append(["tools", v.size() >= 1 and v[0]["id"] == ""]))
	eq(got, [["lo", "PROTON_LOG=1 \"%command%\" -novid"], ["ct", "GE-Proton10-25"], ["tools", true]], "values reach the callback")
	b.free()
	TempTree.remove_tree(home)


## Review 2, problem 7: escape() halved Steam's doubled backslashes, so changing one
## game's launch options rewrote every other game's Windows path ("C:\\prog\\x" came
## back as "C:\prog\x"). Untouched keys and values are written back byte for byte.
func test_untouched_values_are_written_back_verbatim() -> void:
	var home := TempTree.temp_dir("steam_verbatim")
	var user := home.path_join("userdata/1")
	DirAccess.make_dir_recursive_absolute(user.path_join("config"))
	var path := SteamConfig.localconfig_path(user)
	var lines := [
		"\"UserLocalConfigStore\"", "{", "\t\"Software\"", "\t{", "\t\t\"Valve\"", "\t\t{", "\t\t\t\"Steam\"", "\t\t\t{",
		"\t\t\t\t\"apps\"", "\t\t\t\t{",
		"\t\t\t\t\t\"620\"", "\t\t\t\t\t{",
		"\t\t\t\t\t\t\"LaunchOptions\"\t\t\"\\\"C:\\\\Program Files\\\\x.exe\\\" %command%\"",
		"\t\t\t\t\t\t\"Note\"\t\t\"tab\\there\\nnew \\\"q\\\" odd\\p\"",
		"\t\t\t\t\t}",
		"\t\t\t\t\t\"440\"", "\t\t\t\t\t{", "\t\t\t\t\t\t\"LaunchOptions\"\t\t\"WINEPATH=C:\\\\prog\\\\x %command%\"", "\t\t\t\t\t}",
		"\t\t\t\t}", "\t\t\t}", "\t\t}", "\t}", "}", ""]
	var original := "\n".join(PackedStringArray(lines))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(original)
	f.close()
	var r: Variant = VDF.parse_strict_raw(original)
	ok(r is Dictionary, "parses")
	eq(VdfWriter.dump(r["tree"], 0, r["raw"]), original, "dump(parse(original)) is the original, byte for byte")
	var no_proc := home.path_join("noproc")
	eq(SteamConfig.launch_options(user, "440"), "WINEPATH=C:\\prog\\x %command%", "Steam's escapes decoded on read")
	eq(SteamConfig.set_launch_options(home, user, "730", "-novid", no_proc), OK, "another game's options saved")
	var after := FileAccess.get_file_as_string(path)
	for l in [lines[12], lines[13], lines[17]]:
		ok(after.contains(l + "\n"), "untouched line kept byte for byte: " + l)
	eq(SteamConfig.set_launch_options(home, user, "730", "D:\\games\\y \"%command%\"", no_proc), OK, "a new value with a Windows path")
	ok(FileAccess.get_file_as_string(path).contains("\"D:\\\\games\\\\y \\\"%command%\\\"\""), "written with Steam's escapes")
	eq(SteamConfig.launch_options(user, "730"), "D:\\games\\y \"%command%\"", "and reads back")
	eq(SteamConfig.set_launch_options(home, user, "730", "", no_proc), OK, "removed again")
	eq(FileAccess.get_file_as_string(path), original.replace("\t\t\t\t}\n\t\t\t}", "\t\t\t\t\t\"730\"\n\t\t\t\t\t{\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}"),
		"the original again, plus the empty 730 entry")
	# a layout our writer doesn't produce (spaces, not tabs) is never rewritten
	var spaced := original.replace("\t\t\"WINEPATH", "  \"WINEPATH")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(spaced)
	f.close()
	eq(SteamConfig.set_launch_options(home, user, "730", "-novid", no_proc), ERR_FILE_UNRECOGNIZED, "refused: it wouldn't round-trip")
	eq(FileAccess.get_file_as_string(path), spaced, "file untouched")
	TempTree.remove_tree(home)
