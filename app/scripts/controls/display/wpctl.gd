extends RefCounted
## PipeWire through WirePlumber's `wpctl` (on Bazzite and SteamOS). Volume and
## mute work on the @DEFAULT_AUDIO_SINK@ / @DEFAULT_AUDIO_SOURCE@ aliases, so a
## DSP filter sink (speaker tuning on some handhelds) is handled by WirePlumber.
## Device lists come from `wpctl status` (wireplumber 0.4 and 0.5 layouts).

const WPCTL := "wpctl"
const SINK := "@DEFAULT_AUDIO_SINK@"
const SOURCE := "@DEFAULT_AUDIO_SOURCE@"


## `wpctl get-volume X` -> {"volume": 0.0-1.5, "muted": bool}, {} when it fails.
static func parse_volume(out: String) -> Dictionary:
	var s := out.strip_edges()
	if not s.begins_with("Volume:"):
		return {}
	var rest := s.substr(7).strip_edges()
	var num := rest.get_slice(" ", 0)
	if not num.is_valid_float():
		return {}
	return {"volume": num.to_float(), "muted": "[MUTED]" in rest}


## `wpctl status` -> {"sinks": [...], "sources": [...], "streams": [...]} for the
## Audio part. Each sink/source: {"id", "name", "default": bool, "volume", "muted"};
## each stream: {"id", "name"}.
static func parse_status(out: String) -> Dictionary:
	var res := {"sinks": [], "sources": [], "streams": []}
	var in_audio := false
	var section := ""
	for raw in out.split("\n"):
		var line := _strip_tree(raw)
		if raw.strip_edges() == "Audio":
			in_audio = true
			continue
		if raw.length() > 0 and raw[0] != " " and raw.strip_edges() != "" and not _is_tree(raw[0]):
			in_audio = raw.strip_edges() == "Audio"
			continue
		if not in_audio:
			continue
		if line.ends_with(":") and not line.begins_with("*") and not line.substr(0, 1).is_valid_int():
			section = line.trim_suffix(":").to_lower()
			continue
		var is_default := line.begins_with("*")
		if is_default:
			line = line.substr(1).strip_edges()
		var dot := line.find(". ")
		if dot <= 0 or not line.substr(0, dot).is_valid_int():
			continue
		var id := line.substr(0, dot).to_int()
		var name := line.substr(dot + 2).strip_edges()
		var vol := -1.0
		var muted := false
		# WirePlumber 0.5 lists loopback / echo-cancel nodes under "Filters", each with
		# its media class: on SteamOS the Ally's microphone is such a loopback source
		# (alsa_loopback_device.alsa_input...), so it counts as a real one
		var klass := ""
		var cb := name.rfind("[Audio/")
		if cb >= 0 and section == "filters":
			klass = name.substr(cb + 1).trim_suffix("]")
			name = name.substr(0, cb).strip_edges()
		var b := name.rfind("[vol:")
		if b >= 0:
			var inner := name.substr(b + 5).trim_suffix("]").strip_edges()
			muted = "MUTED" in inner
			var n := inner.get_slice(" ", 0)
			vol = n.to_float() if n.is_valid_float() else -1.0
			name = name.substr(0, b).strip_edges()
		if section == "filters":
			if klass.begins_with("Audio/Source"):
				res["sources"].append({"id": id, "name": name, "default": is_default, "volume": vol, "muted": muted})
			elif klass.begins_with("Audio/Sink"):
				res["sinks"].append({"id": id, "name": name, "default": is_default, "volume": vol, "muted": muted})
			continue
		match section:
			"sinks":
				res["sinks"].append({"id": id, "name": name, "default": is_default, "volume": vol, "muted": muted})
			"sources":
				res["sources"].append({"id": id, "name": name, "default": is_default, "volume": vol, "muted": muted})
			"streams":
				# stream ports ("output_FL > ...") are indented below their stream
				if not ">" in name and not "<" in name:
					res["streams"].append({"id": id, "name": name})
	return res


static func _is_tree(ch: String) -> bool:
	return ch in ["│", "├", "└", "─"]


static func _strip_tree(s: String) -> String:
	var out := s
	for ch in ["│", "├", "└", "─"]:
		out = out.replace(ch, " ")
	return out.strip_edges()


## `pactl -f json list sinks|sources` (pipewire-pulse) -> descriptions of the nodes whose
## jacks have nothing plugged in: every port reports availability "not available". With UCM (Intel SOF/SoundWire, the MSI Claw) Headphones and Headset
## Microphone are nodes of their own that wpctl lists even when no jack is connected.
## Unknown availability counts as plugged. [] when the text isn't that JSON.
static func parse_unplugged(json: String) -> Array:
	var data: Variant = JSON.parse_string(json)
	var out := []
	if not data is Array:
		return out
	for n in data:
		if not n is Dictionary or not n.get("ports") is Array or (n["ports"] as Array).is_empty():
			continue
		# ports, not nodes: only a node whose every port is empty is gone (the Ally's mic
		# has an internal port next to the empty headset jack)
		var ports: Array = n["ports"]
		var gone := ports.all(func(p): return p is Dictionary and str(p.get("availability", "")) == "not available")
		if gone:
			out.append(str(n.get("description", n.get("name", ""))))
	return out


## `wpctl inspect @DEFAULT_AUDIO_SOURCE@` -> the node's description (else nick, else name).
static func parse_inspect_name(out: String) -> String:
	var found := {}
	for line in out.split("\n"):
		var l := line.strip_edges().trim_prefix("* ").strip_edges()
		for k in ["node.description", "node.nick", "node.name"]:
			if l.begins_with(k + " = "):
				found[k] = l.substr(k.length() + 3).strip_edges().trim_prefix("\"").trim_suffix("\"")
	for k in ["node.description", "node.nick", "node.name"]:
		if found.has(k):
			return found[k]
	return ""
