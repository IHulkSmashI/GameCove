extends RefCounted
## What GameCove sends over the network, and the one switch that stops everything it does on its own (review M22).
## README.md "Network and privacy" and docs/PRIVACY.md list the same calls; the About page shows NETWORK_CALLS.
##
## "Background lookups" (user://settings.cfg [privacy] background, default on): off = nothing is requested unless
## the user asks for it right then (opening a store page, pressing Check, searching). Each feature keeps its own
## switch too: "Look up deals and prices" (Discover settings price_lookups), "Show maker photos"
## (DevicePhoto, [device] maker_photo) and "Look up game details" ([privacy] metadata: Steam store details,
## OpenCritic with the user's key, SteamGridDB art for games missing it).

const SettingsFile := preload("res://scripts/system/settings_file.gd")
const PREFS_PATH := "user://settings.cfg"

## Every outbound call, plain words: {"who", "what", "when", "switch"}. Order: background first.
const NETWORK_CALLS := [
	{"who": "GitHub (GameCove's own releases)", "what": "The game database (time to beat, release dates, compatibility) and the upcoming-releases calendar. Nothing about you is sent.",
		"when": "At start, at most once a day", "switch": "Background lookups"},
	{"who": "GitHub (GameCove's upscalers list and mirror)", "what": "The signed list of the newest OptiScaler, OptiPatcher, fakenvapi, XeSS driver and FSR 4 files; the files themselves only when you install or update them. Nothing about you is sent.",
		"when": "At most once a day, 90 s after start; when you install, update or press Check", "switch": "Background lookups (the daily check)"},
	{"who": "CheapShark and the Steam store", "what": "The Steam app ids and titles on your wishlist and in Discover, and your store country, to get deals and prices.",
		"when": "45 s after start, then every 6 hours; when you search or open a game", "switch": "Look up deals and prices"},
	{"who": "GG.deals", "what": "Steam app ids, your region and your own API key, for local prices.",
		"when": "With the deals refresh, only if you added a key", "switch": "Look up deals and prices"},
	{"who": "Your handheld's maker (or GitHub for free photos)", "what": "One request for your device model's picture; the address tells the site which model you have.",
		"when": "At start until the picture is saved, then weekly", "switch": "Show maker photos / Background lookups"},
	{"who": "GitHub (GE-Proton releases)", "what": "Which GE-Proton release is newest; the release itself and its checksum when you install it. Nothing about you is sent.",
		"when": "When you press Check or Install in Settings > Performance > GE-Proton", "switch": "You start it"},
	{"who": "GitHub (firmware index), then the maker's own site", "what": "The list of the newest BIOS and firmware; the firmware file itself only when you ask for a USB drive.",
		"when": "When you check for updates", "switch": "You start it"},
	{"who": "Steam (insights on a game's page)", "what": "The game's app id, for players now, reviews, the Steam Deck rating, the last update and its DLC (DLC prices: also your store country). GameCove never contacts SteamDB; it only shows a QR code for it.",
		"when": "When you open a Steam game's page; players at most every 10 minutes, the rest every 12 hours", "switch": "Background lookups (prices: Look up deals and prices)"},
	{"who": "Steam store (game details)", "what": "The Steam app id of a library game (or of the Steam edition of a GOG, Epic or Amazon game) whose description, genres, screenshots or Metacritic score are missing. Cached for a week.",
		"when": "In the background after start, one request every 2 s; at once for the game page you open", "switch": "Look up game details (+ Background lookups for the background fill)"},
	{"who": "OpenCritic (through RapidAPI)", "what": "A game's title, then its OpenCritic id, with your own API key.",
		"when": "Same as game details, only if you added a key; at most 20 searches and 180 requests a day", "switch": "Look up game details / remove the key"},
	{"who": "SteamGridDB", "what": "A game's Steam app id or title, for artwork you browse in Change artwork, and for covers, banners and logos a game has none of.",
		"when": "When you open Change artwork; in the background for games missing art", "switch": "Look up game details (+ Background lookups for the automatic fill)"},
	{"who": "Your phone, on your own network (Game art step)", "what": "A one-time page your phone opens to send GameCove your SteamGridDB key; then one SteamGridDB request checks the key.",
		"when": "Only while the Game art step is open, 10 minutes at most", "switch": "You start it"},
	{"who": "Steam (achievements, art)", "what": "The app id of the game whose page you open.",
		"when": "When you open a game page", "switch": "Settings > Performance"},
	{"who": "Steam's, IGDB's and SteamGridDB's image servers (no others)", "what": "The address of a game picture Discover, the calendar or your wishlist shows; it names the game, nothing about you.",
		"when": "When a tile shows a picture that isn't saved yet", "switch": "None (SteamGridDB lookups: Look up game details)"},
	{"who": "PCs on your own network (GameStream)", "what": "A fixed client id and Moonlight's certificate; Wake-on-LAN packets to your PC. With no PC saved and none found by mDNS, a connection attempt to port 47989 on every address of your local network (up to 1,022), then GameStream's serverinfo to those that answer.",
		"when": "When you open the Stream tab or wake a PC", "switch": "You start it"},
	{"who": "OS, Flatpak, fwupd and store tools", "what": "Their own update and sign-in requests.",
		"when": "When you update or sign in; Flatpak apps also once a day, with no game running, if you turned on Update apps by themselves", "switch": "You start it (automatic app updates: off by default, and Background lookups)"},
]


static func background_allowed(path := PREFS_PATH) -> bool:
	return _switch(path, "background")


## A switch's value; on by default, but off when the settings file couldn't be read (this run it's quarantined,
## later starts find <path>.bad) until the user sets that switch again (review problem 4: no failing open).
static func _switch(path: String, key: String) -> bool:
	return switch_value(path, "privacy", key)


## Any network switch kept in a settings file ([device] maker_photo, [achievements]
## fetch_rarity, ...): its saved value, else on, but off when the file couldn't be read
## (review 2, low 18: those two still read as on after a damaged file).
static func switch_value(path: String, section: String, key: String) -> bool:
	var cfg := SettingsFile.load_cfg(path)
	if SettingsFile.blocked(path):
		return false
	if cfg.has_section_key(section, key):
		return bool(cfg.get_value(section, key))
	return not FileAccess.file_exists(SettingsFile.abs_path(path) + ".bad")


static func set_background_allowed(on: bool, path := PREFS_PATH) -> bool:
	return SettingsFile.update_cfg(path, func(cfg: ConfigFile): cfg.set_value("privacy", "background", on)) == OK


## "Look up game details" ([privacy] metadata, default on): off = no Steam store details, OpenCritic or
## SteamGridDB requests at all, background or not.
static func metadata_allowed(path := PREFS_PATH) -> bool:
	return _switch(path, "metadata")


static func set_metadata_allowed(on: bool, path := PREFS_PATH) -> bool:
	return SettingsFile.update_cfg(path, func(cfg: ConfigFile): cfg.set_value("privacy", "metadata", on)) == OK
