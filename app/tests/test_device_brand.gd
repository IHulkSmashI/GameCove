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
	eq(Brand.key_for("Micro-Star International Co., Ltd"), "msi", "no final dot")
	eq(Brand.key_for("ASUSTeK COMPUTER INC."), "asus")
	eq(Brand.key_for("ASUS"), "asus")
	eq(Brand.key_for("ROG"), "rog")
	eq(Brand.key_for("LENOVO"), "lenovo")
	eq(Brand.key_for("Legion"), "lenovo", "Legion shows the Lenovo logo")
	eq(Brand.key_for("AYANEO"), "ayaneo")
	eq(Brand.key_for("AYA NEO"), "ayaneo")
	eq(Brand.key_for("AYADEVICE"), "ayaneo")
	eq(Brand.key_for("AYANEO Ltd"), "ayaneo", "company suffix dropped")
	eq(Brand.key_for("ONE-NETBOOK"), "onexplayer")
	eq(Brand.key_for("One Netbook Technology Co., Ltd."), "onexplayer")
	eq(Brand.key_for("GPD"), "gpd")
	eq(Brand.key_for("Shenzhen GPD"), "gpd")
	eq(Brand.key_for("Shenzhen GPD Technology Co., Ltd."), "gpd")
	eq(Brand.key_for("OrangePi"), "orangepi")
	eq(Brand.key_for("Orange Pi"), "orangepi")
	eq(Brand.key_for("AOKZOE"), "aokzoe")
	eq(Brand.key_for("ZOTAC"), "zotac")
	eq(Brand.key_for("Acer"), "acer")
	eq(Brand.key_for("Valve"), "valve")
	eq(Brand.key_for("GenuineIntel"), "intel")
	eq(Brand.key_for("Intel(R) Corporation"), "intel")
	eq(Brand.key_for("AuthenticAMD"), "amd")
	eq(Brand.key_for("  Steam "), "steam")
	eq(Brand.key_for("Prime Gaming"), "amazon")
	eq(Brand.key_for("Heroic Games Launcher"), "heroic")
	eq(Brand.key_for("Some Unknown Maker Inc."), "", "unknown maker")
	eq(Brand.key_for("Co., Ltd."), "", "only company-form words")
	eq(Brand.key_for(""), "")


## Every maker and DMI vendor in devices.json maps to a brand.
func test_every_device_maker_has_a_brand() -> void:
	var j := JSON.new()
	ok(j.parse(FileAccess.get_file_as_string("res://data/devices.json")) == OK, "devices.json parses")
	for row in j.data.get("devices", []):
		var maker := str(row.get("maker", ""))
		ok(Brand.key_for(maker) != "", "maker " + maker)
		var matches: Array = row.get("match") if row.get("match") is Array else [row.get("match", {})]
		for m in matches:
			if not m is Dictionary:
				continue
			for field in ["sys_vendor", "board_vendor"]:
				for v in m.get(field, []):
					eq(Brand.key_for(str(v)), Brand.key_for(maker), "%s %s" % [field, v])


func _brands() -> Dictionary:
	var j := JSON.new()
	j.parse(FileAccess.get_file_as_string("res://data/brand_logos.json"))
	return j.data["brands"]


func test_every_enabled_logo_file_exists_and_is_valid_svg() -> void:
	var brands := _brands()
	var shipped := 0
	for key in brands:
		var e: Dictionary = brands[key]
		ok(e.has("enabled") and e["enabled"] is bool, key + " has an enabled flag")
		ok(str(e.get("source", "")) != "" or str(e.get("file", "")) == "", key + " logo has a source")
		var file := str(e.get("file", ""))
		if not e.get("enabled", false) or file == "":
			continue
		shipped += 1
		ok(file.begins_with("res://assets/brand/") and file.ends_with(".svg"), key + " path")
		ok(FileAccess.file_exists(file), key + " file exists")
		var svg := FileAccess.get_file_as_string(file)
		ok(svg.contains("<svg") and svg.contains("</svg>"), key + " looks like SVG")
		ok(not svg.to_lower().contains("<script"), key + " has no script")
		var xml := XMLParser.new()
		ok(xml.open_buffer(svg.to_utf8_buffer()) == OK, key + " opens as XML")
		var err := OK
		while err == OK:
			err = xml.read()
		eq(err, ERR_FILE_EOF, key + " parses to the end")
		var img := Image.new()
		eq(img.load_svg_from_string(svg, 1.0), OK, key + " renders")
		ok(img.get_width() > 0 and img.get_height() > 0, key + " has a size")
		eq(Brand.bundled_logo_for(key), file, key + " is served")
		if str(e.get("source", "")).begins_with("simple-icons@"):
			ok(e.get("mono", false) == true, key + " Simple Icons logos are single-colour")
			eq(str(e.get("hex", "")).length(), 6, key + " brand colour")
	ok(shipped >= 14, "at least 14 logos ship, got %d" % shipped)


