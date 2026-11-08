extends Node
## One library across every store. See docs/CONTRACTS.md for the game shape.
## Owner: library agent. Today: Steam only.

signal changed

const Steam := preload("res://scripts/library/stores/steam.gd")

var games: Array[Dictionary] = []


func _ready() -> void:
	refresh()


func refresh() -> void:
	var out: Array[Dictionary] = []
	for e in Steam.list_installed():
		out.append(make_game(e))
	out.sort_custom(func(a, b): return a["title"].naturalnocasecmp_to(b["title"]) < 0)
	games = out
	changed.emit()


## Fills every field of the contract's game shape so the UI never checks for missing keys.
static func make_game(entry: Dictionary) -> Dictionary:
	return {
		"key": "%s:%s" % [entry["store"], entry["id"]],
		"store": entry["store"],
		"id": entry["id"],
		"title": entry.get("title", ""),
		"installed": entry.get("installed", false),
		"art": entry.get("art", {"cover": "", "hero": "", "logo": "", "icon": ""}),
		"info": entry.get("info", {"released": null, "time_to_beat": null, "anticheat": null, "protondb": null}),
		"last_played": entry.get("last_played", 0),
		"playtime_min": entry.get("playtime_min", 0),
	}


func launch(game: Dictionary) -> void:
	match game["store"]:
		"steam":
			Steam.launch(game["id"])
		_:
			push_warning("No launcher for store %s yet" % game["store"])
