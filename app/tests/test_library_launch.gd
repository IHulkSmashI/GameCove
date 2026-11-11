extends "res://tests/test_case.gd"
## Launch commands per store, built from fake tool paths (nothing is started).

const Epic := preload("res://scripts/library/stores/epic.gd")
const Gog := preload("res://scripts/library/stores/gog.gd")
const Amazon := preload("res://scripts/library/stores/amazon.gd")
const Common := preload("res://scripts/library/stores/common.gd")
const LibraryScript := preload("res://scripts/library/library.gd")

const TOOLS := {"umu": "/usr/bin/umu-run", "legendary": "/usr/bin/legendary", "nile": "/usr/bin/nile",
	"heroic": [], "heroic_flatpak": ["/usr/bin/flatpak", "run", "com.heroicgameslauncher.hgl"]}
const NO_TOOLS := {"umu": "", "legendary": "", "nile": "", "heroic": [], "heroic_flatpak": []}


func _epic(source := "legendary", proton := true) -> Dictionary:
	return {"store": "epic", "id": "Quail", "installed": true, "source": source, "heroic_flatpak": true,
		"config_dir": "/h/.config/legendary", "prefix": "/pfx/celeste", "proton": proton, "proton_path": "", "umu_id": "umu-504230"}


func test_epic_legendary_with_umu() -> void:
	eq(Epic.launch_command(_epic(), TOOLS, {"PROTON_ENABLE_WAYLAND": "1"}),
		["env", "GAMEID=umu-504230", "LEGENDARY_CONFIG_PATH=/h/.config/legendary", "PROTON_ENABLE_WAYLAND=1",
		"STORE=egs", "WINEPREFIX=/pfx/celeste",
		"/usr/bin/legendary", "launch", "--no-wine", "--wrapper", "/usr/bin/umu-run", "--", "Quail"] as Array[String],
		"legendary launch --no-wine --wrapper umu-run")


func test_epic_heroic_fallbacks() -> void:
	var expect_heroic := ["/usr/bin/flatpak", "run", "com.heroicgameslauncher.hgl", "--no-gui", "--no-sandbox",
		"heroic://launch?appName=Quail&runner=legendary"] as Array[String]
	eq(Epic.launch_command(_epic("heroic", false), TOOLS), expect_heroic, "Wine-type Heroic game goes back to Heroic")
	var no_cli := TOOLS.duplicate()
	no_cli["legendary"] = ""
	eq(Epic.launch_command(_epic("heroic"), no_cli), expect_heroic, "no legendary on the host -> Heroic")
	eq(Epic.launch_command(_epic(), NO_TOOLS), [] as Array[String], "nothing available -> []")
	var e := _epic()
	e["installed"] = false
	eq(Epic.launch_command(e, TOOLS), [] as Array[String], "not installed -> []")


func test_gog_windows_via_umu_and_linux_direct() -> void:
	var dir := fixture("library/games/witcher3")
	var e := {"store": "gog", "id": "1207664663", "installed": true, "source": "heroic", "heroic_flatpak": true,
		"install_path": dir, "platform": "windows", "prefix": "/pfx/w3", "proton": true,
		"proton_path": "/proton/GE-Proton10-25"}
	eq(LibraryScript.launch_command(e, TOOLS),
		["env", "-C", dir + "/bin/x64", "GAMEID=umu-default", "PROTONPATH=/proton/GE-Proton10-25", "STORE=gog",
		"WINEPREFIX=/pfx/w3", "/usr/bin/umu-run", dir + "/bin/x64/witcher3.exe", "-skipLauncher", "-lang", "en US"] as Array[String],
		"primary task through umu-run")
	e["platform"] = "linux"
	e["install_path"] = "/games/Stardew Valley"
	eq(Gog.launch_command(e, NO_TOOLS, {}), ["env", "-C", "/games/Stardew Valley", "/games/Stardew Valley/start.sh"] as Array[String],
		"native Linux runs start.sh directly")
	e["platform"] = "windows"
	eq(Gog.launch_command(e, NO_TOOLS, {}), [] as Array[String], "no umu, no Heroic -> []")


func test_amazon_nile_with_umu() -> void:
	var e := {"store": "amazon", "id": "amzn1.adg.product.aaaa-1111", "installed": true, "source": "heroic",
		"heroic_flatpak": false, "config_dir": "/h/.config/heroic/nile_config/nile", "prefix": "/pfx/fo3", "proton": true}
	eq(Amazon.launch_command(e, TOOLS),
		["env", "GAMEID=umu-default", "NILE_CONFIG_PATH=/h/.config/heroic/nile_config", "STORE=amazon", "WINEPREFIX=/pfx/fo3",
		"/usr/bin/nile", "launch", "--no-wine", "--wrapper", "/usr/bin/umu-run", "--", "amzn1.adg.product.aaaa-1111"] as Array[String],
		"nile launch --no-wine --wrapper umu-run")
	var no_nile := TOOLS.duplicate()
	no_nile["nile"] = ""
	eq(Amazon.launch_command(e, no_nile)[-1], "heroic://launch?appName=amzn1.adg.product.aaaa-1111&runner=nile", "Heroic handoff")


func test_find_tools_on_fake_path() -> void:
	var t := Common.find_tools("/nonexistent/home", "/nonexistent/bin:" + fixture("library/games"))
	eq(t["umu"], "", "no umu-run")
	eq(t["heroic_flatpak"], [], "no Flatpak Heroic without its data folder")
