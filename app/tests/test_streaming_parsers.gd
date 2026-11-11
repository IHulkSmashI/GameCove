extends "res://tests/test_case.gd"
## GameStream, Moonlight and stream-settings parsing from captured fixtures.

const GameStream := preload("res://scripts/streaming/gamestream.gd")
const Moonlight := preload("res://scripts/streaming/moonlight.gd")
const Settings := preload("res://scripts/streaming/stream_settings.gd")
const Wol := preload("res://scripts/streaming/wol.gd")
const HostApi := preload("res://scripts/streaming/host_api.gd")


func _f(name: String) -> String:
	return FileAccess.get_file_as_string(fixture("streaming/" + name))


func test_serverinfo_http_vibepollo() -> void:
	var i := GameStream.parse_serverinfo(_f("serverinfo_vibepollo_http.xml"))
	eq(i["name"], "GAMING-PC", "hostname")
	eq(i["uuid"], "A1B2C3D4-0000-4E5F-8899-AABBCCDDEEFF", "uuid")
	eq(i["mac"], "", "dummy MAC over HTTP is dropped")
	eq(i["flavor"], "vibepollo", "flavor")
	ok(i["av1"] and i["hevc"] and i["hdr"], "codecs from ServerCodecModeSupport")
	eq(i["busy"], false, "HTTP state is never trusted")
	eq(i["current_app"], 0, "no current game over HTTP")
	eq(i["permission"], -1, "permission unknown over HTTP")
	eq(i["https_port"], 47984, "https port")
	ok(i["virtual_display"] and i["virtual_display_hdr"], "virtual display")


func test_serverinfo_https_paired_busy() -> void:
	var i := GameStream.parse_serverinfo(_f("serverinfo_vibepollo_https.xml"), true)
	eq(i["mac"], "D8:BB:C1:12:34:56", "real MAC")
	eq(i["busy"], true, "busy")
	eq(i["current_app"], 1093255277, "current app")
	eq(i["server_commands"], ["Turn off monitor", "Restart Steam"], "server commands repeat")
	ok(i["permission"] & GameStream.PERM_LAUNCH != 0, "launch permission")
	ok(i["sleep_supported"] and i["sleep_allowed"], "Vibepollo sleep")
	eq(i["paired"], true, "PairStatus")


func test_serverinfo_sunshine_and_bad() -> void:
	var i := GameStream.parse_serverinfo(_f("serverinfo_sunshine_http.xml"))
	eq(i["flavor"], "sunshine", "plain Sunshine")
	eq(i["av1"], false, "no AV1")
	eq(i["hdr"], true, "HEVC Main10")
	eq(GameStream.parse_serverinfo("<html>nope</html>"), {}, "not GameStream")
	eq(GameStream.parse_serverinfo(""), {}, "empty")
	eq(GameStream.parse_serverinfo("<root status_code=\"503\"><uniqueid>x</uniqueid></root>"), {}, "error status")


func test_applist() -> void:
	var r := GameStream.parse_applist(_f("applist.xml"))
	eq(r["ok"], true, "ok")
	eq(r["apps"].size(), 3, "three apps")
	eq(r["apps"][2]["title"], "Cyberpunk 2077 & Phantom Liberty", "entity decoded")
	eq(r["apps"][2]["id"], 1450239417, "id")
	eq(r["apps"][0]["hdr"], true, "hdr flag")
	var d := GameStream.parse_applist(_f("applist_denied.xml"))
	eq(d["denied"], true, "Vibepollo permission placeholder")
	eq(d["apps"], [], "no fake app shown")
	eq(GameStream.parse_applist(_f("applist_unauthorized.xml"))["ok"], false, "401 is not a list")


func test_moonlight_list_csv() -> void:
	var apps := GameStream.parse_list_csv(_f("moonlight_list_csv.txt"))
	eq(apps.size(), 3, "hidden app left out")
	eq(apps[2]["title"], "Elden Ring \"Nightreign\"", "doubled quotes")
	eq(apps[0]["art"], "", "placeholder art is no art")
	eq(apps[1]["art"], "/home/deck/.var/app/com.moonlight_stream.Moonlight/cache/Moonlight Game Streaming Project/Moonlight/boxart/A1B2/1093255277.png", "file URL decoded")


