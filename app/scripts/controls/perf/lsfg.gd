extends RefCounted
## lsfg-vk (Lossless Scaling frame generation on Linux): find it, and keep
## GameCove's per-game profiles in its config. GameCove never ships Lossless
## Scaling or its DLL: the user's own Steam copy is used.
##
## Facts (lsfg-vk.dev docs, checked 2026-11-08, and decky-lsfg-vk 0.14.4,
## xXJSONDeruloXx/decky-lsfg-vk e744826, py_modules/lsfg_vk/constants.py,
## config_schema.py, steam_service.py, wrapper_service.py):
##   layer      VkLayer_LSFGVK_frame_generation.json (v2) in a Vulkan
##              implicit_layer.d; VkLayer_LS_frame_generation.json is 1.x,
##              whose config format v2 no longer reads
##   config     ~/.config/lsfg-vk/conf.toml (LSFGVK_CONFIG overrides):
##              version = 2, [global] dll / allow_fp16, then [[profile]] with
##              name, active_in, pacing_mode ("vsync" only), multiplier (>= 1),
##              flow_scale (0.25-1.0), performance_mode, override_present_mode,
##              preserve_swapchain_image_count
##   matching   active_in takes Steam app ids, exe names or path tails;
##              LSFGVK_PROFILE=<name> picks a profile by name (our non-Steam games)
##   dll        lsfg-vk.dll in "steamapps/common/Lossless Scaling" of any Steam
##              library, with Lossless Scaling's "lsfg-vk" beta branch (app 993090)
##   gamescope  decky-lsfg-vk turns gamescope's WSI layer off for these games
##              by default (ENABLE_GAMESCOPE_WSI=0) and Proton's HDR
##              (DXVK_HDR=0): the same two variables go into the game's launch
##              environment here.
## Profiles GameCove writes are named "GameCove <game key>"; every other line
## of the file (the user's or decky-lsfg-vk's profiles) is kept as it was.

const LAYER_DIRS := ["/usr/share/vulkan/implicit_layer.d", "/etc/vulkan/implicit_layer.d",
	"/usr/local/share/vulkan/implicit_layer.d"]
const USER_LAYER_DIR := ".local/share/vulkan/implicit_layer.d"
const LAYER_V2 := "VkLayer_LSFGVK_frame_generation.json"
const LAYER_V1 := "VkLayer_LS_frame_generation.json"
const CONFIG := ".config/lsfg-vk/conf.toml"
const DLL_NAMES := ["lsfg-vk.dll", "Lossless.dll"]
const NAME_PREFIX := "GameCove "
const MULTIPLIERS := [2, 3, 4]
const DEFAULTS := {"lsfg": false, "lsfg_multiplier": 2, "lsfg_flow_scale": 0.8, "lsfg_performance": false}
const APP_ID := "993090"                      # Lossless Scaling on Steam
const STORE_URI := "steam://store/993090"
const INSTALL_URI := "steam://install/993090"
## Chips where the lighter model and a lower flow scale are the sensible start
## (device/gpu_caps.gd tiers): RDNA 2 handhelds and Arc without XMX.
const LIGHT_TIERS := ["amd_rdna2", "amd_z2a", "amd_old", "intel"]


## Starting values for a chip tier: 2x everywhere; the lighter model and 60 %
## flow scale on the slower chips.
static func defaults_for(tier: String) -> Dictionary:
	var d := DEFAULTS.duplicate()
	if tier in LIGHT_TIERS:
		d["lsfg_performance"] = true
		d["lsfg_flow_scale"] = 0.6
	return d


## Where Lossless Scaling stands: "ready" (its lsfg-vk DLL is there),
## "wrong_branch" (installed, but not on the "lsfg-vk" beta that has the DLL),
## "not_installed" (owned: the library has it), or "not_owned".
## owned: the library lists Steam app 993090.
## Strict on purpose: "ready" needs Steam's own install record for the app
## (appmanifest_993090.acf) next to the DLL, so a DLL copied in from somewhere
## else never counts. This only works for people who own Lossless Scaling.
static func app_state(libraries: Array, owned: bool) -> String:
	var installed := false
	for lib in libraries:
		if FileAccess.file_exists(str(lib).path_join("steamapps/appmanifest_%s.acf" % APP_ID)):
			installed = true
			if find_dll([lib]) != "":
				return "ready"
	if installed:
		return "wrong_branch"
	return "not_installed" if owned else "not_owned"


## The one thing to do next for Lossless frame generation, in order:
## {"step": "" (nothing: ready) | "buy" | "install_app" | "branch" | "layer" | "layer_update", "line": plain words}.
static func next_step(layer_state: String, app: String) -> Dictionary:
	match app:
		"not_owned":
			return {"step": "buy", "line": "Lossless Scaling is a paid app on Steam. This uses your own copy."}
		"not_installed":
			return {"step": "install_app", "line": "You own Lossless Scaling: install it in Steam first."}
		"wrong_branch":
			return {"step": "branch", "line": "In Steam, open Lossless Scaling > Properties > Betas and pick lsfg-vk."}
	if layer_state == "":
		return {"step": "layer", "line": "One more piece: lsfg-vk, the part that runs it on Linux. Press to install it."}
	if layer_state == "v1":
		return {"step": "layer_update", "line": "lsfg-vk here is version 1: press to install version 2."}
	return {"step": "", "line": ""}
## what decky-lsfg-vk sets for a game it turns frame generation on for (wrapper_service.py default_state)
const GAME_ENV := {"ENABLE_GAMESCOPE_WSI": "0", "DXVK_HDR": "0"}


