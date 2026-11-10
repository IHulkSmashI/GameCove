extends RefCounted
## Screen recording with GPU Screen Recorder (dec05eba, GPL-3.0): the pieces
## that don't move. Where it is, what to run, where clips go, what its errors
## mean. The Recording service (recording.gd) runs it; nothing here starts on
## its own.
##
## Why GPU Screen Recorder: it encodes on the GPU (VA-API on AMD and Intel,
## NVENC on NVIDIA), so a recording costs a few percent of a frame instead of a
## CPU core, and it's on Flathub for every distro.
##
## How it sees a gamescope session: gamescope (Gaming Mode) has no desktop
## portal, so window and portal capture don't exist there. Monitor capture
## (`-w screen`, the first screen) reads the picture gamescope sends to the
## display through KMS, which needs a small root helper:
##   - a host install (Arch, CachyOS...) ships gsr-kms-server with the
##     cap_sys_admin capability set at install, so it just works;
##   - the Flatpak calls kms-server-proxy on the host (flatpak-spawn --host),
##     which on its first run copies itself to
##     ~/.local/share/gpu-screen-recorder/ and sets that capability with pkexec,
##     once. That's why monitor capture needs the system-wide Flatpak install
##     (the proxy is run from /var/lib/flatpak) and why the first set-up asks for
##     the admin password. Gaming Mode has no polkit agent to ask with, so set-up
##     is a Desktop Mode step (`kms-server-proxy setup-gsr-ui ~`, exactly what
##     the official GPU Screen Recorder UI runs); `kms-server-proxy is-setup ~`
##     tells us it's done. Sources: gpu-screen-recorder kms/client/kms_client.c
##     and git.dec05eba.com/kms-server-proxy main.c (read 2026-11-10).
##
## Encoding: H.264 in MP4 (`-k h264 -c mp4`), the one every phone, browser and
## chat app plays; GPU Screen Recorder picks the hardware encoder itself.
## Stopping: SIGINT, which makes it finish the file (its documented stop).
##
## Clips: ~/Videos/GameCove/<game>/<game> <date> <time>.mp4.

const FLATPAK_ID := "com.dec05eba.gpu_screen_recorder"
const BINARY := "gpu-screen-recorder"
const SYSTEM_APP_DIR := "/var/lib/flatpak/app/" + FLATPAK_ID
const KMS_PROXY := SYSTEM_APP_DIR + "/current/active/files/bin/kms-server-proxy"
const USER_APP_DIR := ".local/share/flatpak/app/" + FLATPAK_ID
const FLATHUB_REPO := "https://dl.flathub.org/repo/flathub.flatpakrepo"
const VIDEOS := "Videos/GameCove"
## The folder for clips recorded with no game running.
const NO_GAME := "GameCove"
const EXTENSIONS := ["mp4", "mkv", "webm", "mov"]
const FPS_CHOICES := [30, 60]
## Linux truncates a process name to 15 characters in /proc/<pid>/stat.
const COMM := "gpu-screen-reco"


## The program on PATH, or "".
static func which(program: String, path_env: String, sys_root := "") -> String:
	for d in path_env.split(":", false):
		if FileAccess.file_exists(sys_root + d.path_join(program)):
			return d.path_join(program)
	return ""


## Where GPU Screen Recorder is: {"kind": "host" | "flatpak" | "flatpak_user" | "",
## "program": what to run, "flatpak": the flatpak binary ("" when none)}.
## "flatpak_user": only a per-user Flatpak, which can't capture the screen.
## env: {"home", "path_env", "sys_root"}.
static func locate(env: Dictionary) -> Dictionary:
	var root := str(env.get("sys_root", ""))
	var path_env := str(env.get("path_env", ""))
	var flatpak := which("flatpak", path_env, root)
	var host := which(BINARY, path_env, root)
	if host != "":
		return {"kind": "host", "program": host, "flatpak": flatpak}
	if flatpak != "" and DirAccess.dir_exists_absolute(root + SYSTEM_APP_DIR):
		return {"kind": "flatpak", "program": flatpak, "flatpak": flatpak}
	var home := str(env.get("home", ""))
	if flatpak != "" and home != "" and DirAccess.dir_exists_absolute(root + home.path_join(USER_APP_DIR)):
		return {"kind": "flatpak_user", "program": flatpak, "flatpak": flatpak}
	return {"kind": "", "program": "", "flatpak": flatpak}


