extends RefCounted
## Starts a ROM the way the user's setup starts it (app/data/emu_launchers.json
## says where each rule comes from):
## - RetroDECK: its own CLI (`flatpak run net.retrodeck.retrodeck -s <system> <game>`),
##   which picks the emulator from ES-DE's settings itself;
## - EmuDeck and ES-DE on their own: ES-DE's command for the game, chosen the way
##   ES-DE chooses it (the game's <altemulator>, else the system's
##   <alternativeEmulator>, else the system's first command), from the installed
##   ES-DE's custom_systems/es_systems.xml or else ES-DE's own list
##   (app/data/esde_commands.json), with ES-DE's variables filled in and each
##   %EMULATOR_x% found by ES-DE's find rules (custom_systems/es_find_rules.xml
##   first). With EmuDeck, an emulator EmuDeck has a launcher script for runs
##   through <Emulation>/tools/launchers/<script> instead, with the same
##   arguments, exactly how EmuDeck's Steam ROM Manager shortcuts start games
##   (cloud saves, netplay and its settings stay EmuDeck's).
##
## The command is built as an argument list (nothing goes through a shell), so
## file names with spaces, quotes or brackets reach the emulator as they are.
## Pure functions; safe on any thread.

const Common := preload("res://scripts/library/stores/common.gd")

const DATA := "res://data/esde_commands.json"
const LAUNCHERS := "res://data/emu_launchers.json"
const RETRODECK_ID := "net.retrodeck.retrodeck"
const INJECT_MAX := 4096
## ES-DE variables we can't fill outside ES-DE: such a command is left to ES-DE.
const UNSUPPORTED := ["%RPCS3_GAMEID%", "%ROMRAWWIN%", "%ESCAPESPECIALS%", "%EMUPATH%"]
## What ES-DE's shortcut entries run (a .desktop's Exec line, a script, an AppImage).
const SHELL_EXT := ["desktop", "sh", "appimage"]
## ES-DE systems that hold apps and other stores' games, not ROMs: never Library games of ours.
const NOT_GAME_SYSTEMS := ["androidapps", "desktop", "emulators", "epic", "kodi", "lutris", "steam"]
## Variables that only change how ES-DE itself behaves while the game runs.
const DROPPED := ["%RUNINBACKGROUND%", "%HIDEWINDOW%"]

static var _data := {}
static var _launchers := {}
static var _lock := Mutex.new()


static func data() -> Dictionary:
	_lock.lock()
	if _data.is_empty():
		var d: Variant = Common.read_json(ProjectSettings.globalize_path(DATA), {})
		_data = d if d is Dictionary else {}
	_lock.unlock()
	return _data


static func launchers() -> Dictionary:
	_lock.lock()
	if _launchers.is_empty():
		var d: Variant = Common.read_json(ProjectSettings.globalize_path(LAUNCHERS), {})
		_launchers = d if d is Dictionary else {}
	_lock.unlock()
	return _launchers


# ------------------------------------------------------------ ES-DE's files

## The systems and find rules of an installed ES-DE's custom_systems folder:
## {"systems": {id: {"path", "ext", "commands": [[label, command]]}},
##  "emulators": {NAME: {"systempath": [...], "staticpath": [...]}}, "cores": {NAME: [dirs]}}.
static func read_custom(esde_dir: String) -> Dictionary:
	var out := {"systems": {}, "emulators": {}, "cores": {}}
	if esde_dir == "":
		return out
	out["systems"] = read_systems_xml(esde_dir.path_join("custom_systems/es_systems.xml"))
	var rules := read_rules_xml(esde_dir.path_join("custom_systems/es_find_rules.xml"))
	out["emulators"] = rules["emulators"]
	out["cores"] = rules["cores"]
	return out


