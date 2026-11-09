extends RefCounted
## Moonlight (moonlight-qt) as GameCove uses it: find it, build its command
## lines, and read what it remembers (Moonlight.conf). GameCove never decodes
## video or speaks the pairing protocol itself; Moonlight does both.
##
## CLI (moonlight-qt app/cli/commandlineparser.cpp):
##   moonlight list <host> [--csv]            no window; prints the host's apps
##   moonlight pair <host> [--pin NNNN]       opens a window, waits for the PIN on the host
##   moonlight stream <host> "<app>" [opts]   the stream itself, fullscreen
##   moonlight quit <host>                    quits the app running on the host
## Stream options used here: --resolution WxH, --fps N, --bitrate Kbps,
## --video-codec auto|H.264|HEVC|AV1, --video-decoder auto|hardware|software,
## --display-mode fullscreen, --audio-config stereo|5.1-surround|7.1-surround,
## and the toggles --[no-]vsync, --[no-]frame-pacing, --[no-]hdr,
## --[no-]game-optimization, --[no-]audio-on-host, --[no-]performance-overlay,
## --[no-]swap-gamepad-buttons, --[no-]multi-controller, --[no-]keep-awake,
## --[no-]quit-after, --[no-]background-gamepad, --capture-system-keys never.
## Options given on the command line apply to that run only; Moonlight's own
## saved settings stay as the user left them.
##
## pair and quit open a Qt window. GameCove runs them with QT_QPA_PLATFORM=
## offscreen so nothing pops over its own screen; pairing shows our own PIN
## screen instead, and success is read from Moonlight.conf (the host gets a
## server certificate there), since the CLI's pair window never exits by itself.

const FLATPAK_ID := "com.moonlight_stream.Moonlight"
const ORG := "Moonlight Game Streaming Project"
const FLATHUB_REPO := "https://dl.flathub.org/repo/flathub.flatpakrepo"
const NATIVE_NAMES := ["moonlight", "moonlight-qt"]


## Where Moonlight is: {"kind": "flatpak" | "native" | "", "program", "prefix": [args before
## the action], "config": Moonlight.conf path, "cache": box art cache folder, "scope": "user"|"system"|""}.
## sys_root prefixes every path (tests); `path_env` is $PATH.
static func locate(home: String, path_env: String, sys_root := "") -> Dictionary:
	for scope in ["user", "system"]:
		var app_dir := sys_root + (home + "/.local/share/flatpak/app/" if scope == "user" else "/var/lib/flatpak/app/") + FLATPAK_ID
		if DirAccess.dir_exists_absolute(app_dir + "/current"):
			var data := sys_root + home + "/.var/app/" + FLATPAK_ID
			return {"kind": "flatpak", "program": _which("flatpak", path_env, sys_root, "/usr/bin/flatpak"),
				"prefix": ["run", "--branch=stable", FLATPAK_ID], "scope": scope,
				"config": data + "/config/" + ORG + "/Moonlight.conf",
				"cache": data + "/cache/" + ORG + "/Moonlight/boxart"}
	for n in NATIVE_NAMES:
		var p := _which(n, path_env, sys_root, "")
		if p != "":
			return {"kind": "native", "program": p, "prefix": [], "scope": "",
				"config": sys_root + home + "/.config/" + ORG + "/Moonlight.conf",
				"cache": sys_root + home + "/.cache/" + ORG + "/Moonlight/boxart"}
	return {"kind": "", "program": "", "prefix": [], "scope": "", "config": "", "cache": ""}


static func _which(name: String, path_env: String, sys_root: String, fallback: String) -> String:
	for d in path_env.split(":", false):
		var p := sys_root + d.path_join(name)
		if FileAccess.file_exists(p):
			return p.trim_prefix(sys_root) if sys_root != "" else p
	return fallback if fallback != "" and (sys_root == "" or FileAccess.file_exists(sys_root + fallback)) else ""


## [program, args...] for one Moonlight action. `env`: extra variables (flatpak
## gets them as --env=, a native binary through `env`).
static func command(m: Dictionary, action_args: Array, env := {}) -> Array[String]:
	var out: Array[String] = []
	if str(m.get("kind", "")) == "":
		return out
	if m["kind"] == "flatpak":
		out.append(str(m["program"]))
		out.append("run")
		for k in env:
			out.append("--env=%s=%s" % [k, env[k]])
		for a in (m["prefix"] as Array).slice(1):
			out.append(str(a))
	else:
		if not env.is_empty():
			out.append("env")
			for k in env:
				out.append("%s=%s" % [k, env[k]])
		out.append(str(m["program"]))
	for a in action_args:
		out.append(str(a))
	return out


static func list_args(host: String) -> Array:
	return ["list", host, "--csv"]


static func pair_args(host: String, pin: String) -> Array:
	return ["pair", host, "--pin", pin]


static func quit_args(host: String) -> Array:
	return ["quit", host]


## Moonlight's stream arguments from resolved settings (stream_settings.gd resolve()).
static func stream_args(host: String, app_title: String, s: Dictionary) -> Array:
	var a: Array = ["stream", host, app_title,
		"--resolution", "%dx%d" % [int(s["width"]), int(s["height"])],
		"--fps", str(int(s["fps"])),
		"--bitrate", str(int(s["bitrate_kbps"])),
		"--video-codec", str(s["codec"]),
		"--video-decoder", str(s.get("decoder", "auto")),
		"--display-mode", "fullscreen",
		"--audio-config", str(s.get("audio", "stereo")),
		"--capture-system-keys", "never"]
	for flag in ["vsync", "frame-pacing", "hdr", "game-optimization", "audio-on-host",
			"performance-overlay", "swap-gamepad-buttons", "multi-controller", "keep-awake",
			"quit-after", "background-gamepad"]:
		var key: String = flag.replace("-", "_")
		if s.has(key):
			a.append("--" + flag if bool(s[key]) else "--no-" + flag)
	return a


