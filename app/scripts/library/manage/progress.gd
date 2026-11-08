extends RefCounted
## Reads download progress out of the store tools' log lines. The formats come
## from their source (checked 2026-11-08):
##
## legendary (legendary/downloader/mp/manager.py, cli.py), logged as
##   "[cli] INFO: Download size: 1234.56 MiB (Compression savings: ...)"
##   "[DLManager] INFO: = Progress: 12.34% (123/1000), Running for 00:01:02, ETA: 00:10:00"
##   "[DLManager] INFO:  - Downloaded: 152.40 MiB, Written: 300.00 MiB"
##   "[DLManager] INFO:  + Download	- 10.50 MiB/s (raw) / 20.00 MiB/s (decompressed)"
##   "Verification progress: 12/345 (3.5%) [120.0 MiB/s]"          (verify, \r-separated)
## heroic-gogdl (gogdl/dl/progressbar.py): bytes written / total bytes
##   "[PROGRESS] INFO: = Progress: 12.34 1048576/8388608, Running for: 00:00:05, ETA: 00:00:40"
##   "= Downloaded: 1.00 MiB, Written: 1.00 MiB" / " + Download	- 2.00 MiB/s (raw) / ..."
## nile (nile/downloading/progress.py): bytes downloaded / total bytes
##   "= Progress: 12.34 1048576/8388608, Running for: 00:00:05, ETA: 00:00:40"
##   " + Download	- 2.00 MiB/s"
## Heroic parses the same lines (src/backend/storeManagers/*/games.ts).

const MIB := 1048576.0

static var _re := {}


static func _rx(pattern: String) -> RegEx:
	if not _re.has(pattern):
		_re[pattern] = RegEx.create_from_string(pattern)
	return _re[pattern]


## A fresh progress record. unit: bytes | files | none.
static func empty() -> Dictionary:
	return {"bytes_done": 0, "bytes_total": 0, "rate": 0.0, "eta": -1, "percent": -1.0, "unit": "bytes", "phase": ""}


static func hms(s: String) -> int:
	var p := s.split(":")
	if p.size() != 3:
		return -1
	return p[0].to_int() * 3600 + p[1].to_int() * 60 + p[2].to_int()


## Updates `p` from one line of `tool` output (legendary | gogdl | nile).
## Returns true when the line changed something worth showing.
static func parse_line(tool: String, text: String, p: Dictionary) -> bool:
	var m: RegExMatch
	if tool == "legendary":
		m = _rx("Download size: ([\\d.]+) MiB").search(text)
		if m:
			p["bytes_total"] = int(m.get_string(1).to_float() * MIB)
			return false
		m = _rx("= Progress: ([\\d.]+)% \\((\\d+)/(\\d+)\\).*ETA: (\\d+:\\d\\d:\\d\\d)").search(text)
		if m:
			p["percent"] = m.get_string(1).to_float()
			p["eta"] = hms(m.get_string(4))
			p["phase"] = "download"
			if int(p["bytes_total"]) > 0:
				p["bytes_done"] = int(p["bytes_total"] * p["percent"] / 100.0)
			return true
		m = _rx("Downloaded: ([\\d.]+) MiB").search(text)
		if m:
			# legendary counts compressed bytes here; the percentage above is the
			# reliable figure, so only use this when no total is known.
			if int(p["bytes_total"]) <= 0:
				p["bytes_done"] = int(m.get_string(1).to_float() * MIB)
			return false
		m = _rx("Verification progress: (\\d+)/(\\d+) \\(([\\d.]+)%\\) \\[([\\d.]+) MiB/s\\]").search(text)
		if m:
			p["unit"] = "files"
			p["phase"] = "verify"
			p["bytes_done"] = m.get_string(1).to_int()
			p["bytes_total"] = m.get_string(2).to_int()
			p["percent"] = m.get_string(3).to_float()
			p["rate"] = m.get_string(4).to_float() * MIB
			return true
	elif tool == "gogdl" or tool == "nile":
		m = _rx("= Progress: ([\\d.]+) (\\d+)/(\\d+).*ETA: (\\d+:\\d\\d:\\d\\d)").search(text)
		if m:
			p["percent"] = m.get_string(1).to_float()
			p["bytes_done"] = m.get_string(2).to_int()
			p["bytes_total"] = m.get_string(3).to_int()
			p["eta"] = hms(m.get_string(4))
			p["phase"] = "download"
			return true
	else:
		return false
	m = _rx("\\+ Download\\s+- ([\\d.]+) MiB/s").search(text)
	if m:
		p["rate"] = m.get_string(1).to_float() * MIB
		return true
	return false


## Size a tool reports before installing, in bytes (0 = unknown):
## legendary `info <app> --json` (manifest.disk_size), gogdl `info <id>`
## (size."*".disk_size), nile `install <id> --info --json` (download_size).
static func parse_size(tool: String, output: String) -> int:
	var start := output.find("{")
	if start < 0:
		return 0
	var data: Variant = JSON.parse_string(output.substr(start))
	if not (data is Dictionary):
		return 0
	match tool:
		"legendary":
			var man: Variant = data.get("manifest", {})
			if man is Dictionary:
				return int(man.get("disk_size", 0))
		"gogdl":
			var size: Variant = data.get("size", {})
			if size is Dictionary and size.get("*") is Dictionary:
				return int(size["*"].get("disk_size", size["*"].get("download_size", 0)))
		"nile":
			return int(data.get("download_size", 0))
	return 0
