extends RefCounted
## gamescope's built-in ReShade: it loads an effect named by the root atom
## GAMESCOPE_RESHADE_EFFECT (a path under a Shaders folder) and runs technique
## GAMESCOPE_RESHADE_TECHNIQUE_IDX on the game's picture. It looks in
## ~/.local/share/gamescope/reshade/Shaders then /usr/share/gamescope/reshade/
## Shaders (src/reshade_effect_manager.cpp). Effects only show over games.

const Shaders := preload("res://scripts/controls/display/reshade_shaders.gd")

const ATOM_EFFECT := "GAMESCOPE_RESHADE_EFFECT"
const ATOM_TECHNIQUE := "GAMESCOPE_RESHADE_TECHNIQUE_IDX"
const USER_DIR := ".local/share/gamescope/reshade/Shaders"
const SYSTEM_DIR := "/usr/share/gamescope/reshade/Shaders"
const BUNDLE := "gamecove"
## Ours first, with plain names.
const BUNDLED := [
	{"value": "gamecove/crt-lottes.fx", "label": "CRT (Lottes)"},
	{"value": "gamecove/scanlines.fx", "label": "Scanlines"},
]


static func user_dir(ctx: Dictionary) -> String:
	return str(ctx.get("home", "")).path_join(USER_DIR)


## Choice options: Off, the bundled effects, then every other .fx in the two
## shader folders (one level of sub-folders).
static func options(ctx: Dictionary) -> Array:
	var out := [{"value": "", "label": "Off"}]
	out.append_array(BUNDLED)
	var seen := {}
	for o in BUNDLED:
		seen[o["value"]] = true
	for base in [user_dir(ctx), str(ctx.get("sys_root", "")) + SYSTEM_DIR]:
		for rel in _fx_files(base):
			if not seen.has(rel):
				seen[rel] = true
				out.append({"value": rel, "label": rel.get_file().get_basename().capitalize()})
	return out


static func _fx_files(base: String) -> Array:
	var out := []
	var d := DirAccess.open(base)
	if d == null:
		return out
	for f in d.get_files():
		if f.get_extension().to_lower() == "fx":
			out.append(f)
	for sub in d.get_directories():
		if sub == BUNDLE:
			continue
		for f in DirAccess.get_files_at(base.path_join(sub)):
			if f.get_extension().to_lower() == "fx":
				out.append(sub + "/" + f)
	out.sort()
	return out


## Writes the bundled files (only those missing or different). True when all
## are in place.
static func install_bundled(ctx: Dictionary) -> bool:
	var dir := user_dir(ctx).path_join(BUNDLE)
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		return false
	for name in Shaders.FILES:
		var p := dir.path_join(name)
		var want: String = Shaders.FILES[name]
		if FileAccess.file_exists(p) and FileAccess.get_file_as_string(p) == want:
			continue
		var f := FileAccess.open(p, FileAccess.WRITE)
		if f == null:
			return false
		f.store_string(want)
		f.close()
	return true


static func is_bundled(rel: String) -> bool:
	return rel.begins_with(BUNDLE + "/")
