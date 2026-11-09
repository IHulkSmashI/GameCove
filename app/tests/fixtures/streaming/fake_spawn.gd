extends RefCounted
## Stands in for scripts/streaming/spawner.gd: records commands, never runs them.

var spawned: Array = []
var killed: Array = []
var alive := {}
var next_pid := 4000
## -1 makes spawn fail.
var fail := false


func spawn(cmd: Array) -> int:
	spawned.append(cmd.duplicate())
	if fail:
		return -1
	next_pid += 1
	alive[next_pid] = true
	return next_pid


func kill(pid: int) -> void:
	killed.append(pid)
	alive.erase(pid)


func running(pid: int) -> bool:
	return alive.has(pid)


func last() -> Array:
	return spawned[spawned.size() - 1] if not spawned.is_empty() else []
