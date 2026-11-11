extends "res://tests/test_case.gd"
## Firmware index, maker version schemes, Steam Deck BIOS from the OS image, driver stack and the
## Updates hub, with fake DMI trees, a fake fwupd, a fake index download and a fake runner.

const Index := preload("res://scripts/system/firmware_index.gd")
const Drivers := preload("res://scripts/system/driver_versions.gd")
const Parse := preload("res://scripts/system/update_parse.gd")
const UpdatesScript := preload("res://scripts/system/updates.gd")
const Fake := preload("res://tests/fixtures/system/fake_runner.gd")
const DeviceScript := preload("res://scripts/device/device.gd")

const BASE := "user://test_firmware"

var _n := 0


func _row(id: String) -> Dictionary:
	for r in DeviceScript.load_table():
		if r["id"] == id:
			return r
	return {}


## A fresh folder with the given files ({"rel/path": "text"}).
func _tree(files: Dictionary) -> String:
	_n += 1
	var dir := ProjectSettings.globalize_path("%s/%d_%d" % [BASE, Time.get_ticks_usec(), _n])
	for rel in files:
		DirAccess.make_dir_recursive_absolute(dir.path_join(rel).get_base_dir())
		var f := FileAccess.open(dir.path_join(rel), FileAccess.WRITE)
		f.store_string(str(files[rel]))
		f.close()
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _dmi(bios: String, extra := {}) -> Dictionary:
	var d := {"sys/class/dmi/id/bios_version": bios + "\n", "sys/class/dmi/id/bios_date": "09/12/2026\n",
		"sys/class/power_supply/ADP1/type": "Mains", "sys/class/power_supply/ADP1/online": "1",
		"sys/class/power_supply/BAT1/type": "Battery", "sys/class/power_supply/BAT1/capacity": "80",
		"usr/bin/curl": "", "usr/bin/fwupdmgr": "", "usr/bin/systemctl": ""}
	d.merge(extra, true)
	return d


func _index() -> Dictionary:
	return {"schema": 1, "built": "2026-11-09T05:41:00Z",
		"devices": {
			"asus-rog-ally": {"maker": "ASUS", "source": "asus", "support_url": "https://www.asus.com/supportonly/RC71L/helpdesk_bios/", "stale": false,
				"items": [{"kind": "bios", "name": "BIOS", "version": "343", "date": "2026-10-14", "flash": "ez-flash", "scheme": "asus",
					"download_url": "https://dlcdnets.asus.com/RC71LAS343.zip", "sha256": "", "notes": "Fixes."},
					{"kind": "controller", "name": "Controller (MCU) firmware", "version": "V321", "flash": "windows", "scheme": "asus-mcu", "match_name": "MCU"}]},
			"msi-claw-8-ex": {"maker": "MSI", "source": "msi", "items": [
				{"kind": "bios", "name": "BIOS", "version": "E1T91IMS.10E", "flash": "msi-usb", "scheme": "msi", "board": "E1T91IMS"}]},
			"lenovo-legion-go": {"maker": "Lenovo", "source": "lenovo", "items": [
				{"kind": "bios", "name": "BIOS", "version": "N3CN40WW", "flash": "windows", "scheme": "lenovo"}]},
			"steam-deck-lcd": {"maker": "Valve", "source": "valve", "items": [
				{"kind": "bios", "name": "BIOS", "version": "F7A0135", "flash": "steamos", "scheme": "valve"}]},
			"gpd-win-4": {"maker": "GPD", "source": "link", "support_url": "https://gpd.hk/gpdwin4firmwaredriver",
				"items": [{"kind": "bios", "name": "BIOS", "version": "", "flash": "link", "download_page": "https://gpd.hk/gpdwin4firmwaredriver"}]}},
		"shared": [{"traits": {"family": "steam-deck"}, "items": [{"kind": "controller", "name": "Controller firmware", "version": "6AA8483A", "flash": "steamos", "scheme": "hex-ts"}]}],
		"software": {"kernel": {"version": "7.3.3"}, "mesa": {"version": "26.2.6"}, "linux-firmware": {"version": "20261019"},
			"inputplumber": {"version": "0.70.2"}, "decky": {"version": "3.2.1"}, "xess-xmx": {"version": "20261104"}}}


func _gz(doc: Dictionary) -> PackedByteArray:
	return JSON.stringify(doc).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)


func _write_bytes(path: String, b: PackedByteArray) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


