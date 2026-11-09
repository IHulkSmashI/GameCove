extends "res://tests/test_case.gd"
## Audio (providers/audio.gd) and radios / system actions (providers/system.gd)
## against the fake PipeWire, NetworkManager, BlueZ, rfkill and gamescope.

const Env := preload("res://tests/fixtures/ctl_display/env.gd")
const AudioProvider := preload("res://scripts/controls/providers/audio.gd")
const SystemProvider := preload("res://scripts/controls/providers/system.gd")
const Wp := preload("res://scripts/controls/display/wpctl.gd")
const T := preload("res://scripts/controls/display/texts_display.gd")

const RADIOS := {
	"sys/class/ieee80211/phy0/index": "0\n",
	"sys/class/bluetooth/hci0/name": "hci0\n",
	"sys/class/rfkill/rfkill0/type": "wlan\n", "sys/class/rfkill/rfkill0/soft": "0\n", "sys/class/rfkill/rfkill0/hard": "0\n",
	"sys/class/rfkill/rfkill1/type": "bluetooth\n", "sys/class/rfkill/rfkill1/soft": "0\n", "sys/class/rfkill/rfkill1/hard": "0\n",
	"sys/power/state": "freeze mem disk\n",
}


func _audio(s: Dictionary) -> Dictionary:
	return _detect(AudioProvider.new(), s)


func _system(s: Dictionary, p = null) -> Dictionary:
	return _detect(p if p != null else SystemProvider.new(), s)


func _detect(p, s: Dictionary) -> Dictionary:
	var out := {}
	for c in p.controls():
		c.ctx = s.ctx
		c.detect()
		c.read()
		out[c.id] = c
	return out


func _speakers(s: Dictionary) -> void:
	s.fake.sinks = [{"id": 48, "name": "Speaker", "volume": 0.4, "muted": false},
		{"id": 49, "name": "HDMI / DisplayPort 1 Output", "volume": 1.0, "muted": false}]
	s.fake.sources = [{"id": 50, "name": "Digital Microphone", "volume": 1.0, "muted": false}]
	s.fake.default_sink = 48
	s.fake.default_source = 50


# --- wpctl parsing ----------------------------------------------------------

func test_parse_wpctl_status() -> void:
	var s := Env.make("wp_parse", "steam-deck-oled")
	_speakers(s)
	s.fake.streams = [{"id": 70, "name": "Hades II", "volume": 1.0}]
	var st := Wp.parse_status(s.fake.status_text())
	eq(st["sinks"].size(), 2, "two outputs")
	eq(st["sinks"][0], {"id": 48, "name": "Speaker", "default": true, "volume": 0.4, "muted": false}, "default speaker")
	eq(st["sinks"][1]["name"], "HDMI / DisplayPort 1 Output", "HDMI name intact")
	eq(st["sources"][0]["name"], "Digital Microphone", "mic")
	eq(st["streams"], [{"id": 70, "name": "Hades II"}], "streams, not their ports")
	var muted := Wp.parse_status("Audio\n ├─ Sinks:\n │  *   52. Headphones  [vol: 0.25 MUTED]\n │  \n")
	eq(muted["sinks"][0]["muted"], true, "MUTED inside the brackets")
	eq(Wp.parse_volume("Volume: 0.45 [MUTED]\n"), {"volume": 0.45, "muted": true}, "get-volume")
	eq(Wp.parse_volume("Volume: 1.00\n"), {"volume": 1.0, "muted": false}, "not muted")
	eq(Wp.parse_volume("error"), {}, "junk")


# --- audio controls -------------------------------------------------------------

func test_volume_and_mute() -> void:
	var s := Env.make("vol", "steam-deck-oled")
	_speakers(s)
	var c := _audio(s)
	var v = c["audio.volume"]
	ok(v.available, v.reason)
	eq(v.value, 40.0, "read")
	ok(v.write(75), "write")
	ok(s.fake.calls.has("wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 0.75"), "limited to 100 %, default sink")
	eq(v.read(), 75.0, "read back")
	ok(v.write(150), "clamped")
	eq(s.fake.sinks[0]["volume"], 1.0, "never above 100 %")
	var m = c["audio.mute"]
	ok(m.write(true), "mute")
	eq(m.read(), true, "muted")
	ok(m.write(false), "unmute")
	eq(s.fake.sinks[0]["muted"], false, "unmuted")
	eq(v.per_game, false, "volume isn't per game")


