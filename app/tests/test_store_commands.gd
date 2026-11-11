extends "res://tests/test_case.gd"
## Plans for Epic / GOG / Amazon actions: which tool, exact command lines, Heroic
## hand-offs, refusals, delete safety, install locations and our GOG record.

const StoreCommands := preload("res://scripts/library/manage/store_commands.gd")
const Disk := preload("res://scripts/library/manage/disk.gd")
const Gog := preload("res://scripts/library/stores/gog.gd")
const TempTree := preload("res://tests/fixtures/stores/temp_tree.gd")

const TOOLS := {"legendary": "/usr/bin/legendary", "nile": "/usr/bin/nile", "gogdl": "/opt/heroic/gogdl",
	"umu": "/usr/bin/umu-run", "heroic": ["/usr/bin/heroic"],
	"heroic_flatpak": ["/usr/bin/flatpak", "run", "com.heroicgameslauncher.hgl"]}
const FACTS := {"install_root": "/home/u/Games", "home": "/home/u", "gog_auth_exists": true}


func _epic(installed: bool, source := "legendary", flatpak := false) -> Dictionary:
	return {"store": "epic", "id": "Quail", "title": "Hades", "installed": installed, "source": source,
		"heroic_flatpak": flatpak, "config_dir": "/home/u/.config/legendary", "install_path": "/home/u/Games/epic/Hades"}


func _cmd(p: Dictionary, i := -1) -> String:
	var steps: Array = p["steps"]
	return " ".join(PackedStringArray(steps[i]["cmd"]))


func test_epic_with_legendary() -> void:
	var p := StoreCommands.plan("install", _epic(false), TOOLS, FACTS)
	ok(p["ok"], "install planned")
	eq(p["via"], "legendary", "via")
	eq(_cmd(p, 0), "/usr/bin/legendary info Quail --json", "size probe first")
	eq(p["steps"][0]["kind"], "probe", "probe step")
	eq(_cmd(p), "/usr/bin/legendary install Quail --base-path /home/u/Games/epic --platform Windows -y --skip-sdl", "install")
	eq(p["steps"][1]["env"], {"LEGENDARY_CONFIG_PATH": "/home/u/.config/legendary"}, "legendary's config")
	eq(p["finalize"]["base"], "/home/u/Games/epic", "base for the space check")
	var custom := FACTS.duplicate()
	custom["options"] = {"path": "/run/media/deck/SD/Games"}
	ok(_cmd(StoreCommands.plan("install", _epic(false), TOOLS, custom)).contains("--base-path /run/media/deck/SD/Games"), "chosen folder")
	eq(_cmd(StoreCommands.plan("update", _epic(true), TOOLS, FACTS)), "/usr/bin/legendary update Quail -y --skip-sdl", "update")
	eq(_cmd(StoreCommands.plan("verify", _epic(true), TOOLS, FACTS)), "/usr/bin/legendary repair Quail -y --skip-sdl", "verify = repair")
	eq(_cmd(StoreCommands.plan("uninstall", _epic(true), TOOLS, FACTS)), "/usr/bin/legendary uninstall Quail -y --skip-uninstaller", "uninstall")


func test_epic_move_copies_then_tells_legendary() -> void:
	var f := FACTS.duplicate()
	f["options"] = {"path": "/run/media/deck/SD/Games"}
	f["same_drive"] = true
	var p := StoreCommands.plan("move", _epic(true), TOOLS, f)
	eq(_cmd(p, 0), "mv -T -- /home/u/Games/epic/Hades /run/media/deck/SD/Games/Hades", "same drive: one rename")
	eq(_cmd(p, 1), "/usr/bin/legendary move Quail /run/media/deck/SD/Games --skip-move", "legendary records it")
	ok(p["steps"][0]["no_stop"] and p["steps"][1]["no_stop"], "neither can be stopped half way")
	eq(p["steps"][0]["done_if"], {"gone": "/home/u/Games/epic/Hades", "there": "/run/media/deck/SD/Games/Hades"}, "and a restart knows the rename happened")
	ok(not StoreCommands.plan("move", _epic(true), TOOLS, FACTS)["ok"], "no folder: refused")


func test_epic_heroic_hand_offs() -> void:
	var native := StoreCommands.plan("install", _epic(false, "heroic"), TOOLS, FACTS)
	eq(native["via"], "legendary", "native Heroic + host legendary: legendary with Heroic's config")
	var fp := StoreCommands.plan("install", _epic(false, "heroic", true), TOOLS, FACTS)
	eq(fp["via"], "heroic", "Flatpak Heroic: hand to Heroic")
	eq(fp["external"], ["/usr/bin/flatpak", "run", "com.heroicgameslauncher.hgl", "heroic://launch?appName=Quail&runner=legendary"], "heroic:// asks to install")
	var no_cli := TOOLS.duplicate()
	no_cli["legendary"] = ""
	var up := StoreCommands.plan("update", _epic(true, "heroic"), no_cli, FACTS)
	eq(up["external"], ["/usr/bin/heroic"], "other actions just open Heroic")
	ok(not StoreCommands.plan("install", _epic(false), no_cli, FACTS)["ok"], "own legendary game, no legendary: refused")
	ok(not StoreCommands.plan("install", _epic(true), TOOLS, FACTS)["ok"], "already installed")
	ok(not StoreCommands.plan("update", _epic(false), TOOLS, FACTS)["ok"], "not installed")
	ok(not StoreCommands.plan("install", {"store": "steam", "id": "1"}, TOOLS, FACTS)["ok"], "Steam isn't planned here")