## A fake runner whose curl serves the index (and its .sha256) by writing the -o file.
func _fake_with_index(doc: Dictionary, sha_override := "") -> RefCounted:
	var f: RefCounted = Fake.new()
	var data := _gz(doc)
	var src := _tree({}) + "/served.json.gz"
	_write_bytes(src, data)
	var sha := sha_override if sha_override != "" else FileAccess.get_sha256(src)
	f.handler = func(cmd: String):
		if cmd.begins_with("curl ") and cmd.ends_with(Index.URL):
			var p := cmd.split(" ")
			var out := p[p.find("-o") + 1]
			DirAccess.copy_absolute(src, out)
			return {"code": 0, "out": ""}
		if cmd.begins_with("curl ") and cmd.ends_with(Index.URL + ".sha256"):
			return {"code": 0, "out": sha + "  firmware.json.gz\n"}
		return null
	return f


## The fake runner also has a cosign that accepts the index's signature (the device checked it).
func _with_cosign(f: RefCounted) -> RefCounted:
	var base: Callable = f.handler
	f.handler = func(cmd: String):
		if cmd.begins_with("curl ") and cmd.ends_with(Index.URL + ".sigstore.json"):
			var p := cmd.split(" ")
			_write_bytes(p[p.find("-o") + 1], "{}".to_utf8_buffer())
			return {"code": 0, "out": ""}
		if cmd.begins_with("/usr/bin/cosign verify-blob"):
			return {"code": 0, "out": "Verified OK"}
		return base.call(cmd)
	return f


## curl serving `zip_path` for a URL ending in `suffix`; it prints `final` (curl -w %{url_effective}), else the URL.
func _serve_zip(f: RefCounted, suffix: String, zip_path: String, final := "") -> void:
	var base: Callable = f.handler
	f.handler = func(cmd: String):
		if cmd.begins_with("curl ") and cmd.ends_with(suffix):
			var p := cmd.split(" ")
			DirAccess.copy_absolute(zip_path, p[p.find("-o") + 1])
			return {"code": 0, "out": final if final != "" else p[p.size() - 1]}
		return base.call(cmd)


func _upd(root: String, fake: RefCounted, row: Dictionary) -> Node:
	var u: Node = UpdatesScript.new()
	u.device_row = row
	u.cache_dir = _tree({})
	u.now_unix = 1794200000
	u.setup(fake, root, _tree({}), "/usr/bin:/bin")
	return u


# ---- index parsing and traits ------------------------------------------------------------

func test_parse_gz_and_sha() -> void:
	eq(Index.parse_gz(_gz(_index()))["built"], "2026-11-09T05:41:00Z")
	eq(Index.parse_gz(_gz({"schema": 2, "devices": {}})), {}, "other schema refused")
	eq(Index.parse_gz("<html>".to_utf8_buffer()), {}, "junk refused")
	eq(Index.sha_from_text("%s  firmware.json.gz\n" % "AB".repeat(32)), "ab".repeat(32))
	eq(Index.sha_from_text("404: Not Found"), "")


func test_traits_fill_from_row_and_shared_firmware_matches_siblings() -> void:
	var t := Index.traits_of(_row("steam-deck-oled"))
	eq(t["family"], "steam-deck")
	eq(t["maker"], "Valve")
	var own := Index.traits_of({"id": "x", "family": "f", "traits": {"soc": "custom", "wifi": ["rtl8922ae"]}})
	eq(own["soc"], "custom", "row's own traits win")
	eq(own["family"], "f", "missing ones filled")
	ok(Index.traits_match({"wifi": "RTL8922AE"}, own), "lists and case")
	ok(not Index.traits_match({}, own), "empty traits match nothing")
	# traits review: "platform" is the shared board group, never the CPU vendor
	var ally := Index.traits_of(_row("asus-rog-ally"))
	ok(str(ally.get("platform", "")) != "amd", "platform isn't the CPU vendor (%s)" % ally.get("platform", ""))
	eq(ally["cpu_vendor"], "amd", "the vendor has its own key")
	ok(not Index.traits_match({"platform": "amd"}, ally), "firmware for platform 'amd' doesn't reach every AMD handheld")
	var bare := Index.traits_of({"id": "y", "cpu_vendor": "intel", "traits": {"platform": null, "wifi": []}})
	ok(not bare.has("platform"), "a null trait is unknown, not filled with something else")
	ok(not bare.has("wifi"), "an empty list is unknown too")
	# both Deck models get the shared controller firmware; the OLED has no own entry at all
	var oled := Index.entries_for(_index(), _row("steam-deck-oled"))
	eq(oled["items"].size(), 1)
	eq(oled["items"][0]["kind"], "controller")
	eq(Index.entries_for(_index(), _row("steam-deck-lcd"))["items"].size(), 2)
	eq(Index.entries_for(_index(), _row("asus-rog-ally"))["items"].size(), 2, "no Deck firmware on an Ally")


# ---- version schemes ------------------------------------------------------------------------

