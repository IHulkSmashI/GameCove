extends RefCounted
## Bridge to packaging/libexec/gamecove-upscale (Python, ported from ClawDeck:
## OptiScaler, XeSS on XMX, FSR, REFramework per game; see
## packaging/helpers/gamecove_upscale/games.py). Every call is one process
## through ctx.runner and answers one JSON object; nothing here touches a game
## folder itself.

const GpuCaps := preload("res://scripts/device/gpu_caps.gd")
const PATHS := ["/usr/libexec/gamecove/gamecove-upscale"]
const LABELS := {
	"own": "Game's own", "xess": "XeSS 2", "fsr4_xmx": "FSR 4.1.2 on XMX",
	"fsr4_xmx_lite": "FSR 4.1.2 Lite on XMX", "fsr31": "FSR 3.1", "fsr4_amd": "FSR 4.1.2",
}
const MODES := ["best", "custom", "native"]
const MODE_LABELS := {"best": "Best for this handheld", "custom": "My choice", "native": "Native (nothing added)"}
const GENERATOR_LABELS := {"fsrfg": "FSR frame generation", "xefg": "XeSS frame generation"}
const FG_LABELS := {0: "Off", 2: "2x", 3: "3x", 4: "4x"}
## One plain line per choice, shown under the row for the option in view.
## "best" has none here: its line is what the helper's plan picked for the game.
const MODE_HELP := {
	"custom": "You picked the upscaler and frame generation below. We keep them exactly as you set them.",
	"native": "The game as it shipped: everything we added is taken out, and nothing comes back by itself.",
}
const UPSCALER_HELP := {
	"own": "The game's own upscaler, untouched. Nothing of ours goes into the game.",
	"xess": "Intel's XeSS 2: sharp and light. On Arc with the XMX driver it runs on the XMX cores.",
	"fsr4_xmx": "AMD's newest FSR on Arc's XMX cores: the sharpest picture here. DirectX 12 games.",
	"fsr4_xmx_lite": "The lighter FSR 4 model on the XMX cores: a few more frames, a slightly softer picture.",
	"fsr31": "FSR 3.1: runs on every chip and costs the fewest frames.",
	"fsr4_amd": "AMD's newest FSR: the sharpest picture, for a few frames. DirectX 12 games. FSR 3.1 is one tap away.",
}
## FSR 4 on chips where it is offered but never picked by itself (RDNA 2, Z2 A).
## Steam Deck tests (steamdeckhq.com, club386.com, September 2025): about 10 fps, a fifth to a quarter, for a clearly better picture.
const FSR4_HEAVY_HELP := "AMD's newest FSR: a clearly better picture for about a quarter fewer frames on this chip. FSR 3.1 is the faster pick."
const FG_HELP := {
	0: "No frames are added.",
	2: "One made frame between every two real ones, with low latency on. Best from about 40 real fps.",
	3: "Two made frames for every real one. Best from about 40 real fps on a 120 Hz screen.",
	4: "Three made frames for every real one: the smoothest motion and the most artefacts.",
}
const GENERATOR_HELP := {
	"fsrfg": "AMD's: the lightest, paired with Anti-Lag 2.",
	"xefg": "Intel's: cleaner menus and HUDs, costs more, and brings XeLL low latency.",
}
const LSFG_HELP := {
	2: "One made frame per real frame.",
	3: "Two made frames per real frame: more lag and more artefacts.",
	4: "Three made frames per real frame: the most lag and artefacts.",
}


## The upscaler lines for this GPU (FSR 4 says so where it is heavy).
static func upscaler_help(g: Dictionary) -> Dictionary:
	var out := UPSCALER_HELP.duplicate()
	if GpuCaps.tier(g) in ["amd_rdna2", "amd_z2a"]:
		out["fsr4_amd"] = FSR4_HEAVY_HELP
	return out


## Where the helper is, "" when missing. extra: dev/test paths tried first.
static func command(sys_root: String, extra: Array = []) -> String:
	for p in extra + PATHS:
		if p != "" and FileAccess.file_exists(sys_root + str(p)):
			return str(p)
	return ""


## The GPU facts the helper needs, from the device profile (devices.json row)
## and, when known, the card the system reports (Device.gpu_info(): an NVIDIA
## desktop has no row that says so). device/gpu_caps.gd owns the table.
static func gpu(profile: Dictionary, gpu_dev: Dictionary = {}) -> Dictionary:
	return GpuCaps.gpu(profile, gpu_dev)


## Same choices the helper's chips.py gives (kept in step by gpu_tiers.json).
static func upscalers(g: Dictionary) -> Array:
	return GpuCaps.upscalers(g)


static func frame_gens(g: Dictionary) -> Array:
	return GpuCaps.frame_gens(g)


static func generators(g: Dictionary) -> Array:
	return GpuCaps.generators(g)


## --gpu for the helper: the GPU facts as one JSON object (keys sorted). The
## runners pass it byte for byte (system/exec_safe.gd); the helper also still
## reads the older vendor=..,xmx=.. pairs.
static func gpu_arg(g: Dictionary) -> String:
	return JSON.stringify({"vendor": str(g.get("vendor", "")), "family": str(g.get("family", "")),
		"arch": str(g.get("arch", "")), "xmx": bool(g.get("xmx", false)), "chip": str(g.get("chip", "")),
		"gpu": str(g.get("gpu", "")), "tier": GpuCaps.tier(g)}, "", true)


## Runs one command; {} with "ok": false and "error" when it can't.
static func run(runner: RefCounted, cmd: String, verb: String, home: String, game_key: String,
		g: Dictionary, game_dir := "", extra: Array = []) -> Dictionary:
	if runner == null or cmd == "":
		return {"ok": false, "error": "The upscaling helper isn't installed"}
	var args := PackedStringArray([verb, "--home", home, "--gpu", gpu_arg(g)])
	if game_key != "":
		args.append_array(["--key", helper_key(game_key)])
	if game_dir != "":
		args.append_array(["--dir", game_dir])
	for a in extra:
		args.append(str(a))
	var r: Dictionary = runner.run(cmd, args)
	var out := str(r.get("out", ""))
	var lines := out.strip_edges().split("\n")
	var parsed: Variant = JSON.parse_string(lines[lines.size() - 1]) if out.strip_edges() != "" else null
	if parsed is Dictionary:
		return parsed
	return {"ok": false, "error": "The upscaling helper failed (exit %s)" % str(r.get("code", r.get("exit", -1)))}


## The helper keys Steam games by app id (its launch file is <appid>.env, the
## same name the wrapper reads) and other games by their GameCove key.
static func helper_key(game_key: String) -> String:
	return game_key.trim_prefix("steam:") if game_key.begins_with("steam:") else game_key
