extends RefCounted
## Gyro aiming (mouse or stick, sensitivity, activation button) is Steam
## Input's job: InputPlumber and Handheld Daemon hand raw motion to an
## emulated Steam Deck or DualSense and Steam does the rest (docs/CONTROLS.md,
## Controller findings). So the UI explains that and opens Steam's own
## controller settings for the game: steam://controllerconfig/<appid>
## (Valve's Steam browser protocol page).

const AppId := preload("res://scripts/steam/app_id.gd")
const STEAM_STORE := "res://scripts/library/stores/steam.gd"


## The URI for a Library game, or "" when it isn't a Steam game.
static func uri_for(game: Dictionary) -> String:
	if str(game.get("store", "")) != "steam":
		return ""
	var appid := str(game.get("id", ""))
	if not AppId.valid(appid):
		return ""
	return "steam://controllerconfig/" + appid


## Opens it. `opener(uri) -> bool` replaces the real call (tests).
static func open(game: Dictionary, opener := Callable()) -> bool:
	var uri := uri_for(game)
	if uri == "":
		return false
	if opener.is_valid():
		return bool(opener.call(uri))
	var s: Script = load(STEAM_STORE)
	return bool(s.open_uri(uri, s.steam_bin()))
