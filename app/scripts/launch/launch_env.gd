extends RefCounted
## Turns a game's settings into environment variables for this GPU and this Proton.
## Pure: no files, no system. Launcher gathers the facts and calls compose().
##
## Sources (checked 2026-11-08; these move fast, re-check when bumping):
##   Proton-CachyOS README + 11.0 release notes: PROTON_FSR4_UPGRADE (1 = latest
##     known-good, or a version: 4.0.0 / 4.1.1), PROTON_FSR4_RDNA3_UPGRADE removed
##     in 11, PROTON_FSR3_UPGRADE renamed PROTON_FFX3_UPGRADE, PROTON_FSR4_INDICATOR,
##     PROTON_USE_OPTISCALER / PROTON_OPTISCALER_NAME, LOW_LATENCY_LAYER bundled.
##     In 10.x the RDNA3 path was PROTON_FSR4_RDNA3_UPGRADE.
##   GE-Proton README: PROTON_FSR4_UPGRADE (RDNA3 too; PROTON_FSR4_RDNA3_UPGRADE
##     obsolete), PROTON_FSR4_INDICATOR.
##   Valve Proton: FSR 4 only through Proton Experimental on RDNA3 dGPUs, nothing to
##     set and nothing for handheld iGPUs.
##   low_latency_layer README (Korthos-Software): LOW_LATENCY_LAYER=1 (Anti-Lag 2),
##     LOW_LATENCY_LAYER_REFLEX=1, LOW_LATENCY_LAYER_SPOOF_NVIDIA and
##     PROTON_FORCE_NVAPI=1 break Proton's FSR 4 upgrade.
##   xess-xmx-linux (via ClawDeck launchenv.py/xess.py, tested on a Claw 8 EX):
##     XESS_FG=<n>, FSR=xess, FSR_FG=xess, IGDEXT_XELL_CAP=off; Proton 11's DXVK hides
##     the Intel GPU from XeSS games, DXVK_CONFIG="dxgi.customVendorId = 8086" shows
##     it again (a game's own XeSS-FG 1.1 can crash with it, so explicit XeSS only).

const AMD := ["amd-rdna2", "amd-rdna3"]
const INTEL := ["intel-xe-lpg", "intel-xe2", "intel-xe3"]
## Below this base frame rate frame generation feels worse than no frame generation.
const FRAME_GEN_MIN_BASE_FPS := 40
const SHOW_INTEL := "dxgi.customVendorId = 8086"
const FSR4_VARS := ["PROTON_FSR4_UPGRADE", "PROTON_FSR4_RDNA3_UPGRADE"]
const NVAPI_SPOOF := ["PROTON_FORCE_NVAPI", "LOW_LATENCY_LAYER_SPOOF_NVIDIA"]


## Which FSR 4 upgrade variable this Proton reads on this GPU, or "" for none.
static func fsr4_var(gpu_family: String, proton: Dictionary) -> String:
	if gpu_family != "amd-rdna3":
		return ""
	var flavour: String = proton.get("flavour", "")
	var major: int = proton.get("major", -1)
	if flavour == "cachyos":
		if major >= 11:
			return "PROTON_FSR4_UPGRADE"
		if major == 10:
			return "PROTON_FSR4_RDNA3_UPGRADE"
	if flavour == "ge" and major >= 10:
		return "PROTON_FSR4_UPGRADE"
	return ""


## Does this Proton carry low_latency_layer itself?
static func bundles_low_latency_layer(proton: Dictionary) -> bool:
	return proton.get("flavour", "") == "cachyos" and int(proton.get("major", -1)) >= 11


static func bundles_optiscaler(proton: Dictionary) -> bool:
	return proton.get("flavour", "") == "cachyos" and int(proton.get("major", -1)) >= 11


static func proton_major(proton: Dictionary) -> int:
	return int(proton.get("major", -1))


## A per-game choice is shared by every handheld the drive boots, so one picked
## on an Intel Claw can reach an AMD Ally. Choices that can't work on this GPU
## fall back to "auto" for it (the saved choice stays): [choice, note or ""].
static func choice_for_gpu(choice: String, gpu_family: String) -> Array:
	if choice == "xess" and gpu_family in AMD:
		return ["auto", "XeSS was picked on an Intel handheld; this AMD GPU uses Auto (FSR) instead. The game's own XeSS still works from its menu."]
	if choice in ["xess", "fsr"] and gpu_family == "":
		return ["off", "Unknown GPU: upscaler off."]
	return [choice, ""]


