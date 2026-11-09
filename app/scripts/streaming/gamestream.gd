extends RefCounted
## The GameStream protocol pieces GameCove reads itself (no video: Moonlight does
## the streaming). Pure functions, no I/O, so every parser is tested with
## fixtures captured from Sunshine / Apollo / Vibepollo.
##
## Ports (Sunshine's defaults, "port" setting = 47989): HTTP 47989 (serverinfo,
## pairing), HTTPS 47984 (serverinfo with the paired client's certificate,
## applist, appasset, launch, cancel), web UI 47990 (HTTPS), RTSP 48010.
## Hosts may move them: serverinfo's HttpsPort / ExternalPort say where.
## mDNS: Sunshine and its forks announce `_nvstream._tcp` (avahi on Linux,
## DNS-SD on Windows) on the HTTP port.
##
## serverinfo over HTTP (no certificate) gives hostname, uniqueid, appversion,
## ports, codec support and a dummy MAC (00:00:00:00:00:00); state is always
## SUNSHINE_SERVER_FREE there. Over HTTPS with a paired certificate it adds the
## real MAC, currentgame, Permission bits and, on Vibepollo, PowerActionVersion /
## SleepSupported / SleepAllowed (sources: Apollo and Vibepollo src/nvhttp.cpp).

const HTTP_PORT := 47989
const HTTPS_PORT := 47984
const WEB_UI_PORT := 47990
## What moonlight-qt sends as uniqueid: every Moonlight client uses this one id;
## hosts tell clients apart by certificate.
const UNIQUE_ID := "0123456789ABCDEF"
const MDNS_SERVICE := "_nvstream._tcp"
const DUMMY_MAC := "00:00:00:00:00:00"

## ServerCodecModeSupport bits (moonlight-common-c Limelight.h).
const SCM_H264 := 0x00000001
const SCM_HEVC := 0x00000100
const SCM_HEVC_MAIN10 := 0x00000200
const SCM_AV1_MAIN8 := 0x00010000
const SCM_AV1_MAIN10 := 0x00020000

## Apollo / Vibepollo client permission bits (src/crypto.h PERM). New clients get
## only list + view: launching and controller input must be allowed for the
## device in the host's web UI, so the page says so when they're missing.
const PERM_INPUT_CONTROLLER := 0x00000100
const PERM_SERVER_CMD := 0x00100000
const PERM_LIST := 0x01000000
const PERM_VIEW := 0x02000000
const PERM_LAUNCH := 0x04000000

## Vibepollo answers a client without "List applications" with one fake app.
const PERMISSION_DENIED_APP_ID := 114514


## Every direct child of <root> as text, plus "status_code" / "status_message"
## from root's attributes, and "ServerCommand" as an Array (it repeats).
## {} when `xml` isn't a GameStream answer.
static func parse_root(xml: String) -> Dictionary:
	var p := XMLParser.new()
	if xml.strip_edges() == "" or p.open_buffer(xml.to_utf8_buffer()) != OK:
		return {}
	var out := {}
	var depth := 0
	var current := ""
	var text := ""
	var commands: Array = []
	var seen_root := false
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var empty := p.is_empty()
				if depth == 0:
					if p.get_node_name() != "root":
						return {}
					seen_root = true
					for i in p.get_attribute_count():
						out[p.get_attribute_name(i)] = p.get_attribute_value(i)
				elif depth == 1:
					current = p.get_node_name()
					text = ""
					if empty:
						_store(out, commands, current, "")
						current = ""
				if not empty:
					depth += 1
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if depth == 2 and current != "":
					text += p.get_node_data()
			XMLParser.NODE_ELEMENT_END:
				depth -= 1
				if depth == 1 and current != "":
					_store(out, commands, current, text.strip_edges())
					current = ""
	if not seen_root:
		return {}
	out["ServerCommand"] = commands
	return out


static func _store(out: Dictionary, commands: Array, key: String, value: String) -> void:
	if key == "ServerCommand":
		commands.append(value)
	else:
		out[key] = value


