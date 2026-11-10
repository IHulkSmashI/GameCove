extends RefCounted
## Files the perf controls write for a game's launch, and Steam's settings they
## touch. Pure functions plus small file writes under the user's home.
##
##   ~/.local/share/gamecove/launch/<appid>.perf.env   KEY=VALUE lines that
##       packaging/libexec/gamecove-run exports before a Steam game starts
##       (steam:// takes no environment; the wrapper goes into the game's
##       launch options, before any other wrapper such as Decky Framegen's
##       fgmod, as ClawDeck does with clawdeck-launch.sh).
##   steam_dev.cfg "unShaderBackgroundProcessingThreads N": how many threads
##       Steam's shader pre-caching (fossilize) uses. Bazzite sets it the same
##       way at Steam's start (bazzite system_files/desktop/shared/usr/bin/
##       bazzite-steam: cores - 2, clamped 1-16, only when the line is missing).
##   steamapps/shadercache/<appid>: Steam's compiled shaders for one game,
##       rebuilt on the next launch (decky-storage-cleaner, mcarlucci,
##       main.py delete_cache, removes the same folder).

const SteamConfig := preload("res://scripts/steam/steam_config.gd")
const SettingsFile := preload("res://scripts/system/settings_file.gd")

const DATA := ".local/share/gamecove"
const WRAPPER_PATHS := ["/usr/libexec/gamecove/gamecove-run"]
const SHADER_KEY := "unShaderBackgroundProcessingThreads"
const KEY_RE := "^[A-Za-z_][A-Za-z0-9_]*$"


static func launch_dir(home: String) -> String:
	return home.path_join(DATA).path_join("launch")


## Steam app id of a game key ("steam:976730" -> "976730"), "" for other stores.
static func steam_appid(game_key: String) -> String:
	if not game_key.begins_with("steam:"):
		return ""
	var id := game_key.trim_prefix("steam:")
	return id if id.is_valid_int() and int(id) > 0 else ""


static func perf_env_path(home: String, appid: String) -> String:
	return launch_dir(home).path_join(appid + ".perf.env")


## Writes the file the wrapper reads ({} removes it). Atomic (temp + rename).
static func write_env(home: String, appid: String, env: Dictionary) -> bool:
	if home == "" or appid == "":
		return false
	var path := perf_env_path(home, appid)
	if env.is_empty():
		if FileAccess.file_exists(path):
			return DirAccess.remove_absolute(path) == OK
		return true
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(render_env(env))
	f.close()
	return DirAccess.rename_absolute(tmp, path) == OK


## "# ..." header then sorted KEY=VALUE lines; bad names and values with a
## newline are left out.
static func render_env(env: Dictionary) -> String:
	var re := RegEx.create_from_string(KEY_RE)
	var keys := env.keys()
	keys.sort()
	var lines := ["# Written by GameCove (perf controls) for gamecove-run. KEY=VALUE, one per line."]
	for k in keys:
		var v := str(env[k])
		if re.search(str(k)) != null and not "\n" in v:
			lines.append("%s=%s" % [k, v])
	return "\n".join(PackedStringArray(lines)) + "\n"


