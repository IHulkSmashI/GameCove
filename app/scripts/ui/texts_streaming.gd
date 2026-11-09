extends RefCounted
## Words for the Streaming page and service. Plain and short.

const TAB := "Stream"
const TITLE := "Stream"
const SUBTITLE := "Play games from your PC on this screen"
const VIBEPOLLO_URL := "https://github.com/Nonary/Vibepollo/releases"
const MOONLIGHT_URL := "https://moonlight-stream.org"

# service notices and errors
const INSTALL_RUNNING := "Installing Moonlight…"
const INSTALL_DONE := "Moonlight is ready"
const INSTALL_FAILED := "Moonlight didn't install. Check the internet connection and try again."
const INSTALL_NO_FLATPAK := "Flatpak isn't on this system, so Moonlight can't be installed from here."
const BAD_ADDRESS := "That doesn't look like a PC address. Try something like 192.168.1.20."
const ADDED_OFFLINE := "Added %s. It isn't answering yet."
const WOKE := "%s is awake"
const WAKE_FAILED := "Couldn't send the wake-up signal"
const WAKE_NO_ANSWER := "%s didn't wake up. Is Wake-on-LAN on in its BIOS?"
const SLEEPING := "%s is going to sleep"
const SLEEP_FAILED := "The PC didn't go to sleep"
const PAIR_NO_START := "Moonlight didn't start"
const PAIR_TIMEOUT := "Pairing timed out. Start again for a new PIN."
const PAIR_STOPPED := "Pairing stopped. The PIN may not have matched; try again."
const NO_HOST := "That PC isn't here anymore"
const NEED_MOONLIGHT := "Install Moonlight first"
const NOT_PAIRED := "Pair with this PC first"
const STREAM_NO_START := "Moonlight didn't start"
const QUIT_SENT := "Quitting %s on your PC"

# page
const SEARCHING := "Looking for PCs…"
const ADD_PC := "Add PC"
const SEARCH_AGAIN := "Search again"
const SETTINGS := "Stream settings"
const PAIR := "Pair"
const WAKE := "Wake"
const SLEEP := "Sleep PC"
const RESUME := "Resume"
const QUIT_ON_PC := "Quit on PC"
const REMOVE := "Forget this PC"
const OPEN := "Open"
const APPS_ON := "On %s"
const APPS_LOADING := "Getting the app list…"
const APPS_EMPTY := "No apps on this PC yet. Add games in Vibepollo's web UI under Applications."
const APPS_DENIED := "This PC hides its apps from this handheld. In Vibepollo's web UI, open Clients and allow \"List applications\" and \"Launch apps\" for it."
const APPS_ERROR := "Couldn't get the app list. Check the PC is on, then press X to try again."
const NO_LAUNCH_PERMISSION := "In Vibepollo's web UI, open Clients and allow \"Launch apps\" and controller input for this handheld, or streams won't start."
const RUNNING_ON_PC := "Running on %s"
const PLAYING := "Playing %s"

const STATUS := {
	"online": "Online", "busy": "In use", "asleep": "Asleep", "offline": "Offline",
	"waking": "Waking up…", "checking": "Checking…", "unknown": "Not checked",
}
const STATUS_LINE := {
	"online": "Ready to stream", "busy": "Something's already running",
	"asleep": "Press A to wake it", "offline": "Turn it on, or check it's on this network",
	"waking": "This can take half a minute", "checking": "One moment", "unknown": "",
}
const NOT_PAIRED_LINE := "Not paired yet: press A"
const REMOTE := "Remote"
const LAN := "Home network"
const LATENCY := "%d ms"

