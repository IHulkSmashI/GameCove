extends "res://scripts/ui/settings/page.gd"
## Settings > Media: recording (GPU Screen Recorder: install it, allow screen
## capture once, sound and frame rate) and Clips (what you've recorded, with
## pictures: watch, send to your phone, delete).
##
## Built the first time it's shown and read again each time it's shown or a
## clip is saved. Everything that touches the disk or runs a program happens
## on a WorkerThreadPool task, never the main thread. Nothing runs by itself.
## The jobs (a read, installing the recorder or a player, allowing capture)
## belong to scripts/system/card_jobs.gd: leaving or rebuilding the page never
## waits for one, and the page that is there when it ends gets the result.
##
## services: "recording" (the Recording node; the page reads its locate() /
## options()), "media_runner" (proc.gd or a fake), "media_env" ({"home",
## "path_env", "sys_root"}), "drop_bind" (tests: the address the phone page
## listens on instead of the LAN one). The host (settings screen) opens sheets and starts apps
## through request_app_launch(app).

const Recorder := preload("res://scripts/system/recorder.gd")
const Clips := preload("res://scripts/system/clips.gd")
const Proc := preload("res://scripts/system/proc.gd")
const Sheet := preload("res://scripts/ui/games/sheet.gd")
const ShareSheet := preload("res://scripts/ui/settings/share_sheet.gd")
const ClipRow := preload("res://scripts/ui/settings/clip_row.gd")
const Services := preload("res://scripts/ui/settings/services.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")
## card_jobs.gd channel.
const CH := "media"
## Clips listed at once (the rest are counted); pictures made per read with ffmpeg.
const MAX_ROWS := 40
const THUMBS_PER_READ := 6

## {"loc", "status", "clips", "player", "ffmpeg"} from the last read; {} before it.
## Kept by `jobs`, so a rebuilt page shows it at once.
var state: Dictionary:
	get: return _jobs().memo(CH).get("state", {})
	set(v): _jobs().memo(CH)["state"] = v
## "read" / "install" / "setup" / "player" / "", while a job runs (in `jobs`).
var busy: String:
	get: return _jobs().busy(CH)
## The owner of the jobs: CardJobs.shared(), or one of its own under tests
## ("media_runner" given) unless "card_jobs" is.
var jobs: RefCounted
var sheet: Control
var share: Control
var clip_rows: Array = []
var _built := false
var _textures := {}     # clip path -> Texture2D


func _connect() -> void:
	var rec := svc("recording")
	if rec != null and rec.has_signal("saved"):
		rec.saved.connect(func(_p, _i): if is_visible_in_tree(): refresh())


func _runner() -> RefCounted:
	var r: Variant = services.get("media_runner")
	return r if r is RefCounted else _jobs().runner()


func _jobs() -> RefCounted:
	if jobs == null:
		var j: Variant = services.get("card_jobs") if services is Dictionary else null
		if j is RefCounted:
			jobs = j
		elif services is Dictionary and services.get("media_runner") != null:
			jobs = CardJobs.new()
		else:
			jobs = CardJobs.shared()
		jobs.subscribe(CH, self)
	return jobs


func _env() -> Dictionary:
	var e: Variant = services.get("media_env")
	if e is Dictionary:
		return e
	return {"home": OS.get_environment("HOME"), "path_env": OS.get_environment("PATH"), "sys_root": ""}


func on_shown() -> void:
	_built = true
	refresh()


## Reads the recorder, the clips and the player again.
func refresh() -> void:
	if busy != "":
		return
	if services.get("media_runner") == null and Services.under_tests(self):
		return   # unit tests pass a fake; nothing real may run under them
	var r := _runner()
	var env := _env()
	if _job("read", func(): return read_state(r, env), "_on_state"):
		rebuild()