## <system> entries of an es_systems.xml, as in esde_commands.json.
static func read_systems_xml(path: String) -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(path):
		return out
	var x := XMLParser.new()
	if x.open(path) != OK:
		return out
	var cur := ""
	var s := {}
	var label := ""
	while x.read() == OK:
		match x.get_node_type():
			XMLParser.NODE_ELEMENT:
				cur = x.get_node_name()
				if cur == "system":
					s = {"name": "", "path": "", "ext": [], "commands": []}
				elif cur == "command":
					label = x.get_named_attribute_value_safe("label")
			XMLParser.NODE_TEXT:
				var t := x.get_node_data().strip_edges()
				if s.is_empty() or t == "":
					continue
				match cur:
					"name": s["name"] = t
					"path": s["path"] = t.xml_unescape()
					"extension":
						for e in t.split(" ", false):
							var l := e.to_lower()
							if l.begins_with(".") and l.length() > 1 and not l in s["ext"]:
								s["ext"].append(l)
					"command": s["commands"].append([label.xml_unescape(), t.xml_unescape()])
			XMLParser.NODE_ELEMENT_END:
				if x.get_node_name() == "system" and not s.is_empty():
					if s["name"] != "":
						out[s["name"]] = {"path": s["path"], "ext": s["ext"], "commands": s["commands"]}
					s = {}
				cur = ""
	return out


## <emulator> and <core> rules of an es_find_rules.xml.
static func read_rules_xml(path: String) -> Dictionary:
	var out := {"emulators": {}, "cores": {}}
	if not FileAccess.file_exists(path):
		return out
	var x := XMLParser.new()
	if x.open(path) != OK:
		return out
	var cur := ""
	var tag := ""
	var name := ""
	var rtype := ""
	while x.read() == OK:
		match x.get_node_type():
			XMLParser.NODE_ELEMENT:
				cur = x.get_node_name()
				if cur in ["emulator", "core"]:
					tag = cur
					name = x.get_named_attribute_value_safe("name")
					if tag == "emulator":
						out["emulators"][name] = {}
					else:
						out["cores"][name] = []
				elif cur == "rule":
					rtype = x.get_named_attribute_value_safe("type")
			XMLParser.NODE_TEXT:
				var t := x.get_node_data().strip_edges()
				if t == "" or cur != "entry" or name == "":
					continue
				if tag == "emulator":
					if not out["emulators"][name].has(rtype):
						out["emulators"][name][rtype] = []
					out["emulators"][name][rtype].append(t.xml_unescape())
				elif rtype == "corepath":
					out["cores"][name].append(t.xml_unescape())
			XMLParser.NODE_ELEMENT_END:
				if x.get_node_name() in ["emulator", "core"]:
					name = ""
				cur = ""
	return out


## A system as ES-DE sees it: the custom one when the user's ES-DE has one
## (it replaces ES-DE's own entirely), else ES-DE's. {} when unknown.
static func system_def(id: String, custom: Dictionary) -> Dictionary:
	var c: Variant = custom.get("systems", {}).get(id)
	if c is Dictionary and not c.get("commands", []).is_empty():
		return c
	var d: Variant = data().get("systems", {}).get(id)
	return d if d is Dictionary else {}


## [label, command] ES-DE would run: the game's alternative emulator, else the
## system's, else the first command. A label no command has is ignored (ES-DE
## falls back to the default too). One difference: when the default only runs
## shortcuts and scripts (PS3's and PS4's "Shortcut" entries) and `rom` is
## neither, the first command that can open it is used (ES-DE would hand a game
## folder or disc image to the shell and fail).
static func pick(commands: Array, system_alt: String, game_alt: String, rom := "") -> Array:
	for want in [game_alt, system_alt]:
		if want == "":
			continue
		for c in commands:
			if str(c[0]) == want:
				return c
	if commands.is_empty():
		return []
	var first: Array = commands[0]
	if rom != "" and "%EMULATOR_OS-SHELL%" in str(first[1]) and "%ENABLESHORTCUTS%" in str(first[1]) \
			and not rom.get_extension().to_lower() in SHELL_EXT:
		for c in commands.slice(1):
			if not "%EMULATOR_OS-SHELL%" in str(c[1]) and not UNSUPPORTED.any(func(v): return v in str(c[1])):
				return c
	return first


# ------------------------------------------------------------ finding programs

static func _home_path(p: String, home: String) -> String:
	return home + p.substr(1) if p.begins_with("~") else p


