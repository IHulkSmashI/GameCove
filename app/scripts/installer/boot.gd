extends Node
## First scene. Picks what GameCove starts as, then gets out of the way:
##   gamecove.x86_64 -- --installer   the installer (scenes/installer.tscn)
##   gamecove.x86_64 --headless -- --controls ...
##                                    hardware-test access to Controls (controls_cli.gd)
##   gamecove.x86_64 --headless -- --prefetch-photo
##                                    fetch this handheld's real photo into the cache
##                                    and quit (get-gamecove.sh --no-launch), so it shows
##                                    on the first, possibly offline, start
##   anything else                    the home screen (scenes/main.tscn)
## User arguments come after `--` (OS.get_cmdline_user_args(), the same in an
## exported binary). Kept apart from main.gd so the shell stays untouched.
##
## On a normal start it also hands a leftover pending-choices file to
## gamecove-apply-choices (the installer's startup choice, when the login unit
## didn't get to it), in the background.

const MAIN := "res://scenes/main.tscn"
const INSTALLER := "res://scenes/installer.tscn"
const Paths := preload("res://scripts/installer/paths.gd")
const ControlsCli := preload("res://scripts/hwtest/controls_cli.gd")


static func wants_installer(args: PackedStringArray) -> bool:
	return "--installer" in args


static func wants_controls_cli(args: PackedStringArray) -> bool:
	return "--controls" in args


static func wants_photo_prefetch(args: PackedStringArray) -> bool:
	return "--prefetch-photo" in args


static func scene_for(args: PackedStringArray) -> String:
	return INSTALLER if wants_installer(args) else MAIN


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if wants_controls_cli(args):
		var cli: Node = ControlsCli.new()
		cli.name = "ControlsCli"
		cli.args = args
		add_child(cli)
		return
	if wants_photo_prefetch(args):
		prefetch_photo_and_quit(get_node_or_null("/root/DevicePhoto"), get_tree())
		return
	var scene := scene_for(args)
	if scene == MAIN:
		apply_pending(Paths.new())
	get_tree().change_scene_to_file.call_deferred(scene)


## Headless: DevicePhoto.prefetch_detected(), then quit once the picture is in
## (photo_ready) or after PREFETCH_WAIT_S, whichever comes first. Exit code 0
## when the photo is cached, 1 otherwise (offline, switched off, no source).
const PREFETCH_WAIT_S := 30.0

static func prefetch_photo_and_quit(ph: Node, tree: SceneTree) -> void:
	if ph == null or not ph.has_method("prefetch_detected") or not ph.prefetch_detected():
		tree.quit(1)
		return
	var dev := tree.root.get_node_or_null("Device")
	var id := str(dev.id()) if dev != null and dev.has_method("id") else ""
	if ph.has_cached(id):
		tree.quit(0)
		return
	ph.photo_ready.connect(func(_d, _p): tree.quit(0))
	tree.create_timer(PREFETCH_WAIT_S).timeout.connect(func(): tree.quit(0 if ph.has_cached(id) else 1))


## Runs gamecove-apply-choices when choices wait and the package is live. Never blocks.
static func apply_pending(paths: RefCounted) -> bool:
	if not FileAccess.file_exists(paths.pending_file()) or not FileAccess.file_exists(paths.apply_helper()):
		return false
	return OS.create_process(paths.apply_helper(), PackedStringArray()) > 0
