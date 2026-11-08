extends RefCounted
## Valve's binary KeyValues, as the Steam client writes appcache/stats/*.bin
## (and appinfo.vdf sections). Each entry is one type byte, a NUL-terminated
## UTF-8 key, then the value:
##   0x00 nested map (ends with 0x08)   0x01 string (NUL-terminated UTF-8)
##   0x02 int32   0x03 float32   0x04 pointer (int32)   0x05 wide string
##   (UTF-16LE, NUL-terminated)   0x06 color (int32)   0x07 uint64
##   0x0A int64   0x08 / 0x0B end of map. All numbers little-endian.
## Format as read by node-vdf's lib/binary.js (Anthony Beaumont, MIT) and the
## Valve Developer Wiki's "Binary VDF" notes; this is our own GDScript.
## uint64 values above 2^63 come back as negative ints (GDScript has no
## unsigned 64-bit); SteamIDs and the like fit.

const T_MAP := 0x00
const T_STRING := 0x01
const T_INT32 := 0x02
const T_FLOAT := 0x03
const T_PTR := 0x04
const T_WSTRING := 0x05
const T_COLOR := 0x06
const T_UINT64 := 0x07
const T_END := 0x08
const T_INT64 := 0x0A
const T_END_ALT := 0x0B
## Deeper than this is not a real stats file.
const MAX_DEPTH := 64


## The whole buffer as nested Dictionaries; {} when it can't be read (a
## truncated or foreign file never raises, it just yields nothing).
static func parse(data: PackedByteArray) -> Dictionary:
	var pos := [0]
	var out: Variant = _map(data, pos, 0)
	return out if out is Dictionary else {}


static func parse_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return parse(FileAccess.get_file_as_bytes(path))


static func _cstr(data: PackedByteArray, pos: Array) -> Variant:
	var start: int = pos[0]
	var end := data.find(0, start)
	if end < 0:
		return null
	pos[0] = end + 1
	return data.slice(start, end).get_string_from_utf8()


static func _wstr(data: PackedByteArray, pos: Array) -> Variant:
	var start: int = pos[0]
	var i := start
	while i + 1 < data.size():
		if data[i] == 0 and data[i + 1] == 0:
			pos[0] = i + 2
			return data.slice(start, i).get_string_from_utf16()
		i += 2
	return null


## Returns the map, or null when the data is malformed.
static func _map(data: PackedByteArray, pos: Array, depth: int) -> Variant:
	if depth > MAX_DEPTH:
		return null
	var out := {}
	var n := data.size()
	while pos[0] < n:
		var t: int = data[pos[0]]
		pos[0] += 1
		if t == T_END or t == T_END_ALT:
			return out
		var key: Variant = _cstr(data, pos)
		if key == null:
			return null
		var p: int = pos[0]
		var value: Variant
		match t:
			T_MAP:
				value = _map(data, pos, depth + 1)
				if value == null:
					return null
			T_STRING:
				value = _cstr(data, pos)
				if value == null:
					return null
			T_INT32, T_PTR, T_COLOR:
				if p + 4 > n:
					return null
				value = data.decode_s32(p)
				pos[0] = p + 4
			T_FLOAT:
				if p + 4 > n:
					return null
				value = data.decode_float(p)
				pos[0] = p + 4
			T_WSTRING:
				value = _wstr(data, pos)
				if value == null:
					return null
			T_UINT64, T_INT64:
				if p + 8 > n:
					return null
				value = data.decode_s64(p)
				pos[0] = p + 8
			_:
				return null  # unknown type: we can't know its size
		out[key] = value
	return out  # top level may end without an end byte


## d[key] matching the key case-insensitively (Steam writes "Hidden" and
## "hidden", "Name" and "name"). `fallback` when missing.
static func get_ci(d: Variant, key: String, fallback: Variant = null) -> Variant:
	if not d is Dictionary:
		return fallback
	if d.has(key):
		return d[key]
	var low := key.to_lower()
	for k in d:
		if str(k).to_lower() == low:
			return d[k]
	return fallback
