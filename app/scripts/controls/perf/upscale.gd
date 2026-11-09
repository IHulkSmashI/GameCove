extends RefCounted
## Bridge to packaging/libexec/gamecove-upscale (Python, ported from ClawDeck:
## OptiScaler, XeSS on XMX, FSR, REFramework per game; see
## packaging/helpers/gamecove_upscale/games.py). Every call is one process
## through ctx.runner and answers one JSON object; nothing here touches a game
## folder itself.

const PATHS := ["/usr/libexec/gamecove/gamecove-upscale"]
const LABELS := {
	"own": "Game's own", "xess": "XeSS (OptiScaler)", "fsr4_xmx": "FSR 4.1.2 on XMX",
	"fsr4_xmx_lite": "FSR 4.1.2 Lite on XMX", "fsr31": "FSR 3.1 (OptiScaler)", "fsr4_amd": "FSR 4 (OptiScaler)",
}
const INTEL_XMX := ["intel-xe2", "intel-xe3"]


## Where the helper is, "" when missing. extra: dev/test paths tried first.
static func command(sys_root: String, extra: Array = []) -> String:
	for p in extra + PATHS:
		if p != "" and FileAccess.file_exists(sys_root + str(p)):
			return str(p)
	return ""


## The GPU facts the helper needs, from the device profile (devices.json row).
static func gpu(profile: Dictionary) -> Dictionary:
	var fam := str(profile.get("gpu_family", ""))
	var vendor := "intel" if fam.begins_with("intel") else ("amd" if fam.begins_with("amd") else "other")
	return {"vendor": vendor, "family": fam, "arch": str(profile.get("gpu_arch", "")),
		"xmx": bool(profile.get("xmx", fam in INTEL_XMX)), "chip": str(profile.get("chip", ""))}


## Same choices games.upscalers_for() gives (kept in step by test_perf_upscale).
static func upscalers(g: Dictionary) -> Array:
	match str(g.get("vendor", "")):
		"intel":
			return ["own", "xess", "fsr4_xmx", "fsr4_xmx_lite"] if g.get("xmx", false) else ["own", "xess"]
		"amd":
			return ["own", "fsr31", "fsr4_amd"] if str(g.get("arch", "")) in ["RDNA3", "RDNA3.5"] else ["own", "fsr31"]
	return ["own"]


static func frame_gens(g: Dictionary) -> Array:
	match str(g.get("vendor", "")):
		"intel":
			return [0, 2, 3, 4] if g.get("xmx", false) else [0]
		"amd":
			return [0, 2]
	return [0]


## --gpu for the helper: the GPU facts as one JSON object (keys sorted). The
## runners pass it byte for byte (system/exec_safe.gd); the helper also still
## reads the older vendor=..,xmx=.. pairs.
static func gpu_arg(g: Dictionary) -> String:
	return JSON.stringify({"vendor": str(g.get("vendor", "")), "family": str(g.get("family", "")),
		"arch": str(g.get("arch", "")), "xmx": bool(g.get("xmx", false)), "chip": str(g.get("chip", ""))}, "", true)


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
