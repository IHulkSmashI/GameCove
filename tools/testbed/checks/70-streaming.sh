#!/bin/sh
# Streaming from the owner's PC (Vibepollo / Sunshine). GC_STREAM_HOST=<pc address>; skipped
# when unset or unreachable. Only the public serverinfo is read (no pairing, no secrets).
. "$(dirname "$0")/lib.sh"
host="${GC_STREAM_HOST:-}"
[ -n "$host" ] || { skip host "GC_STREAM_HOST not set: streaming skipped"; exit 0; }
if have flatpak && flatpak info com.moonlight_stream.Moonlight >/dev/null 2>&1; then
	pass moonlight "Moonlight Flatpak installed"
else
	warn moonlight "Moonlight isn't installed (installer option or the Stream page installs it)"
fi
if curl -fsS -m 5 "http://$host:47989/serverinfo" >"$CHECK_OUT/serverinfo.xml" 2>/dev/null; then
	name="$(sed -n 's:.*<hostname>\(.*\)</hostname>.*:\1:p' "$CHECK_OUT/serverinfo.xml" | head -n 1)"
	pass host "PC answers on 47989 (${name:-unnamed})"
	sed -i -e 's:<uniqueid>[^<]*</uniqueid>:<uniqueid>-</uniqueid>:' -e 's:<mac>[^<]*</mac>:<mac>-</mac>:' "$CHECK_OUT/serverinfo.xml"
	manual pair "Stream page: the PC shows up; pair (type the PIN on the PC); start a stream; the controller works; quit returns to GameCove"
else
	skip host "$host doesn't answer on 47989 (PC off, or not on this network)"
fi
