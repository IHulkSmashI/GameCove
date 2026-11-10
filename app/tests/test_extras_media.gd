extends "res://tests/test_case.gd"
## Media controls: scripts/system/media.gd over a fake session bus (busctl
## answers as systemd 255 prints them) and the quick menu's Now playing card.
## Nothing real runs.

const Media := preload("res://scripts/system/media.gd")
const MediaCard := preload("res://scripts/ui/controls/media_card.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")

const LIST := "busctl --user call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ListNames"
const SPOT := "org.mpris.MediaPlayer2.spotify"
const FOX := "org.mpris.MediaPlayer2.firefox.instance_1_42"


class Reg extends RefCounted:
	var ctx := {}
	func run_on_worker(job: Callable) -> void:
		job.call()


func _prop(player: String, iface: String, prop: String) -> String:
	return "busctl --user get-property %s /org/mpris/MediaPlayer2 %s %s" % [player, iface, prop]


func _fake(spotify_status := "Paused", firefox_status := "Playing") -> RefCounted:
	var f: RefCounted = Fake.new()
	f.responses[LIST] = {"code": 0, "out": JSON.stringify({"type": "as", "data": [["org.freedesktop.DBus", ":1.12", SPOT, FOX]]})}
	var p := "org.mpris.MediaPlayer2.Player"
	f.responses[_prop(SPOT, p, "PlaybackStatus")] = {"code": 0, "out": JSON.stringify({"type": "s", "data": spotify_status})}
	f.responses[_prop(SPOT, p, "Metadata")] = {"code": 0, "out": JSON.stringify({"type": "a{sv}", "data": {
		"xesam:title": {"type": "s", "data": "Midnight City"}, "xesam:artist": {"type": "as", "data": ["M83", " "]},
		"xesam:album": {"type": "s", "data": "Hurry Up, We're Dreaming"}}})}
	f.responses[_prop(SPOT, "org.mpris.MediaPlayer2", "Identity")] = {"code": 0, "out": JSON.stringify({"type": "s", "data": "Spotify"})}
	f.responses[_prop(SPOT, p, "CanGoNext")] = {"code": 0, "out": JSON.stringify({"type": "b", "data": true})}
	f.responses[_prop(SPOT, p, "CanGoPrevious")] = {"code": 0, "out": JSON.stringify({"type": "b", "data": false})}
	f.responses[_prop(FOX, p, "PlaybackStatus")] = {"code": 0, "out": JSON.stringify({"type": "s", "data": firefox_status})}
	f.responses[_prop(FOX, p, "Metadata")] = {"code": 0, "out": JSON.stringify({"type": "a{sv}", "data": {"xesam:title": {"type": "s", "data": "Lo-fi beats"}}})}
	f.responses["busctl --user call %s /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player PlayPause" % SPOT] = {"code": 0, "out": ""}
	return f


func test_players_are_the_mpris_names() -> void:
	eq(Media.players(_fake()), [FOX, SPOT], "media players only, sorted")
	eq(Media.players(Fake.new()), [], "no session bus: none")
	eq(Media.players(null), [], "no runner")


func test_metadata_parsing() -> void:
	var m := Media.parse_metadata({"xesam:title": {"type": "s", "data": " Song "}, "xesam:artist": {"type": "as", "data": ["A", "B"]}})
	eq(m, {"title": "Song", "artist": "A, B", "album": ""}, "title and artists")
	eq(Media.parse_metadata(null), {"title": "", "artist": "", "album": ""}, "nothing")
	eq(Media.app_from_name(FOX), "Firefox", "name from the bus name when Identity is missing")


func test_playing_beats_paused() -> void:
	var st := Media.now_playing(_fake())
	eq(st["player"], FOX, "the one playing wins")
	eq(st["app"], "Firefox", "app named from its bus name")
	eq(st["title"], "Lo-fi beats", "title")
	var st2 := Media.now_playing(_fake("Paused", "Stopped"))
	eq(st2["player"], SPOT, "paused beats stopped")
	eq(st2["app"], "Spotify", "Identity")
	eq(st2["artist"], "M83", "blank artist dropped")
	eq(st2["can_prev"], false, "can't go back")
	eq(st2["can_next"], true, "can skip")
	eq(Media.now_playing(Fake.new()), {}, "nothing running")


func test_send_only_known_actions() -> void:
	var f := _fake()
	ok(Media.send(f, SPOT, "PlayPause"), "play/pause sent")
	ok(f.called("busctl --user call %s /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player PlayPause" % SPOT), "over MPRIS")
	ok(not Media.send(f, SPOT, "Quit"), "nothing else")
	ok(not Media.send(f, "org.freedesktop.systemd1", "Next"), "only media players")
	ok(not Media.send(f, SPOT, "Next"), "a failed call says so")


func test_card_shows_and_presses() -> void:
	var r := Reg.new()
	r.ctx = {"runner": _fake("Paused", "Stopped")}
	var c: PanelContainer = MediaCard.new()
	c.setup(r)
	ok(c.visible, "shown while a player runs")
	eq((c.find_child("MediaTitle", true, false) as Label).text, "Midnight City", "song title")
	eq((c.find_child("MediaArtist", true, false) as Label).text, "M83", "artist")
	ok(c.buttons["Previous"].disabled, "previous greyed when the player can't")
	eq(c.buttons["PlayPause"].tooltip_text, TX.MEDIA_PLAY, "paused: Play")
	eq(c.focusables(), [c.buttons["PlayPause"]], "one stop in the up/down chain")
	ok(c.find_child("MediaHelp", true, false) != null, "one plain help line")
	var got := []
	c.failed.connect(func(t): got.append(t))
	c.press("PlayPause")
	eq(got, [], "press went through")
	c.press("Next")
	eq(got, [TX.MEDIA_FAILED % "Spotify"], "a refused press says so")
	c.free()


func test_card_hidden_with_nothing_playing() -> void:
	var r := Reg.new()
	r.ctx = {"runner": Fake.new()}
	var c: PanelContainer = MediaCard.new()
	c.setup(r)
	ok(not c.visible, "hidden")
	eq(c.focusables(), [], "not focusable")
	c.free()
	var c2: PanelContainer = MediaCard.new()
	c2.setup(null)
	ok(not c2.visible and not c2.supported(), "no registry: hidden")
	c2.free()


func test_quick_menu_audio_tab_has_the_card() -> void:
	var text := FileAccess.get_file_as_string("res://scripts/ui/quick_menu.gd")
	ok(text.contains("MediaCard.new()"), "Audio tab builds Now playing")