func _gog(installed: bool, source: String, flatpak := false) -> Dictionary:
	return {"store": "gog", "id": "1207664663", "installed": installed, "source": source, "heroic_flatpak": flatpak,
		"heroic_root": "/home/u/.config/heroic", "install_path": "/home/u/Games/gog/The Witcher 3", "platform": "windows"}


func test_gog_plans() -> void:
	var heroic_inst := StoreCommands.plan("update", _gog(true, "heroic"), TOOLS, FACTS)
	eq(heroic_inst["via"], "heroic", "Heroic's GOG install stays Heroic's")
	var p := StoreCommands.plan("install", _gog(false, "heroic"), TOOLS, FACTS)
	eq(p["via"], "gogdl", "new install through gogdl")
	eq(_cmd(p), "/opt/heroic/gogdl --auth-config-path /home/u/.config/heroic/gog_store/auth.json download 1207664663 --platform windows --path /home/u/Games/gog --skip-dlcs", "gogdl download")
	eq(_cmd(p, 0), "/opt/heroic/gogdl --auth-config-path /home/u/.config/heroic/gog_store/auth.json info 1207664663 --platform windows", "size probe")
	eq(p["finalize"]["gog_record"], "add", "recorded by us")
	var no_auth := FACTS.duplicate()
	no_auth["gog_auth_exists"] = false
	eq(StoreCommands.plan("install", _gog(false, "heroic"), TOOLS, no_auth)["via"], "heroic", "no GOG sign-in: Heroic")
	eq(StoreCommands.plan("install", _gog(false, "heroic", true), TOOLS, FACTS)["external"].back(), "heroic://launch?appName=1207664663&runner=gog", "Flatpak: heroic://")
	var ours := _gog(true, "gamecove")
	eq(_cmd(StoreCommands.plan("update", ours, TOOLS, FACTS)), "/opt/heroic/gogdl --auth-config-path /home/u/.config/heroic/gog_store/auth.json update 1207664663 --platform windows --path /home/u/Games/gog/The Witcher 3", "update in place")
	ok(_cmd(StoreCommands.plan("verify", ours, TOOLS, FACTS)).contains(" repair 1207664663 "), "repair")
	var del_facts := FACTS.duplicate()
	ok(not StoreCommands.plan("uninstall", ours, TOOLS, del_facts)["ok"], "no marker file: won't delete")
	del_facts["gog_marker_exists"] = true
	var del := StoreCommands.plan("uninstall", ours, TOOLS, del_facts)
	eq(_cmd(del), "rm -rf -- /home/u/Games/gog/The Witcher 3", "delete")
	eq(del["finalize"]["gog_record"], "remove", "record updated")


func test_safe_to_delete() -> void:
	ok(StoreCommands.safe_to_delete("/home/u/Games/gog/X", "/home/u", true), "game folder")
	ok(not StoreCommands.safe_to_delete("/home/u/Games/gog/X", "/home/u", false), "no marker")
	ok(not StoreCommands.safe_to_delete("/home/u", "/home/u", true), "home")
	ok(not StoreCommands.safe_to_delete("/", "/home/u", true), "root")
	ok(not StoreCommands.safe_to_delete("/home/u/", "/home/u", true), "home with slash")
	ok(not StoreCommands.safe_to_delete("Games/x/y", "/home/u", true), "relative")
	ok(not StoreCommands.safe_to_delete("", "/home/u", true), "empty")


func test_amazon_plans() -> void:
	var e := {"store": "amazon", "id": "amzn1.adg.product.x", "installed": false, "source": "nile", "config_dir": "/home/u/.config/nile"}
	var p := StoreCommands.plan("install", e, TOOLS, FACTS)
	eq(_cmd(p), "/usr/bin/nile install amzn1.adg.product.x --base-path /home/u/Games/amazon", "install")
	eq(p["steps"][1]["env"], {"NILE_CONFIG_PATH": "/home/u/.config"}, "nile appends /nile itself")
	e["installed"] = true
	eq(_cmd(StoreCommands.plan("verify", e, TOOLS, FACTS)), "/usr/bin/nile verify amzn1.adg.product.x", "verify")
	var f := FACTS.duplicate()
	f["options"] = {"path": "/x"}
	ok(not StoreCommands.plan("move", e, TOOLS, f)["ok"], "nile can't move")