## A find rule's path on this machine: ~ is home; other absolute paths sit under
## `abs_root` (tests point it at their own folder, so the machine's Flatpaks and
## /usr never leak in).
static var abs_root := ""


static func _rule_path(p: String, home: String) -> String:
	if p.begins_with("~"):
		return home + p.substr(1)
	return abs_root + p if p.begins_with("/") and abs_root != "" else p


## The newest file matching a find-rule path (a * may be in its file name).
static func _glob(pattern: String) -> String:
	if not "*" in pattern:
		return pattern if FileAccess.file_exists(pattern) else ""
	var dir := pattern.get_base_dir()
	if "*" in dir:
		return ""
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var hits: Array = []
	for f in d.get_files():
		if f.match(pattern.get_file()):
			hits.append(dir.path_join(f))
	hits.sort()
	return hits[-1] if not hits.is_empty() else ""


## Where ES-DE's find rules find emulator `name` ("" when nowhere): the user's
## custom rule for it replaces ES-DE's; systempath entries are looked up on PATH,
## staticpath entries on disk (~ is home, %ESPATH% ES-DE's folder).
static func find_emulator(name: String, ctx: Dictionary) -> String:
	var rules: Variant = ctx.get("custom", {}).get("emulators", {}).get(name)
	var own: bool = rules is Dictionary   # the user's own rules name real paths as they are
	if not own:
		rules = data().get("emulators", {}).get(name, {})
	var home := str(ctx.get("home", ""))
	for p in rules.get("systempath", []):
		var hit := Common.which(str(p), str(ctx.get("path_env", "")))
		if hit != "":
			return hit
	for p in rules.get("staticpath", []):
		var raw := str(p)
		var s := (_home_path(raw, home) if own else _rule_path(raw, home)) if not ("%ESPATH%" in raw or "%ROMPATH%" in raw) else \
			_home_path(raw.replace("%ESPATH%", str(ctx.get("es_path", ""))).replace("%ROMPATH%", str(ctx.get("roms_dir", ""))), home)
		var hit := _glob(s)
		if hit != "":
			return hit
	return ""


## The folder of core `name` holding `file` ("" when no core folder has it).
static func find_core(name: String, file: String, ctx: Dictionary) -> String:
	var dirs: Variant = ctx.get("custom", {}).get("cores", {}).get(name)
	var own: bool = dirs is Array and not dirs.is_empty()
	if not own:
		dirs = data().get("cores", {}).get(name, [])
	for d in dirs:
		var raw := str(d)
		var p := (_home_path(raw, str(ctx.get("home", ""))) if own else _rule_path(raw, str(ctx.get("home", "")))) if not "%ESPATH%" in raw else _home_path(raw.replace("%ESPATH%", str(ctx.get("es_path", ""))), str(ctx.get("home", "")))
		if FileAccess.file_exists(p.path_join(file)):
			return p
	return ""


# ------------------------------------------------------------ building the command

## What starts `game` ({"system", "path", "altemulator"}). ctx: {"kind": emudeck |
## retrodeck | esde, "home", "path_env", "emu_path" (EmuDeck's Emulation folder),
## "roms_dir", "es_path", "custom" (read_custom), "system_alt"}.
## {"ok", "cmd": [program, args...], "env": {}, "cwd": "", "label", "via", "why"}.
static func build(game: Dictionary, ctx: Dictionary) -> Dictionary:
	var out := {"ok": false, "cmd": [], "env": {}, "cwd": "", "label": "", "via": "", "why": ""}
	var system := str(game.get("system", ""))
	var rom := str(game.get("path", ""))
	if rom == "" or not (FileAccess.file_exists(rom) or DirAccess.dir_exists_absolute(rom)):
		out["why"] = "The game file isn't there any more: %s" % rom
		return out
	var def := system_def(system, ctx.get("custom", {}))
	var chosen := pick(def.get("commands", []), str(ctx.get("system_alt", "")), str(game.get("altemulator", "")), rom)
	out["label"] = str(chosen[0]) if not chosen.is_empty() else ""
	if str(ctx.get("kind", "")) == "retrodeck":
		var tpl: Array = launchers().get("retrodeck", {}).get("command", [])
		for t in tpl:
			out["cmd"].append(str(t).replace("%SYSTEM%", system).replace("%ROM%", rom))
		out["via"] = "retrodeck"
		out["ok"] = not out["cmd"].is_empty()
		return out
	if chosen.is_empty():
		out["why"] = "ES-DE has no way to start %s games" % system
		return out
	return expand(str(chosen[1]), rom, ctx, out)