static func read_env(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.begins_with("#") or not "=" in line:
			continue
		var i := line.find("=")
		out[line.substr(0, i)] = line.substr(i + 1)
	return out


## The wrapper's path on this system, "" when it isn't installed.
static func wrapper_path(sys_root: String, extra: Array = []) -> String:
	for p in extra + WRAPPER_PATHS:
		if p != "" and FileAccess.file_exists(sys_root + str(p)):
			return str(p)
	return ""


## What goes in front of %command% (review S2-1): a fall-through shim, so a game still starts
## when GameCove is removed or the system boots a deployment without it (Steam runs launch
## options through a shell, as the common `bash -c '...' -- %command%` recipes rely on):
##   /bin/sh -c '[ -x <w> ] && exec <w> "$@"; exec "$@"' gamecove-run %command%
static func launch_prefix(wrapper: String) -> String:
	return "/bin/sh -c '[ -x %s ] && exec %s \"$@\"; exec \"$@\"' gamecove-run" % [wrapper, wrapper]


## Older GameCove builds put the bare wrapper path in front of %command%: a missing file then
## stops the game. True when `options` has that form.
static func has_legacy_wrapper(options: String, wrapper: String) -> bool:
	if wrapper == "":
		return false
	var rest := options.replace(launch_prefix(wrapper), " ")
	return (" " + rest + " ").contains(" " + wrapper + " ")


static func has_wrapper(options: String, wrapper: String) -> bool:
	return wrapper != "" and (options.contains(launch_prefix(wrapper)) or has_legacy_wrapper(options, wrapper))


## Any GameCove wrapper at all (the shim or a bare gamecove-run path, from any install path).
static func mentions_gamecove(options: String) -> bool:
	return options.contains("gamecove-run")


## Steam launch options with the wrapper in front of the game's command (after
## any VAR=value assignments, before other wrappers): "" -> "<shim> %command%",
## "PROTON_LOG=1 %command%" -> "PROTON_LOG=1 <shim> %command%",
## "~/fgmod/fgmod %command%" -> "<shim> ~/fgmod/fgmod %command%",
## "-dx11" (game arguments only) -> "<shim> %command% -dx11". A legacy bare path is replaced.
static func with_wrapper(options: String, wrapper: String) -> String:
	if wrapper == "":
		return options.strip_edges()
	var o := without_wrapper(options, wrapper) if has_legacy_wrapper(options, wrapper) else options.strip_edges()
	if o.contains(launch_prefix(wrapper)):
		return o
	var shim := launch_prefix(wrapper)
	if not "%command%" in o:
		return ("%s %%command%% %s" % [shim, o]).strip_edges()
	var words := o.split(" ", false)
	var assign := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*=")
	var i := 0
	while i < words.size() and words[i] != "%command%" and assign.search(words[i]) != null:
		i += 1
	var head := " ".join(words.slice(0, i))
	var tail := " ".join(words.slice(i))
	return ("%s %s %s" % [head, shim, tail]).strip_edges()


## The options without our wrapper (shim or legacy path); "%command%" alone becomes "".
static func without_wrapper(options: String, wrapper: String) -> String:
	if wrapper == "":
		return options.strip_edges()
	var o := options.replace(launch_prefix(wrapper), " ")
	var words := Array(o.strip_edges().split(" ", false)).filter(func(w): return w != wrapper)
	var out := " ".join(PackedStringArray(words))
	return "" if out == "%command%" else out


## Every GameCove wrapper out, whatever path it named (a removed install, another prefix):
## the shim for any path, then any bare word ending in /gamecove-run.
static func strip_all_wrappers(options: String) -> String:
	var o := options
	var shim := RegEx.create_from_string("/bin/sh -c '\\[ -x (\\S+/gamecove-run) \\] && exec \\S+ \"\\$@\"; exec \"\\$@\"' gamecove-run")
	o = shim.sub(o, " ", true)
	var words := Array(o.strip_edges().split(" ", false)).filter(func(w): return not str(w).ends_with("/gamecove-run"))
	var out := " ".join(PackedStringArray(words))
	return "" if out == "%command%" else out


## Takes GameCove's wrapper out of every Steam game of every account (uninstall, Repair).
## Steam must be stopped. {"error", "changed": [appid...]}
static func unwrap_all(home: String, steam_root: String, proc_root := "/proc") -> Dictionary:
	return SteamConfig.rewrite_launch_options(home, steam_root,
		func(_id: String, o: String) -> String: return strip_all_wrappers(o) if mentions_gamecove(o) else o, proc_root)


## Moves old bare-path entries to the fall-through form (Steam stopped; at GameCove's start).
static func upgrade_legacy_all(home: String, steam_root: String, wrapper: String, proc_root := "/proc") -> Dictionary:
	if wrapper == "":
		return {"error": OK, "changed": []}
	return SteamConfig.rewrite_launch_options(home, steam_root,
		func(_id: String, o: String) -> String: return with_wrapper(o, wrapper) if has_legacy_wrapper(o, wrapper) else o, proc_root)


# ---- Steam's shader pre-caching -------------------------------------------------

## Threads set in steam_dev.cfg, 0 when the line isn't there (Steam's default).
static func shader_threads(steam_root: String) -> int:
	var p := steam_root.path_join("steam_dev.cfg")
	if steam_root == "" or not FileAccess.file_exists(p):
		return 0
	for line in FileAccess.get_file_as_string(p).split("\n"):
		var w := line.strip_edges().split(" ", false)
		if w.size() >= 2 and w[0] == SHADER_KEY and w[1].is_valid_int():
			return int(w[1])
	return 0


## Sets (n > 0) or removes (0) the line, keeping every other line.
static func set_shader_threads(steam_root: String, n: int) -> bool:
	if steam_root == "" or not DirAccess.dir_exists_absolute(steam_root):
		return false
	var p := steam_root.path_join("steam_dev.cfg")
	var lines: Array = []
	if FileAccess.file_exists(p):
		for line in FileAccess.get_file_as_string(p).split("\n"):
			var w := line.strip_edges().split(" ", false)
			if not (w.size() >= 1 and w[0] == SHADER_KEY) and line != "":
				lines.append(line)
	if n > 0:
		lines.append("%s %d" % [SHADER_KEY, clampi(n, 1, 16)])
	# atomic (review H9): a crash mid-write never leaves Steam half a steam_dev.cfg
	return SettingsFile.save_text(p, "\n".join(PackedStringArray(lines)) + ("\n" if not lines.is_empty() else "")) == OK


## The game's shader cache folders in every Steam library.
static func shader_cache_dirs(libraries: Array, appid: String) -> Array:
	var out := []
	if appid == "":
		return out
	for lib in libraries:
		var d := str(lib).path_join("steamapps/shadercache").path_join(appid)
		if DirAccess.dir_exists_absolute(d):
			out.append(d)
	return out


## Deletes a folder tree (only below a .../steamapps/shadercache/<digits> path).
static func remove_shader_cache(dir: String) -> bool:
	var re := RegEx.create_from_string("/steamapps/shadercache/[0-9]+$")
	if re.search(dir) == null:
		return false
	return _rm(dir)


static func _rm(dir: String) -> bool:
	var d := DirAccess.open(dir)
	if d == null:
		return false
	d.include_hidden = true
	for f in d.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for sub in d.get_directories():
		if d.is_link(sub):
			DirAccess.remove_absolute(dir.path_join(sub))   # the link only, never what it points to
		else:
			_rm(dir.path_join(sub))
	return DirAccess.remove_absolute(dir) == OK
