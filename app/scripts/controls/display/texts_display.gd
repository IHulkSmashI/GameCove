extends RefCounted
## Words for the display, audio and system controls: title and one plain help
## line per control id, and the reasons shown when one can't be used here.

const TEXT := {
	# display
	"display.brightness": ["Brightness", "Screen brightness."],
	"display.refresh_rate": ["Refresh rate", "How many times a second the screen redraws while a game runs. Lower saves battery. Has no effect while VRR is on."],
	"display.refresh_unlock": ["Unlock refresh rates", "Lets gamescope switch this screen's refresh rate. Takes effect after the session restarts."],
	"display.fps_limit": ["Frame limit", "Caps the game's frame rate. Steadier and cooler; pick a whole fraction of the refresh rate."],
	"display.vrr": ["Variable refresh rate (VRR)", "The screen follows the game's frame rate, so uneven frame rates look smooth."],
	"display.allow_tearing": ["Allow tearing", "Shows each frame as soon as it's ready. A little less input lag, some tearing."],
	"display.upscale_filter": ["Scaling filter", "How the screen scales up a game running below its resolution (not the game's own upscaler). FSR and NIS sharpen; Nearest and Pixel keep pixel art crisp."],
	"display.upscale_scaler": ["Scaling", "How the game's picture fits the screen."],
	"display.sharpness": ["Sharpness", "How much FSR, NIS or SGSR sharpen the picture."],
	"display.vibrance": ["Colour vibrance", "Richer colours. 0 is the most natural."],
	"display.color_temp": ["Colour temperature", "Warmer (lower) or cooler (higher) whites. 6500 K is neutral."],
	"display.night_light": ["Night light", "Warmer colours, easier on the eyes at night."],
	"display.night_light_strength": ["Night light strength", "How warm the night light is."],
	"display.night_light_schedule": ["Night light schedule", "Turn night light on and off by itself."],
	"display.hdr": ["HDR", "High dynamic range for games that support it. Also kept for the next session."],
	"display.hdr_itm": ["HDR for SDR games", "Expands normal (SDR) games to HDR brightness."],
	"display.sdr_brightness": ["SDR brightness in HDR", "How bright normal content looks while HDR is on."],
	"display.effect": ["Screen effect", "A ReShade effect over the game, like a CRT look. Shows in games only."],
	"display.rotation": ["Screen rotation", "Turn the picture. Takes effect after the session restarts."],
	"display.dim_after": ["Dim screen after", "Dims the screen when you haven't touched anything for a while."],
	"display.screen_off_after": ["Turn screen off after", "Turns the screen off when you haven't touched anything for a while."],
	# audio
	"audio.volume": ["Volume", "Speaker or headphone volume."],
	"audio.mute": ["Mute", "Silences all sound."],
	"audio.output": ["Sound output", "Where sound plays: speakers, headphones, HDMI or Bluetooth."],
	"audio.mic_mute": ["Mute microphone", "Nobody hears you while this is on."],
	"audio.input": ["Microphone", "Which microphone to use."],
	# network / system
	"network.wifi": ["Wi-Fi", "Turn Wi-Fi on or off."],
	"network.bluetooth": ["Bluetooth", "Turn Bluetooth on or off."],
	"network.airplane": ["Airplane mode", "Turns off every radio (Wi-Fi and Bluetooth). Turning it off brings back what was on."],
	"network.wifi_power_save": ["Wi-Fi power saving", "Saves battery. Turn off if online games stutter."],
	"system.sleep": ["Sleep now", "Puts the handheld to sleep."],
	"system.screenshot": ["Take a screenshot", "Saves the game's picture to Pictures/Screenshots."],
	"system.keep_awake": ["Keep awake", "Stops the screen from dimming or the handheld from sleeping on its own."],
}

const NO_GAMESCOPE := "Needs the GameCove (gamescope) session"
const NO_BACKLIGHT := "This screen has no brightness control"
const NO_PANEL_RANGE := "This screen runs at one refresh rate"
const NEEDS_UNLOCK := "Turn on Unlock refresh rates, then restart the session"
const RESTART_PENDING := "Restart the session to use the new refresh rates"
const ALREADY_KNOWN := "Already works on this screen"
const UNKNOWN_DEVICE := "Needs a known handheld"
const NO_SESSION := "Needs gamescope-session-plus"
const NO_VRR := "This screen doesn't support VRR"
const NO_HDR := "This screen doesn't support HDR"
const HDR_OFF := "Turn on HDR first"
const USE_BRIGHTNESS := "Use Brightness on this screen"
const NO_RESHADE := "This gamescope has no ReShade support"
const NO_SGSR := "SGSR needs a newer gamescope"
const NO_WPCTL := "Needs PipeWire (wpctl)"
const NO_SINK := "No sound output found"
## An app stream PipeWire gave no name.
const APP_UNNAMED := "Unnamed app"
const NO_SOURCE := "No microphone found"
const NO_NMCLI := "Needs NetworkManager"
const NO_WIFI := "No Wi-Fi adapter"
const NO_BT := "No Bluetooth adapter"
const NO_BLUEZ := "Needs BlueZ (bluetoothctl)"
const NO_RFKILL := "No radios to turn off"
const NO_STEAMOS_MANAGER := "Needs steamos-manager"
const NO_SLEEP := "Sleep isn't supported here"


static func title(id: String) -> String:
	return TEXT.get(id, [id, ""])[0]


static func help(id: String) -> String:
	return TEXT.get(id, ["", ""])[1]