## ES-DE's command line with its variables filled in, as an argument list.
static func expand(command: String, rom: String, ctx: Dictionary, out: Dictionary) -> Dictionary:
	for v in UNSUPPORTED:
		if v in command:
			out["why"] = "This game starts with %s, which only ES-DE itself can fill in: start it from ES-DE" % v
			return out
	var home := str(ctx.get("home", ""))
	# A .desktop shortcut (ES-DE's %ENABLESHORTCUTS%): the command in its Exec line, no shell needed.
	if "%ENABLESHORTCUTS%" in command and rom.get_extension().to_lower() == "desktop":
		var exec := desktop_exec(rom)
		if exec.is_empty():
			out["why"] = "The shortcut has no command to run: %s" % rom.get_file()
			return out
		out["cmd"] = exec
		out["via"] = "esde"
		out["ok"] = true
		return out
	var basename := rom.get_file().get_basename()
	var gamedir := rom.get_base_dir()
	var tokens := Common.shell_split(command)
	var words: Array[String] = []
	var program_at := -1
	var emu_dir := ""
	var launcher_args: Variant = null
	var startdir := ""
	var em := RegEx.create_from_string("^%(EMULATOR|PRECOMMAND)_([^%]+)%$")
	var core_re := RegEx.create_from_string("%CORE_([^%]+)%")
	for tok in tokens:
		if tok in DROPPED or tok == "%ENABLESHORTCUTS%":
			continue
		var m := em.search(tok)
		if m != null:
			var name := m.get_string(2)
			var script := _launcher_script(name, ctx)
			if script != "":
				words.append("/bin/bash")
				words.append(script)
				emu_dir = script.get_base_dir()
				out["via"] = "emudeck"
				var spec: Dictionary = launchers().get("emudeck", {}).get(name, {})
				if spec.get("args") is Array:
					launcher_args = spec["args"]
			else:
				var exe := find_emulator(name, ctx)
				if exe == "":
					out["why"] = "%s isn't installed where ES-DE looks for it" % (str(out["label"]) if str(out["label"]) != "" else name)
					return out
				words.append(exe)
				emu_dir = exe.get_base_dir()
				if out["via"] == "":
					out["via"] = "esde"
			if m.get_string(1) == "EMULATOR":
				program_at = words.size() - (2 if script != "" else 1)
			continue
		if tok.begins_with("%STARTDIR%="):
			startdir = tok.substr(11)   # may name %EMUDIR%, found further on
			continue
		if tok.begins_with("%INJECT%="):
			var f := _vars(tok.substr(9), rom, basename, gamedir, emu_dir, ctx)
			f = _home_path(f, home)
			if not f.begins_with("/"):
				f = gamedir.path_join(f)
			if DirAccess.dir_exists_absolute(rom) and f == rom:
				f = rom.path_join(rom.get_file())
			var fa := FileAccess.open(f, FileAccess.READ)
			if fa != null and fa.get_length() > 0 and fa.get_length() <= INJECT_MAX:
				for w in Common.shell_split(fa.get_as_text().strip_edges()):
					words.append(w)
			if fa != null:
				fa.close()
			continue
		var cm := core_re.search(tok)
		if cm != null:
			var rest := tok.substr(cm.get_end()).trim_prefix("/")
			var core_dir := find_core(cm.get_string(1), rest.get_file() if rest != "" else "", ctx)
			if core_dir == "":
				out["why"] = "The RetroArch core %s isn't installed (%s)" % [rest.get_file(), out["label"]]
				return out
			tok = tok.replace(cm.get_string(0), core_dir)
		words.append(_vars(tok, rom, basename, gamedir, emu_dir, ctx))
	if startdir != "":
		out["cwd"] = _home_path(_vars(startdir, rom, basename, gamedir, emu_dir, ctx), home)
	if program_at < 0:
		program_at = 0
		var first := words[0] if not words.is_empty() else ""
		if first != "" and not first.begins_with("/"):
			var w := Common.which(first, str(ctx.get("path_env", "")))
			if w != "":
				words[0] = w
		if out["via"] == "":
			out["via"] = "esde"
	# An EmuDeck script that reads its arguments its own way gets what EmuDeck gives it.
	if launcher_args is Array:
		var head := words.slice(0, program_at + 2)
		words.clear()
		words.append_array(head)
		for a in launcher_args:
			words.append(_vars(str(a), rom, basename, gamedir, emu_dir, ctx))
	# Words before the program that set variables (an injected .esprefix) are its environment.
	var env := {}
	var cmd: Array[String] = []
	var re_env := RegEx.create_from_string("^[A-Za-z_][A-Za-z0-9_]*=")
	for i in words.size():
		if i < program_at and re_env.search(words[i]) != null:
			env[words[i].get_slice("=", 0)] = words[i].substr(words[i].find("=") + 1)
		else:
			cmd.append(words[i])
	if cmd.is_empty() or cmd[0] == "":
		out["why"] = "ES-DE's command for this game is empty"
		return out
	out["cmd"] = cmd
	out["env"] = env
	out["ok"] = true
	return out


