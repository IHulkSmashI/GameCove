extends "res://tests/test_case.gd"
## Clips: listing, length from the MP4 header, delete, the video player,
## the phone page (clip_drop.gd: answers, ranges, a real transfer over
## 127.0.0.1) and Settings > Media with a fake system. Nothing real runs.

const Clips := preload("res://scripts/system/clips.gd")
const ClipDrop := preload("res://scripts/system/clip_drop.gd")
const KeyDrop := preload("res://scripts/system/key_drop.gd")
const Recorder := preload("res://scripts/system/recorder.gd")
const MediaPage := preload("res://scripts/ui/settings/media_page.gd")
const ClipRow := preload("res://scripts/ui/settings/clip_row.gd")
const ShareSheet := preload("res://scripts/ui/settings/share_sheet.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")


func _tmp(tag: String) -> String:
	var d := OS.get_cache_dir().path_join("gamecove_clips_%s_%d" % [tag, Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _wipe(dir: String) -> void:
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	DirAccess.remove_absolute(dir)


func _bytes(path: String, data: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


## A gamescope that answers the screenshot request by writing `img` to <root>/tmp/gamescope.png
## (or not at all when `img` is null).
class ShotRunner extends RefCounted:
	var root := ""
	var img: Image
	var asked := 0
	func run(_program: String, args: PackedStringArray) -> Dictionary:
		if "-notype" in args:
			return {"code": 0, "out": "GAMESCOPE_FOCUSABLE_APPS = 769\n"}
		if "GAMESCOPECTRL_REQUEST_SCREENSHOT" in args:
			asked += 1
			if img != null:
				img.save_png(root + "/tmp/gamescope.png")
		return {"code": 0, "out": ""}


## Final review (Low): the clip's picture removed /tmp/gamescope.png first. That
## file isn't ours: it may be the user's last screenshot, or the one the quick
## menu's Screenshot is copying right now.
func test_clip_picture_never_removes_the_screenshot_file() -> void:
	var root := _tmp("shot")
	DirAccess.make_dir_recursive_absolute(root + "/tmp")
	var old := Image.create_empty(64, 36, false, Image.FORMAT_RGB8)
	old.fill(Color.RED)
	old.save_png(root + "/tmp/gamescope.png")
	var old_md5 := FileAccess.get_md5(root + "/tmp/gamescope.png")
	var clip := root.path_join("Videos/a.mp4")
	# gamescope doesn't answer: the file that was there stays, and isn't taken for the clip's picture
	var r := ShotRunner.new()
	r.root = root
	Clips.remove_thumb(clip)
	Clips.grab_gamescope_thumb(clip, r, root)
	eq(r.asked, 1, "gamescope was asked")
	eq(FileAccess.get_md5(root + "/tmp/gamescope.png"), old_md5, "the screenshot that was there is untouched")
	ok(not FileAccess.file_exists(Clips.thumb_path(clip)), "and an old screenshot isn't used as this clip's picture")
	# gamescope answers: the new picture is used, nothing removed
	r.img = Image.create_empty(960, 540, false, Image.FORMAT_RGB8)
	r.img.fill(Color.BLUE)
	Clips.grab_gamescope_thumb(clip, r, root)
	ok(FileAccess.file_exists(root + "/tmp/gamescope.png"), "the file is still there for whoever else wants it")
	var t := Image.load_from_file(Clips.thumb_path(clip))
	ok(t != null and t.get_width() == Clips.THUMB_W, "the clip's picture was saved")
	ok(t != null and t.get_pixel(5, 5).b > 0.9 and t.get_pixel(5, 5).r < 0.1, "from the new screenshot")
	# and with no file there before
	DirAccess.remove_absolute(root + "/tmp/gamescope.png")
	Clips.remove_thumb(clip)
	Clips.grab_gamescope_thumb(clip, r, root)
	ok(FileAccess.file_exists(Clips.thumb_path(clip)), "works the first time too")
	Clips.remove_thumb(clip)
	_wipe(root)


static func _u32(n: int) -> PackedByteArray:
	var b := PackedByteArray([0, 0, 0, 0])
	b.encode_u32(0, n)
	b.reverse()
	return b


static func _box(kind: String, body: PackedByteArray) -> PackedByteArray:
	var out := _u32(body.size() + 8)
	out.append_array(kind.to_ascii_buffer())
	out.append_array(body)
	return out


## A minimal MP4 the way GPU Screen Recorder lays it out: ftyp, mdat, then moov
## with an mvhd of `seconds` at timescale 1000.
static func _mp4(seconds: float, mdat_size := 5000) -> PackedByteArray:
	var mvhd := PackedByteArray([0, 0, 0, 0])   # version 0, flags
	mvhd.append_array(_u32(0))
	mvhd.append_array(_u32(0))
	mvhd.append_array(_u32(1000))
	mvhd.append_array(_u32(int(seconds * 1000)))
	var pad := PackedByteArray()
	pad.resize(80)
	mvhd.append_array(pad)
	var data := PackedByteArray()
	data.resize(mdat_size)
	var out := _box("ftyp", "isom".to_ascii_buffer() + PackedByteArray([0, 0, 2, 0]))
	out.append_array(_box("mdat", data))
	out.append_array(_box("moov", _box("mvhd", mvhd)))
	return out


func test_lists_clips_newest_first() -> void:
	var root := _tmp("list")
	_bytes(root + "/Hades/Hades 2026-11-09 10-00-00.mp4", _mp4(12.0))
	_bytes(root + "/Celeste/Celeste 2026-11-10 10-00-00.mp4", _mp4(42.5))
	_bytes(root + "/Celeste/notes.txt", PackedByteArray([1]))
	_bytes(root + "/Celeste/empty.mp4", PackedByteArray())
	_bytes(root + "/GameCove/home.mkv", _mp4(1.0))
	var list := Clips.list(root)
	eq(list.size(), 3, "videos only, empty files skipped")
	ok(list.all(func(c): return str(c["path"]).get_extension() in ["mp4", "mkv"]), "video files")
	eq(Clips.title_of(list.filter(func(c): return c["game"] == "Celeste")[0]), "Celeste", "named by the game folder")
	eq(Clips.list(root + "/missing"), [], "no folder, no clips")
	_wipe(root)


func test_length_comes_from_the_mp4_header() -> void:
	var root := _tmp("len")
	_bytes(root + "/a.mp4", _mp4(42.5))
	ok(absf(Clips.mp4_seconds(root + "/a.mp4") - 42.5) < 0.01, "42.5 s read past the video data")
	_bytes(root + "/b.mp4", "not an mp4 at all".to_utf8_buffer())
	eq(Clips.mp4_seconds(root + "/b.mp4"), -1.0, "unknown")
	eq(Clips.size_text(48_200_000), "48 MB", "size")
	eq(Clips.size_text(1_260_000_000), "1.3 GB", "big")
	_wipe(root)


func test_delete_stays_inside_the_clips_folder() -> void:
	var root := _tmp("del")
	var clip := root + "/Hades/Hades 1.mp4"
	_bytes(clip, _mp4(1.0))
	var img := Image.create_empty(640, 360, false, Image.FORMAT_RGB8)
	ok(Clips.save_thumb(clip, img), "picture saved")
	eq(Image.load_from_file(Clips.thumb_path(clip)).get_width(), Clips.THUMB_W, "scaled to 480 wide")
	var outside := _tmp("outside") + "/keep.mp4"
	_bytes(outside, _mp4(1.0))
	ok(not Clips.delete(root, outside), "never outside the folder")
	ok(not Clips.delete(root, root + "/Hades/../../" + outside.get_file()), "no climbing out")
	ok(Clips.delete(root, clip), "deleted")
	ok(not FileAccess.file_exists(clip) and not FileAccess.file_exists(Clips.thumb_path(clip)), "file and picture gone")
	ok(not DirAccess.dir_exists_absolute(root + "/Hades"), "empty game folder gone")
	ok(FileAccess.file_exists(outside), "the other file is untouched")
	_wipe(root)
	_wipe(outside.get_base_dir())


func test_picks_a_video_player() -> void:
	var root := _tmp("player")
	eq(Clips.find_player("/usr/bin", [], root), {}, "none")
	var vlc := Clips.find_player("/usr/bin", ["org.videolan.VLC"], root)
	eq([vlc["kind"], vlc["name"]], ["flatpak", "VLC"], "VLC flatpak")
	var mpv := Clips.find_player("/usr/bin", ["org.videolan.VLC", Clips.MPV_FLATPAK], root)
	eq(mpv["id"], Clips.MPV_FLATPAK, "mpv first (controller support)")
	_bytes(root + "/usr/bin/flatpak", PackedByteArray([1]))
	var cmd := Clips.play_command(mpv, "/v/a b.mp4", "/usr/bin", root)
	eq(cmd, ["/usr/bin/flatpak", "run", Clips.MPV_FLATPAK, "--fs", "--input-gamepad=yes", "--keep-open=no", "--force-window=yes", "/v/a b.mp4"], "full screen, controller, file as one argument")
	var item := Clips.play_item({"path": "/v/a b.mp4", "game": "Hades"}, cmd)
	eq([item["store"], item["title"], item["installed"]], ["app", "Hades", true], "started like an app")
	ok(str(item["key"]).begins_with("app:clip:"), "its own key")
	eq(Clips.player_install_commands("flatpak")[1], ["flatpak", "install", "--user", "--noninteractive", "-y", "flathub", Clips.MPV_FLATPAK], "mpv for this user, no password")
	_wipe(root)


func test_ffmpeg_makes_missing_pictures() -> void:
	var f: RefCounted = Fake.new()
	f.responses["/usr/bin/ffmpeg*"] = {"code": 0, "out": ""}
	ok(not Clips.make_thumb(f, "", "/v/a.mp4"), "no ffmpeg, no picture")
	Clips.make_thumb(f, "/usr/bin/ffmpeg", "/v/a.mp4")
	ok(f.called("/usr/bin/ffmpeg -nostdin -y -loglevel error -ss 1 -i /v/a.mp4 -frames:v 1 -vf scale=480:-2 " + Clips.thumb_path("/v/a.mp4")), "one frame, 480 wide")


# ---- the phone page --------------------------------------------------------------------

func _req(path: String, headers := {}) -> Dictionary:
	return {"method": "GET", "path": path, "headers": headers, "body": ""}


func test_page_answers() -> void:
	var tok := "a".repeat(32)
	eq(ClipDrop.respond(_req("/c/" + "b".repeat(32)), tok, "Hades", 100)["status"], 404, "wrong token")
	eq(ClipDrop.respond(_req("/"), tok, "Hades", 100)["status"], 404, "anything else")
	eq(ClipDrop.respond({"method": "POST", "path": "/c/" + tok, "headers": {}}, tok, "Hades", 100)["status"], 405, "read only")
	var page := ClipDrop.respond(_req("/c/" + tok), tok, "Hades <3", 100)
	eq(page["status"], 200, "the page")
	var html: String = (page["body"] as PackedByteArray).get_string_from_utf8()
	ok(html.contains("Hades &lt;3") and html.contains("/c/%s/clip.mp4?dl=1" % tok) and html.contains("<video"), "title escaped, Download link, player")
	ok(not html.contains("<script"), "no scripts")
	var whole := ClipDrop.respond(_req("/c/%s/clip.mp4?dl=1" % tok), tok, "Hades", 100)
	eq([whole["status"], whole["range"], whole["full"]], [200, [0, 99], true], "the download")
	ok(str(whole["headers"]["Content-Disposition"]).begins_with("attachment; filename=\"Hades.mp4\""), "saved under its name")
	var seek := ClipDrop.respond(_req("/c/%s/clip.mp4" % tok, {"range": "bytes=10-19"}), tok, "Hades", 100)
	eq([seek["status"], seek["range"], seek["full"], seek["headers"]["Content-Range"]], [206, [10, 19], false, "bytes 10-19/100"], "the player seeks")
	eq(ClipDrop.respond(_req("/c/%s/clip.mp4" % tok, {"range": "bytes=500-"}), tok, "Hades", 100)["status"], 416, "past the end")
	eq(ClipDrop.parse_range("bytes=-10", 100), [90, 99], "suffix")
	eq(ClipDrop.parse_range("bytes=90-", 100), [90, 99], "open end")
	eq(ClipDrop.parse_range("bytes=0-1,5-6", 100), [], "several ranges: the whole file")
	eq(ClipDrop.ascii_name("Ōkami \"HD\""), "_kami _HD_.mp4", "plain file name for old phones")
	var head := ClipDrop.http_head(200, {"Content-Type": "text/html"}, "hi".to_utf8_buffer()).get_string_from_utf8()
	ok(head.contains("Cache-Control: no-store") and head.contains("Referrer-Policy: no-referrer") and head.contains("media-src 'self'"), "no caching, no referrer, own media only")


func test_page_only_on_a_lan_address() -> void:
	var d: Node = ClipDrop.new()
	d.interfaces_fn = func() -> Array: return [{"name": "lo", "addresses": ["127.0.0.1"]}, {"name": "tailscale0", "addresses": ["100.64.0.1"]}]
	var root := _tmp("lan")
	_bytes(root + "/a.mp4", _mp4(1.0))
	ok(not d.start(root + "/a.mp4"), "no Wi-Fi or Ethernet address: no page")
	ok(not d.start(root + "/missing.mp4"), "no file: no page")
	d.free()
	_wipe(root)


## Reads what the server sent until it closes the connection.
func _fetch(d: Node, path: String, extra := "") -> PackedByteArray:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", d.port)
	var sent := false
	var got := PackedByteArray()
	for i in 400:
		d.poll(0.016)
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED and not sent:
			peer.put_data(("GET %s HTTP/1.1\r\nHost: x\r\n%s\r\n" % [path, extra]).to_utf8_buffer())
			sent = true
		if st == StreamPeerTCP.STATUS_CONNECTED and peer.get_available_bytes() > 0:
			var r: Array = peer.get_data(peer.get_available_bytes())
			got.append_array(r[1])
		if sent and (st == StreamPeerTCP.STATUS_NONE or st == StreamPeerTCP.STATUS_ERROR):
			break
		OS.delay_msec(2)
	return got


func test_sends_the_clip_over_the_network_and_closes() -> void:
	var root := _tmp("xfer")
	var data := PackedByteArray()
	data.resize(700_000)
	for i in data.size():
		data[i] = i % 251
	_bytes(root + "/clip.mp4", data)
	var d: Node = ClipDrop.new()
	d.bind_address = "127.0.0.1"
	var done := []
	d.sent.connect(func(): done.append(true))
	ok(d.start(root + "/clip.mp4", "Hades"), "listening")
	ok(d.url.begins_with("http://127.0.0.1:") and d.url.contains("/c/" + d.token), "one-time address")
	var tok: String = d.token
	var page := _fetch(d, "/c/" + tok).get_string_from_utf8()
	ok(page.begins_with("HTTP/1.1 200") and page.contains("Download to this phone"), "the page")
	var part := _fetch(d, "/c/%s/clip.mp4" % tok, "Range: bytes=100-199\r\n")
	var sep := part.find(13, 0)
	var head_end := part.get_string_from_ascii().find("\r\n\r\n")
	ok(part.slice(0, 12).get_string_from_ascii() == "HTTP/1.1 206" and sep > 0, "a range")
	eq(part.slice(head_end + 4), data.slice(100, 200), "the right bytes")
	ok(d.is_running() and done.is_empty(), "watching doesn't close it")
	var whole := _fetch(d, "/c/%s/clip.mp4?dl=1" % tok)
	var end := whole.get_string_from_ascii().find("\r\n\r\n")
	eq(whole.slice(end + 4).size(), data.size(), "every byte")
	eq(whole.slice(end + 4), data, "unchanged")
	eq(done, [true], "sent")
	ok(not d.is_running(), "the page closed after the download")
	d.free()
	_wipe(root)


## Final review, low: the clip page had no idle-socket eviction (eight silent connections kept the
## phone out for good), one wrong-request count for everybody, and a lifetime in frame time.
func test_clip_page_cant_be_shut_by_someone_else_on_the_wifi() -> void:
	var root := _tmp("dos")
	_bytes(root + "/clip.mp4", _mp4(1.0))
	var d: Node = ClipDrop.new()
	d.bind_address = "127.0.0.1"
	var who := ["10.0.0.66"]
	d.peer_address = func(_peer: StreamPeerTCP) -> String: return who[0]
	var now := [5000.0]
	d.clock = func() -> float: return now[0]
	ok(d.start(root + "/clip.mp4", "Hades"), "listening")
	# silent sockets in every slot
	var idle: Array = []
	for i in ClipDrop.MAX_CLIENTS + 2:
		var c := StreamPeerTCP.new()
		c.connect_to_host("127.0.0.1", d.port)
		idle.append(c)
	for i in 50:
		for c in idle:
			c.poll()
		d.poll(0.01)
		OS.delay_msec(2)
	who[0] = "10.0.0.7"
	ok(_fetch(d, "/c/" + d.token).get_string_from_utf8().begins_with("HTTP/1.1 200"), "the phone still gets the page with every slot taken")
	d.poll(ClipDrop.IDLE_TIMEOUT)
	d.poll(0.01)
	eq(d._clients.size(), 0, "silent connections are closed after the idle timeout")
	for c in idle:
		c.disconnect_from_host()
	# wrong requests from one device hold off that device only
	who[0] = "10.0.0.66"
	for i in KeyDrop.MAX_BAD:
		_fetch(d, "/c/guess")
	ok(d.throttled("10.0.0.66") and not d.throttled("10.0.0.7"), "the guessing device is held off, the phone isn't")
	eq(_fetch(d, "/c/" + d.token).size(), 0, "the guessing device gets no answer")
	who[0] = "10.0.0.7"
	ok(_fetch(d, "/c/" + d.token).get_string_from_utf8().begins_with("HTTP/1.1 200"), "the phone still gets the page")
	# the lifetime runs by the clock
	var why := []
	d.expired.connect(func(w): why.append(w))
	now[0] += 700.0
	d.poll(0.016)
	eq(why, ["timeout"], "closed by the clock (a sleep counts)")
	d.free()
	_wipe(root)


## A download that stops taking bytes gives its slot and the file back (and no longer keeps the
## page from closing).
func test_a_stalled_download_is_closed() -> void:
	var root := _tmp("stall")
	var data := PackedByteArray()
	data.resize(8_000_000)
	_bytes(root + "/clip.mp4", data)
	var d: Node = ClipDrop.new()
	d.bind_address = "127.0.0.1"
	ok(d.start(root + "/clip.mp4"), "listening")
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", d.port)
	var asked := false
	for i in 300:
		d.poll(0.016)
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED and not asked:
			peer.put_data(("GET /c/%s/clip.mp4?dl=1 HTTP/1.1\r\nHost: x\r\n\r\n" % d.token).to_utf8_buffer())
			asked = true
		if asked and d._clients.size() == 1 and d._clients[0]["file"] != null and i > 150:
			break
		OS.delay_msec(2)
	eq(d._clients.size(), 1, "a download is under way and the phone has stopped reading")
	ok(d._clients[0]["file"] != null, "the file is open for it")
	d.poll(ClipDrop.STALL_TIMEOUT)
	d.poll(0.016)
	eq(d._clients.size(), 0, "no bytes taken for the stall timeout: closed")
	ok(d.is_running(), "the page itself stays for the phone to try again")
	peer.disconnect_from_host()
	d.free()
	_wipe(root)


func test_page_times_out() -> void:
	var root := _tmp("timeout")
	_bytes(root + "/clip.mp4", _mp4(1.0))
	var d: Node = ClipDrop.new()
	d.bind_address = "127.0.0.1"
	d.lifetime = 1.0
	var why := []
	d.expired.connect(func(w): why.append(w))
	d.start(root + "/clip.mp4")
	d.poll(0.6)
	ok(d.is_running(), "still open")
	d.poll(0.6)
	eq(why, ["timeout"], "closed after its lifetime")
	ok(not d.is_running(), "closed")
	d.free()
	_wipe(root)


# ---- Settings > Media ------------------------------------------------------------------

class FakeRec extends Node:
	signal saved(path: String, info: Dictionary)
	var opts := {"audio": true, "fps": 60}
	var ready_set: Array = []

	func options() -> Dictionary:
		return opts

	func set_option(k: String, v: Variant) -> bool:
		opts[k] = v
		return true

	func set_ready(r: bool) -> void:
		ready_set.append(r)


class FakeHost extends Control:
	var launched: Array = []
	var notes: Array = []

	func request_app_launch(app: Dictionary) -> void:
		launched.append(app)

	func notify(text: String, tone := "") -> void:
		notes.append([text, tone])


func _page(home: String, f: RefCounted, root: String, rec: Node, host: Control) -> VBoxContainer:
	var p: VBoxContainer = MediaPage.new()
	p.setup("media", {"recording": rec, "media_runner": f, "media_env": {"home": home, "path_env": "/usr/bin", "sys_root": root},
		"drop_bind": "127.0.0.1"}, host)
	return p


func _rec_row(p: Node) -> Node:
	return p.rows.get("rec_status")


func test_media_page_walks_through_install_set_up_and_ready() -> void:
	var home := _tmp("media")
	var root := home + "/root"
	_bytes(root + "/usr/bin/flatpak", PackedByteArray([1]))
	var f: RefCounted = Fake.new()
	f.responses["/usr/bin/flatpak list --app --columns=application"] = {"code": 0, "out": "org.videolan.VLC\n"}
	f.responses["/usr/bin/flatpak remotes --system --columns=name"] = {"code": 0, "out": "flathub\n"}
	f.responses["/usr/bin/flatpak install --system --noninteractive -y flathub " + Recorder.FLATPAK_ID] = {"code": 0, "out": ""}
	var rec := FakeRec.new()
	var host := FakeHost.new()
	var p := _page(home, f, root, rec, host)
	eq(p.next_step(), "checking", "before the first read")
	p.on_shown()
	eq(p.next_step(), "install", "not installed: offer it")
	eq(_rec_row(p).title_label.text, TX.MEDIA_INSTALL, "Install GPU Screen Recorder")
	ok(p.find_child("ClipsEmpty", true, false) != null, "no clips yet")
	# installing: the fake makes the system flatpak appear
	f.handler = func(cmd: String):
		if cmd.begins_with("/usr/bin/flatpak install --system"):
			DirAccess.make_dir_recursive_absolute(root + Recorder.SYSTEM_APP_DIR)
			return {"code": 0, "out": ""}
		if cmd == Recorder.KMS_PROXY + " is-setup " + home:
			return {"code": 0 if FileAccess.file_exists(home + "/.setup") else 1, "out": ""}
		if cmd == Recorder.KMS_PROXY + " setup-gsr-ui " + home:
			return {"code": 127, "out": "Error executing command as another user: No authentication agent found."}
		return null
	p.press_recorder()
	ok(f.called("/usr/bin/flatpak install --system --noninteractive -y flathub " + Recorder.FLATPAK_ID), "system-wide install")
	eq(host.notes[0], [TX.MEDIA_INSTALLED, "good"], "installed")
	eq(p.next_step(), "setup", "then the one-time OK")
	eq(rec.ready_set.back(), false, "the quick menu learns it needs set-up")
	p.press_recorder()
	ok(f.called(Recorder.KMS_PROXY + " setup-gsr-ui " + home), "the official set-up")
	eq(host.notes.back(), [TX.MEDIA_SETUP_DESKTOP, "bad"], "Gaming Mode can't ask for the password: say Desktop Mode")
	_bytes(home + "/.setup", PackedByteArray([1]))
	p.refresh()
	eq(p.next_step(), "ready", "ready once allowed")
	eq(_rec_row(p).value_label.text, TX.MEDIA_READY, "Ready")
	eq(rec.ready_set.back(), true, "and the quick menu can record")
	p.rows["rec_fps"].changed.emit(30)
	eq(rec.opts["fps"], 30, "frame rate saved")
	p.free()
	host.free()
	rec.free()
	_wipe(home)


func test_install_without_permission_points_to_desktop_mode() -> void:
	ok(MediaPage.install_needs_desktop("error: Flatpak system operation Deploy not allowed for user"), "polkit refused")
	ok(not MediaPage.install_needs_desktop("error: Unable to connect to system bus"), "other errors shown as they are")


func test_media_page_lists_clips_and_acts_on_them() -> void:
	var home := _tmp("mclips")
	var root := home + "/root"
	_bytes(root + "/usr/bin/flatpak", PackedByteArray([1]))
	DirAccess.make_dir_recursive_absolute(root + Recorder.SYSTEM_APP_DIR)
	var clip := home + "/Videos/GameCove/Hades/Hades 2026-11-10 15-04-09.mp4"
	_bytes(clip, _mp4(65.0))
	Clips.save_thumb(clip, Image.create_empty(320, 180, false, Image.FORMAT_RGB8))
	var f: RefCounted = Fake.new()
	f.responses[Recorder.KMS_PROXY + " is-setup " + home] = {"code": 0, "out": ""}
	f.responses["/usr/bin/flatpak list --app --columns=application"] = {"code": 0, "out": Clips.MPV_FLATPAK + "\n"}
	var host := FakeHost.new()
	var rec := FakeRec.new()
	var p := _page(home, f, root, rec, host)
	p.on_shown()
	eq(p.clip_rows.size(), 1, "one clip")
	var row: Node = p.clip_rows[0]
	ok(row.has_picture(), "with its picture")
	ok(row.meta_label.text.contains("1:05"), "and its length: " + row.meta_label.text)
	var items := MediaPage.clip_items(row.clip, p.state["player"])
	eq(items.map(func(i): return i["id"]), ["play", "share", "delete"], "watch, send, delete")
	eq(MediaPage.clip_items(row.clip, {}).map(func(i): return i["id"])[0], "get_player", "no player: get one")
	p.act(row.clip, "play")
	eq(host.launched.size(), 1, "the player starts like an app")
	eq(host.launched[0]["exec"].back(), clip, "on this clip")
	p.act(row.clip, "share")
	ok(p.share != null and p.share.is_open(), "QR page open")
	ok(str(p.share.drop.url).begins_with("http://127.0.0.1:"), "on the LAN address")
	ok(p.share.qr_rect.texture != null, "QR code shown")
	p.share.close()
	ok(not p.share.drop.is_running(), "closing the sheet closes the page")
	p.act(row.clip, "delete_yes")
	ok(not FileAccess.file_exists(clip), "deleted")
	eq(p.clip_rows.size(), 0, "gone from the list")
	ok(p.find_child("ClipsEmpty", true, false) != null, "empty note")
	p.free()
	host.free()
	rec.free()
	_wipe(home)


## Review 3, medium 3: deleting the focused clip moves focus to the next clip.
func test_deleting_a_focused_clip_keeps_focus() -> void:
	var home := _tmp("mclipsfocus")
	var root := home + "/root"
	_bytes(root + "/usr/bin/flatpak", PackedByteArray([1]))
	DirAccess.make_dir_recursive_absolute(root + Recorder.SYSTEM_APP_DIR)
	var a := home + "/Videos/GameCove/Hades/Hades 2026-11-10 15-04-09.mp4"
	var b := home + "/Videos/GameCove/Hades/Hades 2026-11-09 15-04-09.mp4"
	_bytes(a, _mp4(65.0))
	_bytes(b, _mp4(30.0))
	var f: RefCounted = Fake.new()
	f.responses[Recorder.KMS_PROXY + " is-setup " + home] = {"code": 0, "out": ""}
	var host := FakeHost.new()
	var rec := FakeRec.new()
	var p := _page(home, f, root, rec, host)
	p.on_shown()
	eq(p.clip_rows.size(), 2, "two clips")
	p.set_meta(preload("res://scripts/ui/keep_focus.gd").TEST_META, p.clip_rows[0].button)
	p.act(p.clip_rows[0].clip, "delete_yes")
	eq(p.clip_rows.size(), 1, "one left")
	var now: Control = p.get_meta(preload("res://scripts/ui/keep_focus.gd").TEST_META)
	ok(is_instance_valid(now) and now == p.clip_rows[0].button, "focus on the clip left")
	p.free()
	host.free()
	rec.free()
	_wipe(home)