## Worker: everything the page shows. Static so tests can call it.
static func read_state(r: RefCounted, env: Dictionary) -> Dictionary:
	var home := str(env.get("home", ""))
	var loc := Recorder.locate(env)
	var st := Recorder.status(r, loc, home)
	var clips := Clips.list(Recorder.clips_root(home))
	var ffmpeg := Recorder.which("ffmpeg", str(env.get("path_env", "")), str(env.get("sys_root", "")))
	var made := 0
	var pictures := {}
	for c in clips.slice(0, MAX_ROWS):
		var t := Clips.thumb_path(c["path"])
		if not FileAccess.file_exists(t) and ffmpeg != "" and made < THUMBS_PER_READ:
			made += 1
			Clips.make_thumb(r, ffmpeg, c["path"])
		if FileAccess.file_exists(t):
			var img := Image.load_from_file(t)
			if img != null and not img.is_empty():
				pictures[c["path"]] = img
		c["seconds"] = Clips.mp4_seconds(c["path"])
	var apps := []
	var flatpak := str(loc.get("flatpak", ""))
	if flatpak != "":
		var out: Dictionary = r.run(flatpak, PackedStringArray(["list", "--app", "--columns=application"]))
		if int(out.get("code", -1)) == 0:
			for l in str(out.get("out", "")).split("\n", false):
				apps.append(l.strip_edges())
	var player := Clips.find_player(str(env.get("path_env", "")), apps, str(env.get("sys_root", "")))
	return {"loc": loc, "status": st, "clips": clips, "pictures": pictures, "player": player, "flatpak": flatpak}


## Hands `fn` to the job owner; `done(result, extra...)` runs on whichever page is
## there when it ends. Outside the tree (tests) it runs at once.
func _job(job_name: String, fn: Callable, done: String, extra: Array = []) -> bool:
	var j := _jobs()
	return j.start(CH, job_name, fn, done, extra, is_inside_tree() or j.force_threads)


func _enter_tree() -> void:
	if jobs != null:
		jobs.subscribe(CH, self)


## Leaving never waits for a job (it isn't ours): we just stop listening.
func _exit_tree() -> void:
	if jobs != null:
		jobs.unsubscribe(CH, self)


func _on_state(st: Dictionary) -> void:
	state = st
	_textures.clear()
	var pics: Dictionary = st.get("pictures", {})
	for p in pics:
		_textures[p] = ImageTexture.create_from_image(pics[p])
	var rec := svc("recording")
	if rec != null and rec.has_method("set_ready"):
		rec.set_ready(str(st.get("status", {}).get("why", "")) != "needs_setup")
	rebuild()


# ---- the page -----------------------------------------------------------------------

func build() -> void:
	clip_rows.clear()
	_build_recorder()
	_build_clips()


## The recorder row says what to do next: install, allow capture, or ready.
func _build_recorder() -> void:
	var box := add_card(TX.MEDIA_REC_TITLE, "record", TX.MEDIA_REC_LINE)
	var r := action_row(box, "rec_status", TX.MEDIA_RECORDER, "", "", "record")
	r.collapse_hint = false
	var step := next_step()
	match step:
		"checking":
			r.set_value(TX.MEDIA_CHECKING, "muted")
		"ready":
			r.set_value(TX.MEDIA_READY, "good")
			r.set_hint(TX.MEDIA_READY_HINT.get(str(state["loc"].get("kind", "")), ""))
		"install":
			r.title_label.text = TX.MEDIA_INSTALL
			r.set_value(TX.MEDIA_INSTALLING if busy == "install" else TX.MEDIA_MISSING, "muted" if busy == "install" else "warn")
			r.set_hint(TX.MEDIA_INSTALL_HINT)
		"install_system":
			r.title_label.text = TX.MEDIA_INSTALL
			r.set_value(TX.MEDIA_INSTALLING if busy == "install" else TX.MEDIA_USER_ONLY, "muted" if busy == "install" else "warn")
			r.set_hint(TX.MEDIA_USER_ONLY_HINT)
		"no_flatpak":
			r.set_value(TX.MEDIA_MISSING, "warn")
			r.set_hint(TX.MEDIA_NO_FLATPAK)
		"setup":
			r.title_label.text = TX.MEDIA_SETUP
			r.set_value(TX.MEDIA_SETUP_RUNNING if busy == "setup" else TX.MEDIA_SETUP_STATE, "muted" if busy == "setup" else "warn")
			r.set_hint(TX.MEDIA_SETUP_HINT)
	r.pressed.connect(press_recorder)
	var rec := svc("recording")
	var opts: Dictionary = rec.options() if rec != null and rec.has_method("options") else {"audio": true, "fps": 60}
	var a := toggle(box, "rec_audio", TX.MEDIA_AUDIO, bool(opts["audio"]), by_value(TX.MEDIA_AUDIO_HELP), "volume")
	a.changed.connect(func(v): _set_option("audio", bool(v)))
	var f := choice(box, "rec_fps", TX.MEDIA_FPS, Recorder.FPS_CHOICES, TX.MEDIA_FPS_LABELS, int(opts["fps"]), by_value(TX.MEDIA_FPS_HELP), "gauge")
	f.changed.connect(func(v): _set_option("fps", int(v)))