## Can it record right now? {"ready": bool, "why": "" | "missing" | "user_only" |
## "needs_setup" | "no_flatpak"}. Runs kms-server-proxy is-setup for the Flatpak
## (blocks briefly: worker thread).
static func status(runner: RefCounted, loc: Dictionary, home: String) -> Dictionary:
	match str(loc.get("kind", "")):
		"host":
			return {"ready": true, "why": ""}
		"flatpak":
			var r: Dictionary = runner.run(KMS_PROXY, PackedStringArray(["is-setup", home])) if runner != null else {"code": -1}
			return {"ready": int(r.get("code", -1)) == 0, "why": "" if int(r.get("code", -1)) == 0 else "needs_setup"}
		"flatpak_user":
			return {"ready": false, "why": "user_only"}
	return {"ready": false, "why": "missing" if str(loc.get("flatpak", "")) != "" else "no_flatpak"}


## The arguments for one recording. opts: {"fps": 30 | 60, "audio": bool}.
static func record_args(out_path: String, opts: Dictionary) -> PackedStringArray:
	var fps := int(opts.get("fps", 60))
	if not fps in FPS_CHOICES:
		fps = 60
	var a := PackedStringArray(["-w", "screen", "-c", "mp4", "-k", "h264", "-f", str(fps), "-q", "very_high",
		"-cursor", "no", "-v", "no"])
	if bool(opts.get("audio", true)):
		a.append_array(PackedStringArray(["-a", "default_output"]))
	a.append_array(PackedStringArray(["-o", out_path]))
	return a


