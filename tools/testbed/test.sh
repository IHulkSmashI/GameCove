#!/bin/sh
# Tests for gamecove-testbed.sh with a fake device, fake fixes and fake rpm-ostree.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $*"; }
mkdir -p "$T/home" "$T/dmi" "$T/bin" "$T/state"
printf 'Micro-Star International Co., Ltd.\n' >"$T/dmi/sys_vendor"
printf 'Claw 8 EX AI+ A2VM\n' >"$T/dmi/product_name"
printf 'MS-1T91\n' >"$T/dmi/board_name"
touch "$T/state/claw8ex-vrr" "$T/state/claw8ex-gyro" "$T/state/fan"
cat >"$T/bin/fix" <<EOF
#!/bin/sh
S="$T/state"
case "\$1" in
--list) printf 'claw8ex-buttons\nclaw8ex-gyro\nclaw8ex-vrr\nfan\n' ;;
*) case "\$2" in
   status) if [ -f "\$S/\$1" ]; then echo installed=yes; else echo installed=no; fi; echo state=x ;;
   remove) rm -f "\$S/\$1"; echo "removed \$1" >>"$T/actions" ;;
   esac ;;
esac
EOF
printf '#!/bin/sh\n"$@"\n' >"$T/bin/pkexec"
printf '#!/bin/sh\n[ "$1" = kargs ] && cat "%s/kargs" 2>/dev/null\nexit 0\n' "$T" >"$T/bin/rpmostree"
chmod +x "$T/bin/"*
export GAMECOVE_TESTBED_HOME="$T/home" GAMECOVE_TESTBED_DMI="$T/dmi" GAMECOVE_TESTBED_FIX="$T/bin/fix" \
	GAMECOVE_TESTBED_PKEXEC="$T/bin/pkexec" GAMECOVE_TESTBED_RPM_OSTREE="$T/bin/rpmostree" GAMECOVE_TESTBED_SELFTEST=/nonexistent
S="$HERE/gamecove-testbed.sh"

out="$(sh "$S" status)"
case "$out" in *"fix claw8ex-vrr: installed"*) ok ;; *) bad "status lists installed fixes" ;; esac

echo "rhgb drm.edid_firmware=eDP-1:edid/claw.bin" >"$T/kargs"
out="$(sh "$S" status)"
case "$out" in *"device-specific kernel arguments present"*) ok ;; *) bad "status flags an EDID karg" ;; esac
rm -f "$T/kargs"

sh "$S" reset --yes >/dev/null && ok || bad "reset exits 0 when clean afterwards"
grep -q "removed claw8ex-gyro" "$T/actions" && grep -q "removed claw8ex-vrr" "$T/actions" && ok || bad "device fixes removed"
grep -q "removed fan" "$T/actions" && bad "fan is a setting and must be kept" || ok
[ -f "$T/state/fan" ] && ok || bad "fan state untouched"
found=0; for d in "$T"/home/gamecove-tests/*-micro-star-international*; do [ -d "$d" ] && found=1; done
[ "$found" = 1 ] && ok || bad "report folder named after the device"

touch "$T/state/claw8ex-vrr"
echo "drm.edid_firmware=eDP-1:edid/claw.bin" >"$T/kargs"
printf '#!/bin/sh\nexit 1\n' >"$T/bin/pkexec"
if sh "$S" reset --yes >/dev/null 2>&1; then bad "a failed removal must not report clean"; else ok; fi

sh "$S" bogus >/dev/null 2>&1 && bad "unknown command exits non-zero" || ok
echo "testbed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
