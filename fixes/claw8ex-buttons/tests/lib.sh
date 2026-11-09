# shellcheck shell=sh
# Test helpers for the Claw 8 EX fixes: a fake root, stubbed system commands on PATH, assertions.
# Sourced by fixes/claw8ex-*/tests/test.sh. Nothing here touches the real system.

FIXES=$(cd "$(dirname "$0")/../.." && pwd)
REAL_SHA256SUM=$(command -v sha256sum)
PASS=0
FAILS=0

STOCK_YAML='version: 1
kind: CompositeDevice
name: MSI Claw 8 EX AI+ CG3EM
matches:
  - dmi_data:
      board_name: MS-1T91
source_devices:
  - group: gamepad
    hidraw:
      vendor_id: 0x0db0

# Optional configuration for the composite device
options:
  auto_manage: true
target_devices:
  - deck-uhid
capability_map_id: claw2
'

ok() {
	if eval "$1"; then
		PASS=$((PASS + 1))
	else
		FAILS=$((FAILS + 1))
		printf 'FAIL %s: %s\n' "${CASE:-?}" "$2" >&2
	fi
}

case_start() {
	CASE=$1
	setup
}

# A fresh fake root and stubs for every case.
setup() {
	[ -z "${T:-}" ] || rm -rf "$T"
	T=$(mktemp -d)
	export GAMECOVE_ROOT="$T/root" FAKE="$T/fake"
	R=$GAMECOVE_ROOT
	BIN=$T/bin
	mkdir -p "$R/sys/class/dmi/id" "$R/proc" "$R/run" "$R/var/lib" "$R/etc/systemd/system" "$R/usr/share/inputplumber/devices" \
		"$R/sys/bus/pci/devices/0000:00:12.0" "$FAKE/active" "$BIN"
	echo MS-1T91 >"$R/sys/class/dmi/id/board_name"
	echo "Micro-Star International Co., Ltd." >"$R/sys/class/dmi/id/sys_vendor"
	echo "Claw 8 EX AI+ CG3EM" >"$R/sys/class/dmi/id/product_name"
	echo "BOOT_IMAGE=/vmlinuz root=UUID=x quiet splash" >"$R/proc/cmdline"
	echo 0x8086 >"$R/sys/bus/pci/devices/0000:00:12.0/vendor"
	echo 0xe445 >"$R/sys/bus/pci/devices/0000:00:12.0/device"
	printf '%s' "$STOCK_YAML" >"$R/usr/share/inputplumber/devices/50-msi_claw8_ex_ai_cg3em.yaml"
	printf 'root=UUID=x\nquiet\nsplash\n' >"$FAKE/kargs"
	: >"$FAKE/initramfs"
	: >"$FAKE/calls"
	: >"$FAKE/active/inputplumber"
	make_stubs
	PATH="$BIN:$ORIG_PATH"
	export PATH
	unset GAMECOVE_GYRO_BPF_OBJ GAMECOVE_VRR_PANELS FAKE_KIT FAKE_SHA_NAME FAKE_SHA_VALUE FAKE_FAIL
}

ORIG_PATH=$PATH

make_stubs() {
	cat >"$BIN/rpm-ostree" <<'EOF'
#!/bin/sh
echo "rpm-ostree $*" >>"$FAKE/calls"
cmd=$1
shift
# FAKE_FAIL=kargs / initramfs-etc: changes fail (listing still works)
[ $# -gt 0 ] && [ "${FAKE_FAIL:-}" = "$cmd" ] && exit 1
case $cmd in
kargs)
	if [ $# -eq 0 ]; then tr '\n' ' ' <"$FAKE/kargs" | sed 's/ $//'; echo; exit 0; fi
	for a; do
		case $a in
		--append-if-missing=*) v=${a#*=}; grep -qxF "$v" "$FAKE/kargs" || echo "$v" >>"$FAKE/kargs" ;;
		--delete-if-present=*) v=${a#*=}; grep -vxF "$v" "$FAKE/kargs" >"$FAKE/k.tmp" || true; mv "$FAKE/k.tmp" "$FAKE/kargs" ;;
		*) exit 2 ;;
		esac
	done
	;;
initramfs-etc)
	for a; do
		case $a in
		--track=*) echo "${a#*=}" >>"$FAKE/initramfs" ;;
		--untrack=*) grep -vxF "${a#*=}" "$FAKE/initramfs" >"$FAKE/i.tmp" || true; mv "$FAKE/i.tmp" "$FAKE/initramfs" ;;
		esac
	done
	;;
*) exit 2 ;;
esac
EOF
	cat >"$BIN/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >>"$FAKE/calls"
cmd=$1
shift
[ "${1:-}" = --now ] && shift
case $cmd in
is-active) if [ -e "$FAKE/active/$1" ]; then echo active; else echo inactive; exit 3; fi ;;
enable) for u; do : >"$FAKE/active/$u"; done ;;
disable) for u; do rm -f "$FAKE/active/$u"; done ;;
restart | daemon-reload | try-restart) : ;;
*) exit 1 ;;
esac
EOF
	cat >"$BIN/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$FAKE/calls"
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
[ -n "$out" ] && [ -f "${FAKE_KIT:-}" ] || exit 22
cp "$FAKE_KIT" "$out"
EOF
	cat >"$BIN/unzip" <<'EOF'
#!/bin/sh
# -Z1 <zip>: list names; -p <zip> <member>: member to stdout
exec python3 -I -c '
import sys, zipfile
a = sys.argv[1:]
z = zipfile.ZipFile(a[1])
if a[0] == "-Z1":
    print("\n".join(z.namelist()))
else:
    sys.stdout.buffer.write(z.read(a[2]))
' "$@"
EOF
	cat >"$BIN/sha256sum" <<EOF
#!/bin/sh
# Pretend files matching FAKE_SHA_NAME have FAKE_SHA_VALUE (a stand-in for MSI's real firmware).
case \$(basename "\$1") in
\${FAKE_SHA_NAME:-//none//}) [ -f "\$1" ] && echo "\$FAKE_SHA_VALUE  \$1" && exit 0; exit 1 ;;
esac
exec "$REAL_SHA256SUM" "\$@"
EOF
	printf '#!/bin/sh\nexit 0\n' >"$BIN/udev-hid-bpf"
	chmod +x "$BIN"/*
}

# Every path and file checksum in the fake root, except what the kernel provides (sys, proc).
snapshot() {
	(cd "$GAMECOVE_ROOT" && find . -path ./sys -prune -o -path ./proc -prune -o -print | sort | while read -r f; do
		if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"; else printf '%s\n' "$f"; fi
	done)
	echo "kargs: $(tr '\n' ' ' <"$FAKE/kargs")"
	echo "initramfs: $(tr '\n' ' ' <"$FAKE/initramfs")"
}

fix() { sh "$FIXES/$1/fix.sh" "$2" ${3:+"$3"} ${4:+"$4"} ${5:+"$5"}; }

karg_count() { grep -cxF "$1" "$FAKE/kargs" || true; }

override() { cat "$GAMECOVE_ROOT/etc/inputplumber/devices.d/50-msi_claw8_ex_ai_cg3em.yaml" 2>/dev/null; }

finish() {
	[ -z "${T:-}" ] || rm -rf "$T"
	printf '%s: %d passed, %d failed\n' "$(basename "$(dirname "$(dirname "$0")")")" "$PASS" "$FAILS"
	[ "$FAILS" -eq 0 ]
}