## [program, args...] that records with `args`.
static func command(loc: Dictionary, args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	match str(loc.get("kind", "")):
		"host":
			out.append(str(loc["program"]))
		"flatpak":
			out.append_array(PackedStringArray([str(loc["program"]), "run", "--command=" + BINARY, FLATPAK_ID]))
		_:
			return out
	out.append_array(args)
	return out


## The system-wide install (Flathub's own polkit rules let a local admin user
## install apps without a password; elsewhere it fails and we say to use
## Desktop Mode). The remote is only added when it isn't there.
static func install_commands(flatpak: String, have_flathub: bool) -> Array:
	var out := []
	if not have_flathub:
		out.append([flatpak, "remote-add", "--system", "--if-not-exists", "flathub", FLATHUB_REPO])
	out.append([flatpak, "install", "--system", "--noninteractive", "-y", "flathub", FLATPAK_ID])
	return out


## True when `flatpak remotes --system --columns=name` lists flathub.
static func has_flathub(remotes_out: String) -> bool:
	for l in remotes_out.split("\n", false):
		if l.strip_edges() == "flathub":
			return true
	return false


## The one-time screen-capture set-up (asks for the admin password).
static func setup_command(home: String) -> PackedStringArray:
	return PackedStringArray([KMS_PROXY, "setup-gsr-ui", home])


## pkexec's "nobody could say yes" codes: no polkit agent (Gaming Mode) or dismissed.
static func needs_desktop(code: int) -> bool:
	return code == 126 or code == 127


## A folder name from a game title: no slashes, control characters or dots in
## front; at most 80 characters; NO_GAME when nothing is left.
static func safe_name(title: String) -> String:
	var s := ""
	for ch in title.strip_edges():
		var c := ch.unicode_at(0)
		if c < 32 or c == 127 or ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
			s += " "
		else:
			s += ch
	s = RegEx.create_from_string("\\s+").sub(s, " ", true).strip_edges().lstrip(".").strip_edges()
	if s.length() > 80:
		s = s.substr(0, 80).strip_edges()
	return s if s != "" else NO_GAME


static func clips_root(home: String) -> String:
	return home.path_join(VIDEOS)


## A new clip's path for `title` at `when` (Time datetime dict); never an existing file.
static func clip_path(home: String, title: String, when: Dictionary) -> String:
	var folder := clips_root(home).path_join(safe_name(title))
	var stamp := "%04d-%02d-%02d %02d-%02d-%02d" % [int(when.get("year", 1970)), int(when.get("month", 1)),
		int(when.get("day", 1)), int(when.get("hour", 0)), int(when.get("minute", 0)), int(when.get("second", 0))]
	var base := "%s %s" % [safe_name(title), stamp]
	var p := folder.path_join(base + ".mp4")
	var n := 2
	while FileAccess.file_exists(p):
		p = folder.path_join("%s (%d).mp4" % [base, n])
		n += 1
	return p


## What went wrong, from its exit code and last lines: "needs_setup" (the KMS
## helper wasn't allowed to start), "no_encoder" (no hardware video encoder),
## "missing" (not installed any more), "no_screen", or "failed".
static func error_kind(code: int, lines: Array) -> String:
	var text := "\n".join(lines).to_lower()
	if code == 127 and (text.contains("not found") or text == ""):
		return "missing"
	if text.contains("kms") and (text.contains("pkexec") or text.contains("permission") or text.contains("not authorized")
			or text.contains("missing capabilities") or text.contains("failed to launch") or text.contains("setup")):
		return "needs_setup"
	if text.contains("vaapi") or text.contains("va-api") or text.contains("no video encoder") or text.contains("doesn't support")\
			or text.contains("does not support") or text.contains("encoder") and text.contains("not available"):
		return "no_encoder"
	if text.contains("no monitor") or text.contains("failed to find monitor") or text.contains("monitor") and text.contains("not found"):
		return "no_screen"
	return "failed"


## The last line worth showing ("" when none).
static func last_line(lines: Array) -> String:
	for i in range(lines.size() - 1, -1, -1):
		var l := str(lines[i]).strip_edges()
		if l != "":
			return l
	return ""


# ---- the process ------------------------------------------------------------------

## {pid: ppid} and {pid: comm} from /proc/<pid>/stat (proc_root: "/proc", or a
## folder of fake stat files in tests).
static func proc_table(proc_root: String) -> Dictionary:
	var parents := {}
	var names := {}
	for d in DirAccess.get_directories_at(proc_root):
		if not d.is_valid_int():
			continue
		var text := _read(proc_root.path_join(d).path_join("stat"))
		# "pid (comm) state ppid ...": comm may hold spaces and parentheses
		var open := text.find("(")
		var close := text.rfind(")")
		if open < 0 or close < open:
			continue
		var rest := text.substr(close + 2).split(" ", false)
		if rest.size() < 2 or not rest[1].is_valid_int():
			continue
		parents[int(d)] = int(rest[1])
		names[int(d)] = text.substr(open + 1, close - open - 1)
	return {"parents": parents, "names": names}


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var DeviceScript = load("res://scripts/device/device.gd")
	return DeviceScript.read_all(f)


## The recorder's own process under `root_pid` (the Flatpak runs it a few
## sandbox levels down; SIGINT has to reach it, not the wrapper). root_pid
## itself when it is the recorder; -1 when it's gone.
static func recorder_pid(root_pid: int, table: Dictionary) -> int:
	var parents: Dictionary = table.get("parents", {})
	var names: Dictionary = table.get("names", {})
	if not names.has(root_pid):
		return -1
	if str(names[root_pid]).begins_with(COMM):
		return root_pid
	var queue: Array = [root_pid]
	var seen := {root_pid: true}
	while not queue.is_empty():
		var p: int = queue.pop_front()
		for c in parents:
			if int(parents[c]) == p and not seen.has(c):
				seen[c] = true
				if str(names.get(c, "")).begins_with(COMM):
					return int(c)
				queue.append(int(c))
	return root_pid