## Flatpak install for the user, no password: works in Gaming Mode.
## [[program, args...], ...] run in order.
static func install_commands(flatpak := "flatpak") -> Array:
	return [
		[flatpak, "remote-add", "--user", "--if-not-exists", "flathub", FLATHUB_REPO],
		[flatpak, "install", "--user", "--noninteractive", "-y", "flathub", FLATPAK_ID],
	]


# ---------------------------------------------------------------- Moonlight.conf

## What Moonlight.conf (QSettings INI) says: {"hosts": [{"uuid", "name", "mac",
## "addresses": [..], "paired": bool, "custom_name": bool}], "cert": PEM, "key": PEM}.
## Missing or unreadable file: empty lists and "".
static func read_conf(path: String) -> Dictionary:
	var out := {"hosts": [], "cert": "", "key": ""}
	if path == "" or not FileAccess.file_exists(path):
		return out
	return parse_conf(FileAccess.get_file_as_string(path))


static func parse_conf(text: String) -> Dictionary:
	var out := {"hosts": [], "cert": "", "key": ""}
	var section := ""
	var hosts := {}
	for raw in text.split("\n"):
		var line := raw.strip_edges(true, false).trim_suffix("\r")
		if line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2)
			continue
		var eq := line.find("=")
		if eq < 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if section == "General" and key in ["certificate", "key"]:
			out["cert" if key == "certificate" else "key"] = qsettings_value(value)
		elif section == "hosts" and key.contains("\\"):
			var idx := key.get_slice("\\", 0)
			var field := key.substr(idx.length() + 1)
			if field.contains("\\"):
				continue   # apps\N\... inside a host
			if not hosts.has(idx):
				hosts[idx] = {}
			hosts[idx][field] = value
	var keys := hosts.keys()
	keys.sort_custom(func(a, b): return str(a).to_int() < str(b).to_int())
	for k in keys:
		var h: Dictionary = hosts[k]
		var uuid := qsettings_value(str(h.get("uuid", "")))
		if uuid == "":
			continue
		var addrs: Array = []
		for f in ["manualaddress", "localaddress", "remoteaddress", "ipv6address"]:
			var a := qsettings_value(str(h.get(f, "")))
			if a != "" and not a in addrs:
				addrs.append(a)
		out["hosts"].append({
			"uuid": uuid,
			"name": qsettings_value(str(h.get("hostname", ""))),
			"mac": mac_from_bytes(qsettings_bytes(str(h.get("mac", "")))),
			"addresses": addrs,
			"paired": qsettings_value(str(h.get("srvcert", ""))).contains("BEGIN CERTIFICATE"),
			"custom_name": qsettings_value(str(h.get("customname", ""))) == "true",
		})
	return out


## A QSettings INI value as text: quotes removed, escapes resolved,
## "@ByteArray(...)" unwrapped (as Latin-1 text).
static func qsettings_value(v: String) -> String:
	var b := qsettings_bytes(v)
	return b.get_string_from_utf8() if not b.is_empty() else ""


## A QSettings INI value as bytes (QSettings::iniUnescapedString + @ByteArray).
static func qsettings_bytes(v: String) -> PackedByteArray:
	var s := v.strip_edges()
	var out := PackedByteArray()
	var i := 0
	var quoted := false
	var chars: Array[int] = []
	while i < s.length():
		var c := s[i]
		if c == "\"":
			quoted = not quoted
			i += 1
			continue
		if c == "\\" and i + 1 < s.length():
			var n := s[i + 1]
			match n:
				"x":
					var j := i + 2
					var hex := ""
					while j < s.length() and s[j].is_valid_hex_number():
						hex += s[j]
						j += 1
					chars.append(hex.hex_to_int() if hex != "" else 0)
					i = j
					continue
				"n": chars.append(10)
				"r": chars.append(13)
				"t": chars.append(9)
				"0": chars.append(0)
				"a": chars.append(7)
				"b": chars.append(8)
				"f": chars.append(12)
				"v": chars.append(11)
				_: chars.append(n.unicode_at(0))
			i += 2
			continue
		if c == "," and not quoted:
			break   # a list value: first item only
		chars.append(c.unicode_at(0))
		i += 1
	for ch in chars:
		if ch < 256:
			out.append(ch)
		else:
			out.append_array(String.chr(ch).to_utf8_buffer())
	# @ByteArray(...): the inner characters are the bytes as written
	if out.size() >= 12 and out.slice(0, 11).get_string_from_ascii() == "@ByteArray(" and out[out.size() - 1] == 41:
		out = out.slice(11, out.size() - 1)
	return out


static func mac_from_bytes(b: PackedByteArray) -> String:
	if b.size() != 6:
		return ""
	var parts: Array[String] = []
	for x in b:
		parts.append("%02X" % x)
	var mac := ":".join(parts)
	return "" if mac == "00:00:00:00:00:00" else mac


## Moonlight's box art cache file for an app ("" when it isn't there).
static func cached_art(m: Dictionary, host_uuid: String, app_id: int) -> String:
	var p := str(m.get("cache", "")).path_join(host_uuid).path_join("%d.png" % app_id)
	return p if str(m.get("cache", "")) != "" and FileAccess.file_exists(p) else ""