func test_output_and_mic() -> void:
	var s := Env.make("out", "lenovo-legion-go")
	_speakers(s)
	var c := _audio(s)
	var o = c["audio.output"]
	eq(o.options.map(func(x): return x["value"]), ["Speaker", "HDMI / DisplayPort 1 Output"], "outputs by name")
	eq(o.value, "Speaker", "current default")
	ok(o.write("HDMI / DisplayPort 1 Output"), "switch")
	ok(s.fake.calls.has("wpctl set-default 49"), "by today's PipeWire id")
	eq(o.read(), "HDMI / DisplayPort 1 Output", "read back")
	ok(not o.write("Bluetooth thing"), "unknown output refused")
	var mic = c["audio.mic_mute"]
	ok(mic.write(true), "mic mute")
	eq(s.fake.sources[0]["muted"], true, "source muted")
	eq(c["audio.input"].value, "Digital Microphone", "mic choice")


## The fake system plus pipewire-pulse's `pactl -f json list sinks|sources`.
class WithPactl extends RefCounted:
	var inner: RefCounted
	var json := {}   # "sinks"/"sources" -> JSON text

	func run(program: String, args: PackedStringArray) -> Dictionary:
		if program == "pactl":
			inner.calls.append("pactl " + " ".join(args))
			return {"code": 0, "out": json.get(args[3], "[]")} if json.has(args[3]) else {"code": 1, "out": ""}
		return inner.run(program, args)


## The Claw 8 EX (Bazzite 45): UCM gives every jack its own node; nothing was plugged in.
func test_claw_unplugged_jacks_are_not_offered() -> void:
	var s := Env.make("jacks", "msi-claw-8-ex")
	var spk := "Core Ultra Processors (Series 3) HD Audio Speaker"
	var hp := "Core Ultra Processors (Series 3) HD Audio Headphones"
	var mic := "Core Ultra Processors (Series 3) HD Audio SoundWire microphones"
	var hs := "Core Ultra Processors (Series 3) HD Audio Headset Microphone"
	s.fake.sinks = [{"id": 60, "name": spk, "volume": 0.5, "muted": false}, {"id": 61, "name": hp, "volume": 0.5, "muted": false}]
	s.fake.sources = [{"id": 70, "name": mic, "volume": 1.0, "muted": false}, {"id": 71, "name": hs, "volume": 1.0, "muted": false}]
	s.fake.default_sink = 60
	s.fake.default_source = 70
	var w := WithPactl.new()
	w.inner = s.fake
	w.json = {
		"sinks": JSON.stringify([
			{"name": "alsa_output.speaker", "description": spk, "active_port": "[Out] Speaker",
				"ports": [{"name": "[Out] Speaker", "availability": "availability unknown"}]},
			{"name": "alsa_output.headphones", "description": hp, "active_port": "[Out] Headphones",
				"ports": [{"name": "[Out] Headphones", "availability": "not available"}]}]),
		"sources": JSON.stringify([
			{"name": "alsa_input.dmic", "description": mic, "active_port": "[In] Mic1",
				"ports": [{"name": "[In] Mic1", "availability": "availability unknown"}]},
			{"name": "alsa_input.headset", "description": hs, "active_port": "[In] Mic2",
				"ports": [{"name": "[In] Mic2", "availability": "not available"}]},
			{"name": "alsa_output.speaker.monitor", "description": "Monitor of " + spk, "ports": []}])}
	s.ctx["runner"] = w
	var c := _audio(s)
	eq(c["audio.output"].options.map(func(x): return x["value"]), [spk], "headphones jack empty: not offered")
	eq(c["audio.input"].options.map(func(x): return x["value"]), [mic], "headset mic jack empty: not offered")
	ok(not c["audio.output"].write(hp), "an empty jack is refused")
	ok(not s.fake.calls.has("wpctl set-default 61"), "nothing switched")
	# plugged in: offered
	w.json["sinks"] = w.json["sinks"].replace("not available", "available")
	c = _audio(s)
	eq(c["audio.output"].options.size(), 2, "headphones offered once plugged in")
	ok(c["audio.output"].write(hp), "and selectable")


