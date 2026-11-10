extends RefCounted
## Media controls for music and video apps (Spotify, a browser, VLC, ...)
## through MPRIS, the standard every Linux media player speaks on the session
## bus. busctl (systemd) does the D-Bus calls, so nothing extra is needed; the
## same approach as the MusicControl Decky plugin, without the plugin.
##
## Everything blocks on busctl: call from a worker (the Controls worker in the
## quick menu), never the main thread. Nothing here polls: the quick menu reads
## once when the Audio tab opens and again after a button press.

const Busctl := preload("res://scripts/device/busctl.gd")

const PREFIX := "org.mpris.MediaPlayer2."
const PATH := "/org/mpris/MediaPlayer2"
const ROOT_IFACE := "org.mpris.MediaPlayer2"
const PLAYER_IFACE := "org.mpris.MediaPlayer2.Player"
## The only methods the UI sends.
const ACTIONS := ["PlayPause", "Next", "Previous"]


static func _bus(runner: RefCounted) -> RefCounted:
	return Busctl.new(runner, "--user")


## Bus names of every media player running now, sorted (one per player instance).
static func players(runner: RefCounted) -> Array:
	var out := []
	if runner == null:
		return out
	var r: Variant = _bus(runner).call_method("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames")
	if not r is Array or (r as Array).is_empty() or not r[0] is Array:
		return out
	for n in r[0]:
		if str(n).begins_with(PREFIX):
			out.append(str(n))
	out.sort()
	return out


## Unwraps busctl's {"type": ..., "data": ...} variants.
static func _v(x: Variant) -> Variant:
	return x.get("data") if x is Dictionary and x.has("type") and x.has("data") else x


## {"title", "artist", "album"} from an MPRIS Metadata dictionary (busctl JSON).
static func parse_metadata(meta: Variant) -> Dictionary:
	var out := {"title": "", "artist": "", "album": ""}
	if not meta is Dictionary:
		return out
	out["title"] = str(_v(meta.get("xesam:title", ""))).strip_edges()
	out["album"] = str(_v(meta.get("xesam:album", ""))).strip_edges()
	var artist: Variant = _v(meta.get("xesam:artist", []))
	if artist is Array:
		out["artist"] = ", ".join(PackedStringArray(artist.map(func(a): return str(a).strip_edges()).filter(func(a): return a != "")))
	else:
		out["artist"] = str(artist).strip_edges()
	return out


## One player's state: {"player", "app", "status" (Playing / Paused / Stopped),
## "title", "artist", "album", "can_next", "can_prev"}; {} when it doesn't answer.
static func player_state(runner: RefCounted, player: String) -> Dictionary:
	var bus := _bus(runner)
	var status: Variant = bus.get_prop(player, PATH, PLAYER_IFACE, "PlaybackStatus")
	if status == null:
		return {}
	var st := parse_metadata(bus.get_prop(player, PATH, PLAYER_IFACE, "Metadata"))
	var app: Variant = bus.get_prop(player, PATH, ROOT_IFACE, "Identity")
	st["player"] = player
	st["app"] = str(app) if app != null and str(app) != "" else app_from_name(player)
	st["status"] = str(status)
	st["can_next"] = bus.get_prop(player, PATH, PLAYER_IFACE, "CanGoNext") != false
	st["can_prev"] = bus.get_prop(player, PATH, PLAYER_IFACE, "CanGoPrevious") != false
	return st


## "org.mpris.MediaPlayer2.spotify" -> "Spotify"; "...firefox.instance_1_23" -> "Firefox".
static func app_from_name(player: String) -> String:
	var n := player.trim_prefix(PREFIX).get_slice(".", 0)
	return n.capitalize() if n != "" else player


## The player to show: the one playing, else a paused one, else the first that
## answers. {} when no media app is running.
static func now_playing(runner: RefCounted) -> Dictionary:
	var paused := {}
	var other := {}
	for p in players(runner):
		var st := player_state(runner, p)
		if st.is_empty():
			continue
		match st["status"]:
			"Playing":
				return st
			"Paused":
				if paused.is_empty():
					paused = st
			_:
				if other.is_empty():
					other = st
	return paused if not paused.is_empty() else other


## Sends PlayPause / Next / Previous to one player. False for anything else or
## when the player didn't take it.
static func send(runner: RefCounted, player: String, action: String) -> bool:
	if runner == null or not action in ACTIONS or not player.begins_with(PREFIX):
		return false
	# no reply value, so busctl prints nothing: the exit code says it all
	var r: Dictionary = runner.run("busctl", PackedStringArray(["--user", "--timeout=2", "call", player, PATH, PLAYER_IFACE, action]))
	return int(r.get("code", -1)) == 0
