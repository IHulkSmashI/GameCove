extends RefCounted
## Reads the YAML InputPlumber hands back from GetProfileYaml (serde_yaml
## output: block mappings and sequences, plain or quoted scalars, `[]`/`{}`,
## block scalars `|` / `>` with chomping, plain scalars continued on deeper lines).
## Not a general YAML parser: no anchors or flow collections with content. We never write YAML: InputPlumber's
## LoadProfileFromYaml takes JSON too (JSON is YAML), so profiles go back as JSON.


static func parse(text: String) -> Variant:
	var t := text.strip_edges()
	if t.begins_with("{") or t.begins_with("["):
		return _json(t)   # a profile we sent as JSON
	var lines: Array = []
	for raw in text.split("\n"):
		var line := _strip_comment(raw).strip_edges(false, true)
		if line.strip_edges() == "" or line.strip_edges() == "---":
			continue
		# [indent, text, the raw line: a block scalar's content keeps its '#' and spacing]
		lines.append([_indent(line), line.strip_edges(), raw.strip_edges(false, true)])
	if lines.is_empty():
		return null
	var pos: Array[int] = [0]
	return _block(lines, pos, lines[0][0])


static func _indent(line: String) -> int:
	var n := 0
	while n < line.length() and line[n] == " ":
		n += 1
	return n


static func _strip_comment(line: String) -> String:
	var quote := ""
	for i in line.length():
		var c := line[i]
		if quote != "":
			if c == quote:
				quote = ""
		elif c == "'" or c == "\"":
			quote = c
		elif c == "#" and (i == 0 or line[i - 1] == " "):
			return line.substr(0, i)
	return line


static func _block(lines: Array, pos: Array[int], indent: int) -> Variant:
	if pos[0] >= lines.size():
		return null
	var first: String = lines[pos[0]][1]
	if first == "-" or first.begins_with("- "):
		return _seq(lines, pos, indent)
	if _key_split(first).size() == 2:
		return _map(lines, pos, indent)
	pos[0] += 1
	return scalar(first)


static func _seq(lines: Array, pos: Array[int], indent: int) -> Array:
	var out: Array = []
	while pos[0] < lines.size():
		var ind: int = lines[pos[0]][0]
		var text: String = lines[pos[0]][1]
		if ind != indent or not (text == "-" or text.begins_with("- ")):
			break
		var rest := text.substr(1).strip_edges()
		if rest == "":
			pos[0] += 1
			out.append(_block(lines, pos, lines[pos[0]][0]) if pos[0] < lines.size() and lines[pos[0]][0] > indent else null)
		elif _key_split(rest).size() == 2:
			# "- key: value" starts a mapping indented at the key's column
			lines[pos[0]] = [indent + (text.length() - rest.length()), rest, lines[pos[0]][2]]
			out.append(_map(lines, pos, lines[pos[0]][0]))
		else:
			pos[0] += 1
			out.append(scalar(rest))
	return out


static func _map(lines: Array, pos: Array[int], indent: int) -> Dictionary:
	var out := {}
	while pos[0] < lines.size():
		var ind: int = lines[pos[0]][0]
		var text: String = lines[pos[0]][1]
		if ind != indent:
			break
		var kv := _key_split(text)
		if kv.size() != 2:
			break
		pos[0] += 1
		var key := str(scalar(kv[0]))
		if _BLOCK.search(kv[1]) != null:
			out[key] = _block_scalar(lines, pos, indent, kv[1])
			continue
		if kv[1] != "":
			out[key] = _plain_more(lines, pos, indent, kv[1])
			continue
		# nested block: deeper indent, or a sequence at the same indent (serde_yaml style)
		if pos[0] < lines.size():
			var nind: int = lines[pos[0]][0]
			var ntext: String = lines[pos[0]][1]
			if nind > indent or (nind == indent and (ntext == "-" or ntext.begins_with("- "))):
				out[key] = _block(lines, pos, nind)
				continue
		out[key] = null
	return out


static var _BLOCK := RegEx.create_from_string("^[|>][-+0-9]*$")


## A `|` (literal) or `>` (folded) block scalar: every following line indented deeper than
## its key, from the raw text (a '#' inside is content), with YAML's chomping: "-" strips
## the final newline, "+" keeps them, none keeps one (review L14: everything after a
## `description: |-` was dropped).
static func _block_scalar(lines: Array, pos: Array[int], indent: int, head: String) -> String:
	var body: Array = []
	var base := -1
	while pos[0] < lines.size() and int(lines[pos[0]][0]) > indent:
		var raw: String = lines[pos[0]][2]
		var ind := _indent(raw)
		if base < 0:
			base = ind
		body.append(raw.substr(mini(base, ind)))
		pos[0] += 1
	var text := ("\n" if head.begins_with("|") else " ").join(PackedStringArray(body))
	if head.contains("-"):
		return text
	return text + "\n"


## A plain scalar that goes on over deeper lines (folded with spaces); a deeper line that
## starts a mapping or a sequence isn't a continuation.
static func _plain_more(lines: Array, pos: Array[int], indent: int, first: String) -> Variant:
	var parts: Array = [first]
	while pos[0] < lines.size() and int(lines[pos[0]][0]) > indent:
		var t: String = lines[pos[0]][1]
		if t == "-" or t.begins_with("- ") or _key_split(t).size() == 2:
			break
		parts.append(t)
		pos[0] += 1
	return scalar(first) if parts.size() == 1 else " ".join(PackedStringArray(parts))


## ["key", "value"] for "key: value" / "key:", else [].
static func _key_split(text: String) -> Array:
	var quote := ""
	for i in text.length():
		var c := text[i]
		if quote != "":
			if c == quote:
				quote = ""
		elif c == "'" or c == "\"":
			if i == 0:
				quote = c
		elif c == ":" and (i == text.length() - 1 or text[i + 1] == " "):
			return [text.substr(0, i).strip_edges(), text.substr(i + 1).strip_edges()]
	return []


static func scalar(s: String) -> Variant:
	var t := s.strip_edges()
	if t == "" or t == "~" or t == "null":
		return null
	if t == "[]":
		return []
	if t == "{}":
		return {}
	if t == "true":
		return true
	if t == "false":
		return false
	if t.length() >= 2 and t[0] == "'" and t[t.length() - 1] == "'":
		return t.substr(1, t.length() - 2).replace("''", "'")
	if t.length() >= 2 and t[0] == "\"" and t[t.length() - 1] == "\"":
		var j: Variant = _json(t)
		return j if j is String else t.substr(1, t.length() - 2)
	if t.is_valid_int():
		return int(t)
	if t.is_valid_float() and not t.begins_with("."):
		return float(t)
	return t


## JSON.parse_string without the engine's error line on bad input.
static func _json(text: String) -> Variant:
	var j := JSON.new()
	return j.data if j.parse(text) == OK else null
