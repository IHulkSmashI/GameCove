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
const CLEAN_AWAY := "A drive with Steam games isn't in right now (%s). We keep its games' caches."
const UPSCALE_STORE_TITLE := "Upscaling files"
const UPSCALE_STORE_SIZE := "%s in one folder"
const UPSCALE_STORE_GAMES := "Set up in %d %s. Pick Native on a game's page to take ours out of it."
const UPSCALE_STORE_NO_GAMES := "Not in any game right now."
const UPSCALE_STORE_BUNDLE := "Another %s came with GameCove, so nothing is downloaded when a game is first set up."
const UPSCALE_STORE_LINE := "Upscalers and frame generation for your games. Uninstalling GameCove removes all of it and puts every game back as it shipped."
const CLEAN_MISSING := "A drive with Steam games isn't there right now (%s), so we can't tell which caches are left over. Put it back in and open this page again."

# ---- GE-Proton ---------------------------------------------------------------------------
const GE_TITLE := "GE-Proton"
const GE_LINE := "A community Proton with extra fixes and codecs some games need. Install it here, then pick it in a game's Proton version."
const GE_CHECK := "Check for the latest GE-Proton"
const GE_CHECK_HINT := "Asks GitHub for the newest release. Nothing about you is sent."
const GE_CHECKING := "Checking…"
const GE_LATEST := "%s is out"
const GE_HAVE_LATEST := "You have the latest: %s"
const GE_INSTALL := "Install %s"
const GE_INSTALL_HINT := "Downloads about %s from GloriousEggroll's GitHub page, checks it, and unpacks it for Steam."
const GE_INSTALLING := "Downloading and checking… this takes a few minutes"
const GE_INSTALLED := "%s installed. Steam games can use it after Steam restarts."
const GE_ROW_HINT := "Press A to remove it."
const GE_ROW_IN_USE := "Used by %d %s"
const GE_REMOVE := "Remove %s"
const GE_REMOVE_DETAIL := "Frees the space it takes (about 1.5 GB). Versions a game is set to stay until you pick another for it."
const GE_REMOVED := "Removed %s"
const GE_NONE := "No GE-Proton installed yet."
const GE_BROKEN := "Didn't finish unpacking"
const GE_BROKEN_HINT := "Steam can't use it. Press A to remove it."
const GE_BROKEN_DETAIL := "The install stopped half way (the handheld switched off or GameCove closed). Removing it frees the space; install it again any time."
const GE_NO_STEAM := "Steam isn't set up on this handheld yet, so there's nowhere to install Proton."
const GE_ERRORS := {
	"offline": "Couldn't reach GitHub. Check the internet connection and try again.",
	"bad_release": "GitHub's answer didn't look like a GE-Proton release. Try again later.",
	"exists": "That version is already installed.",
	"download": "The download stopped. Check the internet connection and try again.",
	"checksum": "The download didn't match its checksum, so it wasn't installed. Try again.",
	"unpack": "Couldn't unpack it. Is there enough free space?",
	"no_steam": "Steam isn't set up on this handheld yet, so there's nowhere to install Proton.",
	"in_use": "A game is set to this version. Pick another Proton for it first.",
	"not_found": "That version isn't installed any more.",
	"failed": "Couldn't remove it. Try again.",
	"game_running": "A game is running. Install GE-Proton once you've closed it, so the download doesn't slow the game down.",
}

# ---- automatic app updates -------------------------------------------------------------
const AUTO_APPS := "Update apps by themselves"
const AUTO_APPS_HELP := {
	false: "Off: apps update when you press Update here.",
	true: "Once a day, when no game is running, Flatpak apps update quietly in the background. Needs Background lookups on, and waits for the charger or Wi-Fi that isn't metered.",
}

# ---- recording (quick menu + Settings > Media) ------------------------------------------
const REC_START := "Record"
const REC_START_HINT := "Records the screen and sound until you stop it here. Saved to Videos/GameCove."
const REC_STOP := "Stop recording"
const REC_STOP_HINT := "Saves the clip. You'll find it in Settings > Media > Clips."
const REC_STARTING := "Starting…"
const REC_SAVING := "Saving…"
const REC_SET_UP := "Set up recording"
const REC_SET_UP_HINT := "Recording needs GPU Screen Recorder. Press A to open Settings > Media."
const REC_STARTED := "Recording. Open the quick menu to stop."
const REC_SAVED := "Clip saved: %s"
const REC_CHIP := "REC"
const REC_ERRORS := {
	"needs_setup": "Recording needs a one-time OK first. Open Settings > Media and press Allow screen capture.",
	"no_encoder": "This handheld's video encoder didn't answer, so nothing was recorded.",
	"missing": "GPU Screen Recorder isn't installed any more. Install it again in Settings > Media.",
	"no_screen": "GPU Screen Recorder couldn't find the screen to record.",
	"not_ready": "Recording isn't set up yet. Open Settings > Media.",
	"empty": "The recording stopped before anything was saved.",
	"failed": "Recording stopped unexpectedly.",
}