func test_audio_reasons() -> void:
	var s := Env.make("noaudio", "steam-deck-oled")
	s.fake.wpctl_ok = false
	var c := _audio(s)
	for id in c:
		eq(c[id].reason, T.NO_WPCTL, id)
	var s2 := Env.make("nomic", "steam-deck-oled")
	_speakers(s2)
	s2.fake.sources = []
	var c2 := _audio(s2)
	eq(c2["audio.mic_mute"].reason, T.NO_SOURCE, "no microphone")
	ok(c2["audio.volume"].available, "speakers still fine")


func test_per_app_streams() -> void:
	var s := Env.make("streams", "steam-deck-oled")
	_speakers(s)
	s.fake.streams = [{"id": 70, "name": "Hades II", "volume": 1.0}]
	var p = AudioProvider.new()
	eq(p.streams(s.ctx), [{"id": 70, "name": "Hades II"}], "apps")
	ok(p.set_stream_volume(s.ctx, 70, 30), "set")
	eq(s.fake.streams[0]["volume"], 0.3, "stream volume")
	ok(not p.set_stream_volume(s.ctx, 0, 30), "bad id")


# --- Wi-Fi / Bluetooth / airplane --------------------------------------------------

func test_wifi() -> void:
	var s := Env.make("wifi", "steam-deck-oled", RADIOS)
	var w = _system(s)["network.wifi"]
	ok(w.available, w.reason)
	eq(w.value, true, "on")
	ok(w.write(false), "off")
	eq(s.fake.wifi_enabled, false, "nmcli radio wifi off")
	FileAccess.open(s.root + "/sys/class/rfkill/rfkill0/soft", FileAccess.WRITE).store_string("1\n")
	ok(w.write(true), "on again")
	ok(s.fake.calls.has("rfkill unblock wlan"), "soft block lifted first")
	eq(w.read(), true, "on")
	var none := Env.make("nowifi", "steam-deck-oled")
	eq(_system(none)["network.wifi"].reason, T.NO_WIFI, "no adapter")
	var nonm := Env.make("nonm", "steam-deck-oled", RADIOS)
	nonm.fake.nmcli_ok = false
	eq(_system(nonm)["network.wifi"].reason, T.NO_NMCLI, "no NetworkManager")


func test_bluetooth() -> void:
	var s := Env.make("bt", "msi-claw-8-ex", RADIOS)
	var b = _system(s)["network.bluetooth"]
	ok(b.available, b.reason)
	eq(b.value, true, "powered")
	ok(b.write(false), "off")
	ok(s.fake.calls.has("busctl --system set-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered b false"), "BlueZ Powered")
	FileAccess.open(s.root + "/sys/class/rfkill/rfkill1/soft", FileAccess.WRITE).store_string("1\n")
	ok(b.write(true), "on while soft-blocked")
	eq(s.fake.bt_powered, true, "unblocked, then powered")
	var none := Env.make("nobt", "msi-claw-8-ex")
	eq(_system(none)["network.bluetooth"].reason, T.NO_BT, "no adapter")


## A dock or dongle on hci0, the user's devices paired on hci1 (Outpox/Bluetooth's rule).
func test_bluetooth_switches_the_adapter_with_paired_devices() -> void:
	var files := RADIOS.duplicate()
	files["sys/class/bluetooth/hci1/name"] = "hci1\n"
	var s := Env.make("bt2", "msi-claw-8-ex", files)
	s.fake.bt_devices = {"/org/bluez/hci0/dev_11_22": false, "/org/bluez/hci1/dev_AA_BB": true}
	var b = _system(s)["network.bluetooth"]
	ok(b.write(false), "off")
	eq(s.fake.bt_set_paths, ["/org/bluez/hci1"], "the adapter owning the paired device")
	s.fake.bt_devices = {}
	s.fake.bt_set_paths = []
	var b2 = _system(s)["network.bluetooth"]
	ok(b2.write(true), "on")
	eq(s.fake.bt_set_paths, ["/org/bluez/hci0"], "nothing paired: the lowest adapter")
	var nobluez := Env.make("nobluez", "msi-claw-8-ex", RADIOS)
	nobluez.fake.bluez_ok = false
	eq(_system(nobluez)["network.bluetooth"].reason, T.NO_BLUEZ, "bluetoothd not running")


