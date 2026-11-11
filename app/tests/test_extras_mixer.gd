extends "res://tests/test_case.gd"
## Per-app volume: providers/audio.gd app_mixer() over the fake PipeWire, and
## the mixer widget (ui/controls/app_mixer.gd) in the quick menu's Audio tab and
## in Settings > Sound, through a real Controls registry in sync mode.

const Env := preload("res://tests/fixtures/ctl_display/env.gd")
const AudioProvider := preload("res://scripts/controls/providers/audio.gd")
const ControlsScript := preload("res://scripts/controls/controls.gd")
const AppMixer := preload("res://scripts/ui/controls/app_mixer.gd")
const GroupPage := preload("res://scripts/ui/controls/group_page.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")


func _env(name: String) -> Dictionary:
	var s := Env.make(name, "steam-deck-oled")
	s.fake.sinks = [{"id": 48, "name": "Speaker", "volume": 0.4, "muted": false}]
	s.fake.default_sink = 48
	s.fake.streams = [{"id": 70, "name": "Hades II", "volume": 1.0},
		{"id": 71, "name": "Spotify", "volume": 0.5, "muted": true},
		{"id": 72, "name": "Spotify", "volume": 0.25}]
	var reg: Node = ControlsScript.new()
	reg.sync_mode = true
	reg.setup(s.ctx)
	reg.register_provider(AudioProvider.new())
	s["reg"] = reg
	return s


func test_app_mixer_lists_apps_with_volume() -> void:
	var s := _env("mixer_list")
	var apps: Array = AudioProvider.new().app_mixer(s.ctx)
	eq(apps.size(), 3, "three apps")
	eq(apps[0], {"id": 70, "name": "Hades II", "stream": "Hades II", "volume": 100.0, "muted": false}, "the game")
	eq(apps[1]["name"], "Spotify", "first Spotify")
	eq(apps[1]["muted"], true, "muted")
	eq(apps[2]["name"], "Spotify 2", "a second app with the same name is told apart")
	eq(apps[2]["volume"], 25.0, "25 %")
	s.reg.free()


func test_app_mixer_empty_without_pipewire() -> void:
	var s := _env("mixer_nopw")
	s.fake.wpctl_ok = false
	eq(AudioProvider.new().app_mixer(s.ctx), [], "no wpctl, no apps")
	eq(AudioProvider.new().app_mixer({}), [], "no runner")
	s.reg.free()


func test_widget_rows_and_volume_change() -> void:
	var s := _env("mixer_widget")
	var m: VBoxContainer = AppMixer.new()
	m.setup(s.reg)
	ok(m.supported(), "real audio provider found through audio.volume")
	ok(m.visible, "shown")
	eq(m.rows.size(), 3, "one slider per app")
	eq(m.focusables().size(), 3, "each slider is in the focus chain")
	eq(m.rows[0].title_label.text, "Hades II", "named after the app")
	eq(m.rows[0].hint_text(), TX.MIXER_HELP, "one plain help line")
	m.set_volume(70, 30.0)
	eq(s.fake.streams[0]["volume"], 0.3, "the game's stream turned down")
	eq(s.fake.sinks[0]["volume"], 0.4, "main volume untouched")
	m.rows[2].changed.emit(60.0)
	eq(s.fake.streams[2]["volume"], 0.6, "slider change reaches the right app")
	m.free()
	s.reg.free()


func test_widget_empty_and_failed() -> void:
	var s := _env("mixer_empty")
	s.fake.streams = []
	var m: VBoxContainer = AppMixer.new()
	m.setup(s.reg)
	ok(m.find_child("MixerEmpty", true, false) != null, "says nothing is playing")
	eq(m.focusables(), [], "nothing to focus")
	var got := []
	m.failed.connect(func(t): got.append(t))
	m.set_volume(99, 50.0)
	eq(got, [TX.MIXER_FAILED], "a vanished app says so")
	m.free()
	s.reg.free()


## Final review (Low): the mixer reads once; PipeWire reuses a finished stream's
## id, so a slider moved later could set another app's volume.
func test_a_stale_stream_id_never_sets_another_apps_volume() -> void:
	var s := _env("mixer_stale")
	var m: VBoxContainer = AppMixer.new()
	m.setup(s.reg)
	eq(m.rows[1].title_label.text, "Spotify", "the row was built for Spotify (id 71)")
	# Spotify stops; a call starts and PipeWire gives it id 71
	s.fake.streams = [{"id": 70, "name": "Hades II", "volume": 1.0}, {"id": 71, "name": "Discord", "volume": 0.8}]
	var got := []
	m.failed.connect(func(t): got.append(t))
	m.rows[1].changed.emit(10.0)
	eq(s.fake.streams[1]["volume"], 0.8, "the other app's volume is left alone")
	eq(got, [TX.MIXER_FAILED], "the row says its app stopped playing")
	eq(m.rows.map(func(r): return r.title_label.text), ["Hades II", "Discord"], "and the list is read again")
	m.rows[1].changed.emit(10.0)
	eq(s.fake.streams[1]["volume"], 0.1, "the new row sets its own app")
	# an id that now belongs to a device, not an app
	s.fake.streams = [{"id": 70, "name": "Hades II", "volume": 1.0}]
	var p := AudioProvider.new()
	ok(not p.set_app_volume(s.ctx, 48, "Speaker", 5.0), "a sink's id is never an app's")
	eq(s.fake.sinks[0]["volume"], 0.4, "main volume untouched")
	ok(p.set_app_volume(s.ctx, 70, "Hades II", 50.0), "the same app still works")
	eq(s.fake.streams[0]["volume"], 0.5, "set")
	m.free()
	s.reg.free()


func test_widget_hidden_without_provider() -> void:
	var m: VBoxContainer = AppMixer.new()
	m.setup(null)
	ok(not m.supported() and not m.visible, "no registry: hidden")
	eq(m.focusables(), [], "no focus")
	m.free()


func test_sound_page_has_the_mixer_card() -> void:
	var s := _env("mixer_page")
	var page: VBoxContainer = GroupPage.new()
	page.lazy = false
	page.setup("audio", {"controls": s.reg}, null)
	ok(page.extras.size() == 1, "Sound gets the Apps card")
	var ids: Array = page.focusables().filter(func(f): return f is HSlider and String(f.get_parent().get_parent().get_parent().name).begins_with("app_volume_"))
	eq(ids.size(), 3, "app sliders in the page's focus chain")
	page.free()
	s.reg.free()


func test_quick_menu_audio_tab_has_the_mixer() -> void:
	var text := FileAccess.get_file_as_string("res://scripts/ui/quick_menu.gd")
	ok(text.contains("\"audio\": _build_audio()") and text.contains("AppMixer.new()"), "Audio tab builds the per-app mixer")