## "v2", "v1" (1.x only: needs an update) or "" (not installed).
static func layer(sys_root: String, home: String) -> String:
	var dirs: Array = []
	for d in LAYER_DIRS:
		dirs.append(sys_root + d)
	if home != "":
		dirs.append(home.path_join(USER_LAYER_DIR))
	var found := ""
	for d in dirs:
		if FileAccess.file_exists(d.path_join(LAYER_V2)):
			return "v2"
		if FileAccess.file_exists(d.path_join(LAYER_V1)):
			found = "v1"
	return found


## The user's Lossless Scaling DLL in any Steam library, or "".
static func find_dll(steam_libraries: Array) -> String:
	for lib in steam_libraries:
		var d: String = str(lib).path_join("steamapps/common/Lossless Scaling")
		for n in DLL_NAMES:
			if FileAccess.file_exists(d.path_join(n)):
				return d.path_join(n)
	return ""


## Steam library roots: the Steam root plus the paths in libraryfolders.vdf.
static func steam_libraries(steam_root: String) -> Array:
	var out: Array = []
	if steam_root == "":
		return out
	out.append(steam_root)
	var vdf := steam_root.path_join("steamapps/libraryfolders.vdf")
	if FileAccess.file_exists(vdf):
		var re := RegEx.create_from_string("\"path\"\\s+\"([^\"]+)\"")
		for m in re.search_all(FileAccess.get_file_as_string(vdf)):
			var p := m.get_string(1).replace("\\\\", "/")
			if not p in out:
				out.append(p)
	return out


static func profile_name(game_key: String) -> String:
	return NAME_PREFIX + game_key


## TOML for one of our profiles. settings: DEFAULTS keys. active_in: Steam app
## id for Steam games (lsfg-vk matches it itself), none for the others (they
## get LSFGVK_PROFILE in their launch environment).
static func profile_block(game_key: String, settings: Dictionary) -> String:
	var lines := ["[[profile]]", "name = %s" % JSON.stringify(profile_name(game_key))]
	if game_key.begins_with("steam:"):
		lines.append("active_in = [ %s ]" % JSON.stringify(game_key.trim_prefix("steam:")))
	var m := int(settings.get("lsfg_multiplier", 2))
	lines.append("pacing_mode = \"vsync\"")
	lines.append("multiplier = %d" % (m if m in MULTIPLIERS else 2))
	lines.append("flow_scale = %s" % str(snappedf(clampf(float(settings.get("lsfg_flow_scale", 0.8)), 0.25, 1.0), 0.01)))
	lines.append("performance_mode = %s" % ("true" if bool(settings.get("lsfg_performance", false)) else "false"))
	lines.append("override_present_mode = true")
	lines.append("preserve_swapchain_image_count = false")
	return "\n".join(PackedStringArray(lines))


## The config with GameCove's profiles replaced by `profiles` ({game key:
## settings}, only games with frame generation on). Everything else is kept;
## a missing file gets the header (with the DLL when found).
static func merge_config(existing: String, profiles: Dictionary, dll := "") -> String:
	var head: Array = []
	var blocks: Array = []        # each: Array of lines
	var cur: Array = head
	for line in existing.split("\n"):
		var s := line.strip_edges()
		if s.begins_with("[") and s.ends_with("]"):
			cur = [line]
			blocks.append(cur)
		else:
			cur.append(line)
	var kept: Array = []
	for b in blocks:
		if _is_ours(b):
			continue
		kept.append(b)
	var text := ""
	if existing.strip_edges() == "":
		text = "version = 2\n\n[global]\n"
		if dll != "":
			text += "dll = %s\n" % JSON.stringify(dll)
		text += "allow_fp16 = true\n"
	else:
		text = "\n".join(PackedStringArray(head)).strip_edges(false, true) + "\n"
		for b in kept:
			text += "\n" + "\n".join(PackedStringArray(b)).strip_edges(false, true) + "\n"
		if dll != "" and not _has_dll(kept):
			text = _add_dll(text, dll)
	var keys := profiles.keys()
	keys.sort()
	for k in keys:
		text += "\n" + profile_block(str(k), profiles[k]) + "\n"
	return text.strip_edges(true, false)


static func _is_ours(block: Array) -> bool:
	if block.is_empty() or str(block[0]).strip_edges() != "[[profile]]":
		return false
	var re := RegEx.create_from_string("^\\s*name\\s*=\\s*\"" + NAME_PREFIX)
	for l in block:
		if re.search(str(l)) != null:
			return true
	return false


static func _has_dll(blocks: Array) -> bool:
	for b in blocks:
		if str(b[0]).strip_edges() == "[global]":
			for l in b:
				if str(l).strip_edges().begins_with("dll"):
					return true
	return false


static func _add_dll(text: String, dll: String) -> String:
	var i := text.find("[global]")
	if i < 0:
		return text.replace("version = 2\n", "version = 2\n\n[global]\ndll = %s\n" % JSON.stringify(dll)) \
			if "version = 2" in text else text
	var eol := text.find("\n", i)
	return text.substr(0, eol + 1) + "dll = %s\n" % JSON.stringify(dll) + text.substr(eol + 1)


## Environment for a game with frame generation on.
static func game_env(game_key: String) -> Dictionary:
	var env := GAME_ENV.duplicate()
	if not game_key.begins_with("steam:"):
		env["LSFGVK_PROFILE"] = profile_name(game_key)
	return env