func _set_option(key: String, v: Variant) -> void:
	var rec := svc("recording")
	if rec != null and rec.has_method("set_option"):
		rec.set_option(key, v)


## "checking" | "ready" | "install" | "install_system" | "no_flatpak" | "setup".
func next_step() -> String:
	if state.is_empty():
		return "checking"
	var st: Dictionary = state.get("status", {})
	if bool(st.get("ready", false)):
		return "ready"
	match str(st.get("why", "")):
		"user_only": return "install_system"
		"needs_setup": return "setup"
		"no_flatpak": return "no_flatpak"
	return "install"


## A on the recorder row: the next step.
func press_recorder() -> void:
	if busy != "":
		return
	match next_step():
		"install", "install_system": install_recorder()
		"setup": allow_capture()
		"ready", "no_flatpak": refresh()


func install_recorder() -> void:
	var flatpak := str(state.get("flatpak", ""))
	if flatpak == "":
		notify(TX.MEDIA_NO_FLATPAK, "bad")
		return
	var r := _runner()
	var started := _job("install", func():
		var remotes: Dictionary = r.run(flatpak, PackedStringArray(["remotes", "--system", "--columns=name"]))
		for cmd in Recorder.install_commands(flatpak, Recorder.has_flathub(str(remotes.get("out", "")))):
			var args := PackedStringArray()
			for c in cmd.slice(1):
				args.append(str(c))
			var res: Dictionary = r.run(str(cmd[0]), args)
			if int(res.get("code", -1)) != 0:
				return {"ok": false, "out": str(res.get("out", ""))}
		return {"ok": true, "out": ""}, "_on_installed")
	if started and busy == "install":
		rebuild()


## Flatpak says "not allowed" / "authentication" when polkit wanted a password.
static func install_needs_desktop(out: String) -> bool:
	var o := out.to_lower()
	return o.contains("not allowed") or o.contains("authenticat") or o.contains("authoriz") or o.contains("polkit")


func _on_installed(res: Dictionary) -> void:
	if bool(res.get("ok", false)):
		notify(TX.MEDIA_INSTALLED, "good")
	elif install_needs_desktop(str(res.get("out", ""))):
		notify(TX.MEDIA_INSTALL_DESKTOP, "bad")
	else:
		notify(TX.MEDIA_INSTALL_FAILED % Recorder.last_line(Array(str(res.get("out", "")).split("\n"))), "bad")
	refresh()


func allow_capture() -> void:
	var r := _runner()
	var home := str(_env().get("home", ""))
	var started := _job("setup", func():
		var cmd := Recorder.setup_command(home)
		var res: Dictionary = r.run(cmd[0], cmd.slice(1))
		return {"code": int(res.get("code", -1)), "out": str(res.get("out", ""))}, "_on_setup")
	if started and busy == "setup":
		rebuild()


func _on_setup(res: Dictionary) -> void:
	var code := int(res.get("code", -1))
	if code == 0:
		notify(TX.MEDIA_SETUP_DONE, "good")
	elif Recorder.needs_desktop(code):
		notify(TX.MEDIA_SETUP_DESKTOP, "bad")
	else:
		notify(TX.MEDIA_SETUP_FAILED % Recorder.last_line(Array(str(res.get("out", "")).split("\n"))), "bad")
	refresh()


# ---- clips ---------------------------------------------------------------------------

func _build_clips() -> void:
	var box := add_card(TX.CLIPS_TITLE, "film", TX.CLIPS_LINE)
	if state.is_empty():
		box.add_child(SKit.note(TX.CLIPS_LOADING, "info", "ClipsLoading"))
		return
	var clips: Array = state.get("clips", [])
	if clips.is_empty():
		box.add_child(SKit.note(TX.CLIPS_EMPTY, "info", "ClipsEmpty"))
		return
	for c in clips.slice(0, MAX_ROWS):
		var row: VBoxContainer = ClipRow.new()
		row.setup(c, _textures.get(c["path"]))
		var clip: Dictionary = c
		row.pressed.connect(func(): open_clip(clip))
		add_row(box, row)
		clip_rows.append(row)
	if clips.size() > MAX_ROWS:
		var more := Kit.label(TX.CLIPS_MORE % (clips.size() - MAX_ROWS), "QuietLabel")
		more.name = "ClipsMore"
		box.add_child(more)


func _sheet() -> Control:
	if sheet == null or not is_instance_valid(sheet):
		sheet = Sheet.new()
		sheet.z_index = 15
		var parent: Node = host if host is Node else self
		parent.add_child(sheet)
	return sheet


