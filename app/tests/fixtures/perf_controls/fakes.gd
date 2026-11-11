extends RefCounted
## Fakes for the perf controls tests: PerfMonitor, Launcher, Library and a
## command runner. Every call is recorded.


class FakePerf extends RefCounted:
	var supported := true
	var level := 0
	var override: Array = []
	var extra: Array = []
	var calls: Array = []
	func overlay_supported() -> bool: return supported
	func overlay_level() -> int: return level
	func set_overlay_level(l: int) -> bool:
		calls.append("level %d" % l)
		level = l
		return supported
	func set_overlay_style(o: Array, e: Array) -> bool:
		calls.append("style")
		override = o
		extra = e
		return supported


class FakeLauncher extends RefCounted:
	var settings := {}
	var env := {"LOW_LATENCY_LAYER": "1"}
	var env_hooks: Array[Callable] = []
	var frame_gen_hooks: Array[Callable] = []
	var anticheat_keys: Array = []
	func has_anticheat(game: Dictionary) -> bool:
		return str(game.get("key", "")) in anticheat_keys
	func settings_for(key: String) -> Dictionary:
		return settings.get(key, {"low_latency": true}).duplicate()
	func save_settings(key: String, s: Dictionary) -> void:
		settings[key] = s
	func launch_env(game: Dictionary) -> Dictionary:
		return env.duplicate() if settings_for(str(game.get("key", ""))).get("low_latency", true) else {}


class FakeLibrary extends RefCounted:
	var options := {}
	var tools: Array = [{"id": "", "name": "Default"}, {"id": "proton_cachyos_11", "name": "Proton-CachyOS 11"}]
	var compat := {}
	var calls: Array = []
	var games := {}
	func game_by_key(key: String) -> Dictionary:
		return games.get(key, {})
	func launch_options(g: Dictionary) -> String:
		return str(options.get(g.get("key", ""), ""))
	func set_launch_options(g: Dictionary, o: String) -> Dictionary:
		calls.append("options %s %s" % [g.get("key", ""), o])
		options[g.get("key", "")] = o
		return {"ok": true}
	func compat_tools(_g: Dictionary) -> Array:
		return tools
	func compat_tool(g: Dictionary) -> String:
		return str(compat.get(g.get("key", ""), ""))
	func set_compat_tool(g: Dictionary, t: String) -> Dictionary:
		calls.append("compat %s %s" % [g.get("key", ""), t])
		compat[g.get("key", "")] = t
		return {"ok": true}


class FakeRunner extends RefCounted:
	var calls: Array = []
	## verb -> Dictionary answered as JSON
	var answers := {}
	func run(program: String, args: PackedStringArray) -> Dictionary:
		calls.append(program + " " + " ".join(args))
		var verb := args[0] if args.size() > 0 else ""
		if answers.has(verb):
			return {"code": 0, "out": JSON.stringify(answers[verb])}
		return {"code": 1, "out": ""}