func test_airplane_restores_what_was_on() -> void:
	var s := Env.make("air", "asus-rog-ally", RADIOS)
	var p = SystemProvider.new()
	var c := _system(s, p)
	ok(c["network.bluetooth"].write(false), "Bluetooth off before")
	var a = c["network.airplane"]
	eq(a.value, false, "not in airplane mode")
	ok(a.write(true), "airplane on")
	ok(s.fake.calls.has("rfkill block all"), "every radio")
	eq(a.read(), true, "all blocked")
	ok(a.write(false), "airplane off")
	eq(FileAccess.get_file_as_string(s.root + "/sys/class/rfkill/rfkill0/soft").strip_edges(), "0", "Wi-Fi back")
	eq(FileAccess.get_file_as_string(s.root + "/sys/class/rfkill/rfkill1/soft").strip_edges(), "1", "Bluetooth stays off as it was")
	eq(s.fake.bt_powered, false, "not powered")
	eq(a.read(), false, "out of airplane mode")
	var none := Env.make("noair", "asus-rog-ally")
	eq(_system(none)["network.airplane"].reason, T.NO_RFKILL, "no radios")


func test_wifi_power_save() -> void:
	var s := Env.make("wpm", "steam-deck-oled", RADIOS)
	var w = _system(s)["network.wifi_power_save"]
	eq(w.value, true, "on (1)")
	ok(w.write(false), "off")
	eq(s.fake.wifi_pm, 0, "steamos-manager property")
	var s2 := Env.make("wpm2", "steam-deck-oled", RADIOS)
	s2.fake.steamos_manager = false
	eq(_system(s2)["network.wifi_power_save"].reason, T.NO_STEAMOS_MANAGER, "needs steamos-manager")


# --- sleep / screenshot / keep awake ----------------------------------------------------

func test_sleep() -> void:
	var s := Env.make("sleep", "steam-deck-oled", RADIOS)
	var z = _system(s)["system.sleep"]
	ok(z.available, z.reason)
	ok(z.write(true), "sleep")
	ok(s.fake.calls.has("systemctl suspend"), "logind suspend")
	var none := Env.make("nosleep", "steam-deck-oled")
	eq(_system(none)["system.sleep"].reason, T.NO_SLEEP, "no /sys/power/state")


func test_screenshot() -> void:
	var s := Env.make("shot", "steam-deck-oled")
	var sh = _system(s)["system.screenshot"]
	ok(sh.available, sh.reason)
	ok(sh.write(true), "taken")
	ok(s.fake.calls.has("xprop -root -f GAMESCOPECTRL_REQUEST_SCREENSHOT 32c -set GAMESCOPECTRL_REQUEST_SCREENSHOT 1"), "base-plane screenshot request")
	var path: String = sh.get_meta("last_path", "")
	ok(path.begins_with(s.ctx.home.path_join("Pictures/Screenshots/GameCove_")), "saved under Pictures: " + path)
	ok(FileAccess.get_file_as_string(path).begins_with("PNG-"), "copied")
	ok(sh.write(true), "second one")
	ok(sh.get_meta("last_path") != path, "never overwrites")
	s.fake.props.clear()
	var off = _system(s)["system.screenshot"]
	eq(off.reason, T.NO_GAMESCOPE, "needs gamescope")


func test_keep_awake() -> void:
	var s := Env.make("awake", "steam-deck-oled")
	var p = SystemProvider.new()
	var k = _system(s, p)["system.keep_awake"]
	eq(k.value, false, "off")
	ok(k.write(true), "on")
	eq(k.read(), true, "inhibitor running")
	ok(k.write(true), "on twice keeps one inhibitor")
	ok(k.write(false), "off")
	eq(k.read(), false, "inhibitor gone")
	eq(k.per_game, false, "not per game")
