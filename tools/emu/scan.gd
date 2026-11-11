extends SceneTree
## Prints what GameCove finds in a home's emulation setup and how it would start
## each ROM, without starting anything or writing anywhere but /tmp:
##   godot --headless --path app -s ../tools/emu/scan.gd -- [--home ~] [--system nes] [--limit 20]
## Handy on a real EmuDeck / RetroDECK / ES-DE install to check the ROM roots,
## the systems, the titles, the art found and each launch command.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var home := OS.get_environment("HOME")
	var only := ""
	var limit := 20
	for i in args.size():
		match args[i]:
			"--home": home = args[i + 1]
			"--system": only = args[i + 1]
			"--limit": limit = int(args[i + 1])
	var Emu = load("res://scripts/library/stores/emu.gd")
	var Roms = load("res://scripts/library/stores/roms.gd")
	Roms.cache_path = "/tmp/gamecove-emu-scan.cache"
	var t := Time.get_ticks_msec()
	var setup: Dictionary = Emu.detect(home, OS.get_environment("PATH"), Emu.FLATPAK_DIRS, false)
	print("setup: %s (%s)  front end: %s" % [setup["kind"], setup["name"], setup["frontend"].get("command", [])])
	print("ES-DE folder: %s  media: %s" % [setup["esde_dir"], setup["media_dir"]])
	for r in setup["roots"]:
		print("ROM root: %s  [%s, from %s]" % [r["path"], "online" if r["online"] else "OFFLINE", r["from"]])
	var entries: Array = Emu.scan(home, setup, true)
	print("scan: %d ms, %d entries" % [Time.get_ticks_msec() - t, entries.size()])
	for s in setup["systems"]:
		print("  %-14s %-10s %5d  %s%s" % [s["id"], s["short"], s["count"], ", ".join(s.get("roots", [])), "" if s.get("known", true) else "  (ES-DE doesn't know it)"])
	var shown := 0
	for e in entries:
		if not e.has("rom") or (only != "" and e["emulated"]["system"] != only):
			continue
		if shown >= limit:
			break
		shown += 1
		var plan: Dictionary = Emu.launch_plan(e, {}, home, OS.get_environment("PATH"))
		var art: Array = []
		for k in ["cover", "hero", "logo"]:
			if str(e["art"][k]) != "":
				art.append(k)
		print("\n%s  [%s]  %s" % [e["title"], e["emulated"]["system_short"], e["rom"]])
		print("  runs in: %s   art: %s" % [e["emulated"]["emulator"], ", ".join(art) if not art.is_empty() else "placeholder"])
		print("  launch: %s" % (str(plan["cmd"]) if plan["ok"] else "CAN'T: " + str(plan["why"])))
	quit()