## A serverinfo answer as GameCove uses it. `secure`: it came over HTTPS with a
## paired certificate (only then are mac / currentgame / permission real).
## {} when it isn't a valid answer.
static func parse_serverinfo(xml: String, secure := false) -> Dictionary:
	var r := parse_root(xml)
	if r.is_empty() or str(r.get("status_code", "200")) != "200" or str(r.get("uniqueid", "")) == "":
		return {}
	var mac := str(r.get("mac", "")).to_upper()
	if mac == DUMMY_MAC or not is_mac(mac):
		mac = ""
	var codecs := str(r.get("ServerCodecModeSupport", "0")).to_int()
	var version := str(r.get("appversion", ""))
	return {
		"name": str(r.get("hostname", "")),
		"uuid": str(r.get("uniqueid", "")),
		"version": version,
		"https_port": _port(r.get("HttpsPort", ""), HTTPS_PORT),
		"http_port": _port(r.get("ExternalPort", ""), HTTP_PORT),
		"mac": mac,
		"local_ip": str(r.get("LocalIP", "")),
		"codecs": codecs,
		"hevc": codecs & SCM_HEVC != 0 or str(r.get("MaxLumaPixelsHEVC", "0")) != "0",
		"av1": codecs & (SCM_AV1_MAIN8 | SCM_AV1_MAIN10) != 0,
		"hdr": codecs & (SCM_HEVC_MAIN10 | SCM_AV1_MAIN10) != 0,
		"paired": str(r.get("PairStatus", "0")) == "1",
		"busy": secure and str(r.get("state", "")).ends_with("_BUSY"),
		"current_app": str(r.get("currentgame", "0")).to_int() if secure else 0,
		"permission": str(r.get("Permission", "0")).to_int() if secure else -1,
		"server_commands": r.get("ServerCommand", []),
		"virtual_display": str(r.get("VirtualDisplayCapable", "")) in ["1", "true"],
		"virtual_display_hdr": str(r.get("VirtualDisplayHDRCapable", "")) in ["1", "true"],
		"sleep_supported": str(r.get("SleepSupported", "0")) == "1",
		"sleep_allowed": str(r.get("SleepAllowed", "0")) == "1",
		"flavor": flavor(r),
		"secure": secure,
	}


static func _port(v: Variant, fallback: int) -> int:
	var n := str(v).to_int()
	return n if n > 0 and n < 65536 else fallback


## "vibepollo" | "apollo" | "sunshine" | "gfe" from what serverinfo reveals:
## Vibepollo has its own extensions (HardwareMetricsVersion, FrameLimiterSupported),
## Apollo reports VirtualDisplayCapable or Permission, Sunshine neither; GeForce
## Experience has no ServerCodecModeSupport-style Sunshine version (appversion 7.1.x).
static func flavor(r: Dictionary) -> String:
	if r.has("HardwareMetricsVersion") or r.has("FrameLimiterSupported") or r.has("PowerActionVersion"):
		return "vibepollo"
	if r.has("VirtualDisplayCapable") or r.has("Permission") or r.has("currentgameuuid"):
		return "apollo"
	if str(r.get("appversion", "")).begins_with("7.1."):
		return "gfe"
	return "sunshine"


## <App> entries of an applist answer: [{"id": int, "title", "hdr": bool, "uuid"}].
## Vibepollo's "permission denied" placeholder comes back as
## {"denied": true} in place of the list (see PERMISSION_DENIED_APP_ID).
static func parse_applist(xml: String) -> Dictionary:
	var p := XMLParser.new()
	if xml.strip_edges() == "" or p.open_buffer(xml.to_utf8_buffer()) != OK:
		return {"ok": false, "apps": [], "denied": false}
	var apps: Array = []
	var cur := {}
	var field := ""
	var in_app := false
	var status := "200"
	var root_seen := false
	while p.read() == OK:
		match p.get_node_type():
			XMLParser.NODE_ELEMENT:
				var n := p.get_node_name()
				if n == "root":
					root_seen = true
					if p.has_attribute("status_code"):
						status = p.get_named_attribute_value("status_code")
				elif n == "App":
					in_app = true
					cur = {"id": 0, "title": "", "hdr": false, "uuid": ""}
				elif in_app:
					field = n if not p.is_empty() else ""
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				if in_app and field != "":
					var t := p.get_node_data().strip_edges()
					match field:
						"ID": cur["id"] = t.to_int()
						"AppTitle": cur["title"] = str(cur["title"]) + t
						"IsHdrSupported": cur["hdr"] = t == "1"
						"UUID": cur["uuid"] = t
			XMLParser.NODE_ELEMENT_END:
				var n := p.get_node_name()
				if n == "App" and in_app:
					in_app = false
					apps.append(cur)
				elif in_app:
					field = ""
	if not root_seen or status != "200":
		return {"ok": false, "apps": [], "denied": false}
	if apps.size() == 1 and int(apps[0]["id"]) == PERMISSION_DENIED_APP_ID and str(apps[0]["uuid"]) == "":
		return {"ok": true, "apps": [], "denied": true}
	return {"ok": true, "apps": apps, "denied": false}


