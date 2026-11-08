extends "res://tests/test_case.gd"
## Special buttons, default GameCove actions and glyph lookups per device.

const Buttons := preload("res://scripts/device/buttons.gd")
const DeviceScript := preload("res://scripts/device/device.gd")
const G := "res://assets/devices/glyphs/"


func test_every_glyph_file_exists() -> void:
	for p in Buttons.all_glyphs():
		ok(ResourceLoader.exists(p), "glyph " + p)


func test_every_profile_glyph_resolves_for_every_device() -> void:
	var names := ["accept", "back", "option", "context", "menu", "view", "tab_left", "tab_right", "page_left", "page_right",
		"home", "quick_menu", "osk", "screenshot", "Guide", "QuickAccess", "QuickAccess2", "Keyboard",
		"LeftPaddle1", "LeftPaddle2", "RightPaddle1", "RightPaddle2", "DPadUp", "LeftStick", "nonsense"]
	for d in DeviceScript.load_table():
		for n in names:
			var p := Buttons.glyph_for(n, d["id"])
			ok(p.begins_with(G) and ResourceLoader.exists(p), "%s %s -> %s" % [d["id"], n, p])


func test_profiles_are_well_formed() -> void:
	var caps := ["Guide", "QuickAccess", "QuickAccess2", "Keyboard", "Screenshot", "LeftTop", "RightTop",
		"LeftStickTouch", "RightStickTouch", "LeftPaddle1", "LeftPaddle2", "LeftPaddle3", "RightPaddle1", "RightPaddle2", "RightPaddle3"]
	var actions := ["", "home", "quick_menu", "osk", "screenshot"]
	for id in Buttons.PROFILES:
		var p: Dictionary = Buttons.PROFILES[id]
		ok(p["glyphs"] in Buttons.SET_FILES, "%s glyph set" % id)
		for b in p["special"]:
			ok(b["capability"] in caps, "%s %s capability %s" % [id, b["id"], b["capability"]])
			ok(b.get("press", "short") in ["short", "long", "combo"], "%s press" % id)
		for c in p["paddles"]:
			ok(c.contains("Paddle"), "%s paddle %s" % [id, c])
		for c in p.get("actions", {}):
			ok(p["actions"][c] in actions, "%s action %s" % [id, p["actions"][c]])


func test_steam_deck() -> void:
	eq(Buttons.glyph_set("steam-deck-oled"), "deck", "deck labels")
	eq(Buttons.glyph_for("accept", "steam-deck-oled"), G + "deck/a.svg", "A")
	eq(Buttons.glyph_for("tab_left", "steam-deck-lcd"), G + "deck/l1.svg", "L1, not LB")
	eq(Buttons.glyph_for("home", "steam-deck-lcd"), G + "deck/steam.svg", "STEAM button")
	eq(Buttons.glyph_for("quick_menu", "steam-deck-lcd"), G + "deck/qam.svg", "… button")
	eq(Buttons.glyph_for("LeftPaddle2", "steam-deck-lcd"), G + "paddle/l5.svg", "L5")
	eq(Buttons.paddles("steam-deck-lcd").size(), 4, "four back buttons")
	eq(Buttons.label_for("steam-deck-lcd", "RightBumper"), "R1", "R1")
	eq(Buttons.action_map("steam-deck-oled"), {"Guide": "home", "QuickAccess": "quick_menu"}, "actions")


func test_rog_ally() -> void:
	eq(Buttons.glyph_for("home", "asus-rog-ally"), G + "special/command_center.svg", "Command Center opens home")
	eq(Buttons.glyph_for("quick_menu", "asus-rog-ally-x"), G + "special/armoury_crate.svg", "Armoury Crate opens quick menu")
	eq(Buttons.glyph_for("osk", "asus-rog-ally"), G + "special/command_center.svg", "long press Command Center = keyboard")
	eq(Buttons.glyph_for("accept", "asus-rog-ally"), G + "xbox/a.svg", "xbox A")
	eq(Buttons.glyph_for("tab_left", "asus-rog-ally"), G + "xbox/lb.svg", "LB")
	eq(Buttons.label_for("asus-rog-ally", "LeftPaddle1"), "M1", "M1")
	eq(Buttons.action_map("asus-rog-ally"), {"Guide": "home", "Keyboard": "osk", "QuickAccess": "quick_menu"}, "actions")