func test_compare_per_maker() -> void:
	eq(Index.compare("asus", "RC71L.341", "343"), -1)
	eq(Index.compare("asus", "RC71L.343", "343"), 0)
	eq(Index.display_version("asus", "RC71L.343"), "343")
	eq(Index.compare("msi", "E1T91IMS.10D", "E1T91IMS.10E"), -1)
	eq(Index.compare("msi", "E1T91IMS.114", "E1T91IMS.10E"), 1, "hex: 114 > 10E")
	eq(Index.compare("msi", "E1T52IMS.10D", "E1T91IMS.10E"), -2, "other board")
	eq(Index.compare("lenovo", "N3CN29WW", "N3CN40WW"), -1)
	eq(Index.compare("lenovo", "QCCN26WW", "N3CN40WW"), -2, "other BIOS family")
	eq(Index.compare("valve", "F7A0131", "F7A0133"), -1)
	eq(Index.compare("valve", "F7G0014T20", "F7G0114"), -1)
	eq(Index.compare("valve", "F7G0114", "F7A0133"), -2, "LCD vs OLED")
	eq(Index.compare("hex-ts", "69C6B03E", "6AA8483A"), -1)
	eq(Index.compare("asus-mcu", "V319", "V321"), -1)
	eq(Index.compare("natural", "", "1.0"), -2, "unknown current")


# ---- maker items -----------------------------------------------------------------------------

func test_firmware_items_ally_bios_update_and_mcu_from_fwupd() -> void:
	var inst := {"bios_version": "RC71L.341"}
	var fw := [{"id": "m1", "name": "ROG Ally MCU", "current": "V319"}]
	var items := Index.firmware_items(_index(), _row("asus-rog-ally"), inst, fw)
	var bios: Dictionary = items.filter(func(i): return i["kind"] == "bios")[0]
	eq([bios["current"], bios["latest"], bios["status"], bios["how"]], ["341", "343", "update", "guided"])
	var mcu: Dictionary = items.filter(func(i): return i["kind"] == "controller")[0]
	eq([mcu["current"], mcu["status"], mcu["how"]], ["V319", "update", "link"])
	var none := Index.firmware_items(_index(), _row("asus-rog-ally"), {"bios_version": "RC71L.343"}, [])
	eq(none[0]["status"], "current")
	eq(none[1]["status"], "unknown", "MCU version unreadable without fwupd")


func test_firmware_items_msi_other_board_skipped_and_link_only_makers() -> void:
	var claw := Index.firmware_items(_index(), _row("msi-claw-8-ex"), {"bios_version": "E1T91IMS.10D"})
	eq([claw[0]["status"], claw[0]["latest"], claw[0]["flash"]], ["update", "E1T91IMS.10E", "msi-usb"])
	eq(Index.firmware_items(_index(), _row("msi-claw-8-ex"), {"bios_version": "E1T52IMS.10D"}).size(), 0)
	var gpd := Index.firmware_items(_index(), _row("gpd-win-4"), {"bios_version": "2.10"})
	eq([gpd[0]["status"], gpd[0]["how"], gpd[0]["download_page"]], ["unknown", "link", "https://gpd.hk/gpdwin4firmwaredriver"])
	eq(Index.firmware_items(_index(), _row("ayaneo-2"), {}).size(), 0, "not in this index: nothing")


func test_deck_bios_target_from_os_image_script() -> void:
	var s := FileAccess.get_file_as_string(fixture("firmware/jupiter-biosupdate"))
	eq(Index.deck_bios_target(s, "F7A0131"), "F7A0133")
	eq(Index.deck_bios_target(s, "F7G0110"), "F7G0114")
	eq(Index.deck_bios_target(s, "F7A0133"), "", "newest: nothing configured")
	eq(Index.deck_bios_target("no map", "F7A0131"), "")


# ---- fwupd ------------------------------------------------------------------------------------

func test_fwupd_devices_and_notes() -> void:
	var devs := Parse.fwupd_devices(JSON.stringify({"Devices": [
		{"Name": "ROG Ally MCU", "DeviceId": "m1", "Version": "V319", "Flags": ["updatable"], "Plugin": "asus_hid"},
		{"Name": "Battery", "DeviceId": "b", "Version": "1", "Flags": ["internal"]}]}))
	eq(devs.size(), 1, "only updatable devices")
	eq(devs[0]["plugin"], "asus_hid")
	eq(Parse.strip_markup("<p>Fixes:</p><ul><li>Fan &amp; power</li></ul>"), "Fixes:\n• Fan & power")
	var upd := Parse.fwupd_updates(0, FileAccess.get_file_as_string(fixture("system/updates/fwupd_updates.json")))
	ok(upd["devices"][0].has("notes"), "release notes carried")


# ---- Updates service --------------------------------------------------------------------------