## `moonlight list <host> --csv` output (moonlight-qt app/cli/listapps.cpp):
## a header, then "Name",ID,HDR,AppCollector,Hidden,DirectLaunch,"Boxart URL".
## Hidden apps are left out. Box art is a local file only when Moonlight cached it.
static func parse_list_csv(text: String) -> Array:
	var out: Array = []
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line == "" or line.begins_with("Name,") or not line.begins_with("\""):
			continue
		var f := csv_fields(line)
		if f.size() < 7:
			continue
		if f[4] == "true":
			continue
		var art := f[6]
		var local := ""
		if art.begins_with("file://"):
			local = art.trim_prefix("file://").uri_decode()
		out.append({"id": f[1].to_int(), "title": f[0], "hdr": f[2] == "true", "uuid": "", "art": local})
	return out


## One CSV line, double quotes escaped by doubling.
static func csv_fields(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var quoted := false
	var i := 0
	while i < line.length():
		var c := line[i]
		if quoted:
			if c == "\"":
				if i + 1 < line.length() and line[i + 1] == "\"":
					cur += "\""
					i += 1
				else:
					quoted = false
			else:
				cur += c
		elif c == "\"":
			quoted = true
		elif c == ",":
			out.append(cur)
			cur = ""
		else:
			cur += c
		i += 1
	out.append(cur)
	return out


## `avahi-browse -rpt _nvstream._tcp` (parsable, resolved, terminate):
## "=;eth0;IPv4;GAMING-PC;_nvstream._tcp;local;gaming-pc.local;192.168.1.20;47989;"
## Returns [{"name", "host", "address", "port", "ipv6": bool}], IPv4 first, one per
## name+address; link-local IPv6 (fe80::) is skipped (Moonlight can't use it bare).
static func parse_avahi(text: String) -> Array:
	var out: Array = []
	var seen := {}
	for raw in text.split("\n", false):
		var f := raw.split(";")
		if f.size() < 9 or f[0] != "=" or f[4] != MDNS_SERVICE:
			continue
		var addr := f[7]
		var v6 := f[2] == "IPv6"
		if v6 and addr.to_lower().begins_with("fe80"):
			continue
		var name := avahi_unescape(f[3])
		var k := name + "|" + addr
		if seen.has(k):
			continue
		seen[k] = true
		out.append({"name": name, "host": f[6], "address": addr, "port": f[8].to_int(), "ipv6": v6})
	out.sort_custom(func(a, b): return (not a["ipv6"]) and b["ipv6"])
	return out


## avahi-browse -p escapes dots, semicolons and backslashes as \DDD (decimal).
static func avahi_unescape(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "\\" and i + 3 < s.length() + 0 and s.substr(i + 1, 3).is_valid_int():
			out += String.chr(s.substr(i + 1, 3).to_int())
			i += 4
		else:
			out += s[i]
			i += 1
	return out


## /proc/net/arp → {ip: "AA:BB:CC:DD:EE:FF"} (complete entries only).
static func parse_arp(text: String) -> Dictionary:
	var out := {}
	for raw in text.split("\n", false):
		var f := raw.split(" ", false)
		if f.size() < 4 or f[0] == "IP":
			continue
		var mac := f[3].to_upper()
		if is_mac(mac) and mac != DUMMY_MAC and f[2] != "0x0":
			out[f[0]] = mac
	return out


## `ip -o -4 addr show` → [{"iface", "address", "prefix", "broadcast"}] without loopback.
static func parse_ip_addr(text: String) -> Array:
	var out: Array = []
	for raw in text.split("\n", false):
		var f := raw.split(" ", false)
		var i := f.find("inet")
		if i < 0 or i + 1 >= f.size() or f.size() < 2:
			continue
		var iface := f[1]
		if iface == "lo":
			continue
		var cidr := f[i + 1].split("/")
		var brd := ""
		var b := f.find("brd")
		if b >= 0 and b + 1 < f.size():
			brd = f[b + 1]
		out.append({"iface": iface, "address": cidr[0], "prefix": cidr[1].to_int() if cidr.size() > 1 else 32, "broadcast": brd})
	return out


## The addresses of a /prefix network to probe for hosts, without ours, the
## network and broadcast addresses. Only /22 and smaller (at most 1022 hosts).
static func subnet_hosts(address: String, prefix: int) -> PackedStringArray:
	var out := PackedStringArray()
	var ip := ip_to_int(address)
	if ip < 0 or prefix < 22 or prefix > 30:
		return out
	var mask := (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF
	var net := ip & mask
	var count := 1 << (32 - prefix)
	for n in range(1, count - 1):
		var a := net + n
		if a != ip:
			out.append(int_to_ip(a))
	return out


static func ip_to_int(s: String) -> int:
	var p := s.split(".")
	if p.size() != 4:
		return -1
	var v := 0
	for x in p:
		if not x.is_valid_int() or x.to_int() < 0 or x.to_int() > 255:
			return -1
		v = (v << 8) | x.to_int()
	return v


static func int_to_ip(v: int) -> String:
	return "%d.%d.%d.%d" % [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]


static func is_mac(s: String) -> bool:
	return RegEx.create_from_string("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$").search(s) != null


## What a user typed as a PC address: "192.168.1.20", "gaming-pc.local",
## "100.64.0.7:47989", "[fd7a::1]:47989", "my-pc.tailnet.ts.net".
## {"address", "port"} or {} when it can't be an address. Port defaults to 47989.
static func parse_address(text: String) -> Dictionary:
	var t := text.strip_edges()
	for scheme in ["http://", "https://"]:
		if t.to_lower().begins_with(scheme):
			t = t.substr(scheme.length())
	t = t.split("/")[0]
	if t == "":
		return {}
	var port := HTTP_PORT
	var host := t
	if t.begins_with("["):
		var end := t.find("]")
		if end < 0:
			return {}
		host = t.substr(1, end - 1)
		var rest := t.substr(end + 1)
		if rest.begins_with(":"):
			port = rest.substr(1).to_int()
	elif t.count(":") == 1:
		host = t.get_slice(":", 0)
		port = t.get_slice(":", 1).to_int()
	if port <= 0 or port > 65535:
		return {}
	var re := RegEx.create_from_string("^([A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*|[0-9A-Fa-f:]+)$")
	if re.search(host) == null or host.begins_with("-"):
		return {}
	return {"address": host, "port": port}


## An address for URLs: IPv6 in brackets.
static func url_host(address: String) -> String:
	return "[%s]" % address if address.contains(":") else address


## Tailscale's CGNAT range 100.64.0.0/10 or its MagicDNS names: shown as "Remote".
static func is_tailscale(address: String) -> bool:
	if address.ends_with(".ts.net"):
		return true
	var v := ip_to_int(address)
	return v >= 0 and (v >> 22) == (ip_to_int("100.64.0.0") >> 22)


## Private LAN ranges (RFC 1918, link-local, .local names).
static func is_lan(address: String) -> bool:
	if address.ends_with(".local"):
		return true
	var v := ip_to_int(address)
	if v < 0:
		return address.to_lower().begins_with("fd") or address.to_lower().begins_with("fe80")
	var a := (v >> 24) & 255
	var b := (v >> 16) & 255
	return a == 10 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 169 and b == 254)
