extends "res://tests/test_case.gd"
## Real sysfs files report a size of 4096 bytes but return only their few real
## bytes. FileAccess.get_as_text() treats that short read as an error and returns
## "" — on real hardware that blanked DMI, GPU and firmware reads, so detection
## fell through to "unknown". Fixtures are regular files and never showed it.
## These tests read the live /sys and /proc of whatever machine runs them.

const DeviceScript := preload("res://scripts/device/device.gd")
const FirmwareIndex := preload("res://scripts/system/firmware_index.gd")


func _sysfs_sample() -> String:
	# Always present on Linux and world-readable, real sysfs semantics.
	for p in ["/sys/devices/system/cpu/online", "/sys/kernel/mm/transparent_hugepage/enabled", "/sys/power/state"]:
		if FileAccess.file_exists(p):
			return p
	return ""


func test_read_text_reads_real_sysfs() -> void:
	var p := _sysfs_sample()
	if p == "":
		ok(true, "no sysfs here; nothing to check")
		return
	var got := DeviceScript.read_text(p)
	ok(got != "", "read_text(%s) returned text (got '%s')" % [p, got])


func test_read_text_reads_proc() -> void:
	if not FileAccess.file_exists("/proc/cpuinfo"):
		ok(true, "no /proc here")
		return
	var got := DeviceScript.read_text("/proc/cpuinfo")
	ok(got.contains("processor"), "read_text(/proc/cpuinfo) has the processor lines")


func test_read_text_reads_dmi_when_readable() -> void:
	var p := "/sys/class/dmi/id/sys_vendor"
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		ok(true, "no readable DMI here")
		return
	f = null
	ok(DeviceScript.read_text(p) != "", "DMI sys_vendor is not blank")
	var fw := FirmwareIndex.read_installed()
	ok(str(fw.get("board_vendor", "")) != "" or str(fw.get("product_name", "")) != "", "firmware index reads DMI too: %s" % fw)


func test_read_text_whole_big_file() -> void:
	# The device table is far bigger than one read chunk: it must come back whole.
	var raw := DeviceScript.read_text(DeviceScript.DEVICE_TABLE)
	var parsed: Variant = JSON.parse_string(raw)
	ok(typeof(parsed) == TYPE_DICTIONARY and parsed.has("devices"), "device table parses after a chunked read")
	var direct := FileAccess.get_file_as_string(DeviceScript.DEVICE_TABLE).strip_edges()
	eq(raw.length(), direct.length(), "same length as a direct read")


func test_read_text_missing_and_empty() -> void:
	eq(DeviceScript.read_text("/nonexistent/gamecove/x"), "", "missing file → empty")
	var p := OS.get_user_data_dir().path_join("sysfs_reads_empty_%d.txt" % OS.get_process_id())
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string("")
	f = null
	eq(DeviceScript.read_text(p), "", "empty file → empty")
	DirAccess.remove_absolute(p)
