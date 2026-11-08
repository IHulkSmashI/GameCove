#!/bin/sh
# Writes a synthetic EDID shaped like the Claw 8 panel's to stdout: 256 bytes, PNP id CSW product 0x0801,
# range descriptor 48-120 Hz in the base block, DisplayID extension with the range at bytes 142/143, valid
# checksums. Same shape as ClawDeck's tests/test_edid.py.
exec python3 -I -c '
import sys
def csum(e, start):
    e[start + 127] = (256 - sum(e[start:start + 127]) % 256) % 256
e = bytearray(256)
e[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
v = ((ord("C") - 64) << 10) | ((ord("S") - 64) << 5) | (ord("W") - 64)
e[8], e[9] = v >> 8, v & 0xFF
e[10], e[11] = 0x01, 0x08
e[18], e[19] = 1, 4
e[93] = 0xFD
e[95], e[96] = 48, 120
e[126] = 1
csum(e, 0)
e[128] = 0x70
e[129], e[130], e[131], e[132] = 0x20, 121, 0, 0
e[133:145] = bytes([0x2B, 0, 9, 0, 0, 0, 0, 0, 0, 48, 120, 0])
e[254] = (256 - sum(e[129:254]) % 256) % 256
csum(e, 128)
sys.stdout.buffer.write(bytes(e))
'