func test_maker_check_downloads_index_verifies_and_compares() -> void:
	var root := _tree(_dmi("RC71L.341"))
	var f := _fake_with_index(_index())
	f.responses["fwupdmgr get-devices --json"] = {"code": 0, "out": JSON.stringify({"Devices": [
		{"Name": "ROG Ally MCU", "DeviceId": "m1", "Version": "V321", "Flags": ["updatable"]}]})}
	f.responses["fwupdmgr get-updates*"] = {"code": 2, "out": "No updatable devices"}
	var u := _upd(root, f, _row("asus-rog-ally"))
	eq(u.phase("maker"), "idle")
	u.check("firmware")
	ok(f.called("fwupdmgr refresh"), "first refresh runs (on AC)")
	u.check("maker")
	eq(u.phase("maker"), "available")
	var hub: Array = u.hub_items()
	eq(hub[0]["id"], "index:bios:bios", "updates first")
	eq(hub[0]["latest"], "343")
	ok(hub.any(func(i): return i["source"] == "fwupd" and i["name"] == "ROG Ally MCU"), "fwupd device listed")
	ok(not hub.any(func(i): return i["source"] == "index" and i["kind"] == "controller"), "fwupd's MCU replaces the index entry")
	ok(not u.apply("maker"), "maker firmware is never applied")
	# a second check within the week uses the cache: no second download
	var n: int = f.calls.filter(func(c): return c.ends_with(Index.URL)).size()
	u.check("maker")
	eq(f.calls.filter(func(c): return c.ends_with(Index.URL)).size(), n)
	u.check("firmware")
	eq(f.calls.filter(func(c): return c == "fwupdmgr refresh").size(), 1, "refresh at most daily")
	u.free()


func test_index_with_wrong_sha_is_refused() -> void:
	var f := _fake_with_index(_index(), "0".repeat(64))
	var u := _upd(_tree(_dmi("RC71L.341")), f, _row("asus-rog-ally"))
	u.check("maker")
	eq(u.phase("maker"), "error")
	eq(u.state()["maker"]["error"], "index_unavailable")
	ok(not FileAccess.file_exists(u.cache_dir.path_join("firmware.json.gz")), "nothing kept")
	u.free()


func test_metered_battery_skips_downloads() -> void:
	var files := _dmi("RC71L.341")
	files["sys/class/power_supply/ADP1/online"] = "0"
	var f := _fake_with_index(_index())
	f.responses["busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager org.freedesktop.NetworkManager Metered"] = {"code": 0, "out": "u 1\n"}
	var u := _upd(_tree(files), f, _row("asus-rog-ally"))
	ok(not u.network_ok(), "metered and on battery")
	u.check("firmware")
	u.check("maker")
	ok(not f.called("fwupdmgr refresh"), "no fwupd refresh")
	ok(not f.called("curl"), "no index download")
	u.free()


## Review Medium (other): a box with no battery (Steam Machine, desktop) was refused every firmware
## update with "needs_ac": it has no charger entry that says online, and nothing to run flat.
func test_a_box_with_no_battery_may_update_firmware() -> void:
	var files := _dmi("E1T91IMS.10D")
	for k in files.keys():
		if str(k).begins_with("sys/class/power_supply"):
			files.erase(k)   # no battery, no charger entry: a box
	var f: RefCounted = Fake.new()
	var u := _upd(_tree(files), f, _row("msi-claw-8-ex"))
	eq(u.power_block(), "", "no battery: on the mains, firmware may be written")
	var st: Dictionary = u.power_state()
	ok(bool(st["ok"]) and st["battery"] == -1 and bool(st["ac"]), "the state says so (%s)" % [st])
	u.free()
	# the same files with a battery on a charger that isn't in: still refused
	files["sys/class/power_supply/ADP1/online"] = "0"
	files["sys/class/power_supply/ADP1/type"] = "Mains"
	files["sys/class/power_supply/BAT1/capacity"] = "80"
	var u2 := _upd(_tree(files), f, _row("msi-claw-8-ex"))
	eq(u2.power_block(), "needs_ac", "a handheld on its battery still needs the charger")
	u2.free()


func test_firmware_install_needs_ac_and_half_battery() -> void:
	var files := _dmi("E1T91IMS.10D")
	files["sys/class/power_supply/ADP1/online"] = "0"
	var f: RefCounted = Fake.new()
	f.responses["fwupdmgr get-updates --json --no-unreported-check --no-metadata-check"] = {"code": 0, "file": fixture("system/updates/fwupd_updates.json")}
	var u := _upd(_tree(files), f, _row("msi-claw-8-ex"))
	var got: Array = []
	u.finished.connect(func(k, o, m): got.append([k, o, m]))
	u.check("firmware")
	eq(u.phase("firmware"), "available")
	ok(not u.apply("firmware"), "refused")
	eq(got.back(), ["firmware", false, "needs_ac"])
	ok(not f.called("fwupdmgr update"), "nothing flashed")
	u.free()
	files["sys/class/power_supply/ADP1/online"] = "1"
	files["sys/class/power_supply/BAT1/capacity"] = "35"
	var u2 := _upd(_tree(files), f, _row("msi-claw-8-ex"))
	u2.check("firmware")
	eq(u2.power_state()["reason"], "low_battery")
	ok(not u2.apply("firmware"), "refused under 50%")
	u2.free()


