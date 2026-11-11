extends RefCounted
## Stream settings: what the user picks (per PC, optionally per app) and what
## Moonlight gets after matching it to this handheld's screen and decoder and
## to what the PC can encode. Pure logic; streaming.gd stores the picks.
##
## Picks (all optional; missing = default):
##   resolution  native | 720p | 1080p | 1440p | 4k      (native = this panel, e.g. 1920x1200)
##   fps         native | 30 | 40 | 60 | 90 | 120        (native = the panel's top refresh)
##   quality     saver | balanced | best                  (bitrate: Moonlight's own default
##               for the resolution and frame rate x 0.6 / 1.0 / 1.6; remote PCs start on saver)
##   codec       auto | AV1 | HEVC | H.264                (auto: AV1 if both ends can, else HEVC, else H.264)
##   hdr         bool  (only when the panel shows HDR now and the PC can encode 10-bit)
##   frame_pacing, vsync, audio_on_host, performance_overlay, swap_gamepad_buttons: bool
##   audio       stereo | 5.1-surround | 7.1-surround

const RESOLUTIONS := {"720p": [1280, 720], "1080p": [1920, 1080], "1440p": [2560, 1440], "4k": [3840, 2160]}
const FPS_CHOICES := ["native", 30, 40, 60, 90, 120]
const QUALITY := {"saver": 0.6, "balanced": 1.0, "best": 1.6}
const CODECS := ["auto", "AV1", "HEVC", "H.264"]
const AUDIO := ["stereo", "5.1-surround", "7.1-surround"]
## Moonlight's range (cli warns outside it).
const MIN_KBPS := 2000
const MAX_KBPS := 150000

const DEFAULTS := {
	"resolution": "native", "fps": "native", "quality": "balanced", "codec": "auto", "hdr": false,
	"frame_pacing": true, "vsync": true, "audio_on_host": false, "performance_overlay": false,
	"swap_gamepad_buttons": false, "audio": "stereo",
}

## Decode support by GPU family when vainfo isn't there to ask (VA-API on these
## APUs: Van Gogh / Vega have no AV1 decode; RDNA3+, Intel Xe-LP (Alder Lake) and newer do).
const DECODE_BY_FAMILY := {
	"amd-vega": {"h264": true, "hevc": true, "hevc10": true, "av1": false},
	"amd-rdna2": {"h264": true, "hevc": true, "hevc10": true, "av1": false},
	"amd-rdna3": {"h264": true, "hevc": true, "hevc10": true, "av1": true},
	"intel-xe-lp": {"h264": true, "hevc": true, "hevc10": true, "av1": true},
	"intel-xe-lpg": {"h264": true, "hevc": true, "hevc10": true, "av1": true},
	"intel-xe2": {"h264": true, "hevc": true, "hevc10": true, "av1": true},
	"intel-xe3": {"h264": true, "hevc": true, "hevc10": true, "av1": true},
}


## The picks with defaults filled in, a per-app layer over the host's.
static func merged(host_picks: Dictionary, app_picks := {}, remote := false) -> Dictionary:
	var out := DEFAULTS.duplicate()
	if remote:
		out["quality"] = "saver"
	for layer in [host_picks, app_picks]:
		for k in layer:
			if out.has(k):
				out[k] = layer[k]
	return out


## Moonlight's default bitrate (moonlight-qt StreamingPreferences::getDefaultBitrate):
## the Shield's per-resolution factors, frame rate scaled linearly to 60 and by
## the square root above it.
static func moonlight_default_kbps(width: int, height: int, fps: int) -> int:
	var frame := (float(fps) if fps <= 60 else sqrt(fps / 60.0) * 60.0) / 30.0
	var table := [[640 * 360, 1], [854 * 480, 2], [1280 * 720, 5], [1920 * 1080, 10], [2560 * 1440, 20], [3840 * 2160, 40]]
	var px := width * height
	var factor: float = table[table.size() - 1][1]
	for i in table.size():
		if px == table[i][0]:
			factor = table[i][1]
			break
		if px < table[i][0]:
			if i == 0:
				factor = table[0][1]
			else:
				var lo: Array = table[i - 1]
				var hi: Array = table[i]
				factor = float(px - lo[0]) / float(hi[0] - lo[0]) * (hi[1] - lo[1]) + lo[1]
			break
	return int(roundf(factor * frame)) * 1000