func test_avahi() -> void:
	var list := GameStream.parse_avahi(_f("avahi.txt"))
	eq(list.size(), 2, "dedup, link-local skipped")
	eq(list[0]["address"], "192.168.1.20", "IPv4 first")
	eq(list[1]["name"], "Living Room.PC", "avahi decimal escapes (space, dot)")
	eq(list[1]["port"], 48989, "moved port")


func test_arp_ip_and_subnets() -> void:
	var arp := GameStream.parse_arp(_f("arp.txt"))
	eq(arp.get("192.168.1.20", ""), "D8:BB:C1:12:34:56", "arp mac")
	ok(not arp.has("192.168.1.77"), "incomplete entry skipped")
	var nets := GameStream.parse_ip_addr(_f("ip_addr.txt"))
	eq(nets.size(), 2, "loopback skipped")
	eq(nets[0]["broadcast"], "192.168.1.255", "broadcast")
	var hosts := GameStream.subnet_hosts("192.168.1.50", 24)
	eq(hosts.size(), 253, "254 minus ours")
	ok(not "192.168.1.50" in hosts and "192.168.1.1" in hosts and not "192.168.1.255" in hosts, "range")
	eq(GameStream.subnet_hosts("100.90.1.2", 32).size(), 0, "/32 not probed")
	eq(GameStream.subnet_hosts("10.0.0.5", 16).size(), 0, "too big to probe")


func test_addresses() -> void:
	eq(GameStream.parse_address(" 192.168.1.20 "), {"address": "192.168.1.20", "port": 47989}, "ip")
	eq(GameStream.parse_address("gaming-pc.local:48989"), {"address": "gaming-pc.local", "port": 48989}, "name and port")
	eq(GameStream.parse_address("[fd7a:115c::1]:47989"), {"address": "fd7a:115c::1", "port": 47989}, "ipv6")
	eq(GameStream.parse_address("https://my-pc.tail1234.ts.net/"), {"address": "my-pc.tail1234.ts.net", "port": 47989}, "url")
	eq(GameStream.parse_address("not an address"), {}, "spaces")
	eq(GameStream.parse_address("pc:99999"), {}, "bad port")
	ok(GameStream.is_tailscale("100.101.102.103"), "tailscale range")
	ok(not GameStream.is_tailscale("100.128.0.1"), "outside CGNAT")
	ok(GameStream.is_lan("192.168.1.20") and GameStream.is_lan("10.1.2.3") and GameStream.is_lan("pc.local"), "lan")
	ok(not GameStream.is_lan("203.0.113.9"), "public")
	eq(GameStream.url_host("fd00::1"), "[fd00::1]", "brackets")


## The fixture is no one's Moonlight identity (final review, low: "contains a PEM private key; make
## sure it's a throwaway"). Its client certificate and "PRIVATE KEY" blocks are stubs, cut off
## after the first base64 line: 48 and 39 bytes of what would be 727 and 1217, i.e. the ASN.1
## headers and nothing of a key. The one complete certificate is a server certificate made with
## openssl for the pinning test below (self-signed "NVIDIA GameStream Server", created
## 2026-11-09), and a certificate is public anyway. This test keeps it that way.
func test_moonlight_fixture_holds_no_private_key() -> void:
	var text := _f("Moonlight.conf")
	var re := RegEx.create_from_string("-----BEGIN ([A-Z ]+)-----(.*?)-----END")
	var kinds: Array = []
	for m in re.search_all(text):
		var raw := Marshalls.base64_to_raw(m.get_string(2).replace("\\n", "").strip_edges())
		kinds.append(m.get_string(1))
		if m.get_string(1).contains("PRIVATE KEY"):
			# DER says how long the whole key would be (bytes 2-3, plus the 4-byte header)
			var declared := (raw[2] << 8 | raw[3]) + 4
			ok(raw.size() < 64 and declared > 1000, "the key block is a %d-byte stub of a %d-byte structure: no key material" % [raw.size(), declared])
	eq(kinds.count("PRIVATE KEY"), 1, "one key block, the stub")
	ok(not text.contains("ENCRYPTED") and not text.contains("RSA PRIVATE KEY") and not text.contains("EC PRIVATE KEY"), "no other kind of key")


