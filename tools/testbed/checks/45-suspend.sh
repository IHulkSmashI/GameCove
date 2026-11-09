#!/bin/sh
# testbed: by-name-only (needs the owner; run it with: check <name>)
# Sleep and wake: values before and after, InputPlumber devices, network, the session.
# GC_RTC=1 wakes it by itself after 40 s (rtcwake through pkexec: the owner types the
# password once); otherwise the owner presses power to wake. Run it with
# `testbed check --detach suspend` so it survives the browser terminal reconnecting.
. "$(dirname "$0")/lib.sh"
ip_devices() { "$GC_BUSCTL" --system --list tree org.shadowblip.InputPlumber 2>/dev/null | grep -c 'CompositeDevice[0-9]*$'; }
# shellcheck disable=SC2046
snap sleep-before $(power_nodes)
ipb="$(ip_devices)"
netb="$(nmcli -t -f STATE general 2>/dev/null)"
t0="$(date +%s)"
if [ "${GC_RTC:-0}" = 1 ]; then
	"$GC_PKEXEC" rtcwake -m no -s 40 >"$CHECK_OUT/rtcwake.txt" 2>&1 || warn rtc "rtcwake failed: press power to wake"
else
	manual wake "The handheld sleeps now: wait 20 s, then press power to wake it"
fi
info sleep "systemctl suspend at $(date -u +%H:%M:%SZ)"
"$GC_SYSTEMCTL" suspend || { fail suspend "systemctl suspend refused"; exit 0; }
# suspend returns at once; wait until the clock jumps (we slept) or 3 minutes pass
n=0
while [ "$n" -lt "${GC_SLEEP_WAIT:-180}" ]; do
	sleep 1
	n=$((n + 1))
	[ $(($(date +%s) - t0 - n)) -gt 5 ] && break
done
slept=$(($(date +%s) - t0 - n))
[ "$slept" -gt 5 ] && pass slept "slept about ${slept}s" || fail slept "the clock didn't jump: it may not have slept"
sleep "${GC_SETTLE:-8}"   # GameCove reapplies controls ~5 s after wake
# shellcheck disable=SC2046
snap sleep-after $(power_nodes)
d="$(snap_diff sleep-before sleep-after | grep -v -e '/status=' -e '/online=' -e 'backlight')"
[ -z "$d" ] && pass values "power/LED values the same after waking" || fail values "changed by sleep: $(echo "$d" | tr '\n' ' ')"
ipa="$(ip_devices)"
[ "$ipa" = "$ipb" ] && pass inputplumber "InputPlumber devices: $ipa before and after" || fail inputplumber "InputPlumber devices: $ipb before, $ipa after (controller lost?)"
neta="$(nmcli -t -f STATE general 2>/dev/null)"
[ "$neta" = "$netb" ] && pass network "network: ${neta:-n/a}" || warn network "network was '$netb', now '$neta' (may still be reconnecting)"
"$GC_JOURNALCTL" -b --no-pager -o short-monotonic --since "@$t0" 2>/dev/null | grep -i -E 'PM: suspend|resume|gamecove|inputplumber|hid-asus|mcu' | tail -n 80 >"$CHECK_OUT/journal.txt"
grep -qi "PM: suspend exit" "$CHECK_OUT/journal.txt" && pass kernel "kernel: suspend exit" || info kernel "no 'PM: suspend exit' line found (journal access?)"
manual controller "After waking: buttons and sticks work at once in GameCove and in a game; LEDs come back in your colour"
