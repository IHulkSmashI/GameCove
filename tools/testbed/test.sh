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

# review S3-1: the browser terminal: 127.0.0.1 only, origin checked, random path, no password, stopped by reset
mkdir -p "$T/home/.local/bin"
cat >"$T/home/.local/bin/ttyd" <<EOF
#!/bin/sh
echo "\$*" >"$T/ttyd-args"
while :; do sleep 1; done
EOF
chmod +x "$T/home/.local/bin/ttyd"
sh "$S" console >"$T/console-out" 2>&1 &
cpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/ttyd-args" ] && break; sleep 0.2; done
args="$(cat "$T/ttyd-args" 2>/dev/null || true)"
case " $args " in *" -i 127.0.0.1 "*) ok ;; *) bad "ttyd listens on 127.0.0.1 only ($args)" ;; esac
case " $args " in *" --check-origin "*) ok ;; *) bad "ttyd checks the WebSocket origin" ;; esac
case " $args " in *" -c "* | *" --credential "*) bad "no basic auth (Claude can't type a password)" ;; *) ok ;; esac
tok="$(printf '%s\n' "$args" | sed -n 's|.* -b /\([0-9a-f]*\) .*|\1|p')"
[ "${#tok}" -eq 32 ] && ok || bad "served under a 128-bit random path ($tok)"
grep -q "http://127.0.0.1:7681/$tok/" "$T/console-out" && ok || bad "console prints the link"
[ "$(stat -c %a "$T/home/gamecove-tests/console-url")" = 600 ] && ok || bad "link file is private"
grep -q "$tok" "$T/home/gamecove-tests/testbed.log" && bad "the token never goes into the log" || ok
grep -rq "ttyd" "$T/home/.config" 2>/dev/null && bad "never an autostart or service" || ok
touch "$T/state/claw8ex-vrr"
rm -f "$T/kargs"
printf '#!/bin/sh\n"$@"\n' >"$T/bin/pkexec"
sh "$S" reset --yes >/dev/null 2>&1 || true
sleep 0.3
kill -0 "$cpid" 2>/dev/null && bad "reset stops the browser terminal" || ok
[ ! -e "$T/home/gamecove-tests/console-url" ] && ok || bad "reset forgets the link"
kill "$cpid" 2>/dev/null || true

# ---- SteamOS status, install [tag], uninstall, console --keep ------------------------------
printf 'ID=steamos\nVERSION_ID=3.8.10\nPRETTY_NAME="SteamOS"\n' >"$T/os-release"
mkdir -p "$T/etc/extensions" "$T/etc/atomic-update.conf.d"
ln -sf /home/.steamos/offload/gamecove/gamecove.raw "$T/etc/extensions/gamecove.raw"
printf '/etc/extensions/gamecove.raw\n' >"$T/etc/atomic-update.conf.d/gamecove.conf"
printf '#!/bin/sh\necho enabled\n' >"$T/bin/readonly"
printf '#!/bin/sh\necho "HIERARCHY EXTENSIONS SINCE"; echo "/usr gamecove Mon"\n' >"$T/bin/sysext"
chmod +x "$T/bin/readonly" "$T/bin/sysext"
export GAMECOVE_TESTBED_OS_RELEASE="$T/os-release" GAMECOVE_TESTBED_ETC="$T/etc" \
	GAMECOVE_TESTBED_READONLY="$T/bin/readonly" GAMECOVE_TESTBED_SYSEXT="$T/bin/sysext"
out="$(sh "$S" status)"
case "$out" in *"ID=steamos"*) ok ;; *) bad "status names the OS" ;; esac
case "$out" in *"steamos-readonly: enabled"*) ok ;; *) bad "status shows steamos-readonly" ;; esac
case "$out" in *"sysext: $T/etc/extensions/gamecove.raw -> /home/.steamos/offload/gamecove/gamecove.raw"*) ok ;; *) bad "status shows where the sysext lives" ;; esac
case "$out" in *"sysext merged: yes"*) ok ;; *) bad "status shows the merge" ;; esac
case "$out" in *"kept across SteamOS updates"*) ok ;; *) bad "status shows the keep list" ;; esac

