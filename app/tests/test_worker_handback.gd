extends "res://tests/test_case.gd"
## Review 3, low 6: worker threads resolved a Node from a WeakRef and called it
## (app mixer, Now playing, Bluetooth, GE-Proton): the main thread could free the
## node in between. Workers now carry only an instance id; card_jobs.gd looks it
## up on the main thread (hand_back / run_for / channel jobs).

const CardJobs := preload("res://scripts/system/card_jobs.gd")
const AppMixer := preload("res://scripts/ui/controls/app_mixer.gd")
const MixerT := preload("res://tests/test_extras_mixer.gd")


class _Sub extends Node:
	var got: Array = []
	var threads: Array = []
	func take(v: Variant) -> void:
		got.append(v)
		threads.append(OS.get_thread_caller_id())


func test_hand_back_resolves_on_the_main_thread() -> void:
	var jobs: RefCounted = CardJobs.new()
	var alive := _Sub.new()
	var gone := _Sub.new()
	var gone_id := gone.get_instance_id()
	var t := Thread.new()
	t.start(func():
		jobs.hand_back(alive.get_instance_id(), "take", [1])
		jobs.hand_back(gone_id, "take", [2]))
	t.wait_to_finish()
	eq(alive.got, [], "nothing ran on the worker")
	gone.free()   # freed before the main thread got to it
	jobs._drain()   # the next frame
	eq(alive.got, [1], "delivered")
	eq(alive.threads, [OS.get_main_thread_id()], "on the main thread")
	ok(instance_from_id(gone_id) == null, "the freed one was skipped without an error")
	alive.free()


## A registry whose worker is a real thread (the Controls worker in the app).
class ThreadedRegistry extends Node:
	var inner: Node
	var ctx: Dictionary
	var _threads: Array = []
	func has(id: String) -> bool:
		return inner.has(id)
	func control(id: String) -> Object:
		return inner.control(id)
	func run_on_worker(job: Callable) -> void:
		var t := Thread.new()
		t.start(job)
		_threads.append(t)
	func join() -> void:
		for t in _threads:
			t.wait_to_finish()
		_threads.clear()


func test_mixer_freed_before_its_read_returns() -> void:
	var mt = MixerT.new()
	var s: Dictionary = mt._env("handback_mixer")
	var reg := ThreadedRegistry.new()
	reg.inner = s.reg
	reg.ctx = s.reg.ctx
	var m: VBoxContainer = AppMixer.new()
	m.setup(reg)   # the read goes to the worker
	var id := m.get_instance_id()
	reg.join()
	eq(m.rows.size(), 0, "the worker didn't build anything itself")
	CardJobs.shared()._drain()
	eq(m.rows.size(), 3, "the main thread did, on the next frame")
	m.refresh()
	m.free()   # a quick-menu tab switch frees it mid-read
	reg.join()
	CardJobs.shared()._drain()
	ok(instance_from_id(id) == null, "no call reached the freed widget")
	reg.free()
	s.reg.free()


## No worker-side WeakRef left in the scripts that hand results back from workers.
func test_lint_no_weakref_resolution_on_workers() -> void:
	var bad := []
	for f in ["res://scripts/ui/controls/app_mixer.gd", "res://scripts/ui/controls/media_card.gd",
			"res://scripts/ui/settings/bluetooth_card.gd", "res://scripts/ui/settings/proton_card.gd",
			"res://scripts/ui/settings/media_page.gd", "res://scripts/ui/apps_view.gd", "res://scripts/main.gd"]:
		var text := FileAccess.get_file_as_string(f)
		if "weakref(self)" in text and ("run_on_worker(" in text or "add_task(" in text):
			bad.append(f)
	eq(bad, [], "workers carry an instance id, never a WeakRef to a Node")