func test_moonlight_conf() -> void:
	var c := Moonlight.parse_conf(_f("Moonlight.conf"))
	ok(str(c["cert"]).begins_with("-----BEGIN CERTIFICATE-----\nMIIC"), "client cert with real newlines")
	ok(str(c["key"]).contains("PRIVATE KEY"), "key")
	eq(c["hosts"].size(), 2, "two hosts")
	var h: Dictionary = c["hosts"][0]
	eq(h["name"], "GAMING-PC", "name")
	eq(h["mac"], "D8:BB:C1:12:34:56", "MAC bytes with hex-digit escapes")
	eq(h["paired"], true, "srvcert means paired")
	eq(h["addresses"], ["192.168.1.20", "203.0.113.9"], "addresses")
	eq(c["hosts"][1]["paired"], false, "empty srvcert")
	eq(c["hosts"][1]["mac"], "", "no MAC")
	eq(c["hosts"][1]["addresses"], ["100.101.102.103", "192.168.1.44"], "manual address first")
	eq(Moonlight.read_conf("/nonexistent/Moonlight.conf")["hosts"], [], "missing file")


func test_moonlight_commands() -> void:
	var fp := {"kind": "flatpak", "program": "/usr/bin/flatpak", "prefix": ["run", "--branch=stable", Moonlight.FLATPAK_ID]}
	eq(Moonlight.command(fp, Moonlight.list_args("192.168.1.20")),
		["/usr/bin/flatpak", "run", "--branch=stable", Moonlight.FLATPAK_ID, "list", "--csv", "--", "192.168.1.20"], "flatpak list")
	eq(Moonlight.command(fp, Moonlight.pair_args("pc", "0427"), {"QT_QPA_PLATFORM": "offscreen"}),
		["/usr/bin/flatpak", "run", "--env=QT_QPA_PLATFORM=offscreen", "--branch=stable", Moonlight.FLATPAK_ID, "pair", "--pin", "0427", "--", "pc"], "flatpak pair, env")
	var nat := {"kind": "native", "program": "/usr/bin/moonlight", "prefix": []}
	eq(Moonlight.command(nat, Moonlight.quit_args("pc"), {"QT_QPA_PLATFORM": "offscreen"}),
		["env", "QT_QPA_PLATFORM=offscreen", "/usr/bin/moonlight", "quit", "--", "pc"], "native with env")
	eq(Moonlight.command({"kind": ""}, ["list"]), [] as Array[String], "not installed")
	var r := Settings.resolve({}, {"width": 1920, "height": 1200, "hz": 120, "hdr": false}, Settings.decode_for_family("intel-xe2"),
		{"hevc": true, "av1": true, "hdr": true})
	var a := Moonlight.stream_args("192.168.1.20", "Steam Big Picture", r)
	eq(a[0], "stream", "the action first")
	eq(a.slice(a.size() - 3), ["--", "192.168.1.20", "Steam Big Picture"], "host and app last, after --")
	# final review (Low): a title or host that begins with "-" can't be read as an option
	var odd := Moonlight.stream_args("-h", "--version", {"width": 1280, "height": 800, "fps": 60, "bitrate_kbps": 10000, "codec": "auto"})
	eq(odd.slice(odd.size() - 3), ["--", "-h", "--version"], "everything after -- is a name, whatever it looks like")
	ok(odd.find("--") == odd.size() - 3, "and no option comes after it")
	for args in [Moonlight.list_args("-x"), Moonlight.pair_args("-x", "1234"), Moonlight.quit_args("-x")]:
		eq(args.slice(args.size() - 2), ["--", "-x"], "%s: the host comes last, after --" % args[0])
	ok("--resolution" in a and a[a.find("--resolution") + 1] == "1920x1200", "native resolution")
	ok(a[a.find("--fps") + 1] == "120", "panel refresh")
	ok(a[a.find("--video-codec") + 1] == "AV1", "AV1 on Xe2 with an AV1 host")
	ok("--no-hdr" in a and "--frame-pacing" in a and "--no-multi-controller" in a and "--keep-awake" in a, "toggles")
	ok(a[a.find("--display-mode") + 1] == "fullscreen", "fullscreen")