func test_steam_deck_bios_from_os_image_and_service_state() -> void:
	var files := _dmi("F7A0131")
	files["usr/bin/jupiter-biosupdate"] = FileAccess.get_file_as_string(fixture("firmware/jupiter-biosupdate"))
	var f := _fake_with_index(_index())
	f.responses["systemctl is-enabled jupiter-biosupdate.service"] = {"code": 1, "out": "disabled\n"}
	var u := _upd(_tree(files), f, _row("steam-deck-lcd"))
	u.check("maker")
	var items: Array = u.state()["maker"]["items"]
	var bios: Dictionary = items.filter(func(i): return i["kind"] == "bios")[0]
	eq([bios["current"], bios["latest"], bios["status"], bios["source"], bios["service"]], ["F7A0131", "F7A0133", "update", "local", "disabled"])
	eq(bios["upstream_note"], "F7A0135", "a newer OS image brings a newer BIOS")
	ok(items.any(func(i): return i["kind"] == "controller"), "shared Deck controller firmware")
	u.free()


func test_drivers_stack_rpm_with_os_update_preview() -> void:
	var files := _dmi("RC71L.343", {"proc/sys/kernel/osrelease": "6.19.4-ba01.fc44.x86_64\n", "usr/bin/rpm": "",
		"home_marker": ""})
	var root := _tree(files)
	var f := _fake_with_index(_index())
	f.responses["rpm -q --qf*"] = {"code": 0, "out": "mesa-dri-drivers 26.2.6\nlinux-firmware 20260916\npackage powerstation is not installed\ninputplumber 0.70.2\nhhd 3.20.1\n"}
	var u := _upd(root, f, _row("asus-rog-ally"))
	_write_bytes(u.home + Drivers.DECKY_VERSION, "v3.1.10\n".to_utf8_buffer())
	u._os["available"] = true
	u.os_info["backend"] = "rpm-ostree"
	f.responses["rpm-ostree upgrade --preview"] = {"code": 0, "out": "AvailableUpdate:\nUpgraded:\n  kernel 6.19.4-ba01.fc44 -> 6.19.6-ba01.fc44\n  linux-firmware 20260916-1.fc44 -> 20261019-1.fc44\nAdded:\n  foo-1\n"}
	u.check("drivers")
	var items: Array = u.state()["drivers"]["items"]
	var by := {}
	for i in items:
		by[i["kind"]] = i
	eq([by["kernel"]["current"], by["kernel"]["status"], by["kernel"]["latest"], by["kernel"]["how"]], ["6.19.4", "update", "6.19.6", "auto"])
	eq([by["linux-firmware"]["status"], by["linux-firmware"]["latest"]], ["update", "20261019"])
	eq(by["mesa"]["status"], "current")
	eq(by["inputplumber"]["status"], "current")
	eq(by["hhd"]["status"], "unknown", "no upstream version in this index")
	eq([by["decky"]["current"], by["decky"]["status"], by["decky"]["how"]], ["3.1.10", "upstream", "link"])
	ok(not by.has("powerstation"), "not installed: not listed")
	eq(u.phase("drivers"), "available")
	u.free()


func test_driver_parsers() -> void:
	eq(Drivers.upstream_part("1:25.2.4-1"), "25.2.4")
	eq(Drivers.upstream_part("v3.1.10"), "3.1.10")
	eq(Drivers.pacman_versions("mesa 1:25.2.4-1\nerror: package 'hhd' was not found\n"), {"mesa": "1:25.2.4-1"})
	eq(Drivers.helper_json("noise\n{\"ok\": true, \"xess\": {\"version\": \"20261104\"}}\n")["xess"]["version"], "20261104")