func test_install_locations_with_sd_card() -> void:
	var media := fixture("stores/data/media")
	var locs := Disk.locations("/home/u/Games", media, "deck")
	var paths: Array = locs.map(func(l): return l["path"])
	eq(paths[0], "/home/u/Games", "internal first")
	ok(media.path_join("deck/SDCARD/Games") in paths, "udisks mount under the user")
	ok(media.path_join("mmcblk0p1/Games") in paths, "SteamOS direct mount")
	ok(not (media.path_join("otheruser/Games") in paths), "another user's folder skipped")
	ok(locs[1]["removable"], "removable")
	ok(Disk.is_removable("/run/media/deck/SD/Games"), "under /run/media")
	ok(not Disk.is_removable("/home/u/Games"), "home isn't")
	ok(Disk.free_bytes(OS.get_user_data_dir().path_join("not/yet/made")) > 0, "free space of the nearest existing parent")
	eq(Disk.human(1536 * 1048576), "1.5 GB", "human")


func test_gog_record_and_scan() -> void:
	var home := TempTree.temp_dir("gog_record")
	var list := StoreCommands.gog_record_with([], {"appName": "1", "install_path": "/g/A", "platform": "windows", "title": "A"})
	list = StoreCommands.gog_record_with(list, {"appName": "2", "install_path": "/g/B", "platform": "linux", "title": "B"})
	list = StoreCommands.gog_record_with(list, {"appName": "1", "install_path": "/g/A2", "platform": "windows", "title": "A"})
	eq(list.size(), 2, "replaced, not duplicated")
	eq(StoreCommands.write_gog_record(home, list), OK, "written")
	eq(StoreCommands.read_gog_record(home).size(), 2, "read back")
	var games := Gog.scan(home)
	eq(games.size(), 2, "our installs show up without Heroic")
	var b: Dictionary = games.filter(func(g): return g["id"] == "2")[0]
	eq([b["installed"], b["source"], b["platform"], b["install_path"]], [true, "gamecove", "linux", "/g/B"], "entry")
	StoreCommands.write_gog_record(home, StoreCommands.gog_record_with(list, {"appName": "2"}, true))
	eq(Gog.scan(home).size(), 1, "removed")
	TempTree.remove_tree(home)


## Final review, low: a move was one `mv`. Across drives that is a copy and then a delete,
## which can't be picked up again: paused or cancelled it left half a game in the new
## place (and the next try refused: "already a folder there"), or half of one in each.
## Across drives the plan is now steps that can each be run again.
func test_move_across_drives_is_a_copy_a_rename_and_a_delete() -> void:
	var f := FACTS.duplicate()
	f["options"] = {"path": "/run/media/deck/SD/Games"}
	f["same_drive"] = false
	var p := StoreCommands.plan("move", _epic(true), TOOLS, f)
	var part: String = "/run/media/deck/SD/Games/Hades" + StoreCommands.MOVING_SUFFIX
	eq(_cmd(p, 0), "cp -a -T -- /home/u/Games/epic/Hades " + part, "copied next to where it goes")
	eq(_cmd(p, 1), "mv -T -- %s /run/media/deck/SD/Games/Hades" % part, "then one rename on that drive")
	eq(_cmd(p, 2), "/usr/bin/legendary move Quail /run/media/deck/SD/Games --skip-move", "legendary records it")
	eq(_cmd(p, 3), "rm -rf -- /home/u/Games/epic/Hades", "and only then the old folder goes")
	ok(not p["steps"][0].get("no_stop", false), "the copy can be paused or cancelled")
	eq(p["steps"][0]["cleanup"], ["rm", "-rf", "--", part], "a cancelled copy is cleared away")
	ok(p["steps"][1]["no_stop"] and p["steps"][2]["no_stop"] and p["steps"][3]["no_stop"], "from the rename on it runs to the end")
	eq(p["steps"][1]["done_if"], {"gone": part, "there": "/run/media/deck/SD/Games/Hades"}, "a restart knows the rename happened")
	eq(p["finalize"]["new_path"], "/run/media/deck/SD/Games/Hades", "where it ends up")
	# GOG (ours): the same, with our record updated at the end
	var g := {"store": "gog", "id": "1207", "title": "W", "installed": true, "source": "gamecove", "platform": "windows",
		"install_path": "/home/u/Games/gog/Witcher", "heroic_root": "/h"}
	var gf := f.duplicate()
	gf["gog_auth_exists"] = true
	var gp := StoreCommands.plan("move", g, TOOLS, gf)
	eq(_cmd(gp, 0), "cp -a -T -- /home/u/Games/gog/Witcher /run/media/deck/SD/Games/Witcher" + StoreCommands.MOVING_SUFFIX, "GOG copies too")
	eq(_cmd(gp, 2), "rm -rf -- /home/u/Games/gog/Witcher", "then deletes")
	eq(gp["finalize"]["gog_record"], "move", "and our record follows")
	# a folder that can't be a game's install is never handed to rm
	var odd := _epic(true)
	odd["install_path"] = "/home/u"
	ok(not StoreCommands.plan("move", odd, TOOLS, f)["ok"], "the home folder is never 'moved'")
	odd["install_path"] = "/Hades"
	ok(not StoreCommands.plan("move", odd, TOOLS, f)["ok"], "nor a folder at the top of the disk")
