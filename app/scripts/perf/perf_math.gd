extends RefCounted
## Pure sampling math for PerfMonitor: no files, no clocks. Tests call these
## directly with fixture numbers.


## The aggregate "cpu" line of /proc/stat as [busy, total] jiffies, or [] when
## it isn't one. Idle counts idle + iowait; guest time is already inside user.
static func parse_proc_stat(line: String) -> Array:
	var parts := line.strip_edges().split(" ", false)
	if parts.size() < 5 or parts[0] != "cpu":
		return []
	var total := 0
	var idle := 0
	for i in range(1, mini(parts.size(), 9)):  # user nice system idle iowait irq softirq steal
		if not parts[i].is_valid_int():
			return []
		var v := parts[i].to_int()
		total += v
		if i == 4 or i == 5:
			idle += v
	return [total - idle, total]


## CPU load in percent between two parse_proc_stat() results; -1 when unknown.
static func cpu_load(prev: Array, cur: Array) -> float:
	if prev.size() != 2 or cur.size() != 2:
		return -1.0
	var dt: int = cur[1] - prev[1]
	if dt <= 0:
		return -1.0
	return clampf(100.0 * float(cur[0] - prev[0]) / float(dt), 0.0, 100.0)


## Average watts from two energy counter readings in microjoules (RAPL
## energy_uj, hwmon energyN_input), `dt_s` seconds apart. The counter wraps at
## `max_uj` (RAPL max_energy_range_uj; 0 = unknown, then a wrap reads as -1).
static func energy_watts(prev_uj: int, cur_uj: int, dt_s: float, max_uj := 0) -> float:
	if prev_uj < 0 or cur_uj < 0 or dt_s <= 0.0:
		return -1.0
	var d := cur_uj - prev_uj
	if d < 0:
		if max_uj <= 0:
			return -1.0
		d += max_uj
	return float(d) / 1_000_000.0 / dt_s


## Frames the game rendered: presented fps over the frame-generation multiplier.
static func rendered_fps(presented: float, fg_multiplier: float) -> float:
	if presented <= 0.0:
		return presented
	return presented / maxf(1.0, fg_multiplier)


## Mean of the values >= 0 in `values`; -1 when there are none.
static func mean_known(values: Array) -> float:
	var n := 0
	var sum := 0.0
	for v in values:
		if float(v) >= 0.0:
			sum += float(v)
			n += 1
	return sum / n if n > 0 else -1.0


## Column name -> index for a MangoHud log header ("fps,frametime,cpu_load,...").
static func csv_header(line: String) -> Dictionary:
	var out := {}
	var cols := line.strip_edges().split(",")
	for i in cols.size():
		out[cols[i].strip_edges()] = i
	return out


## One MangoHud log row as {column: float} using a csv_header() map; {} when
## it isn't a full data row.
static func csv_row(line: String, header: Dictionary) -> Dictionary:
	var cols := line.strip_edges().split(",")
	if header.is_empty() or cols.size() < header.size():
		return {}
	var out := {}
	for name in header:
		var raw: String = cols[header[name]].strip_edges()
		if not raw.is_valid_float():
			return {}
		out[name] = raw.to_float()
	return out


## Folds the MangoHud rows that arrived since the last sample into one set of
## values: means of fps, frametime (ms), loads (%), temps (C) and powers (W).
## Missing columns stay out of the result.
static func fold_rows(rows: Array) -> Dictionary:
	var out := {}
	if rows.is_empty():
		return out
	for col in ["fps", "frametime", "cpu_load", "gpu_load", "cpu_temp", "gpu_temp", "cpu_power", "gpu_power", "gpu_core_clock"]:
		var vals := []
		for r in rows:
			if r.has(col):
				vals.append(r[col])
		if not vals.is_empty():
			var m := mean_known(vals)
			if m >= 0.0:
				out[col] = m
	return out
