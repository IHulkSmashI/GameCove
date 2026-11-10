extends RefCounted
## What this process costs, read from /proc/self (Linux): CPU time, context
## switches (wakeups), memory, threads, child processes and write syscalls.
## Used by the performance harness (tests/perf/run_perf.gd, tools/perf/measure.py)
## and by the in-game budget check (tests/e2e/suite_perf.gd).
##
##   var a := ProcStats.snapshot()
##   ... let the app sit ...
##   var d := ProcStats.delta(a, ProcStats.snapshot())   # rates per second
##
## /proc files report a size of 0, so they're read with Device.read_all
## (FileAccess.get_as_text would return "").

const Device := preload("res://scripts/device/device.gd")

## Clock ticks per second of /proc/<pid>/stat (USER_HZ: 100 on every Linux we run on).
const USER_HZ := 100.0


static func _read(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	return Device.read_all(f)


## "Key:\tvalue kB" lines of a status file -> {key: int}.
static func _status(path: String) -> Dictionary:
	var out := {}
	for line in _read(path).split("\n", false):
		var i := line.find(":")
		if i <= 0:
			continue
		var v := line.substr(i + 1).strip_edges().split(" ", false)
		if v.size() > 0 and v[0].is_valid_int():
			out[line.substr(0, i)] = v[0].to_int()
	return out


## Fields of /proc/<pid>/stat after the command name (field 3 is index 0).
static func _stat_fields(path: String) -> PackedStringArray:
	var s := _read(path)
	var close := s.rfind(")")
	if close < 0:
		return PackedStringArray()
	return s.substr(close + 2).split(" ", false)


## Child processes of `pid` (and theirs), as [pid, name] pairs.
static func children(pid: int) -> Array:
	var by_parent := {}
	for d in DirAccess.get_directories_at("/proc"):
		if not d.is_valid_int():
			continue
		var s := _read("/proc/%s/stat" % d)
		var open := s.find("(")
		var close := s.rfind(")")
		if open < 0 or close < 0:
			continue
		var f := s.substr(close + 2).split(" ", false)
		if f.size() < 2:
			continue
		var ppid := f[1].to_int()
		if not by_parent.has(ppid):
			by_parent[ppid] = []
		by_parent[ppid].append([d.to_int(), s.substr(open + 1, close - open - 1)])
	var out: Array = []
	var todo: Array = [pid]
	while not todo.is_empty():
		var p: int = todo.pop_back()
		for c in by_parent.get(p, []):
			out.append(c)
			todo.append(c[0])
	return out


## One look at the process. Times in seconds, memory in kB.
static func snapshot() -> Dictionary:
	var pid := OS.get_process_id()
	var st := _stat_fields("/proc/self/stat")
	var cpu := 0.0
	if st.size() > 12:
		cpu = (st[11].to_float() + st[12].to_float()) / USER_HZ   # utime + stime: every thread, ended ones too
	var status := _status("/proc/self/status")
	var vol := 0
	var invol := 0
	var run_ns := 0
	var per_thread := {}
	for t in DirAccess.get_directories_at("/proc/self/task"):
		var ts := _status("/proc/self/task/%s/status" % t)
		var name := _read("/proc/self/task/%s/comm" % t).strip_edges()
		var v := int(ts.get("voluntary_ctxt_switches", 0))
		var n := int(ts.get("nonvoluntary_ctxt_switches", 0))
		vol += v
		invol += n
		var sched := _read("/proc/self/task/%s/schedstat" % t).split(" ", false)
		var ns := sched[0].to_int() if sched.size() > 0 else 0
		run_ns += ns
		per_thread[t] = {"name": name, "wake": v + n, "ns": ns}
	var io := _status("/proc/self/io")
	return {
		"t": Time.get_ticks_usec() / 1e6,
		"cpu_s": cpu,
		"run_s": run_ns / 1e9,
		"main_vol": int(status.get("voluntary_ctxt_switches", 0)),
		"main_invol": int(status.get("nonvoluntary_ctxt_switches", 0)),
		"vol": vol,
		"invol": invol,
		"rss_kb": int(status.get("VmRSS", 0)),
		"hwm_kb": int(status.get("VmHWM", 0)),
		"threads": int(status.get("Threads", 0)),
		"syscw": int(io.get("syscw", 0)),
		"wchar": int(io.get("wchar", 0)),
		"children": children(pid),
		"per_thread": per_thread,
		"frames": Engine.get_frames_drawn(),
		"iterations": Engine.get_process_frames(),
	}


## From snapshot a to b: per-second rates, percentages and what's alive at b.
static func delta(a: Dictionary, b: Dictionary) -> Dictionary:
	var dt: float = maxf(0.001, float(b["t"]) - float(a["t"]))
	var busiest: Array = []
	for t in b["per_thread"]:
		var pa: Dictionary = a["per_thread"].get(t, {"wake": 0, "ns": 0})
		var pb: Dictionary = b["per_thread"][t]
		busiest.append({"thread": pb["name"], "wake_per_s": snappedf((pb["wake"] - pa["wake"]) / dt, 0.01),
			"cpu_ms_per_s": snappedf((pb["ns"] - pa["ns"]) / 1e6 / dt, 0.001)})
	busiest.sort_custom(func(x, y): return x["wake_per_s"] > y["wake_per_s"])
	return {
		"seconds": snappedf(dt, 0.01),
		"cpu_pct": snappedf(100.0 * (float(b["cpu_s"]) - float(a["cpu_s"])) / dt, 0.01),
		"cpu_ms_per_s": snappedf(1000.0 * (float(b["run_s"]) - float(a["run_s"])) / dt, 0.001),
		"wake_per_s": snappedf(((b["vol"] + b["invol"]) - (a["vol"] + a["invol"])) / dt, 0.01),
		"main_wake_per_s": snappedf(((b["main_vol"] + b["main_invol"]) - (a["main_vol"] + a["main_invol"])) / dt, 0.01),
		"loops_per_s": snappedf((b["iterations"] - a["iterations"]) / dt, 0.01),
		"frames_per_s": snappedf((b["frames"] - a["frames"]) / dt, 0.01),
		"writes_per_min": snappedf((b["syscw"] - a["syscw"]) * 60.0 / dt, 0.1),
		"write_kb_per_min": snappedf((b["wchar"] - a["wchar"]) / 1024.0 * 60.0 / dt, 0.01),
		"rss_mb": snappedf(b["rss_kb"] / 1024.0, 0.1),
		"threads": b["threads"],
		"children": b["children"].map(func(c): return str(c[1])),
		"threads_by_wakeups": busiest.slice(0, 6),
	}
