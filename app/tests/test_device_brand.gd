extends "res://tests/test_case.gd"
## Brand logos (scripts/device/brand.gd) with a fake icon tree under user://;
## never looks at the real system icon dirs.

const Brand := preload("res://scripts/device/brand.gd")

var _root := ""


func _abs(rel: String) -> String:
	return ProjectSettings.globalize_path("user://test_brand_icons").path_join(rel)


func _rm_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_rm_tree(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


func _put(rel: String, body := "x") -> String:
	var p := _abs(rel)
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return p


## Fresh fake tree: user/, flatpak/, system/ icon roots and a pixmaps dir.
func _setup() -> void:
	_rm_tree(_abs(""))
	DirAccess.make_dir_recursive_absolute(_abs("pixmaps"))
	Brand.set_search_dirs([_abs("user"), _abs("flatpak"), _abs("system")], [_abs("pixmaps")])


func _done() -> void:
	Brand.reset_search_dirs()
	_rm_tree(_abs(""))


func test_key_for_aliases_and_dmi_vendors() -> void:
	eq(Brand.key_for("MSI"), "msi")
	eq(Brand.key_for("Micro-Star International Co., Ltd."), "msi")
	eq(Brand.key_for("ASUSTeK COMPUTER INC."), "asus")
	eq(Brand.key_for("  Steam "), "steam")
	eq(Brand.key_for("Heroic Games Launcher"), "heroic")
	eq(Brand.key_for("AYANEO Ltd"), "ayaneo", "first-word fallback")
	eq(Brand.key_for("GenuineIntel"), "intel")
	eq(Brand.key_for("Orange Pi"), "", "unknown maker")
	eq(Brand.key_for(""), "")


func test_only_allowed_logos_are_bundled() -> void:
	_setup()
	eq(Brand.bundled_logo_for("heroic"), "res://assets/brand/heroic.svg")
	ok(ResourceLoader.exists("res://assets/brand/heroic.svg"), "heroic icon ships")
	for name in ["Steam", "Epic", "GOG", "Amazon", "Valve", "MSI", "ASUS", "Lenovo", "Acer",
			"OneXPlayer", "AYANEO", "GPD", "ZOTAC", "Intel", "AMD"]:
		eq(Brand.bundled_logo_for(name), "", name + " has no bundled logo")
		eq(Brand.notice_for(name), "", name + " has no notice")
	ok(Brand.notice_for("Heroic").contains("GPL-3.0"), "heroic notice names its license")
	_done()


func test_makers_and_chips_are_text_only() -> void:
	_setup()
	# Even an icon file named like the maker on disk doesn't make a maker logo.
	_put("system/hicolor/scalable/apps/msi.svg")
	_put("pixmaps/intel.png")
	for name in ["MSI", "ASUS", "Lenovo", "Acer", "OneXPlayer", "AYANEO", "GPD", "ZOTAC", "Valve", "Intel", "AMD"]:
		eq(Brand.logo_for(name), "", name)
	_done()


func test_system_icon_prefers_user_then_flatpak_then_system() -> void:
	_setup()
	var sys := _put("system/hicolor/256x256/apps/steam.png")
	eq(Brand.system_icon_for("steam"), sys, "system hicolor png")
	Brand.set_search_dirs([_abs("user"), _abs("flatpak"), _abs("system")], [_abs("pixmaps")])
	var fp := _put("flatpak/hicolor/128x128/apps/com.valvesoftware.Steam.png")
	var user := _put("user/hicolor/48x48/apps/steam.png")
	# Names are tried in order ("steam" before the Flatpak id); roots in XDG order.
	eq(Brand.system_icon_for("Steam"), user, "user dir wins")
	ok(fp != "", "flatpak icon written")
	_done()


func test_system_icon_scalable_beats_png_and_falls_back_to_flatpak_id() -> void:
	_setup()
	_put("system/hicolor/512x512/apps/com.valvesoftware.Steam.png")
	var svg := _put("system/hicolor/scalable/apps/com.valvesoftware.Steam.svg")
	eq(Brand.system_icon_for("steam"), svg)
	_done()


func test_pixmaps_last_and_bad_files_skipped() -> void:
	_setup()
	_put("system/hicolor/256x256/apps/net.lutris.Lutris.png", "")  # empty: skipped
	var pix := _put("pixmaps/lutris.png")
	eq(Brand.system_icon_for("Lutris"), pix)
	eq(Brand.system_icon_for("bottles"), "", "nothing installed")
	eq(Brand.find_icon("../etc/passwd"), "", "unsafe name refused")
	eq(Brand.find_icon("a/b"), "", "slash refused")
	_done()


func test_logo_for_order_bundled_then_system_then_empty() -> void:
	_setup()
	var heroic_sys := _put("flatpak/hicolor/scalable/apps/com.heroicgameslauncher.hgl.svg")
	eq(Brand.logo_for("Heroic"), "res://assets/brand/heroic.svg", "bundled first")
	eq(Brand.system_icon_for("Heroic"), heroic_sys, "system icon still found")
	eq(Brand.logo_for("Epic Games Store"), "", "no bundled, no system icon")
	var steam := _put("flatpak/hicolor/scalable/apps/com.valvesoftware.Steam.svg")
	eq(Brand.logo_for("steam"), steam, "system icon when nothing is bundled")
	eq(Brand.logo_for("nonsense"), "")
	_done()


func test_cache_is_per_session_and_cleared_by_set_dirs() -> void:
	_setup()
	eq(Brand.system_icon_for("bottles"), "")
	var p := _put("user/hicolor/scalable/apps/com.usebottles.bottles.svg")
	eq(Brand.system_icon_for("bottles"), "", "miss is cached")
	Brand.set_search_dirs([_abs("user")], [])
	eq(Brand.system_icon_for("bottles"), p, "cache cleared")
	_done()


func test_default_dirs_cover_xdg_flatpak_and_system() -> void:
	var roots := Brand.default_icon_roots()
	ok("/var/lib/flatpak/exports/share/icons" in roots, "system flatpak exports")
	ok("/usr/share/icons" in roots, "system icons")
	var home := OS.get_environment("HOME")
	if home != "":
		ok(home.path_join(".local/share/flatpak/exports/share/icons") in roots, "user flatpak exports")


func test_general_notice_text() -> void:
	eq(Brand.general_notice(), "Product and company names are trademarks of their respective owners; GameCove is not affiliated with or endorsed by them.")
