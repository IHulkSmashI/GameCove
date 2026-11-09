#!/bin/sh
# GameCove claw8ex-vrr boot hook, installed as /etc/gamecove/claw8ex-vrr/edid-hook.sh and run by modprobe
# (/etc/modprobe.d/gamecove-claw8ex-vrr.conf) right before the Intel GPU driver loads, in the initramfs or
# later. It hands the driver the corrected EDID only on the board it was installed on, so other handhelds
# booting the same drive get nothing. Shell built-ins only (the initramfs has few commands); always exits
# 0, so the driver loads whatever happens here.
#
# edid.conf: "<board_name> <connector>:edid/<file>", e.g. "MS-1T91 eDP-1:edid/gamecove-csw0801-30-120.bin".
# GAMECOVE_ROOT prefixes every path in tests (empty on a real system).
#
# Kill switch and rollback (review S1-5): it acts only when the kernel command line holds the marker
# gamecove.vrr=1, which the fix adds to the boot entry it creates (rpm-ostree kargs) and removes on
# `remove`. So the previous boot entry, and any entry the marker was deleted from, start with the
# panel's own EDID even though this hook and its rule are in /etc. At the boot menu: press e, add
# gamecove.novrr to the "linux" line (or delete gamecove.vrr=1), Ctrl+X: VRR fix off for that boot.
R=${GAMECOVE_ROOT:-}
conf=$R/etc/gamecove/claw8ex-vrr/edid.conf

cmd=
read -r cmd <"$R/proc/cmdline" 2>/dev/null || [ -n "$cmd" ] || exit 0
case " $cmd " in
*" gamecove.novrr "* | *" gamecove.novrr="*) exit 0 ;;
*" gamecove.vrr=1 "*) ;;
*) exit 0 ;;
esac

board=
read -r board <"$R/sys/class/dmi/id/board_name" 2>/dev/null || [ -n "$board" ] || exit 0
want=
spec=
read -r want spec <"$conf" 2>/dev/null || [ -n "$spec" ] || exit 0
[ -n "$board" ] && [ "$board" = "$want" ] || exit 0
case $spec in
*:edid/*) ;;
*) exit 0 ;;
esac
[ -f "$R/etc/firmware/${spec#*:}" ] || exit 0

# firmware_class looks in /etc/firmware only when told to; never replace a path someone else set.
fw=
p=$R/sys/module/firmware_class/parameters/path
read -r fw <"$p" 2>/dev/null || true
case $fw in
"") printf '%s' /etc/firmware >"$p" 2>/dev/null || exit 0 ;;
/etc/firmware) ;;
*) exit 0 ;;
esac

# Never replace someone else's EDID override (an edid_firmware kernel argument, for one).
cur=
e=$R/sys/module/drm/parameters/edid_firmware
read -r cur <"$e" 2>/dev/null || true
case $cur in
"" | *gamecove-*) printf '%s' "$spec" >"$e" 2>/dev/null || true ;;
esac
exit 0
