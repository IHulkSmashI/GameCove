extends RefCounted
## Small reader for Valve's text KeyValues files (config.vdf, compatibilitytool.vdf).
## Read-only. Keys keep their case; use get_ci() because Steam mixes "Valve" and "valve".


## Whole file as nested Dictionaries of Strings. Broken input gives what parsed so far.
static func parse(text: String) -> Dictionary:
	var tokens := tokenize(text)
	var pos: Array[int] = [0]
	return _object(tokens, pos)


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return parse(FileAccess.get_file_as_string(path))


## Value for a key, ignoring case. Missing gives `fallback`.
static func get_ci(d: Dictionary, key: String, fallback: Variant = null) -> Variant:
	if d.has(key):
		return d[key]
	var low := key.to_lower()
	for k in d:
		if str(k).to_lower() == low:
			return d[k]
	return fallback


## First Dictionary found under `key` anywhere in the tree (depth first), or {}.
static func find_ci(d: Dictionary, key: String) -> Dictionary:
	var hit: Variant = get_ci(d, key)
	if hit is Dictionary:
		return hit
	for k in d:
		if d[k] is Dictionary:
			var sub := find_ci(d[k], key)
			if not sub.is_empty():
				return sub
	return {}


## For files we write back (localconfig.vdf, config.vdf): the whole text as
## nested Dictionaries, or null unless it parsed cleanly: every string closed,
## every brace balanced, every key with a value, all input used, and no key
## twice at one level (a Dictionary would silently drop the second one, and
## writing it back would lose it).
static func parse_strict(text: String) -> Variant:
	var errors: Array = []
	var tokens := tokenize(text, errors)
	if not errors.is_empty():
		return null
	var pos: Array[int] = [0]
	var keys: Array[int] = [0]
	var d: Variant = _object_strict(tokens, pos, 0, keys)
	if d == null or pos[0] != tokens.size() or keys[0] != count_keys(d):
		return null
	return d


static func parse_file_strict(path: String) -> Variant:
	var text: Variant = read_utf8_exact(path)
	return parse_strict(text) if text is String else null


## The file as text only when it is valid UTF-8 byte for byte, else null. A file we
## write back must never go through a decode that replaces bytes (a persona name in a
## legacy encoding came back as U+FFFD, review M26): such a file is left alone.
static func read_utf8_exact(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	var text := bytes.get_string_from_utf8()
	return text if text.to_utf8_buffer() == bytes else null


## Every key at every level.
static func count_keys(d: Dictionary) -> int:
	var n := d.size()
	for k in d:
		if d[k] is Dictionary:
			n += count_keys(d[k])
	return n


static func _object_strict(tokens: PackedStringArray, pos: Array[int], depth: int, keys: Array[int]) -> Variant:
	var d := {}
	while pos[0] < tokens.size():
		var t := tokens[pos[0]]
		pos[0] += 1
		if t == "}":
			return d if depth > 0 else null
		if t == "{":
			return null   # a block without a key
		keys[0] += 1
		if pos[0] >= tokens.size():
			return null   # a key without a value
		var nxt := tokens[pos[0]]
		pos[0] += 1
		if nxt == "{":
			var sub: Variant = _object_strict(tokens, pos, depth + 1, keys)
			if sub == null:
				return null
			d[t.substr(1)] = sub
		elif nxt == "}":
			return null
		else:
			d[t.substr(1)] = nxt.substr(1)
	return d if depth == 0 else null   # end of input inside a block


static func tokenize(text: String, errors: Array = []) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == " " or c == "\t" or c == "\n" or c == "\r":
			i += 1
		elif c == "/" and i + 1 < n and text[i + 1] == "/":
			while i < n and text[i] != "\n":
				i += 1
		elif c == "{" or c == "}":
			out.append(c)
			i += 1
		elif c == "\"":
			i += 1
			var s := ""
			while i < n and text[i] != "\"":
				if text[i] == "\\" and i + 1 < n:
					var e := text[i + 1]
					# \n \t \\ \" are escapes; any other (\p) is kept as written (review M26)
					match e:
						"n": s += "\n"
						"t": s += "\t"
						"\\", "\"": s += e
						_: s += "\\" + e
					i += 2
				else:
					s += text[i]
					i += 1
			if i >= n:
				errors.append("unclosed string")
			i += 1
			# Quoted strings are marked so a literal "{" value is never read as a brace.
			out.append("\"" + s)
		else:
			var s := ""
			while i < n and not (text[i] in [" ", "\t", "\n", "\r", "{", "}", "\""]):
				s += text[i]
				i += 1
			out.append("\"" + s)
	return out


static func _object(tokens: PackedStringArray, pos: Array[int]) -> Dictionary:
	var d := {}
	while pos[0] < tokens.size():
		var t := tokens[pos[0]]
		pos[0] += 1
		if t == "}":
			return d
		if t == "{":
			continue
		var key := t.substr(1)
		if pos[0] >= tokens.size():
			break
		var nxt := tokens[pos[0]]
		pos[0] += 1
		if nxt == "{":
			d[key] = _object(tokens, pos)
		elif nxt == "}":
			return d
		else:
			d[key] = nxt.substr(1)
	return d
