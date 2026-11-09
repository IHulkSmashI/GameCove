extends RefCounted
## Driver / software stack versions: what runs here, what the OS channel would bring and what
## upstream has released. On Linux the drivers live in the kernel, Mesa and linux-firmware, so
## they update with the OS image (rpm-ostree on Bazzite, the SteamOS updater on SteamOS); the
## handheld daemons come with the image too on Bazzite. Pure static parsers; Updates runs the
## commands on its worker.
##
## Status per item: "current" (same as upstream), "update" (the pending OS update brings a
## newer one), "upstream" (upstream is newer, the OS channel doesn't have it yet: nothing to do
## but wait), "unknown".

## name -> {"title", "rpm": package, "pacman": package, "os": true when the OS image ships it}
const STACK := {
	"kernel": {"title": "Linux kernel", "os": true},
	"mesa": {"title": "Mesa (graphics drivers)", "rpm": "mesa-dri-drivers", "pacman": "mesa", "os": true},
	"linux-firmware": {"title": "linux-firmware (Wi-Fi, GPU, Bluetooth firmware)", "rpm": "linux-firmware", "pacman": "linux-firmware", "os": true},
	"inputplumber": {"title": "InputPlumber", "rpm": "inputplumber", "pacman": "inputplumber", "os": true},
	"powerstation": {"title": "PowerStation", "rpm": "powerstation", "pacman": "powerstation", "os": true},
	"hhd": {"title": "Handheld Daemon", "rpm": "hhd", "pacman": "hhd", "os": true},
	"decky": {"title": "Decky Loader", "os": false},
	"xess-xmx": {"title": "XeSS XMX driver", "os": false},
	"optiscaler": {"title": "OptiScaler", "os": false},
}
const DECKY_VERSION := "/homebrew/services/.loader.version"
const NOTES := {
	"decky": "https://github.com/SteamDeckHomebrew/decky-loader/releases",
	"xess-xmx": "https://github.com/HHHHanasak1/xess-xmx-linux/releases",
	"optiscaler": "https://github.com/optiscaler/OptiScaler/releases",
}


## "6.17.7-ba01.fc44.x86_64" -> "6.17.7"; "1:25.2.4-1" -> "25.2.4"; "v3.1.10" -> "3.1.10";
## "20261019-1.fc44" -> "20261019".
static func upstream_part(v: String) -> String:
	v = v.strip_edges()
	if v.contains(":"):
		v = v.get_slice(":", 1)
	v = v.trim_prefix("v")
	var m := RegEx.create_from_string("^(\\d+(?:\\.\\d+)*)").search(v)
	return m.get_string(1) if m else v


## `rpm -q --qf "%{NAME} %{VERSION}\n" a b c` -> {"a": "1.2"}; missing packages are skipped.
static func rpm_versions(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var p := line.strip_edges().split(" ", false)
		if p.size() == 2 and not line.contains("not installed"):
			out[p[0]] = p[1]
	return out


## `pacman -Q a b c` -> {"a": "1:25.2.4-1"}; "error: package 'x' was not found" lines skipped.
static func pacman_versions(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		if line.begins_with("error"):
			continue
		var p := line.strip_edges().split(" ", false)
		if p.size() == 2:
			out[p[0]] = p[1]
	return out


## Package changes in `rpm-ostree upgrade --preview` (the "Upgraded:" block):
## {"mesa-dri-drivers": "25.2.6"} (upstream part of the new version).
static func rpm_ostree_preview(text: String) -> Dictionary:
	var out := {}
	var re := RegEx.create_from_string("^\\s+(\\S+)\\s+(\\S+)\\s+->\\s+(\\S+)\\s*$")
	var inside := false
	for line in text.split("\n"):
		if line.strip_edges().begins_with("Upgraded:"):
			inside = true
			continue
		if inside and line.strip_edges() != "" and not line.begins_with(" "):
			inside = false
		if inside:
			var m := re.search(line)
			if m:
				out[m.get_string(1)] = upstream_part(m.get_string(3))
	return out


## The JSON object in a helper's output (last {...} line), or {}.
static func helper_json(text: String) -> Dictionary:
	var lines := text.strip_edges().split("\n", false)
	for i in range(lines.size() - 1, -1, -1):
		var l := lines[i].strip_edges()
		if l.begins_with("{"):
			var j := JSON.new()
			if j.parse(l) == OK and j.data is Dictionary:
				return j.data
	var j2 := JSON.new()
	return j2.data if j2.parse(text) == OK and j2.data is Dictionary else {}


static func _cmp(a: String, b: String) -> int:
	return preload("res://scripts/system/firmware_index.gd").compare("natural", a, b)


## Hub items for the stack.
## installed: name -> running version ("" when absent); software: index "software" block;
## in_os_update: name -> version the pending OS update brings; os_family: "bazzite" | "steamos" | ...
static func items(installed: Dictionary, software: Dictionary, in_os_update: Dictionary, os_family: String) -> Array:
	var out: Array = []
	for name in STACK:
		var cur := str(installed.get(name, ""))
		if cur == "":
			continue
		var spec: Dictionary = STACK[name]
		var up: Dictionary = software.get(name, {}) if software.get(name) is Dictionary else {}
		var latest := str(up.get("version", ""))
		var cur_up := upstream_part(cur)
		var next := str(in_os_update.get(name, ""))
		var status := "unknown"
		if next != "" and _cmp(cur_up, next) < 0:
			status = "update"
		elif latest != "":
			var c := _cmp(cur_up, upstream_part(latest))
			status = "unknown" if c == -2 else ("current" if c >= 0 else "upstream")
		var how := "auto" if spec["os"] else ("link" if name == "decky" else "guided")
		out.append({
			"id": "driver:" + name, "section": "drivers", "kind": name, "name": spec["title"],
			"current": cur_up, "latest": next if status == "update" else (upstream_part(latest) if latest != "" else ""),
			"upstream": upstream_part(latest) if latest != "" else "", "in_os_update": next,
			"status": status, "severity": "recommended" if status == "update" else "info",
			"how": how, "flash": "os" if spec["os"] else name,
			"notes": "", "notes_url": str(up.get("notes_url", NOTES.get(name, ""))), "download_page": NOTES.get(name, ""),
			"download_url": "", "sha256": "", "date": str(up.get("date", "")), "source": "os" if spec["os"] else "local",
			"os_family": os_family,
		})
	return out
