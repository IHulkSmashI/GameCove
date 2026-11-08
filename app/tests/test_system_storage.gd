extends "res://tests/test_case.gd"
## Storage parsers and service against fixture output (an MSI Claw on Bazzite
## with an SD card and a USB SSD). Nothing real runs.

const Parse := preload("res://scripts/system/storage_parse.gd")
const StorageScript := preload("res://scripts/system/storage.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")

const FINDMNT := "findmnt --json --list -b -o SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL,OPTIONS"
const LSBLK := "lsblk --json -b -o NAME,PATH,PKNAME,TYPE,SIZE,RM,HOTPLUG,TRAN,MODEL,LABEL,FSTYPE"
const DF := "df -B1 --output=source,fstype,size,used,avail,target"


func _text(name: String) -> String:
	return FileAccess.get_file_as_string(fixture("system/storage/" + name))


func _fake(findmnt_file := "findmnt.json") -> RefCounted:
	var f: RefCounted = Fake.new()
	f.responses[FINDMNT] = {"code": 0, "file": fixture("system/storage/" + findmnt_file)}
	f.responses[LSBLK] = {"code": 0, "file": fixture("system/storage/lsblk.json")}
	f.responses[DF] = {"code": 0, "file": fixture("system/storage/df.txt")}
	return f


func _by_device(drives: Array) -> Dictionary:
	var out := {}
	for d in drives:
		out[d["device"]] = d
	return out


func test_findmnt_keeps_block_devices_only() -> void:
	var m := Parse.findmnt(_text("findmnt.json"))
	eq(m.size(), 7)
	ok(m.all(func(x): return x["source"].begins_with("/dev/")), "no composefs")
	eq(m[1]["device"], "/dev/nvme0n1p3")
	eq(m[1]["free"], 608174227456)


func test_lsblk_classifies_sd_usb_internal() -> void:
	var b := Parse.lsblk(_text("lsblk.json"))
	eq(b["/dev/nvme0n1p3"]["kind"], "internal")
	eq(b["/dev/nvme0n1p3"]["model"], "WD PC SN5000S SDEQNSJ-1T00-1032")
	eq(b["/dev/mmcblk0p1"]["kind"], "sd")
	eq(b["/dev/mmcblk0p1"]["label"], "SD512")
	eq(b["/dev/sda1"]["kind"], "external")
	eq(b["/dev/sda1"]["model"], "Portable SSD T7")


func test_drives_one_per_partition_best_mount_first() -> void:
	var d := _by_device(Parse.drives(Parse.findmnt(_text("findmnt.json")), Parse.lsblk(_text("lsblk.json"))))
	eq(d.size(), 3)
	ok(not d.has("/dev/nvme0n1p2") and not d.has("/dev/nvme0n1p1"), "/boot and /boot/efi hidden")
	var nvme: Dictionary = d["/dev/nvme0n1p3"]
	eq(nvme["mount"], "/var/home")
	eq(nvme["compression"], "zstd:1")
	eq(nvme["fstype"], "btrfs")
	eq(nvme["mounts"], ["/var/home", "/var"])
	eq(d["/dev/mmcblk0p1"]["kind"], "sd")
	eq(d["/dev/mmcblk0p1"]["compression"], "")
	eq(d["/dev/sda1"]["kind"], "external")
	eq(d["/dev/sda1"]["free"], 750169226240)


func test_df_parser_and_mount_names_with_spaces() -> void:
	var m := Parse.df(_text("df.txt"))
	eq(m.size(), 4)
	eq(m[3]["target"], "/run/media/deck/My Drive")
	eq(m[0]["size"], 1022336598016)


func test_compression_options() -> void:
	eq(Parse.compression("rw,compress=zstd:1,ssd"), "zstd:1")
	eq(Parse.compression("rw,compress-force=lzo"), "lzo")
	eq(Parse.compression("rw,compress=no"), "")
	eq(Parse.compression("rw,relatime"), "")


func test_steam_libraries_from_vdf() -> void:
	var libs := Parse.steam_libraries(FileAccess.get_file_as_string(fixture("system/home/.local/share/Steam/steamapps/libraryfolders.vdf")))
	eq(libs.size(), 2)
	eq(libs[0]["games"], 2)
	eq(libs[0]["bytes"], 423105324 + 70368744177)
	eq(libs[1]["path"], "/run/media/deck/SD512")


