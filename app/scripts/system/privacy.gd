extends RefCounted
## What GameCove sends over the network, and the one switch that stops everything it does on its own (review M22).
## README.md "Network and privacy" and docs/PRIVACY.md list the same calls; the About page shows NETWORK_CALLS.
##
## "Background lookups" (user://settings.cfg [privacy] background, default on): off = nothing is requested unless
## the user asks for it right then (opening a store page, pressing Check, searching). Each feature keeps its own
## switch too: "Look up deals and prices" (Discover settings price_lookups) and "Show maker photos"
## (DevicePhoto, [device] maker_photo).

const PREFS_PATH := "user://settings.cfg"

## Every outbound call, plain words: {"who", "what", "when", "switch"}. Order: background first.
const NETWORK_CALLS := [
	{"who": "GitHub (GameCove's own releases)", "what": "The game database (time to beat, release dates, compatibility) and the upcoming-releases calendar. Nothing about you is sent.",
		"when": "At start, at most once a day", "switch": "Background lookups"},
	{"who": "CheapShark and the Steam store", "what": "The Steam app ids and titles on your wishlist and in Discover, and your store country, to get deals and prices.",
		"when": "45 s after start, then every 6 hours; when you search or open a game", "switch": "Look up deals and prices"},
	{"who": "GG.deals", "what": "Steam app ids, your region and your own API key, for local prices.",
		"when": "With the deals refresh, only if you added a key", "switch": "Look up deals and prices"},
	{"who": "Your handheld's maker (or GitHub for free photos)", "what": "One request for your device model's picture; the address tells the site which model you have.",
		"when": "At start until the picture is saved, then weekly", "switch": "Show maker photos / Background lookups"},
	{"who": "GitHub (firmware index), then the maker's own site", "what": "The list of the newest BIOS and firmware; the firmware file itself only when you ask for a USB drive.",
		"when": "When you check for updates", "switch": "You start it"},
	{"who": "Steam (achievements, art)", "what": "The app id of the game whose page you open.",
		"when": "When you open a game page", "switch": "Settings > Performance"},
	{"who": "SteamGridDB", "what": "A game's app id or title and your own API key, for missing art.",
		"when": "Only if you added a key", "switch": "Remove the key"},
	{"who": "PCs on your own network (GameStream)", "what": "A fixed client id and Moonlight's certificate; Wake-on-LAN packets to your PC.",
		"when": "When you open the Stream tab or wake a PC", "switch": "You start it"},
	{"who": "OS, Flatpak, fwupd and store tools", "what": "Their own update and sign-in requests.",
		"when": "When you update or sign in", "switch": "You start it"},
]


static func background_allowed(path := PREFS_PATH) -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return true
	return bool(cfg.get_value("privacy", "background", true))


static func set_background_allowed(on: bool, path := PREFS_PATH) -> bool:
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value("privacy", "background", on)
	return cfg.save(path) == OK