func test_locate(tmp := "user://test_streaming_locate") -> void:
	var root := ProjectSettings.globalize_path(tmp)
	DirAccess.make_dir_recursive_absolute(root + "/home/deck/.local/share/flatpak/app/" + Moonlight.FLATPAK_ID + "/current")
	DirAccess.make_dir_recursive_absolute(root + "/usr/bin")
	FileAccess.open(root + "/usr/bin/flatpak", FileAccess.WRITE).store_string("#!/bin/sh\n")
	var m := Moonlight.locate("/home/deck", "/usr/local/bin:/usr/bin", root)
	eq(m["kind"], "flatpak", "user flatpak")
	eq(m["scope"], "user", "scope")
	eq(m["program"], "/usr/bin/flatpak", "flatpak binary")
	ok(str(m["config"]).ends_with("/.var/app/com.moonlight_stream.Moonlight/config/Moonlight Game Streaming Project/Moonlight.conf"), "config path")
	var none := Moonlight.locate("/home/nobody", "/nowhere", root)
	eq(none["kind"], "", "nothing")
	OS.move_to_trash(root)


func test_bitrate_matches_moonlight() -> void:
	eq(Settings.moonlight_default_kbps(1280, 720, 60), 10000, "720p60")
	eq(Settings.moonlight_default_kbps(1920, 1080, 60), 20000, "1080p60")
	eq(Settings.moonlight_default_kbps(1920, 1080, 120), 28000, "1080p120: sqrt above 60")
	eq(Settings.moonlight_default_kbps(1920, 1200, 60), 23000, "interpolated 1200p")
	eq(Settings.moonlight_default_kbps(3840, 2160, 30), 40000, "4k30")


func test_vainfo_and_codec() -> void:
	var d := Settings.parse_vainfo(_f("vainfo_rdna2.txt"))
	eq(d, {"h264": true, "hevc": true, "hevc10": true, "av1": false}, "Van Gogh")
	var x := Settings.parse_vainfo(_f("vainfo_xe2.txt"))
	eq(x["av1"], true, "Xe2 AV1 decode")
	var host_all := {"hevc": true, "av1": true, "hdr": true}
	eq(Settings.pick_codec("auto", d, host_all), "HEVC", "no AV1 decode")
	eq(Settings.pick_codec("auto", x, host_all), "AV1", "AV1 both ends")
	eq(Settings.pick_codec("AV1", x, {"hevc": true, "av1": false}), "HEVC", "host can't AV1")
	eq(Settings.pick_codec("H.264", x, host_all), "H.264", "explicit")


func test_resolve_rules() -> void:
	var disp := {"width": 1280, "height": 800, "hz": 60, "hdr": true}
	var dec := Settings.decode_for_family("amd-rdna3")
	var r := Settings.resolve({"fps": 120, "quality": "best", "hdr": true}, disp, dec, {"hevc": true, "av1": true, "hdr": true})
	eq(r["fps"], 60, "fps capped to the panel")
	ok("fps_capped" in r["notes"], "note")
	eq(r["hdr"], true, "hdr possible")
	eq(r["bitrate_kbps"], int(Settings.moonlight_default_kbps(1280, 800, 60) * 1.6), "best = 1.6x")
	var r2 := Settings.resolve({"hdr": true}, {"width": 1280, "height": 800, "hz": 60, "hdr": false}, dec, {"hevc": true, "av1": true, "hdr": true})
	eq(r2["hdr"], false, "panel not in HDR")
	ok("hdr_off" in r2["notes"], "hdr note")
	var r3 := Settings.resolve({"resolution": "1080p", "fps": 60}, disp, dec, {"hevc": false, "av1": false, "hdr": false})
	eq([r3["width"], r3["height"], r3["codec"]], [1920, 1080, "H.264"], "1080p, H.264 only host")
	eq(Settings.merged({}, {}, true)["quality"], "saver", "remote PCs start on saver")
	eq(Settings.merged({"quality": "best"}, {}, true)["quality"], "best", "user pick wins")
	eq(Settings.summary(r3), "1920x1080 · 60 fps · H.264 · 20 Mb/s", "summary")