## `vainfo` output → {"h264", "hevc", "hevc10", "av1": bool} (VLD = decode entry point).
static func parse_vainfo(text: String) -> Dictionary:
	var out := {"h264": false, "hevc": false, "hevc10": false, "av1": false}
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if not line.contains("VAEntrypointVLD"):
			continue
		if line.begins_with("VAProfileH264"):
			out["h264"] = true
		elif line.begins_with("VAProfileHEVCMain10"):
			out["hevc10"] = true
			out["hevc"] = true
		elif line.begins_with("VAProfileHEVCMain"):
			out["hevc"] = true
		elif line.begins_with("VAProfileAV1"):
			out["av1"] = true
	return out


static func decode_for_family(family: String) -> Dictionary:
	return DECODE_BY_FAMILY.get(family, {"h264": true, "hevc": true, "hevc10": false, "av1": false}).duplicate()


## The codec Moonlight gets: the pick when both ends can, else the best both can.
static func pick_codec(choice: String, decode: Dictionary, host: Dictionary) -> String:
	var can := {
		"AV1": bool(decode.get("av1", false)) and bool(host.get("av1", false)),
		"HEVC": bool(decode.get("hevc", true)) and bool(host.get("hevc", true)),
		"H.264": true,
	}
	if choice != "auto" and can.get(choice, false):
		return choice
	for c in ["AV1", "HEVC", "H.264"]:
		if can[c]:
			return c
	return "H.264"


## Can this stream be HDR: the panel shows HDR now, the decoder does 10-bit for
## the codec and the PC encodes 10-bit (HEVC Main10 / AV1 Main10).
static func hdr_possible(display: Dictionary, decode: Dictionary, host: Dictionary) -> bool:
	return bool(display.get("hdr", false)) and bool(host.get("hdr", false)) \
		and (bool(decode.get("hevc10", false)) or bool(decode.get("av1", false)))


## Everything Moonlight needs for one stream, plus "notes" (why a pick changed).
## display: {"width", "height", "hz", "hdr"}; decode: parse_vainfo / decode_for_family;
## host: a host's serverinfo fields (hevc, av1, hdr).
static func resolve(picks: Dictionary, display: Dictionary, decode: Dictionary, host: Dictionary) -> Dictionary:
	var p := merged(picks)
	var notes: Array = []
	var w := int(display.get("width", 1280))
	var h := int(display.get("height", 800))
	if RESOLUTIONS.has(str(p["resolution"])):
		w = RESOLUTIONS[p["resolution"]][0]
		h = RESOLUTIONS[p["resolution"]][1]
	var panel_hz := int(display.get("hz", 60))
	var fps := panel_hz if str(p["fps"]) == "native" else int(p["fps"])
	if fps > panel_hz and panel_hz > 0:
		notes.append("fps_capped")
		fps = panel_hz
	fps = clampi(fps, 30, 240)
	var kbps := int(moonlight_default_kbps(w, h, fps) * float(QUALITY.get(str(p["quality"]), 1.0)))
	kbps = clampi(kbps, MIN_KBPS, MAX_KBPS)
	var codec := pick_codec(str(p["codec"]), decode, host)
	if str(p["codec"]) != "auto" and codec != str(p["codec"]):
		notes.append("codec_fallback")
	var hdr := bool(p["hdr"]) and hdr_possible(display, decode, host)
	if bool(p["hdr"]) and not hdr:
		notes.append("hdr_off")
	if hdr and codec == "H.264":
		codec = "HEVC" if bool(decode.get("hevc10", false)) and bool(host.get("hevc", false)) else "AV1"
	return {
		"width": w, "height": h, "fps": fps, "bitrate_kbps": kbps, "codec": codec, "decoder": "auto",
		"hdr": hdr, "audio": str(p["audio"]),
		"vsync": bool(p["vsync"]), "frame_pacing": bool(p["frame_pacing"]),
		"game_optimization": true, "audio_on_host": bool(p["audio_on_host"]),
		"performance_overlay": bool(p["performance_overlay"]),
		"swap_gamepad_buttons": bool(p["swap_gamepad_buttons"]),
		# One virtual pad from InputPlumber: a second (the hidden built-in) would double input.
		"multi_controller": false, "keep_awake": true, "quit_after": false, "background_gamepad": false,
		"notes": notes,
	}


## "1920x1200 · 120 fps · HEVC · 38 Mb/s" for the settings sheet and the card.
static func summary(r: Dictionary) -> String:
	var parts := ["%dx%d" % [r["width"], r["height"]], "%d fps" % r["fps"], str(r["codec"])]
	if r.get("hdr", false):
		parts.append("HDR")
	parts.append("%d Mb/s" % int(roundf(r["bitrate_kbps"] / 1000.0)))
	return " · ".join(parts)
