extends RefCounted
## The clips GameCove recorded (~/Videos/GameCove/<game>/*.mp4): list them,
## their pictures, how long they run, delete one, and play one in a video
## player. Static; everything that touches the disk blocks, so the Clips card
## calls it from a worker thread.
##
## Pictures live in user://clips/thumbs/<md5 of the clip's path>.png: from a
## gamescope screenshot taken when recording starts (grab_gamescope_thumb), or,
## for a clip without one, from ffmpeg when it's installed (make_thumb).
##
## Length: read from the MP4 itself (the movie header box, mvhd), no ffprobe needed.
##
## Playing: Godot only plays Theora video, so a clip opens in a real player,
## started like an app (it gets the quick menu and comes back to GameCove when
## it closes): mpv first (it has controller support: `--input-gamepad=yes`), then
## VLC or Celluloid, each as a host program or a Flatpak. Without one, the card
## offers mpv from Flathub for this user (no password).

const Recorder := preload("res://scripts/system/recorder.gd")
const THUMBS := "user://clips/thumbs"
const THUMB_W := 480
const SHOT_TMP := "/tmp/gamescope.png"
const SHOT_WAIT_MS := 3000
const MPV_FLATPAK := "io.mpv.Mpv"
## [kind, id, args before the file]: tried in this order.
const PLAYERS := [
	["host", "mpv", ["--fs", "--input-gamepad=yes", "--keep-open=no", "--force-window=yes"]],
	["flatpak", MPV_FLATPAK, ["--fs", "--input-gamepad=yes", "--keep-open=no", "--force-window=yes"]],
	["flatpak", "org.videolan.VLC", ["--fullscreen", "--play-and-exit"]],
	["host", "vlc", ["--fullscreen", "--play-and-exit"]],
	["flatpak", "io.github.celluloid_player.Celluloid", []],
	["host", "celluloid", []],
]
const PLAYER_NAMES := {"mpv": "mpv", MPV_FLATPAK: "mpv", "org.videolan.VLC": "VLC", "vlc": "VLC",
	"io.github.celluloid_player.Celluloid": "Celluloid", "celluloid": "Celluloid"}


## Every clip, newest first: [{"path", "game", "name", "size", "mtime"}].
## Looks in the root and one level of game folders.
static func list(root: String) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(root):
		return out
	_add_files(root, "", out)
	for d in DirAccess.get_directories_at(root):
		if not d.begins_with("."):
			_add_files(root.path_join(d), d, out)
	out.sort_custom(func(a, b): return int(a["mtime"]) > int(b["mtime"]) if int(a["mtime"]) != int(b["mtime"]) else str(a["path"]) < str(b["path"]))
	return out