static func _vars(s: String, rom: String, basename: String, gamedir: String, emu_dir: String, ctx: Dictionary) -> String:
	var table := {
		"%ROMRAW%": rom, "%ROM%": rom, "%BASENAME%": basename, "%FILENAME%": rom.get_file(),
		"%GAMEDIRRAW%": gamedir, "%GAMEENTRYDIR%": rom if DirAccess.dir_exists_absolute(rom) else gamedir,
		"%GAMEDIR%": gamedir, "%ROMPATH%": str(ctx.get("roms_dir", "")), "%EMUDIR%": emu_dir,
		"%ESPATH%": str(ctx.get("es_path", ""))}
	# one pass, left to right: what a variable stands for is never read again, so a ROM called
	# "%BASENAME%.zip" or a folder named "%EMUDIR%" stays as it is
	var out := ""
	var i := 0
	while i < s.length():
		var hit := ""
		if s[i] == "%":
			for k in table:
				if s.substr(i, k.length()) == k and k.length() > hit.length():
					hit = k
		if hit != "":
			out += table[hit]
			i += hit.length()
		else:
			out += s[i]
			i += 1
	return out


## EmuDeck's launcher script for an ES-DE emulator name, when this is EmuDeck
## and the script is there; "" otherwise.
static func _launcher_script(name: String, ctx: Dictionary) -> String:
	if str(ctx.get("kind", "")) != "emudeck" or str(ctx.get("emu_path", "")) == "":
		return ""
	var spec: Variant = launchers().get("emudeck", {}).get(name)
	if not spec is Dictionary:
		return ""
	var p := str(ctx["emu_path"]).path_join("tools/launchers").path_join(str(spec.get("script", "")))
	return p if FileAccess.file_exists(p) else ""


## The command in a .desktop file's Exec line, with %f %F %u %U removed (ES-DE does the same).
static func desktop_exec(path: String) -> Array[String]:
	var out: Array[String] = []
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null or fa.get_length() > 65536:
		return out
	for line in fa.get_as_text().split("\n"):
		if line.strip_edges().begins_with("Exec="):
			for w in Common.shell_split(line.strip_edges().substr(5)):
				if not w in ["%f", "%F", "%u", "%U"]:
					out.append(w)
			break
	return out


## The emulator a label stands for, for the game page ("Snes9x - Current" ->
## "RetroArch: Snes9x - Current"): RetroArch cores say so, standalone ones don't need to.
static func emulator_name(system: String, label: String, custom: Dictionary) -> String:
	if label == "":
		return ""
	for c in system_def(system, custom).get("commands", []):
		if str(c[0]) == label and "%EMULATOR_RETROARCH%" in str(c[1]):
			return "RetroArch (%s)" % label
	return label.replace(" (Standalone)", "")
