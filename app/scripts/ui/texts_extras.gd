extends RefCounted
## Words for the everyday extras people otherwise add with plugins: per-app
## volume, media controls, Bluetooth devices, clean-up, Proton versions and
## automatic app updates. Plain and short; every setting gets one help line.

# ---- per-app volume ------------------------------------------------------------------
const MIXER_TITLE := "Apps"
const MIXER_LINE := "Turn one app down without touching the others: the game, music, a voice chat."
const MIXER_EMPTY := "No app is playing sound right now."
const MIXER_LOADING := "Looking for apps playing sound…"
const MIXER_HELP := "This app's own volume. The main volume still sets the overall level."
const MIXER_FAILED := "Couldn't change that app's volume. It may have stopped playing."

# ---- media controls --------------------------------------------------------------------
const MEDIA_TITLE := "Now playing"
const MEDIA_UNKNOWN := "Something's playing"
const MEDIA_PREV := "Previous"
const MEDIA_PLAY := "Play"
const MEDIA_PAUSE := "Pause"
const MEDIA_NEXT := "Next"
const MEDIA_HELP := "Controls the music or video app playing in the background, like Spotify or a browser."
const MEDIA_FAILED := "%s didn't answer."

# ---- Bluetooth devices -----------------------------------------------------------------
const BT_TITLE := "Bluetooth devices"
const BT_LINE := "Controllers, headphones and speakers: connect, pair new ones and forget old ones."
const BT_QUICK_HINT := "Connect a controller or headphones, or pair a new one."
const BT_OFF := "Bluetooth is off. Turn it on above to see your devices."
const BT_NONE := "No Bluetooth adapter found on this handheld."
const BT_EMPTY := "Nothing paired yet. Put your controller or headphones in pairing mode and press Find new devices."
const BT_LOADING := "Reading your devices…"
const BT_FIND := "Find new devices"
const BT_FIND_HINT := "Put the device in pairing mode first, then press A. Looking takes about 10 seconds."
const BT_FINDING := "Looking…"
const BT_FOUND_NONE := "Nothing new found. Is it in pairing mode?"
const BT_CONNECTED := "Connected"
const BT_PAIRED := "Paired"
const BT_NEW := "New"
const BT_BATTERY := "%d%% battery"
const BT_ROW_HINT := "Press A to connect, disconnect or forget it."
const BT_NEW_HINT := "Press A to pair it. Controllers and headphones need no code."
const BT_CONNECT := "Connect"
const BT_DISCONNECT := "Disconnect"
const BT_PAIR := "Pair and connect"
const BT_FORGET := "Forget this device"
const BT_FORGET_DETAIL := "It has to be paired again to use it."
const BT_WORKING := "Working on it…"
const BT_DONE := {"connect": "%s connected", "disconnect": "%s disconnected", "pair": "%s paired", "forget": "Forgot %s"}
const BT_FAILED := {"connect": "%s didn't connect. Is it on and nearby?", "disconnect": "%s didn't disconnect",
	"pair": "%s didn't pair. Put it in pairing mode and try again; a keyboard that asks for a code pairs from Desktop Mode.",
	"forget": "Couldn't forget %s"}

# ---- clean up (Storage) ----------------------------------------------------------------
const CLEAN_TITLE := "Clean up"
const CLEAN_LINE := "Shader caches Steam kept for games you've uninstalled. Safe to remove: they only come back if you reinstall and play."
const CLEAN_MEASURING := "Looking for leftovers…"
const CLEAN_NONE := "Nothing to clean up. No leftovers from uninstalled games."
const CLEAN_FOUND := "%s from %d uninstalled %s"
const CLEAN_BUTTON := "Clean up %s"
const CLEAN_RUNNING := "Cleaning up…"
const CLEAN_DONE := "Freed %s"
const CLEAN_FAILED := "Some folders couldn't be removed. Close Steam's download page and try again."
const CLEAN_SAVES := "Your saves and Proton prefixes are never touched."