func test_wol() -> void:
	var p := Wol.magic_packet("D8:BB:C1:12:34:56")
	eq(p.size(), 102, "102 bytes")
	eq(p.slice(0, 6), PackedByteArray([255, 255, 255, 255, 255, 255]), "sync")
	eq(p.slice(6, 12), PackedByteArray([0xD8, 0xBB, 0xC1, 0x12, 0x34, 0x56]), "mac")
	eq(p.slice(96, 102), PackedByteArray([0xD8, 0xBB, 0xC1, 0x12, 0x34, 0x56]), "16th mac")
	eq(Wol.magic_packet("nope").size(), 0, "bad mac")
	var t := Wol.targets(["192.168.1.20", "fd00::1"], 48989, ["192.168.1.255"])
	ok(["192.168.1.20", 9] in t and ["192.168.1.20", 47009] in t, "static ports")
	ok(["192.168.1.20", 48998] in t and ["192.168.1.20", 49010] in t, "offset dynamic ports")
	ok(["255.255.255.255", 9] in t and ["192.168.1.255", 9] in t, "broadcasts")
	ok(not ["255.255.255.255", 47998] in t, "dynamic ports only to the PC")
	ok(t.all(func(x): return not str(x[0]).contains(":")), "no IPv6")
	var sent: Array = []
	ok(Wol.wake("D8:BB:C1:12:34:56", ["192.168.1.20"], 47989, [], func(a, port, b): sent.append([a, port, b.size()]); return true), "wake")
	ok(sent.size() >= 8 and sent.all(func(s): return s[2] == 102), "packets sent")


func test_host_api() -> void:
	var c := HostApi.serverinfo_http("192.168.1.20", 47989)
	eq(c[0], "curl", "curl")
	ok(str(c[c.size() - 1]) == "http://192.168.1.20:47989/serverinfo?uniqueid=0123456789ABCDEF", "url")
	var s := HostApi.applist("fd00::1", 47984, {"cert": "/run/c.pem", "key": "/run/c.key"})
	ok("--cert" in s and "-k" in s and str(s[s.size() - 1]).begins_with("https://[fd00::1]:47984/applist"), "applist with cert")
	var sp := HostApi.split({"code": 0, "out": "<root/>\n@@gamecove 200 0.004213"})
	eq(sp, {"ok": true, "code": 200, "body": "<root/>", "ms": 4}, "split")
	var down := HostApi.split({"code": 7, "out": "curl: (7) Failed to connect\n@@gamecove 000 0.000000"})
	eq([down["ok"], down["code"], down["ms"]], [false, 0, -1], "no answer")


## review M27: GameStream HTTPS is pinned to the certificate Moonlight stored when it paired
func test_host_api_pins_the_paired_certificate() -> void:
	var conf := Moonlight.parse_conf(_f("Moonlight.conf"))
	var pem := str(conf["hosts"][0]["srvcert"])
	ok(pem.begins_with("-----BEGIN CERTIFICATE-----"), "srvcert read from Moonlight.conf")
	# openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
	eq(HostApi.pin_for_pem(pem), "sha256//B3MbKcgJf0lgDvPJd+V8AxkMCntC8aoBkmuyCP+YXhg=", "SPKI sha256 like curl and openssl")
	eq(HostApi.pin_for_pem(""), "", "no certificate: no pin")
	eq(HostApi.pin_for_pem("-----BEGIN CERTIFICATE-----\nMIIC\n-----END CERTIFICATE-----"), "", "truncated: no pin")
	var pin := HostApi.pin_for_pem(pem)
	for cmd in [HostApi.serverinfo_https("10.0.0.2", 47984, {"cert": "c", "key": "k", "pin": pin}),
			HostApi.applist("10.0.0.2", 47984, {"cert": "c", "key": "k", "pin": pin}),
			HostApi.appasset("10.0.0.2", 47984, {"cert": "c", "key": "k", "pin": pin}, 5, "/tmp/x.png"),
			HostApi.sleep_pc("10.0.0.2", 47984, {"cert": "c", "key": "k", "pin": pin})]:
		var i: int = cmd.find("--pinnedpubkey")
		ok(i > 0 and cmd[i + 1] == pin, "every HTTPS call carries the pin: " + str(cmd[cmd.size() - 1]))
	var nopin := HostApi.applist("10.0.0.2", 47984, {"cert": "c", "key": "k"})
	var j: int = nopin.find("--pinnedpubkey")
	ok(j > 0 and nopin[j + 1] != pin and str(nopin[j + 1]).begins_with("sha256//AAAA"), "no pin: fails closed")