## Turn the auto upscaler into a concrete one for this device.
static func resolve_upscaler(choice: String, gpu_family: String, xmx_ready: bool, proton: Dictionary) -> String:
	if choice != "auto":
		return choice
	if gpu_family in INTEL:
		return "xess" if xmx_ready else "off"
	if fsr4_var(gpu_family, proton) != "":
		return "fsr"
	return "off"


## settings: Launcher settings (docs/CONTRACTS.md shape).
## device:   {"gpu_family": String, "xmx": bool}
## proton:   Proton.classify()/resolve() result
## host:     {"xess_xmx": bool, "low_latency_layer": bool}
## game:     {"anticheat": bool, "base_fps": int (-1 unknown), "extra_env": Dictionary,
##            "frame_gen_on": bool (lsfg-vk / OptiScaler frame generation is on)}
## options:  {"indicator": bool}
## Returns {"env", "upscaler", "frame_gen", "low_latency", "low_latency_forced",
## "conflicts": [{id, message}], "notes": [String]}.
static func compose(settings: Dictionary, device: Dictionary, proton: Dictionary, host: Dictionary,
		game: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var env := {}
	var notes: Array[String] = []
	var family: String = device.get("gpu_family", "")
	var flavour: String = proton.get("flavour", "")
	var major := proton_major(proton)
	var native := flavour == "native"
	var xmx_ready: bool = family in INTEL and bool(device.get("xmx", false)) and bool(host.get("xess_xmx", false))
	var anticheat: bool = game.get("anticheat", false)
	var picked := choice_for_gpu(str(settings.get("upscaler", "auto")), family)
	var choice: String = picked[0]
	if picked[1] != "":
		notes.append(picked[1])
	var upscaler := resolve_upscaler(choice, family, xmx_ready, proton)
	# Frame generation only pays off with enough real frames underneath.
	var frame_gen: bool = settings.get("frame_gen", false)
	# Low latency is on by default and forced on whenever frame generation is
	# asked for (here, or lsfg-vk / OptiScaler: facts.frame_gen_on), whatever
	# an old per-game "off" says: generated frames add lag that Anti-Lag 2 /
	# XeLL win back.
	var low_latency_forced: bool = frame_gen or bool(game.get("frame_gen_on", false))
	var low_latency: bool = bool(settings.get("low_latency", true)) or low_latency_forced
	if frame_gen:
		var base: int = game.get("base_fps", -1)
		var limit: int = settings.get("fps_limit", 0)
		if base >= 0 and base < FRAME_GEN_MIN_BASE_FPS:
			frame_gen = false
			notes.append("Frame generation off: this game ran at %d fps here, it needs about %d." % [base, FRAME_GEN_MIN_BASE_FPS])
		elif limit > 0 and floori(limit / 2.0) < FRAME_GEN_MIN_BASE_FPS:
			frame_gen = false
			notes.append("Frame generation off: a %d fps limit leaves only %d real frames." % [limit, floori(limit / 2.0)])

	if native:
		notes.append("Native Linux game: Proton settings don't apply.")
	elif family in AMD:
		if upscaler == "fsr":
			var v := fsr4_var(family, proton)
			if v != "":
				env[v] = "1"
				if options.get("indicator", false):
					env["PROTON_FSR4_INDICATOR"] = "1"
			elif family == "amd-rdna2":
				notes.append("FSR 4 is too heavy for this GPU; the game's own FSR runs.")
			else:
				notes.append("This Proton has no FSR 4 upgrade for this GPU; pick Proton-CachyOS or GE-Proton.")
		elif upscaler == "xess":
			notes.append("XeSS runs from the game's own menu on this GPU.")
		if frame_gen:
			notes.append("Frame generation: turn on the game's own FSR frame generation in its menu.")
	elif family in INTEL:
		if bool(device.get("xmx", false)) and not bool(host.get("xess_xmx", false)) and (upscaler == "xess" or frame_gen):
			notes.append("Install the XeSS XMX driver (xess-xmx-linux) to run XeSS on the XMX cores.")
		if xmx_ready:
			if upscaler == "fsr":
				env["FSR"] = "xess"
			if frame_gen:
				env["XESS_FG"] = "2"
				if upscaler != "fsr":
					env["FSR_FG"] = "xess"
			if not low_latency:
				env["IGDEXT_XELL_CAP"] = "off"
		if choice == "xess" and major >= 11:
			env["DXVK_CONFIG"] = SHOW_INTEL
			notes.append("Shows the Intel GPU to XeSS again (Proton 11 hides it). If the game crashes, set the upscaler to Auto.")
		if choice == "xess" and bundles_optiscaler(proton):
			if anticheat:
				notes.append("OptiScaler left out: this game has anti-cheat.")
			else:
				env["PROTON_USE_OPTISCALER"] = "1"
	elif family == "nvidia":
		notes.append("NVIDIA: the game's own DLSS, frame generation and Reflex are left alone.")
	else:
		notes.append("Unknown GPU: only the game's own settings apply.")

	if low_latency and not native and family != "" and family != "nvidia":
		if bundles_low_latency_layer(proton) or bool(host.get("low_latency_layer", false)):
			env["LOW_LATENCY_LAYER"] = "1"

	env = merge(env, game.get("extra_env", {}))
	return {
		"env": env,
		"upscaler": upscaler,
		"frame_gen": frame_gen,
		"low_latency": low_latency,
		"low_latency_forced": low_latency_forced,
		"conflicts": conflicts(env, family, proton, anticheat, xmx_ready),
		"notes": notes,
	}


## Our variables plus the user's own; the user's win, DXVK_CONFIG entries are joined.
static func merge(ours: Dictionary, extra: Dictionary) -> Dictionary:
	var out := ours.duplicate()
	for k in extra:
		var v := str(extra[k])
		if k == "DXVK_CONFIG" and out.has(k) and str(out[k]) != v:
			out[k] = "%s; %s" % [out[k], v]
		else:
			out[k] = v
	return out


static func _on(env: Dictionary, key: String) -> bool:
	return env.has(key) and not (str(env[key]) in ["", "0"])


## Combinations that are known not to work. Each: {"id", "message"}.
static func conflicts(env: Dictionary, gpu_family: String, proton: Dictionary, anticheat := false, xmx_ready := false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var fsr4 := false
	for v in FSR4_VARS:
		fsr4 = fsr4 or _on(env, v)
	for s in NVAPI_SPOOF:
		if fsr4 and _on(env, s):
			out.append({"id": "nvapi_spoof_breaks_fsr4", "message": "%s breaks the FSR 4 upgrade; remove one of them." % s})
	if fsr4 and gpu_family in INTEL:
		out.append({"id": "fsr4_needs_amd", "message": "The Proton FSR 4 upgrade is for AMD GPUs."})
	var cachy11: bool = proton.get("flavour", "") == "cachyos" and int(proton.get("major", -1)) >= 11
	if cachy11 and env.has("PROTON_FSR4_RDNA3_UPGRADE"):
		out.append({"id": "removed_var", "message": "Proton-CachyOS 11 removed PROTON_FSR4_RDNA3_UPGRADE; use PROTON_FSR4_UPGRADE."})
	if cachy11 and env.has("PROTON_FSR3_UPGRADE"):
		out.append({"id": "renamed_var", "message": "Proton-CachyOS 11 renamed PROTON_FSR3_UPGRADE to PROTON_FFX3_UPGRADE."})
	if _on(env, "LOW_LATENCY_LAYER") and _on(env, "DISABLE_LOW_LATENCY_LAYER"):
		out.append({"id": "low_latency_disabled", "message": "DISABLE_LOW_LATENCY_LAYER wins over LOW_LATENCY_LAYER."})
	if anticheat and _on(env, "PROTON_USE_OPTISCALER"):
		out.append({"id": "optiscaler_anticheat", "message": "OptiScaler injects a DLL; anti-cheat may ban or block the game."})
	if not xmx_ready:
		for k in ["XESS_FG", "FSR_FG", "FSR", "IGDEXT_XELL_CAP"]:
			if env.has(k) and (k != "FSR" or str(env[k]) == "xess"):
				out.append({"id": "needs_xess_xmx", "message": "%s needs the XeSS XMX driver (xess-xmx-linux)." % k})
				break
	return out
