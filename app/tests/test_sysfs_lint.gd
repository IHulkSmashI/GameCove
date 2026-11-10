extends "res://tests/test_case.gd"
## Real sysfs files report a size of 4096 and /proc files a size of 0, so a read
## that trusts the size (FileAccess.get_as_text(), get_file_as_string(),
## get_as_utf8_string()) returns "" on the handheld while the test fixtures,
## being regular files, read fine. Device.read_all() reads to the real end.
##
## Lint: in every script that names a /sys or /proc path or works under a
## sys_root, each size-trusting read must be on the list below, with why the
## file it reads is a regular one. A new one fails here until it uses
## Device.read_all() / a line reader, or is listed with its reason.

const SIZE_TRUSTING := ["get_as_text()", "get_file_as_string(", "get_as_utf8_string("]
## "<script path>|<text on the line>": why that read is a regular file.
const REGULAR_FILES := {
	"res://scripts/streaming/streaming.gd|JSON.parse_string(FileAccess.get_file_as_string(path))": "GameCove's own JSON in its data folder",
	"res://scripts/controls/providers/controller.gd|\"gyro_3d\" in FileAccess.get_file_as_string(f)": "InputPlumber override under /etc",
	"res://scripts/controls/providers/controller.gd|FileAccess.get_file_as_string(str(ctx.get(\"sys_root\", \"\")) + CLAW8EX_OVERRIDE)": "InputPlumber override under /etc",
	"res://scripts/controls/input/hhd_client.gd|var t := FileAccess.get_file_as_string(f)": "hhd token file",
	"res://scripts/controls/input/hhd_client.gd|for line in FileAccess.get_file_as_string(f)": "hhd state.yml in the home folder",
	"res://scripts/controls/power/backend.gd|ally-mcu-version": "GameCove's own state file under /var/lib",
	"res://scripts/controls/perf/lsfg.gd|get_file_as_string(vdf)": "Steam VDF in the home folder",
	"res://scripts/streaming/moonlight.gd|parse_conf(FileAccess.get_file_as_string(path))": "Moonlight.conf in the home folder",
	"res://scripts/controls/profiles.gd|_parse(FileAccess.get_file_as_string(path))": "profiles.json (user://)",
	"res://scripts/controls/providers/perf.gd|var existing := FileAccess.get_file_as_string(path)": "a launch env file GameCove writes",
	"res://scripts/controls/providers/perf.gd|var was := FileAccess.get_file_as_string(stamp)": "GameCove's device stamp file",
	"res://scripts/controls/display/session_env.gd|f.get_as_text()": "environment.d file in the home folder",
	"res://scripts/controls/display/reshade.gd|FileAccess.get_file_as_string(p) == want": "a ReShade .fx GameCove wrote",
	"res://scripts/controls/input/backend.gd|Yaml.parse(FileAccess.get_file_as_string(f))": "InputPlumber's default.yaml under /etc or /usr/share",
	"res://scripts/controls/input/ip_edit.gd|parse_config_head(FileAccess.get_file_as_string(": "InputPlumber device configs under /usr/share and /etc",
	"res://scripts/controls/perf/launch_files.gd|FileAccess.get_file_as_string(path)": "a launch env file GameCove writes",
	"res://scripts/controls/perf/launch_files.gd|FileAccess.get_file_as_string(p)": "a launch env file GameCove writes",
	"res://scripts/system/storage.gd|get_file_as_string(vdf)": "Steam libraryfolders.vdf",
	"res://scripts/system/storage.gd|get_file_as_string(cfg)": "Heroic's config JSON",
	"res://scripts/system/updates.gd|FileAccess.get_file_as_string(path + VERIFIED_SUFFIX)": "GameCove's firmware index stamp in its cache",
	"res://scripts/device/fixes.gd|JSON.parse_string(f.get_as_text())": "GameCove's JSON catalogues / state",
	"res://scripts/device/fixes.gd|get_file_as_string(DEVICE_TABLE)": "devices.json",
	"res://scripts/device/fixes.gd|var text := FileAccess.get_file_as_string(o)": "an os-release / quirks text file",
	"res://scripts/device/fixes.gd|old = JSON.parse_string(FileAccess.get_file_as_string(path))": "GameCove's system-snapshot.json",
	"res://scripts/system/os_info.gd|parse_os_release(FileAccess.get_file_as_string(root + p))": "os-release under /etc or /usr/lib",
	"res://scripts/system/os_info.gd|_json(FileAccess.get_file_as_string(p))": "a JSON file GameCove ships",
}


static func _scripts(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir.path_join(d)))
	return out


static func problems() -> Array[String]:
	var out: Array[String] = []
	for path in _scripts("res://scripts"):
		var text := FileAccess.get_file_as_string(path)
		var touches := "\"/sys/" in text or "\"/proc/" in text or "sys_root" in text
		var n := 0
		for line in text.split("\n"):
			n += 1
			var code := line.get_slice("#", 0) if not "\"#" in line else line
			if code.strip_edges().begins_with("#"):
				continue
			if not SIZE_TRUSTING.any(func(x): return x in code):
				continue
			var names_sys := "/sys/" in code or "/proc/" in code
			if not (touches or names_sys):
				continue
			var listed := false
			for k in REGULAR_FILES:
				if k.get_slice("|", 0) == path and k.substr(k.find("|") + 1) in code:
					listed = true
			if names_sys or not listed:
				out.append("%s:%d reads with a size-trusting call where sysfs / procfs is read (use Device.read_all): %s" % [path, n, code.strip_edges()])
	return out


func test_no_size_trusting_reads_of_sysfs_or_procfs() -> void:
	eq(problems(), [] as Array[String], "sysfs / procfs reads")


## The three reads that were broken on real hardware (found by the lint).
func test_led_nodes_and_proc_files_read_on_a_real_system() -> void:
	var Leds := load("res://scripts/controls/input/leds.gd")
	ok(Leds._read("/proc/self/status").contains("Uid:"), "leds.gd reads a /proc-like (size 0) file to the end")
	var uid_seen := false
	for line in Leds._read("/proc/self/status").split("\n"):
		uid_seen = uid_seen or line.begins_with("Uid:")
	ok(uid_seen, "the Uid line GameSession looks for is there")
	if FileAccess.file_exists("/sys/kernel/mm/transparent_hugepage/enabled"):
		ok(Leds._read("/sys/kernel/mm/transparent_hugepage/enabled") != "", "and a sysfs (size 4096) file")
