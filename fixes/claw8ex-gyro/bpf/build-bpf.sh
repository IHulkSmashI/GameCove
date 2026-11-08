#!/bin/sh
# Builds the Claw 8 EX IMU HID-BPF program from source (MSI__Claw-ISH-IMU.bpf.c, next to this script) with
# udev-hid-bpf's headers at a pinned commit, so packages carry a binary built from this source.
# Packaging runs it (the RPM's %build, .github/workflows/release.yml for the sysext); fix.sh installs the
# result (MSI__Claw-ISH-IMU.bpf.o next to this script).
#
# usage: build-bpf.sh [out.bpf.o]
#   needs clang, llvm-strip and libbpf's headers (<bpf/bpf_tracing.h>; Fedora libbpf-devel, Debian/Ubuntu
#   libbpf-dev), plus Linux UAPI headers (kernel-headers / linux-libc-dev).
#   UHB_SRC=DIR      use an unpacked udev-hid-bpf tree (at the pinned commit) instead of cloning it with git
#   UHB_PIN=COMMIT   udev-hid-bpf commit to clone (default below; keep in step with uhb_commit in the RPM spec)
#   BPF_CFLAGS=...   extra compiler flags, e.g. -I/path/to/libbpf/include
# Taken from ClawDeck's tools/gyro/build-bpf.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/MSI__Claw-ISH-IMU.bpf.o}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
if [ -n "${UHB_SRC:-}" ]; then
	UHB=$UHB_SRC
else
	UHB=$WORK/uhb
	git clone -q https://gitlab.freedesktop.org/libevdev/udev-hid-bpf.git "$UHB"
	git -C "$UHB" checkout -q "${UHB_PIN:-bbaad63}"
fi
[ -f "$UHB/src/bpf/hid_bpf_helpers.h" ] || { echo "build-bpf: $UHB is not a udev-hid-bpf tree" >&2; exit 1; }
# shellcheck disable=SC2086 # BPF_CFLAGS is a list of flags
clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -I"$UHB/src/bpf" -I/usr/include/x86_64-linux-gnu ${BPF_CFLAGS:-} \
	-c "$HERE/MSI__Claw-ISH-IMU.bpf.c" -o "$WORK/full.bpf.o"
mkdir -p "$(dirname "$OUT")"
llvm-strip -g -o "$OUT" "$WORK/full.bpf.o"
echo "built $OUT"