func test_bundled_logos_for_makers_chips_and_stores() -> void:
	_setup()
	for name in ["Steam", "Epic", "GOG", "Valve", "MSI", "ASUS", "ROG", "Lenovo", "Acer",
			"Intel", "AMD", "Heroic", "Lutris", "Bottles"]:
		ok(Brand.bundled_logo_for(name) != "", name + " has a bundled logo")
		eq(Brand.logo_for(name), Brand.bundled_logo_for(name), name + " bundled wins")
	for name in ["Amazon", "OneXPlayer", "AYANEO", "AOKZOE", "GPD", "ZOTAC", "Orange Pi"]:
		eq(Brand.bundled_logo_for(name), "", name + " has no bundled logo yet")
		eq(Brand.logo_for(name), "", name + " shows text")
	ok(Brand.is_mono("Steam"), "Simple Icons logo is mono")
	ok(not Brand.is_mono("Bottles"), "Bottles icon is multi-colour")
	eq(Brand.brand_color("MSI"), Color.from_string("#FF0000", Color.BLACK))
	eq(Brand.brand_color("GPD"), Color(0, 0, 0, 0), "no colour without a logo")
	ok(Brand.notice_for("Heroic").contains("GPL-3.0"), "heroic notice names its license")
	ok(Brand.notice_for("Steam").contains("Valve Corporation"), "Valve's notice")
	eq(Brand.notice_for("GPD"), "", "no logo, no notice")
	_done()


func test_logo_texture_tints_mono_and_keeps_colour_logos() -> void:
	var t := Brand.logo_texture("Steam", 48, Color(1, 0, 0))
	ok(t != null, "texture made")
	if t != null:
		var img := t.get_image()
		eq(img.get_height(), 48, "sized to px")
		var red := false
		for y in range(0, img.get_height(), 2):
			for x in range(0, img.get_width(), 2):
				var c := img.get_pixel(x, y)
				if c.a > 0.9:
					ok(c.r > 0.9 and c.g < 0.1 and c.b < 0.1, "filled with tint")
					red = true
					break
			if red:
				break
		ok(red, "some opaque pixels")
	ok(Brand.logo_texture("Bottles", 32) != null, "colour logo loads")
	eq(Brand.logo_texture("GPD"), null, "no logo")


func test_disabled_brand_returns_nothing() -> void:
	_setup()
	var brands := _brands()
	brands["steam"]["enabled"] = false
	brands["heroic"]["enabled"] = false
	var path := _put("table.json", JSON.stringify({"brands": brands}))
	Brand.use_data(path)
	_put("flatpak/hicolor/scalable/apps/com.valvesoftware.Steam.svg")
	ok(not Brand.is_enabled("Steam"), "steam off")
	eq(Brand.key_for("Steam"), "steam", "still known by name")
	eq(Brand.bundled_logo_for("Steam"), "", "no bundled logo")
	eq(Brand.system_icon_for("Steam"), "", "no system icon either")
	eq(Brand.logo_for("Steam"), "", "text only")
	eq(Brand.logo_for("Heroic"), "")
	eq(Brand.logo_texture("Heroic"), null)
	eq(Brand.notice_for("Steam"), "")
	ok(Brand.logo_for("MSI") != "", "others unaffected")
	Brand.use_data("")
	ok(Brand.logo_for("Steam") != "", "real table back")
	_done()


func test_shipped_table_enables_every_brand() -> void:
	for key in _brands():
		ok(Brand.is_enabled(key), key + " enabled in the shipped table")


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
	eq(Brand.logo_for("Amazon Games"), "", "no bundled, no system icon")
	var steam := _put("flatpak/hicolor/scalable/apps/com.valvesoftware.Steam.svg")
	eq(Brand.logo_for("steam"), "res://assets/brand/steam.svg", "bundled beats system")
	eq(Brand.system_icon_for("steam"), steam, "system icon path still available")
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