func test_xbox_ally_and_legion() -> void:
	eq(Buttons.glyph_for("home", "asus-rog-xbox-ally-x"), G + "special/guide_ring.svg", "Xbox button")
	eq(Buttons.glyph_for("quick_menu", "asus-rog-xbox-ally"), G + "special/library.svg", "Library button")
	eq(Buttons.glyph_for("home", "lenovo-legion-go"), G + "special/legion_l.svg", "Legion L")
	eq(Buttons.glyph_for("quick_menu", "lenovo-legion-go-s-z2go"), G + "special/legion_r.svg", "Legion R")
	eq(Buttons.label_for("lenovo-legion-go", "RightPaddle2"), "M3", "M3")
	eq(Buttons.glyph_for("osk", "lenovo-legion-go-2"), G + "special/view_desktop.svg", "Go 2 ⧉ button")


func test_claw_and_oxp() -> void:
	eq(Buttons.glyph_for("home", "msi-claw-8-ex"), G + "special/msi_m.svg", "MSI Center M")
	eq(Buttons.glyph_for("quick_menu", "msi-claw-8-ex"), G + "special/quick_settings.svg", "Quick Settings")
	eq(Buttons.label_for("msi-claw-8-ex", "RightPaddle1"), "M1", "M1 is the right back button")
	eq(Buttons.glyph_for("quick_menu", "onexplayer-onexfly-f1-pro"), G + "special/turbo.svg", "Turbo")
	eq(Buttons.glyph_for("screenshot", "onexplayer-onexfly-f1"), G + "special/camera.svg", "Turbo + Home")
	eq(Buttons.action_for("onexplayer-3", "QuickAccess2"), "osk", "OXP 3 keyboard button")
	eq(Buttons.action_for("onexplayer-onexfly-f1", "QuickAccess2"), "", "long Home goes to Steam")


func test_missing_buttons_fall_back() -> void:
	eq(Buttons.buttons_for("gpd-win-max-2", "home"), [], "WIN Max 2 has no home button")
	eq(Buttons.glyph_for("home", "gpd-win-max-2"), G + "special/house.svg", "generic home glyph")
	eq(Buttons.FALLBACK_CHORDS["home"], ["QuickAccess", "South"], "chord to offer instead")
	eq(Buttons.glyph_for("quick_menu", "gpd-win-4"), G + "paddle/r4.svg", "WIN 4: R4 is Quick Access")
	eq(Buttons.action_for("zotac-zone", "QuickAccess2"), "home", "Zone Home button opens home")
	eq(Buttons.action_for("ayaneo-kun", "QuickAccess2"), "home", "KUN AYA button opens home")


func test_unknown_device_is_generic() -> void:
	eq(Buttons.profile_id("no-such-device"), "generic", "generic")
	eq(Buttons.glyph_for("accept", "no-such-device"), G + "xbox/a.svg", "xbox A")
	eq(Buttons.glyph_for("home", "no-such-device"), G + "xbox/guide.svg", "guide")
	eq(Buttons.glyph_for("LeftPaddle1", "no-such-device"), G + "paddle/p1.svg", "unnamed paddle")


func test_dbus_events() -> void:
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_guide"), "home", "ui_guide")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_quick"), "quick_menu", "ui_quick")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_osk"), "osk", "ui_osk")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_screenshot"), "screenshot", "ui_screenshot")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_accept"), "accept", "ui_accept")
	eq(Buttons.action_for_dbus("zotac-zone", "ui_quick2"), "home", "per-device override")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_quick2"), "", "pass through")
	eq(Buttons.action_for_dbus("asus-rog-ally", "ui_bogus"), "", "unknown")


func test_special_buttons_carry_paths_and_actions() -> void:
	var sb := Buttons.special_buttons("asus-rog-ally")
	eq(sb.size(), 4, "short and long press of two buttons")
	eq(sb[0]["glyph"], G + "special/command_center.svg", "full path")
	eq(sb[0]["action"], "home", "action")
	eq(sb[3]["action"], "", "Armoury Crate hold passes through")


func test_pictures() -> void:
	eq(DeviceScript.picture_for("steam-deck-oled"), "res://assets/devices/art/steam-deck.svg", "deck")
	eq(DeviceScript.picture_for("lenovo-legion-go-2"), "res://assets/devices/art/legion-go-2.svg", "go 2")
	eq(DeviceScript.picture_for("nope"), "res://assets/devices/art/generic.svg", "generic")
	var svg := FileAccess.get_file_as_string("res://assets/devices/art/steam-deck.svg")
	for part in ["btn-South", "btn-Guide", "btn-QuickAccess", "axis-LeftStick", "btn-DPad", "pad-Left", "btn-LeftPaddle1", "btn-RightBumper", "part-screen"]:
		ok(svg.contains('id="%s"' % part), "deck picture has " + part)
	for f in DirAccess.get_files_at("res://assets/devices/art"):
		if f.ends_with(".svg"):
			var s := FileAccess.get_file_as_string("res://assets/devices/art/" + f)
			ok(s.contains('id="btn-South"') and s.contains('id="axis-RightStick"') and s.contains('id="part-screen"'), f + " has highlightable parts")