func test_prepare_usb_for_ez_flash_checks_sha_and_copies_cap() -> void:
	var zip_path := _tree({}) + "/bios.zip"
	var zp := ZIPPacker.new()
	zp.open(zip_path)
	zp.start_file("RC71LAS343/RC71LAS343.CAP")
	zp.write_file("CAPSULE".to_utf8_buffer())
	zp.close_file()
	zp.start_file("readme.txt")
	zp.write_file("x".to_utf8_buffer())
	zp.close_file()
	zp.close()
	var idx := _index()
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = FileAccess.get_sha256(zip_path)
	var files := _dmi("RC71L.341", {"proc/self/mounts": "/dev/sda1 /run/media/deck/BIOS\\040USB vfat rw 0 0\n/dev/nvme0n1p3 /home btrfs rw 0 0\n"})
	files["usr/bin/cosign"] = ""
	var root := _tree(files)
	DirAccess.make_dir_recursive_absolute(root + "/run/media/deck/BIOS USB")
	var f := _with_cosign(_fake_with_index(idx))
	_serve_zip(f, "RC71LAS343.zip", zip_path)
	var u := _upd(root, f, _row("asus-rog-ally"))
	var got: Array = []
	u.finished.connect(func(k, o, m): got.append([k, o, m]))
	eq(u.usb_targets()[0]["mount"], "/run/media/deck/BIOS USB")
	u.check("maker")
	ok(not u.prepare_usb("index:bios:bios", "/home"), "only a FAT32 USB drive")
	eq(got.back(), ["usb", false, "no_usb"])
	ok(u.prepare_usb("index:bios:bios", "/run/media/deck/BIOS USB"), "started")
	eq(got.back(), ["usb", true, "RC71LAS343.CAP"])
	eq(FileAccess.get_file_as_string(root + "/run/media/deck/BIOS USB/RC71LAS343.CAP"), "CAPSULE")
	ok(not FileAccess.file_exists(root + "/run/media/deck/BIOS USB/readme.txt"), "only the capsule")
	u.free()
	# a tampered download is refused
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = "1".repeat(64)
	var f2 := _with_cosign(_fake_with_index(idx))
	_serve_zip(f2, "RC71LAS343.zip", zip_path)
	var root2 := _tree(files)
	DirAccess.make_dir_recursive_absolute(root2 + "/run/media/deck/BIOS USB")
	var u2 := _upd(root2, f2, _row("asus-rog-ally"))
	var got2: Array = []
	u2.finished.connect(func(k, o, m): got2.append([k, o, m]))
	u2.check("maker")
	u2.prepare_usb("index:bios:bios", "/run/media/deck/BIOS USB")
	eq(got2.back(), ["usb", false, "checksum_mismatch"])
	ok(not FileAccess.file_exists(root2 + "/run/media/deck/BIOS USB/RC71LAS343.CAP"), "nothing written")
	u2.free()


func test_every_device_row_gets_items_or_nothing_without_crashing() -> void:
	for r in DeviceScript.load_table():
		var items := Index.firmware_items(_index(), r, {"bios_version": "X.1"}, [])
		for i in items:
			ok(i["status"] in ["update", "current", "unknown"], "%s status" % r["id"])
			ok(i["how"] in ["auto", "guided", "link"], "%s how" % r["id"])


# ---- review M21: where maker downloads may come from ---------------------------------------

func test_download_host_allow_list_per_maker() -> void:
	eq(Index.download_host("https://dlcdnets.asus.com/pub/ASUS/RC71LAS343.zip", "ASUS"), "dlcdnets.asus.com")
	eq(Index.download_host("https://download.msi.com/bos_exe/claw.zip", "MSI"), "download.msi.com")
	eq(Index.download_host("https://download.lenovo.com/consumer/x.exe", "Lenovo"), "download.lenovo.com")
	eq(Index.download_host("https://dlcdnets.asus.com/x.zip", "MSI"), "", "another maker's host isn't this device's maker")
	eq(Index.download_host("http://dlcdnets.asus.com/x.zip", "ASUS"), "", "https only")
	eq(Index.download_host("file:///etc/passwd", "ASUS"), "")
	eq(Index.download_host("-o/tmp/x https://asus.com/x", "ASUS"), "", "no option-looking values")
	eq(Index.download_host("https://asus.com.evil.example/x.zip", "ASUS"), "", "suffix must be the maker's domain")
	eq(Index.download_host("https://evilasus.com/x.zip", "ASUS"), "", "not a lookalike")
	eq(Index.download_host("https://asus.com@evil.example/x.zip", "ASUS"), "", "no user-info tricks")
	eq(Index.download_host("https://dlcdnets.asus.com:8443/x.zip", "ASUS"), "", "no odd ports")
	eq(Index.download_host("https://x.example/x.zip", "Nobody"), "", "unknown maker: nothing allowed")
	# review problem 9: only a plain host name is ever shown as the maker's host
	for bad in ["https://dl\tcdnets.asus.com/x.zip", "https://evil.example\n.asus.com/x.zip", "https://evil.example%2f.asus.com/x.zip",
			"https://evil.example%2F.asus.com/x.zip", "https://x_y.asus.com/x.zip", "https://-x.asus.com/x.zip", "https://x..asus.com/x.zip"]:
		eq(Index.download_host(bad, "ASUS"), "", "refused: " + bad.c_escape())
	eq(Index.download_host("https://dl-cdn.asus.com./x.zip", "ASUS"), "dl-cdn.asus.com", "a trailing dot is still fine")


