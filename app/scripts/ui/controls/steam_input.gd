extends RefCounted
## Gyro aiming (mouse or stick, sensitivity, activation button) is Steam
## Input's job: InputPlumber and Handheld Daemon hand raw motion to an
## emulated Steam Deck or DualSense and Steam does the rest (docs/CONTROLS.md,
## Controller findings). So the UI explains that and opens Steam's own
## controller settings for the game: steam://controllerconfig/<appid>
## (Valve's Steam browser protocol page: "Opens the controller configurator
## (Steam Input) for the specified game", <id> being a Steam application id).
##
## Which games: every game Steam itself starts. A Steam game by its app id; a
## non-Steam shortcut (an emulated game Steam ROM Manager added, or any entry
## with `shortcut` true) by the shortcut's own 32-bit app id, the `appid` Steam
## keeps for it in shortcuts.vdf and names in `SteamLaunch AppId=<id>`. Not the
## 64-bit game id steam://rungameid takes. Valve's page doesn't spell out the
## shortcut case; shipped tools do: Vesktop (src/main/utils/steamOS.ts), run as
## a shortcut in Game Mode, opens steam://controllerconfig/<its 32-bit shortcut
## id>/<layout> (the id read from its shadercache folder), and Decktricks does
## the same. Still on the list to confirm on a handheld (docs/CONTROLS.md).
## A game GameCove starts itself (Epic, GOG, Amazon, a ROM started directly)
## never passes through Steam Input, so it has no such screen: why_not() says so.
##
## Under gamescope the trip there and back is steam/steam_handoff.gd's; main.gd
## sets `handoff` so every button goes through it.

const AppId := preload("res://scripts/steam/app_id.gd")
const STEAM_STORE := "res://scripts/library/stores/steam.gd"


const TC := preload("res://scripts/ui/texts_controls.gd")

## func(game: Dictionary) -> bool: the app's hand-off to Steam's screen and back
## (main.gd sets it; unset in tests and tools, where the URI is just opened).
static var handoff: Callable = Callable()


## True for a game Steam starts: its own, or a non-Steam shortcut.
static func through_steam(game: Dictionary) -> bool:
	return str(game.get("store", "")) == "steam" or game.get("shortcut", false) == true


## The URI for a Library game, or "" when Steam has no controller settings for it.
static func uri_for(game: Dictionary) -> String:
	if not through_steam(game):
		return ""
	var appid := str(game.get("id", ""))
	if not AppId.valid(appid):
		return ""
	return "steam://controllerconfig/" + appid


## One line for where the button would be when there's none ("" when there is one).
static func why_not(game: Dictionary) -> String:
	if uri_for(game) != "":
		return ""
	if game.is_empty() or str(game.get("key", "")) == "":
		return TC.GYRO_STEAM_NO_GAME
	return TC.GYRO_STEAM_NOT_STEAM


## Opens it. `opener(uri) -> bool` replaces the real call (tests).
static func open(game: Dictionary, opener := Callable()) -> bool:
	var uri := uri_for(game)
	if uri == "":
		return false
	if opener.is_valid():
		return bool(opener.call(uri))
	if handoff.is_valid():
		return bool(handoff.call(game))
	var s: Script = load(STEAM_STORE)
	return bool(s.open_uri(uri, s.steam_bin()))
