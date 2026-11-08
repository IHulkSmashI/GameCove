extends "res://tests/test_case.gd"

const DeviceScript := preload("res://scripts/device/device.gd")
const Steam := preload("res://scripts/library/stores/steam.gd")
const LibraryScript := preload("res://scripts/library/library.gd")


func test_board_name_matches_before_product_name() -> void:
	var table := DeviceScript.load_table()
	ok(table.size() > 0, "device table loads")
	var d := DeviceScript.match_device(table, "MS-1T91", "Claw 8 EX AI+ CG3EM Launch Pack")
	eq(d.get("id", ""), "msi-claw-8-ex", "Claw 8 EX matched by board")
	eq(d.get("support", ""), "full", "Claw 8 EX is full support")


func test_steam_deck_matches_on_product_name() -> void:
	var d := DeviceScript.match_device(DeviceScript.load_table(), "", "Galileo")
	eq(d.get("id", ""), "steam-deck-oled", "Deck OLED matched")


func test_unknown_device_is_empty() -> void:
	eq(DeviceScript.match_device(DeviceScript.load_table(), "XYZ", "Nothing"), {}, "no match")


func test_steam_appmanifest_fields() -> void:
	var acf := "\"AppState\"\n{\n\t\"appid\"\t\t\"976730\"\n\t\"name\"\t\t\"Halo: The Master Chief Collection\"\n}"
	eq(Steam.acf_value(acf, "appid"), "976730", "appid")
	eq(Steam.acf_value(acf, "name"), "Halo: The Master Chief Collection", "name")
	ok(not Steam.is_game("Proton 9.0"), "Proton is not a game")
	ok(Steam.is_game("Hades"), "Hades is a game")


func test_library_game_has_every_contract_field() -> void:
	var g := LibraryScript.make_game({"store": "steam", "id": "1", "title": "X", "installed": true})
	for k in ["key", "store", "id", "title", "installed", "art", "info", "last_played", "playtime_min"]:
		ok(g.has(k), "game has " + k)
	eq(g["key"], "steam:1", "key format")