func test_index_download_url_outside_the_allow_list_is_dropped() -> void:
	var idx := _index()
	idx["devices"]["asus-rog-ally"]["items"][0]["download_url"] = "https://evil.example/RC71LAS343.zip"
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = "a".repeat(64)
	var items := Index.firmware_items(idx, _row("asus-rog-ally"), {"bios_version": "RC71L.341"}, [])
	eq(items[0]["download_url"], "", "not the maker's domain: no download")
	ok(bool(items[0]["download_blocked"]), "flagged")
	var good := Index.firmware_items(_index(), _row("asus-rog-ally"), {"bios_version": "RC71L.341"}, [])
	eq(good[0]["download_host"], "dlcdnets.asus.com", "the maker's host is shown to the user")
	idx["devices"]["asus-rog-ally"]["items"][0]["download_page"] = "javascript:alert(1)"
	eq(Index.firmware_items(idx, _row("asus-rog-ally"), {}, [])[0]["download_page"], "", "pages are https only")


func test_prepare_usb_refuses_a_foreign_host_and_pins_https() -> void:
	var zip_path := _tree({}) + "/bios.zip"
	var zp := ZIPPacker.new()
	zp.open(zip_path)
	zp.start_file("RC71LAS343.CAP")
	zp.write_file("CAPSULE".to_utf8_buffer())
	zp.close_file()
	zp.close()
	var files := _dmi("RC71L.341", {"proc/self/mounts": "/dev/sda1 /run/media/deck/USB vfat rw 0 0\n", "usr/bin/cosign": ""})
	var root := _tree(files)
	DirAccess.make_dir_recursive_absolute(root + "/run/media/deck/USB")
	var idx := _index()
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = FileAccess.get_sha256(zip_path)
	var f := _with_cosign(_fake_with_index(idx))
	_serve_zip(f, "RC71LAS343.zip", zip_path)
	var u := _upd(root, f, _row("asus-rog-ally"))
	u.check("maker")
	ok(u.prepare_usb("index:bios:bios", "/run/media/deck/USB"), "the maker's own host: started")
	var dl: Array = f.calls.filter(func(c): return c.ends_with("RC71LAS343.zip"))
	ok(dl.size() == 1 and "--proto =https" in dl[0] and "--proto-redir =https" in dl[0] and " -- https://" in dl[0],
		"curl is held to https, redirects too, and the URL can't be read as an option")
	# the same item edited behind our back (state replaced after the check) is refused at the last step
	u._maker["items"][0]["download_url"] = "https://evil.example/RC71LAS343.zip"
	var got: Array = []
	u.finished.connect(func(k, o, m): got.append([k, o, m]))
	ok(not u.prepare_usb("index:bios:bios", "/run/media/deck/USB"), "a foreign host is refused")
	eq(got.back(), ["usb", false, "not_available"])
	u.free()


func test_index_signature_checked_when_cosign_is_there() -> void:
	var root := _tree(_dmi("RC71L.341", {"usr/bin/cosign": ""}))
	var f := _fake_with_index(_index())
	var base: Callable = f.handler
	f.handler = func(cmd: String):
		if cmd.begins_with("curl ") and cmd.ends_with(Index.URL + ".sigstore.json"):
			var p := cmd.split(" ")
			_write_bytes(p[p.find("-o") + 1], "{}".to_utf8_buffer())
			return {"code": 0, "out": ""}
		if cmd.begins_with("/usr/bin/cosign verify-blob"):
			return {"code": 1, "out": "none of the expected identities matched"}
		return base.call(cmd)
	var u := _upd(root, f, _row("asus-rog-ally"))
	eq(u.load_index(), {}, "a bad signature: the new index isn't used")
	var v: Array = f.calls.filter(func(c): return c.begins_with("/usr/bin/cosign verify-blob"))
	ok(v.size() == 1 and Index.SIGNER_IDENTITY in v[0] and "--certificate-oidc-issuer https://token.actions.githubusercontent.com" in v[0],
		"verified against the nightly workflow's identity")
	u.free()
	var f2 := _fake_with_index(_index())
	var b2: Callable = f2.handler
	f2.handler = func(cmd: String):
		if cmd.begins_with("curl ") and cmd.ends_with(Index.URL + ".sigstore.json"):
			var p := cmd.split(" ")
			_write_bytes(p[p.find("-o") + 1], "{}".to_utf8_buffer())
			return {"code": 0, "out": ""}
		if cmd.begins_with("/usr/bin/cosign verify-blob"):
			return {"code": 0, "out": "Verified OK"}
		return b2.call(cmd)
	var u2 := _upd(_tree(_dmi("RC71L.341", {"usr/bin/cosign": ""})), f2, _row("asus-rog-ally"))
	eq(u2.load_index()["built"], "2026-11-09T05:41:00Z", "a good signature: used")
	u2.free()
	# without cosign the sha256 and the allow-list still hold, and no bundle is fetched
	var f3 := _fake_with_index(_index())
	var u3 := _upd(_tree(_dmi("RC71L.341")), f3, _row("asus-rog-ally"))
	eq(u3.load_index()["built"], "2026-11-09T05:41:00Z")
	ok(not f3.calls.any(func(c): return c.ends_with(".sigstore.json")), "no cosign: no bundle needed")
	u3.free()


