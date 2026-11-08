# EDID helpers for claw8ex-vrr (POSIX awk). Input: `od -An -v -tu1 <edid>` (decimal bytes).
#   -v mode=id      panel id as Windows names it, e.g. CSW0801 (PNP id + product code)
#   -v mode=range   "min max" vertical rate from the base block's range descriptor (tag 0xFD)
#   -v mode=check   exit 0 if every block checksum and the DisplayID section checksum are valid
#   -v mode=patch -v offsets=95,96,142,143 -v lo=30 -v hi=120
#                   "offset value" for each byte to change; exits 4 if the result fails its own check
#                   or touches anything but the range bytes and checksums
# Ported from ClawDeck's py_modules/clawdeck/edid.py.
{ for (i = 1; i <= NF; i++) e[n++] = $i + 0 }

# Last byte (the checksum) of the DisplayID section in the extension block at `start`, or -1.
function sec_last(a, start,    first, last) {
	first = start + 1
	last = first + 4 + a[first + 1]
	return (last < start + 127) ? last : -1
}

function checks_ok(a,    start, s, i, sl) {
	for (start = 0; start < n; start += 128) {
		s = 0
		for (i = start; i < start + 128; i++) s += a[i]
		if (s % 256) return 0
		if (start > 0 && a[start] == 112) {
			sl = sec_last(a, start)
			if (sl < 0) return 0
			s = 0
			for (i = start + 1; i <= sl; i++) s += a[i]
			if (s % 256) return 0
		}
	}
	return 1
}

function range_of(a,    off) {
	for (off = 54; off <= 108; off += 18)
		if (a[off] == 0 && a[off + 1] == 0 && a[off + 3] == 253) return a[off + 5] " " a[off + 6]
	return ""
}

END {
	if (mode == "id") {
		if (n < 12) exit 1
		v = e[8] * 256 + e[9]
		printf "%c%c%c%02X%02X\n", int(v / 1024) % 32 + 64, int(v / 32) % 32 + 64, v % 32 + 64, e[11], e[10]
		exit 0
	}
	if (mode == "range") {
		r = range_of(e)
		if (r == "") exit 1
		print r
		exit 0
	}
	if (mode == "check") exit checks_ok(e) ? 0 : 1
	if (mode == "patch") {
		for (i = 0; i < n; i++) o[i] = e[i]
		k = split(offsets, offs, ",")
		for (j = 1; j <= k; j += 2) {
			o[offs[j] + 0] = lo + 0
			o[offs[j + 1] + 0] = hi + 0
			allowed[offs[j] + 0] = 1
			allowed[offs[j + 1] + 0] = 1
		}
		for (start = 0; start < n; start += 128) {
			if (start > 0 && o[start] == 112) {
				sl = sec_last(o, start)
				if (sl >= 0) {
					s = 0
					for (i = start + 1; i < sl; i++) s += o[i]
					o[sl] = (256 - s % 256) % 256
					allowed[sl] = 1
				}
			}
			s = 0
			for (i = start; i < start + 127; i++) s += o[i]
			o[start + 127] = (256 - s % 256) % 256
			allowed[start + 127] = 1
		}
		if (!checks_ok(o) || range_of(o) != (lo " " hi)) exit 4
		for (i = 0; i < n; i++) if (o[i] != e[i]) {
			if (!(i in allowed)) exit 4
			print i, o[i]
		}
		exit 0
	}
	exit 2
}