# fake GitHub: the releases list (a pre-release first), a get-gamecove.sh that records its
# arguments and drops a fake installer app that logs how it was started
cat >"$T/bin/curl" <<EOF
#!/bin/sh
echo "curl \$*" >>"$T/curl-calls"
out=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; esac; url="\$1"; shift; done
case "\$url" in
*/releases\?per_page=1) printf '[{"tag_name": "v0.1.0", "prerelease": true}]\n' ;;
*/packaging/get-gamecove.sh) cp "$T/get.sh" "\$out" ;;
*) exit 22 ;;
esac
EOF
cat >"$T/get.sh" <<EOF
#!/bin/sh
echo "get-gamecove tag=\$GAMECOVE_TAG args=\$*"
mkdir -p "$T/home/.local/share/gamecove/installer/app"
printf '#!/bin/sh\necho "installer app \$*"\necho "install ok" >>"$T/home/.local/share/gamecove/installer.log"\n' >"$T/home/.local/share/gamecove/installer/app/gamecove.x86_64"
chmod +x "$T/home/.local/share/gamecove/installer/app/gamecove.x86_64"
echo "a line on stderr" >&2
EOF
chmod +x "$T/bin/curl" "$T/get.sh"
export GAMECOVE_TESTBED_CURL="$T/bin/curl" GAMECOVE_API=https://api.example GAMECOVE_TESTBED_RAW=https://raw.example
out="$(DISPLAY=:9 sh "$S" install 2>&1)" && ok || bad "install runs ($out)"
grep -q "releases?per_page=1" "$T/curl-calls" && ok || bad "no tag: asks the release list (pre-releases included)"
grep -q "raw.example/IHulkSmashI/GameCove/v0.1.0/packaging/get-gamecove.sh" "$T/curl-calls" && ok || bad "downloads the tag's own get-gamecove.sh"
ilog="$(ls "$T"/home/gamecove-tests/install-*.log 2>/dev/null | head -n 1)"
[ -n "$ilog" ] && ok || bad "install writes a log"
grep -q "get-gamecove tag=v0.1.0 args=--tag v0.1.0 --no-launch" "$ilog" && ok || bad "GAMECOVE_TAG and --tag passed to the bootstrap"
grep -q "a line on stderr" "$ilog" && ok || bad "stderr is logged too"
grep -q "installer app -- --installer" "$ilog" && ok || bad "the real installer app runs in the foreground"
grep -q "install ok" "$ilog" && ok || bad "installer.log is appended"
rm -f "$T/curl-calls"
GAMECOVE_TAG=v0.2.0-rc1 DISPLAY=:9 sh "$S" install >/dev/null 2>&1 || true
grep -q "releases?per_page" "$T/curl-calls" 2>/dev/null && bad "GAMECOVE_TAG skips the lookup" || ok
grep -q "/v0.2.0-rc1/packaging" "$T/curl-calls" && ok || bad "GAMECOVE_TAG picks the release"
DISPLAY=:9 sh "$S" install v0.1.1 >/dev/null 2>&1 || true
grep -q "/v0.1.1/packaging" "$T/curl-calls" && ok || bad "the argument picks the release"
sh "$S" install ../../evil >/dev/null 2>&1 && bad "a tag must look like vX.Y.Z" || ok
env -u DISPLAY -u WAYLAND_DISPLAY sh "$S" uninstall >/dev/null 2>&1 && bad "uninstall needs a desktop" || ok
DISPLAY=:9 sh "$S" uninstall >/dev/null 2>&1 && ok || bad "uninstall opens the installer"
ls "$T"/home/gamecove-tests/uninstall-*.log >/dev/null 2>&1 && ok || bad "uninstall is logged"

printf '#!/bin/sh\necho "$*" >"%s/run-args"\n' "$T" >"$T/bin/systemd-run"
printf '#!/bin/sh\necho "systemctl $*" >>"%s/systemctl-calls"\n' "$T" >"$T/bin/systemctl"
chmod +x "$T/bin/systemd-run" "$T/bin/systemctl"
export GAMECOVE_TESTBED_SYSTEMD_RUN="$T/bin/systemd-run" GAMECOVE_TESTBED_SYSTEMCTL="$T/bin/systemctl"
out="$(sh "$S" console --keep 2>&1)" && ok || bad "console --keep starts ($out)"
args="$(cat "$T/run-args")"
case " $args " in *" --user "*"--unit=gamecove-testbed-console"*) ok ;; *) bad "--keep: a transient user unit ($args)" ;; esac
case " $args " in *" -i 127.0.0.1 "*"--check-origin"*) ok ;; *) bad "--keep: same safe ttyd options" ;; esac
case " $args " in *"--collect"*) ok ;; *) bad "--keep: nothing left behind" ;; esac
case "$args" in *" enable "* | *"WantedBy"*) bad "--keep: never enabled" ;; *) ok ;; esac
grep -q "$(cat "$T/home/gamecove-tests/console-url" | sed 's|.*/\([0-9a-f]*\)/$|\1|')" "$T/home/gamecove-tests/testbed.log" && bad "--keep: the token stays out of the log" || ok
sh "$S" console-stop >/dev/null 2>&1
grep -q "systemctl --user stop gamecove-testbed-console" "$T/systemctl-calls" && ok || bad "console-stop stops the unit"
[ ! -e "$T/home/gamecove-tests/console-url" ] && ok || bad "console-stop forgets the link"

sh "$S" bogus >/dev/null 2>&1 && bad "unknown command exits non-zero" || ok
echo "testbed: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