func test_mount_for_longest_prefix() -> void:
	var m := Parse.findmnt(_text("findmnt.json"))
	eq(Parse.mount_for("/var/home/deck/.local/share/Steam", m)["target"], "/var/home")
	eq(Parse.mount_for("/run/media/deck/SD512/steamapps", m)["target"], "/run/media/deck/SD512")
	eq(Parse.mount_for("/var/homework", m)["target"], "/var")


func test_mounts_signature_ignores_order_and_pseudo_fs() -> void:
	var a := Parse.mounts_signature("/dev/a / ext4 rw 0 0\nproc /proc proc rw 0 0\n/dev/b /x ext4 rw 0 0\n")
	var b := Parse.mounts_signature("/dev/b /x ext4 rw 0 0\n/dev/a / ext4 rw 0 0\n")
	eq(a, b)
	ok(Parse.mounts_signature(_text("mounts_a.txt")) != Parse.mounts_signature(_text("mounts_b.txt")), "SSD plugged in")


func test_refresh_builds_drives_and_libraries() -> void:
	var f := _fake()
	var s: Node = StorageScript.new()
	s.setup(f, fixture("system/home"))
	var got: Array = []
	s.changed.connect(func(st): got.append(st))
	eq(f.calls.size(), 0)
	s.refresh()
	eq(got.size(), 1)
	var st: Dictionary = got[0]
	ok(st["ready"], "ready")
	eq(st["drives"].size(), 3)
	var libs: Dictionary = {}
	for l in st["libraries"]:
		libs[l["path"]] = l
	var steam: Dictionary = libs["/var/home/deck/.local/share/Steam"]
	eq(steam["store"], "steam")
	eq(steam["mount"], "/var/home")
	eq(steam["compression"], "zstd:1")
	eq(libs["/run/media/deck/SD512"]["games"], 1)
	eq(libs["/run/media/deck/SD512"]["device"], "/dev/mmcblk0p1")
	ok(libs.has(fixture("system/home") + "/Games/Heroic"), "Heroic's install folder (~ expanded)")
	ok(libs.has(fixture("system/home") + "/Games"), "~/Games")
	eq(libs[fixture("system/home") + "/Games"]["bytes"], -1)
	ok(not f.called("du"), "no folder walk unless asked")
	s.free()


func test_old_findmnt_falls_back_to_df_sizes() -> void:
	var f := _fake("findmnt_nosize.json")
	var s: Node = StorageScript.new()
	s.setup(f, fixture("system/home"))
	s.refresh()
	ok(f.called(DF), "df used")
	var d := _by_device(s.state()["drives"])
	eq(d["/dev/nvme0n1p3"]["free"], 608174227456)
	eq(d["/dev/nvme0n1p3"]["compression"], "zstd:1")
	s.free()


func test_watch_refreshes_only_on_change() -> void:
	var f := _fake()
	var s: Node = StorageScript.new()
	s.setup(f, fixture("system/home"), fixture("system/storage/mounts_a.txt"))
	s.watch(true)
	var n: int = f.calls.size()
	ok(n > 0, "opening the page refreshes")
	ok(not s.poll_mounts(), "nothing changed")
	eq(f.calls.size(), n)
	s.proc_mounts = fixture("system/storage/mounts_b.txt")
	ok(s.poll_mounts(), "SSD plugged in")
	ok(f.calls.size() > n, "refreshed")
	s.watch(false)
	ok(not s.state()["watching"], "stopped")
	s.free()


func test_measure_uses_du_total() -> void:
	var f := _fake()
	f.responses["du -sb " + fixture("system/home") + "/Games"] = {"code": 1, "out": "du: cannot read directory 'x': Permission denied\n123456\t" + fixture("system/home") + "/Games\n"}
	var s: Node = StorageScript.new()
	s.setup(f, fixture("system/home"))
	s.refresh()
	s.measure(fixture("system/home") + "/Games")
	for l in s.state()["libraries"]:
		if l["path"] == fixture("system/home") + "/Games":
			eq(l["bytes"], 123456)
	s.free()
