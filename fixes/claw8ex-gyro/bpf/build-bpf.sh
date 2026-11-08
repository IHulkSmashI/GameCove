#!/bin/sh
# Builds the Claw 8 EX IMU HID-BPF program from source (MSI__Claw-ISH-IMU.bpf.c, next to this script) with
# udev-hid-bpf's headers at a pinned commit, so packages carry a binary built from this source.
# Packaging runs it; fix.sh installs the result (MSI__Claw-ISH-IMU.bpf.o next to this script).
# usage: build-bpf.sh [out.bpf.o]      needs clang, llvm-strip, libbpf headers, git
# Taken from ClawDeck's tools/gyro/build-bpf.sh.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/MSI__Claw-ISH-IMU.bpf.o}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone -q https://gitlab.freedesktop.org/libevdev/udev-hid-bpf.git "$WORK/uhb"
git -C "$WORK/uhb" checkout -q "${UHB_PIN:-bbaad63}"
clang -O2 -g -target bpf -D__TARGET_ARCH_x86 -I"$WORK/uhb/src/bpf" -I/usr/include/x86_64-linux-gnu \
	-c "$HERE/MSI__Claw-ISH-IMU.bpf.c" -o "$WORK/full.bpf.o"
mkdir -p "$(dirname "$OUT")"
llvm-strip -g -o "$OUT" "$WORK/full.bpf.o"
echo "built $OUT"