const MEDIA_REC_TITLE := "Recording"
const MEDIA_REC_LINE := "Record what's on screen from the quick menu. GPU Screen Recorder does the work on the graphics chip, so games barely notice. Nothing records until you press Record."
const MEDIA_RECORDER := "GPU Screen Recorder"
const MEDIA_READY := "Ready"
const MEDIA_CHECKING := "Checking…"
const MEDIA_READY_HINT := {
	"host": "Installed on this system. Record from the quick menu (Guide button).",
	"flatpak": "Installed from Flathub. Record from the quick menu (Guide button).",
}
const MEDIA_MISSING := "Not installed"
const MEDIA_INSTALL := "Install GPU Screen Recorder"
const MEDIA_INSTALL_HINT := "Downloads it from Flathub for everyone on this handheld (about 150 MB). Free and open source."
const MEDIA_INSTALLING := "Installing… this takes a minute or two"
const MEDIA_INSTALLED := "GPU Screen Recorder installed"
const MEDIA_NO_FLATPAK := "Flatpak isn't on this system, so we can't install it from here. Install gpu-screen-recorder with your system's package manager."
const MEDIA_INSTALL_FAILED := "The install didn't finish: %s"
const MEDIA_INSTALL_DESKTOP := "Installing for everyone needs your admin password here, and Gaming Mode can't ask for it. Switch to Desktop Mode, open GameCove there and press Install again."
const MEDIA_USER_ONLY := "Installed for this user only"
const MEDIA_USER_ONLY_HINT := "Recording the screen needs the install for everyone (the screen-capture helper runs from there). Press A to add it; your settings stay."
const MEDIA_SETUP := "Allow screen capture"
const MEDIA_SETUP_STATE := "One-time OK needed"
const MEDIA_SETUP_HINT := "A small helper needs permission to read the screen, once. It asks for your admin password, so do this in Desktop Mode: switch there, open GameCove and press this again."
const MEDIA_SETUP_RUNNING := "Waiting for your password…"
const MEDIA_SETUP_DONE := "Screen capture allowed. Record from the quick menu."
const MEDIA_SETUP_DESKTOP := "Gaming Mode can't ask for your admin password. Switch to Desktop Mode, open GameCove there and press Allow screen capture."
const MEDIA_SETUP_FAILED := "That didn't work: %s"
const MEDIA_AUDIO := "Record sound"
const MEDIA_AUDIO_HELP := {true: "On: the game's sound goes in the clip.", false: "Off: clips are silent."}
const MEDIA_FPS := "Frame rate"
const MEDIA_FPS_HELP := {30: "30 frames a second: smaller files, a little less work while you play.", 60: "60 frames a second: smoother clips."}
const MEDIA_FPS_LABELS := ["30 fps", "60 fps"]

const CLIPS_TITLE := "Clips"
const CLIPS_LINE := "What you've recorded, newest first. Watch, send to your phone or delete."
const CLIPS_EMPTY := "No clips yet. Open the quick menu while you play and press Record."
const CLIPS_LOADING := "Looking for clips…"
const CLIPS_ROW_HINT := "Press A to watch, send to your phone or delete it."
const CLIPS_MORE := "%d more in Videos/GameCove"
const CLIPS_PLAY := "Watch"
const CLIPS_PLAY_WITH := "Opens in %s. Close it to come back."
const CLIPS_NO_PLAYER := "Get a video player to watch"
const CLIPS_NO_PLAYER_DETAIL := "Installs mpv from Flathub for you (no password). It plays clips full screen with the controller."
const CLIPS_PLAYER_INSTALLING := "Installing mpv…"
const CLIPS_PLAYER_FAILED := "mpv didn't install: %s"
const CLIPS_SHARE := "Send to phone"
const CLIPS_SHARE_DETAIL := "A QR code: your phone downloads it over your Wi-Fi."
const CLIPS_DELETE := "Delete clip"
const CLIPS_DELETE_DETAIL := "Removes it from Videos/GameCove for good."
const CLIPS_DELETED := "Deleted %s"
const CLIPS_DELETE_FAILED := "Couldn't delete it"
const CLIPS_LAUNCH_FAILED := "The player didn't start"
const SHARE_TITLE := "Send to your phone"
const SHARE_STEPS := "Scan this with your phone's camera. It opens a page on your own network where you can watch the clip and tap Download."
const SHARE_SAME_WIFI := "Your phone needs to be on the same Wi-Fi."
const SHARE_LEFT := "Closes in %d:%02d, or once it's downloaded."
const SHARE_SENT := "Clip sent to your phone"
const SHARE_EXPIRED := "The page closed after 10 minutes"
const SHARE_OFFLINE := "Connect to Wi-Fi first: the phone downloads the clip over your own network."

# ---- screenshots (Settings > Media) -------------------------------------------------------
const SHOTS_TITLE := "Screenshots"
const SHOTS_LINE := "Pictures you took with the Screenshot shortcut or your handheld's screenshot button, newest first. They're in Pictures/Screenshots."
const SHOTS_EMPTY := "No screenshots yet. Open the quick menu while you play and press Screenshot."
const SHOTS_LOADING := "Looking for screenshots…"
const SHOTS_MORE := "%d more in Pictures/Screenshots"
const SHOTS_VIEW := "Look at it"
const SHOTS_VIEW_DETAIL := "Shows the picture full screen."
const SHOTS_VIEW_FAILED := "Couldn't open that picture."
const SHOTS_DELETE := "Delete screenshot"
const SHOTS_DELETE_DETAIL := "Removes it from Pictures/Screenshots for good."
const SHOTS_DELETED := "Screenshot deleted"
const SHOTS_CLOSE := "Close"

# ---- apps -------------------------------------------------------------------------------
const APPS_TITLE := "Apps"
const APPS_SHELF := "Apps"
const APPS_ALL := "All apps"
const APPS_ALL_LINE := "Every app on this handheld"
const APPS_LINE := "Desktop apps, full screen. Pin the ones you use to Home with X."
const APPS_LOADING := "Finding your apps…"
const APPS_EMPTY := "No apps found. Apps you install from Flathub or your system show up here."
const APPS_PIN := "Pin to Home"
const APPS_UNPIN := "Unpin"
const APPS_PINNED := "%s pinned to Home"
const APPS_UNPINNED := "%s unpinned"
const APPS_PROMPT_OPEN := "Open"
const APPS_FAILED := "%s didn't start"

# ---- controller battery -----------------------------------------------------------------
const PADS_TIP := "Controller battery: %s"