## The sheet for one clip: Watch (or get a player), Send to phone, Delete.
func open_clip(clip: Dictionary) -> void:
	_sheet().open(Clips.title_of(clip), ClipRow.meta_text(clip), clip_items(clip, state.get("player", {})), func(id: String): act(clip, id))


static func clip_items(clip: Dictionary, player: Dictionary) -> Array:
	var items := []
	if not player.is_empty():
		items.append({"id": "play", "text": TX.CLIPS_PLAY, "detail": TX.CLIPS_PLAY_WITH % player["name"], "icon": "play"})
	else:
		items.append({"id": "get_player", "text": TX.CLIPS_NO_PLAYER, "detail": TX.CLIPS_NO_PLAYER_DETAIL, "icon": "download"})
	items.append({"id": "share", "text": TX.CLIPS_SHARE, "detail": TX.CLIPS_SHARE_DETAIL, "icon": "phone"})
	items.append({"id": "delete", "text": TX.CLIPS_DELETE, "detail": TX.CLIPS_DELETE_DETAIL, "icon": "trash", "tone": "bad"})
	return items


## One sheet action (tests call it directly).
func act(clip: Dictionary, id: String) -> void:
	match id:
		"play": play(clip)
		"get_player": install_player(clip)
		"share": share_clip(clip)
		"delete": ask_delete(clip)
		"delete_yes": delete_clip(clip)


func play(clip: Dictionary) -> void:
	var env := _env()
	var cmd := Clips.play_command(state.get("player", {}), str(clip["path"]), str(env.get("path_env", "")), str(env.get("sys_root", "")))
	if cmd.is_empty():
		notify(TX.CLIPS_LAUNCH_FAILED, "bad")
		return
	if host != null and host.has_method("request_app_launch"):
		host.request_app_launch(Clips.play_item(clip, cmd))


func install_player(clip: Dictionary) -> void:
	var flatpak := str(state.get("flatpak", ""))
	if flatpak == "" or busy != "":
		notify(TX.MEDIA_NO_FLATPAK if flatpak == "" else TX.CLIPS_PLAYER_INSTALLING, "bad" if flatpak == "" else "")
		return
	notify(TX.CLIPS_PLAYER_INSTALLING)
	var r := _runner()
	var env := _env()
	_job("player", func():
		for cmd in Clips.player_install_commands(flatpak):
			var args := PackedStringArray()
			for c in cmd.slice(1):
				args.append(str(c))
			var res: Dictionary = r.run(str(cmd[0]), args)
			if int(res.get("code", -1)) != 0:
				return {"ok": false, "out": str(res.get("out", "")), "state": {}}
		return {"ok": true, "out": "", "state": read_state(r, env)}, "_on_player", [clip])


func _on_player(res: Dictionary, clip: Dictionary) -> void:
	if not bool(res.get("ok", false)):
		notify(TX.CLIPS_PLAYER_FAILED % Recorder.last_line(Array(str(res.get("out", "")).split("\n"))), "bad")
		return
	_on_state(res["state"])
	if not (state.get("player", {}) as Dictionary).is_empty():
		play(clip)


func ask_delete(clip: Dictionary) -> void:
	_sheet().open(Clips.title_of(clip), TX.CLIPS_DELETE_DETAIL, [
		{"id": "delete_yes", "text": TX.CLIPS_DELETE, "detail": ClipRow.meta_text(clip), "icon": "trash", "tone": "bad"},
	], func(id: String): act(clip, id))


func delete_clip(clip: Dictionary) -> void:
	var home := str(_env().get("home", ""))
	if Clips.delete(Recorder.clips_root(home), str(clip["path"])):
		notify(TX.CLIPS_DELETED % Clips.title_of(clip), "good")
		var list: Array = state.get("clips", [])
		state["clips"] = list.filter(func(c): return c["path"] != clip["path"])
		_textures.erase(clip["path"])
		rebuild()
	else:
		notify(TX.CLIPS_DELETE_FAILED, "bad")


func share_clip(clip: Dictionary) -> void:
	if share == null or not is_instance_valid(share):
		share = ShareSheet.new()
		share.z_index = 16
		if services.get("drop_bind") is String:
			share.bind_address = services["drop_bind"]
		share.finished.connect(func(text: String, tone: String): notify(text, tone))
		var parent: Node = host if host is Node else self
		parent.add_child(share)
	share.open_for(clip)


func focus_part(_part: String) -> Control:
	if not _built:
		on_shown()
	var f := focusables()
	return f[0] if not f.is_empty() else null