# ---- review problem 1: downloads only from a checked index, and curl's final host is checked too -------------

func _usb_zip() -> String:
	var zip_path := _tree({}) + "/bios.zip"
	var zp := ZIPPacker.new()
	zp.open(zip_path)
	zp.start_file("RC71LAS343.CAP")
	zp.write_file("CAPSULE".to_utf8_buffer())
	zp.close_file()
	zp.close()
	return zip_path


func test_unverified_index_offers_no_download() -> void:
	var zip_path := _usb_zip()
	var idx := _index()
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = FileAccess.get_sha256(zip_path)
	var root := _tree(_dmi("RC71L.341", {"proc/self/mounts": "/dev/sda1 /run/media/deck/USB vfat rw 0 0\n"}))
	DirAccess.make_dir_recursive_absolute(root + "/run/media/deck/USB")
	var f := _fake_with_index(idx)   # no cosign on this device
	_serve_zip(f, "RC71LAS343.zip", zip_path)
	var u := _upd(root, f, _row("asus-rog-ally"))
	u.check("maker")
	ok(not u.index_verified(), "nothing checked the signature")
	var it: Dictionary = u.hub_items().filter(func(i): return i["id"] == "index:bios:bios")[0]
	eq([it["status"], it["download_url"], it["download_host"]], ["update", "", ""], "listed, but no download")
	ok(bool(it["download_unverified"]) and not bool(it["download_blocked"]), "flagged as unverified")
	ok(str(it["download_page"]).begins_with("https://"), "the maker's page is still offered")
	var got: Array = []
	u.finished.connect(func(k, o, m): got.append([k, o, m]))
	ok(not u.prepare_usb("index:bios:bios", "/run/media/deck/USB"), "refused")
	eq(got.back(), ["usb", false, "not_available"])
	ok(not f.calls.any(func(c): return c.ends_with("RC71LAS343.zip")), "nothing downloaded")
	u.free()
	# the same index checked by cosign: the download is offered and recorded as verified
	var f2 := _with_cosign(_fake_with_index(idx))
	var u2 := _upd(_tree(_dmi("RC71L.341", {"usr/bin/cosign": ""})), f2, _row("asus-rog-ally"))
	u2.check("maker")
	ok(u2.index_verified(), "verified")
	eq(u2.hub_items()[0]["download_host"], "dlcdnets.asus.com")
	# a cached file that isn't the one cosign accepted doesn't count
	var cached: String = u2.cache_dir.path_join("firmware.json.gz")
	_write_bytes(cached, _gz(idx).slice(0) + PackedByteArray([0]))
	ok(not u2.index_verified(), "a different file isn't the verified one")
	u2.free()
	eq(Index.firmware_items(idx, _row("asus-rog-ally"), {"bios_version": "RC71L.341"}, [], false)[0]["download_url"], "")


func test_redirect_off_the_makers_site_is_refused() -> void:
	var zip_path := _usb_zip()
	var idx := _index()
	idx["devices"]["asus-rog-ally"]["items"][0]["sha256"] = FileAccess.get_sha256(zip_path)
	var root := _tree(_dmi("RC71L.341", {"proc/self/mounts": "/dev/sda1 /run/media/deck/USB vfat rw 0 0\n", "usr/bin/cosign": ""}))
	DirAccess.make_dir_recursive_absolute(root + "/run/media/deck/USB")
	var f := _with_cosign(_fake_with_index(idx))
	# an asus.com redirector that sent curl to another host (with a matching file)
	_serve_zip(f, "RC71LAS343.zip", zip_path, "https://files.evil.example/RC71LAS343.zip")
	var u := _upd(root, f, _row("asus-rog-ally"))
	var got: Array = []
	u.finished.connect(func(k, o, m): got.append([k, o, m]))
	u.check("maker")
	ok(u.prepare_usb("index:bios:bios", "/run/media/deck/USB"), "started (the index names the maker's host)")
	eq(got.back(), ["usb", false, "not_available"], "curl's final host isn't the maker's")
	ok(not FileAccess.file_exists(root + "/run/media/deck/USB/RC71LAS343.CAP"), "nothing written to the drive")
	var dl: Array = f.calls.filter(func(c): return c.ends_with("RC71LAS343.zip"))
	ok("--max-redirs 5" in dl[0] and ("--max-filesize %d" % u.MAX_FW_BYTES) in dl[0] and "-w %{url_effective}" in dl[0],
		"redirects and size capped, final URL reported")
	u.free()