static func _add_files(dir: String, game: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.begins_with(".") or not f.get_extension().to_lower() in Recorder.EXTENSIONS:
			continue
		var p := dir.path_join(f)
		var size := FileAccess.get_size(p)
		if size <= 0:
			continue
		out.append({"path": p, "game": game, "name": f.get_basename(), "size": size, "mtime": FileAccess.get_modified_time(p)})


## "Hades · Nov 10, 3:30 PM" from a clip's game folder and time.
static func title_of(clip: Dictionary) -> String:
	var game := str(clip.get("game", ""))
	return game if game != "" else str(clip.get("name", ""))


static func when_text(unix: int) -> String:
	if unix <= 0:
		return ""
	var d := Time.get_datetime_dict_from_unix_time(unix + _utc_offset_s())
	var months := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	var h: int = d["hour"]
	return "%s %d, %d:%02d %s" % [months[int(d["month"]) - 1], d["day"], 12 if h % 12 == 0 else h % 12, d["minute"], "PM" if h >= 12 else "AM"]


static func _utc_offset_s() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


## "48 MB", "1.2 GB".
static func size_text(bytes: int) -> String:
	if bytes >= 1_000_000_000:
		return "%.1f GB" % (bytes / 1_000_000_000.0)
	if bytes >= 1_000_000:
		return "%d MB" % roundi(bytes / 1_000_000.0)
	return "%d KB" % maxi(1, roundi(bytes / 1000.0))


# ---- pictures --------------------------------------------------------------------------

static func thumb_path(clip_path: String) -> String:
	return ProjectSettings.globalize_path(THUMBS).path_join(clip_path.md5_text() + ".png")


static func remove_thumb(clip_path: String) -> void:
	var t := thumb_path(clip_path)
	if FileAccess.file_exists(t):
		DirAccess.remove_absolute(t)


## Saves `img` scaled to THUMB_W wide as the clip's picture.
static func save_thumb(clip_path: String, img: Image) -> bool:
	if img == null or img.is_empty():
		return false
	var t := thumb_path(clip_path)
	DirAccess.make_dir_recursive_absolute(t.get_base_dir())
	var copy := img.duplicate() as Image
	if copy.is_compressed():
		copy.decompress()
	var w := copy.get_width()
	if w > THUMB_W:
		copy.resize(THUMB_W, maxi(1, roundi(copy.get_height() * float(THUMB_W) / w)), Image.INTERPOLATE_BILINEAR)
	return copy.save_png(t) == OK


## Worker thread: asks gamescope for a picture of the game (base plane, the
## same request as Screenshot) and keeps it as the clip's picture. Does nothing
## outside gamescope.
static func grab_gamescope_thumb(clip_path: String, runner: RefCounted = null, sys_root := "") -> void:
	var XAtoms = load("res://scripts/controls/display/xatoms.gd")
	var Proc = load("res://scripts/system/proc.gd")
	var xa: RefCounted = XAtoms.new({"runner": runner if runner != null else Proc.new()})
	if not xa.running():
		return
	var tmp := sys_root + SHOT_TMP
	# gamescope always writes the same file, and it isn't ours: the quick menu's
	# Screenshot may be waiting for it or copying it this very moment, and what
	# lies there may be the user's last screenshot. So nothing is removed: the
	# new picture is told from the old one by what the file says about itself.
	var before := shot_stamp(tmp)
	if not xa.send_cardinal("GAMESCOPECTRL_REQUEST_SCREENSHOT", 1):
		return
	var waited := 0
	var seen := before
	var fresh := false
	while waited < SHOT_WAIT_MS:
		OS.delay_msec(100)
		waited += 100
		var now := shot_stamp(tmp)
		# new, and no longer growing (two looks alike): gamescope is done writing
		if not now.is_empty() and now != before and now == seen:
			fresh = true
			break
		seen = now
	if fresh:
		save_thumb(clip_path, Image.load_from_file(tmp))


## What tells one gamescope screenshot from the next without touching the file:
## [modified time, size, md5]; [] when there's none (or it's empty).
static func shot_stamp(path: String) -> Array:
	if not FileAccess.file_exists(path) or FileAccess.get_size(path) <= 0:
		return []
	return [FileAccess.get_modified_time(path), FileAccess.get_size(path), FileAccess.get_md5(path)]


## A picture for a clip that has none, from ffmpeg (one frame a second in).
## False when ffmpeg isn't installed or can't read it.
static func make_thumb(runner: RefCounted, ffmpeg: String, clip_path: String) -> bool:
	if ffmpeg == "" or runner == null:
		return false
	var t := thumb_path(clip_path)
	DirAccess.make_dir_recursive_absolute(t.get_base_dir())
	var r: Dictionary = runner.run(ffmpeg, PackedStringArray(["-nostdin", "-y", "-loglevel", "error", "-ss", "1", "-i", clip_path,
		"-frames:v", "1", "-vf", "scale=%d:-2" % THUMB_W, t]))
	return int(r.get("code", -1)) == 0 and FileAccess.file_exists(t)


# ---- length ----------------------------------------------------------------------------

## The clip's length in seconds from its MP4 header (-1 when unknown).
## GPU Screen Recorder writes the header (moov) after the video data, so this
## walks the top-level boxes by their sizes, reading only box headers.
static func mp4_seconds(path: String) -> float:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1.0
	f.big_endian = true
	var end := f.get_length()
	var moov := _find_box(f, 0, end, "moov")
	if moov.is_empty():
		return -1.0
	var mvhd := _find_box(f, int(moov["body"]), int(moov["end"]), "mvhd")
	if mvhd.is_empty():
		return -1.0
	f.seek(int(mvhd["body"]))
	var version := f.get_8()
	f.get_buffer(3)   # flags
	var scale := 0
	var dur := 0
	if version == 1:
		f.get_64()
		f.get_64()
		scale = f.get_32()
		dur = f.get_64()
	else:
		f.get_32()
		f.get_32()
		scale = f.get_32()
		dur = f.get_32()
	return float(dur) / scale if scale > 0 else -1.0


## {"body": offset after the header, "end": offset after the box} or {}.
static func _find_box(f: FileAccess, from: int, to: int, kind: String) -> Dictionary:
	var pos := from
	while pos + 8 <= to:
		f.seek(pos)
		var size := f.get_32()
		var typ := f.get_buffer(4).get_string_from_ascii()
		var header := 8
		if size == 1:
			size = f.get_64()
			header = 16
		elif size == 0:
			size = to - pos
		if size < header:
			return {}
		if typ == kind:
			return {"body": pos + header, "end": mini(pos + size, to)}
		pos += size
	return {}


# ---- delete ----------------------------------------------------------------------------

## Deletes a clip (only inside `root`) and its picture; an emptied game folder goes too.
static func delete(root: String, clip_path: String) -> bool:
	var r := root.simplify_path()
	var p := clip_path.simplify_path()
	if not p.begins_with(r + "/") or not FileAccess.file_exists(p):
		return false
	if DirAccess.remove_absolute(p) != OK:
		return false
	remove_thumb(p)
	var dir := p.get_base_dir()
	if dir != r and DirAccess.get_files_at(dir).is_empty() and DirAccess.get_directories_at(dir).is_empty():
		DirAccess.remove_absolute(dir)
	return true


# ---- playing ---------------------------------------------------------------------------

## The first video player installed: {"kind": "host" | "flatpak", "id", "name",
## "args"} or {}. flatpak_apps: ids `flatpak list --app --columns=application` printed.
static func find_player(path_env: String, flatpak_apps: Array, sys_root := "") -> Dictionary:
	for p in PLAYERS:
		var found := false
		if p[0] == "host":
			found = Recorder.which(p[1], path_env, sys_root) != ""
		else:
			found = p[1] in flatpak_apps
		if found:
			return {"kind": p[0], "id": p[1], "name": PLAYER_NAMES.get(p[1], p[1]), "args": p[2]}
	return {}


## [program, args...] that plays `clip_path` full screen.
static func play_command(player: Dictionary, clip_path: String, path_env: String, sys_root := "") -> Array:
	if player.is_empty():
		return []
	var out: Array = []
	if player["kind"] == "host":
		out.append(Recorder.which(str(player["id"]), path_env, sys_root))
	else:
		out.append_array([Recorder.which("flatpak", path_env, sys_root), "run", str(player["id"])])
	if str(out[0]) == "":
		return []
	out.append_array(player["args"])
	out.append(clip_path)
	return out


## The per-user mpv install from Flathub (no password).
static func player_install_commands(flatpak: String) -> Array:
	return [
		[flatpak, "remote-add", "--user", "--if-not-exists", "flathub", Recorder.FLATHUB_REPO],
		[flatpak, "install", "--user", "--noninteractive", "-y", "flathub", MPV_FLATPAK],
	]


## The "game" GameCove starts for a clip: an app (store "app") whose command
## plays it, so it runs like any app: quick menu, Guide, back home when it closes.
static func play_item(clip: Dictionary, cmd: Array) -> Dictionary:
	return {"key": "app:clip:" + str(clip.get("path", "")).md5_text(), "store": "app", "id": "clip", "installed": true,
		"title": title_of(clip), "exec": cmd, "art": {}}