# empty state and setup guide
const EMPTY_TITLE := "Set up streaming from your PC"
const EMPTY_LINE := "Your PC runs the game, this handheld shows it. Here's how to set it up once:"
const STEPS := [
	["Install Vibepollo on your PC", "Free. Scan the code, or go to github.com/Nonary/Vibepollo."],
	["Open its web UI and add your games", "On the PC: https://localhost:47990, set a password, add games under Applications."],
	["Come back here and pick your PC", "Same Wi-Fi? It shows up here. Otherwise press Y and type its address."],
]
const QR_CAPTION := "Vibepollo download"
const SCAN := "Scan with your phone"
const MOONLIGHT_TITLE := "Moonlight is needed"
const MOONLIGHT_LINE := "Moonlight is the free player that shows the stream. One quick download from Flathub, no password."
const INSTALL := "Install Moonlight"
const INSTALLING := "Installing…"

# add PC
const ADD_TITLE := "PC address"
const ADD_HINT := "IP or name, e.g. 192.168.1.20 or a Tailscale address"

# pairing sheet
const PAIR_TITLE := "Pair with %s"
const PAIR_ENTER := "Enter this PIN on your PC"
const PAIR_STEPS := [
	"On the PC, open Vibepollo's web UI:",
	"Go to PIN, type the code below and name this handheld",
	"Press Send. This screen moves on by itself.",
]
const PAIR_WAITING := "Waiting for your PC…"
const PAIR_DONE := "Paired with %s"
const PAIR_FAILED_TITLE := "Pairing didn't finish"
const PAIR_NEW_PIN := "New PIN"
const PAIR_ONCE := "Pairing happens once per handheld. Vibepollo's web UI is at %s"
const PAIR_PERMS := "Then allow \"Launch apps\" and controller input for this handheld under Clients."

# settings sheet
const SETTINGS_TITLE := "Stream settings"
const SETTINGS_FOR_PC := "For every game on %s"
const SETTINGS_FOR_APP := "For %s only"
const APP_OWN := "Own settings for this game"
const APP_OWN_LINE := "Off: this game uses the PC's settings"
const ROWS := {
	"resolution": ["Resolution", "Native matches this screen exactly. Vibepollo makes a virtual screen on the PC to fit."],
	"fps": ["Frame rate", "Native is this screen's top refresh rate."],
	"quality": ["Quality", "Higher looks sharper and needs a faster network. Saver is best away from home."],
	"codec": ["Video format", "Auto picks the best format both this handheld and the PC can handle."],
	"hdr": ["HDR", "Needs HDR on in this handheld's display settings and a PC that can send it."],
	"frame_pacing": ["Smooth frame pacing", "Evens out stutter. Adds a frame of delay."],
	"vsync": ["V-Sync", "Stops tearing. Turn off for the lowest delay."],
	"audio_on_host": ["Sound on the PC too", "Also plays the game's sound through the PC's speakers."],
	"performance_overlay": ["Stream stats", "Shows Moonlight's numbers: delay, frame rate, dropped frames."],
	"swap_gamepad_buttons": ["Swap A/B and X/Y", "Nintendo-style layout for the streamed game."],
	"audio": ["Sound", "Stereo for the handheld's speakers and most headphones."],
}
const LABELS := {
	"resolution": {"native": "Native", "720p": "720p", "1080p": "1080p", "1440p": "1440p", "4k": "4K"},
	"quality": {"saver": "Saver", "balanced": "Balanced", "best": "Best"},
	"codec": {"auto": "Auto", "AV1": "AV1", "HEVC": "HEVC", "H.264": "H.264"},
	"audio": {"stereo": "Stereo", "5.1-surround": "5.1", "7.1-surround": "7.1"},
}
const HDR_UNAVAILABLE := "HDR needs HDR on in Display settings and a PC that sends 10-bit video"
const WILL_STREAM := "This stream: %s"

# hints
const H_OPEN := "Open"
const H_STREAM := "Stream"
const H_WAKE := "Wake"
const H_PAIR := "Pair"
const H_SETTINGS := "Settings"
const H_ADD := "Add PC"
const H_REFRESH := "Refresh"
const H_MORE := "More"
const H_BACK := "Back"
const H_CANCEL := "Cancel"
const H_CHANGE := "Change"
const H_HOME := "Home"
