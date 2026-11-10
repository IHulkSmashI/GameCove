extends VBoxContainer
## Per-app volume: one slider per app playing or recording sound, from
## PipeWire (providers/audio.gd app_mixer / set_stream_volume through the
## Controls worker, so wpctl never runs on the main thread). Shown in the quick
## menu's Audio tab and in Settings > Sound.
##
## Reads once when built (and on refresh()): no polling, so it costs nothing
## behind a game. An app that starts playing later shows up the next time the
## tab opens.
##
## registry: the Controls autoload or a fake with has(), control(), ctx and
## run_on_worker(). Without a per-app capable audio provider the widget stays
## empty and hidden.

signal rebuilt
## A change didn't take (the app stopped playing): text for a toast.
signal failed(text: String)

const SliderRow := preload("res://scripts/ui/slider_row.gd")
const Kit := preload("res://scripts/ui/ui_kit.gd")
const ThemeLib := preload("res://theme/gamecove_theme.gd")
const TX := preload("res://scripts/ui/texts_extras.gd")
const KeepFocus := preload("res://scripts/ui/keep_focus.gd")
const CardJobs := preload("res://scripts/system/card_jobs.gd")

var registry: Object
var provider: Object
## [{"id", "name", "volume", "muted"}] from the last read.
var apps: Array = []
var rows: Array = []
var loaded := false
## The small "APPS" heading above the rows (off inside a card that has a title).
var show_title := true
var _gen := 0


func setup(reg: Object, row_name := "AppMixer") -> void:
	name = row_name
	registry = reg
	provider = provider_of(reg)
	add_theme_constant_override("separation", 8)
	visible = supported()
	refresh()


## The audio provider behind audio.volume, when it can list apps.
static func provider_of(reg: Object) -> Object:
	if reg == null or not reg.has_method("has") or not reg.has_method("control") or not reg.has("audio.volume"):
		return null
	var c: Object = reg.control("audio.volume")
	if c == null or not c.has_meta("provider"):
		return null
	var p: Object = c.get_meta("provider")
	return p if p != null and p.has_method("app_mixer") and p.has_method("set_stream_volume") else null


func supported() -> bool:
	return provider != null and registry.has_method("run_on_worker") and "ctx" in registry


## Reads the apps again (on the Controls worker); the rows follow.
func refresh() -> void:
	if not supported():
		_show([])
		return
	_gen += 1
	var gen := _gen
	var p: Object = provider
	var ctx: Dictionary = registry.ctx
	var me := get_instance_id()
	var courier: RefCounted = CardJobs.shared()
	registry.run_on_worker(func():
		var list: Array = p.app_mixer(ctx)
		# the worker never touches the widget: it's looked up on the main thread
		courier.hand_back(me, "_on_apps", [gen, list]))


func _on_apps(gen: int, list: Array) -> void:
	if gen != _gen:
		return
	_show(list)


func _show(list: Array) -> void:
	apps = list
	loaded = true
	var mark := KeepFocus.mark(self, focusables())
	for c in get_children():
		remove_child(c)
		c.queue_free()
	rows.clear()
	if not supported():
		visible = false
		rebuilt.emit()
		KeepFocus.restore(self, mark, [])
		return
	visible = true
	if show_title:
		var head := Kit.micro(TX.MIXER_TITLE.to_upper())
		head.name = "MixerTitle"
		head.add_theme_color_override("font_color", ThemeLib.color("text_3"))
		add_child(head)
	if list.is_empty():
		var e := Kit.label(TX.MIXER_EMPTY, "QuietLabel", true)
		e.name = "MixerEmpty"
		add_child(e)
	for a in list:
		var r: VBoxContainer = SliderRow.new()
		r.setup("app_volume_%d" % int(a["id"]), str(a["name"]), 0.0, 100.0, float(a["volume"]), 5.0, "%")
		r.set_hint(TX.MIXER_HELP)
		var id := int(a["id"])
		r.changed.connect(func(v: float): set_volume(id, v))
		add_child(r)
		rows.append(r)
	rebuilt.emit()
	# a refresh freed the focused slider: the same app's, or the nearest one, or
	# what came before the mixer (an app that stopped playing was the last)
	KeepFocus.restore(self, mark, focusables())


## Sets one app's volume on the Controls worker (tests: sync registry).
func set_volume(stream_id: int, pct: float) -> void:
	if not supported():
		return
	for a in apps:
		if int(a["id"]) == stream_id:
			a["volume"] = pct
	var p: Object = provider
	var ctx: Dictionary = registry.ctx
	var me := get_instance_id()
	var courier: RefCounted = CardJobs.shared()
	registry.run_on_worker(func():
		if not p.set_stream_volume(ctx, stream_id, pct):
			courier.hand_back(me, "_on_failed", []))


func _on_failed() -> void:
	failed.emit(TX.MIXER_FAILED)


func focusables() -> Array:
	return rows.map(func(r): return r.slider)
