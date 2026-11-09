extends RefCounted
## Starts processes that keep running (Moonlight's pair, quit and stream) and
## lets the service stop them. Tests swap in a fake with the same three calls.


## The process id, or -1 when it couldn't start. cmd: [program, args...].
func spawn(cmd: Array) -> int:
	if cmd.is_empty():
		return -1
	var args := PackedStringArray()
	for a in cmd.slice(1):
		args.append(str(a))
	return OS.create_process(str(cmd[0]), args)


func kill(pid: int) -> void:
	if pid > 0:
		OS.kill(pid)


func running(pid: int) -> bool:
	return pid > 0 and OS.is_process_running(pid)
