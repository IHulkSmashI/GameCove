#!/usr/bin/env bash
# Builds cabinet.dll (x86-64 Windows, for Proton): the Compression API LZMS decompressor Wine lacks, plus forwards
# of Wine's own cabinet functions to cabinet_wine.dll (a renamed copy of the Proton's builtin cabinet.dll).
# Ported from ClawDeck's tools/cabinet-lzms (same author). Needs x86_64-w64-mingw32-gcc. Output:
# tools/cabinet-lzms/out/cabinet.dll and the two test programs; test/run.sh tests them under Wine.
# The build is reproducible (no timestamp, static libgcc, stripped): with the toolchain release.yml pins it gives the
# bytes whose sha256 is in cabinet.sha256. `build.sh --check` fails when the result differs from that file, which is
# how the release build makes sure every device gets the reviewed DLL.
set -eu
cd "$(dirname "$0")"
mkdir -p out
echo '/* wimlib build config */' > out/config.h
CC=x86_64-w64-mingw32-gcc
$CC -O2 -Wall -shared -Iout -Iwimlib -DHAVE_CONFIG_H -o out/cabinet.dll cabinet.c \
  wimlib/lzms_decompress.c wimlib/lzms_common.c wimlib/decompress_common.c wimlib/compress_common.c wimlib/cpu_features.c \
  cabinet.def -static-libgcc -s -Wl,--no-insert-timestamp
$CC -O2 -Wall -o out/test_cabinet.exe test/test_cabinet.c
$CC -O2 -Wall -o out/test_forward.exe test/test_forward.c
sha256sum out/cabinet.dll
if [ "${1:-}" = --check ]; then
  want=$(sed -n 's/^\([0-9a-f]\{64\}\)  cabinet\.dll$/\1/p' cabinet.sha256)
  have=$(sha256sum out/cabinet.dll | cut -d' ' -f1)
  [ -n "$want" ] && [ "$have" = "$want" ] || { echo "cabinet.dll is $have, cabinet.sha256 says ${want:-nothing}: toolchain or source changed" >&2; exit 1; }
  echo "cabinet.dll matches cabinet.sha256"
fi
