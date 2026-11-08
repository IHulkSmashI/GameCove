# QR code encoder (vendored)

From [kenyoni-software/godot-addons](https://github.com/kenyoni-software/godot-addons),
`addons/kenyoni/qr_code` v2.0.0, commit 3d92d1bab93c0a8cb58951c039ddb17acd70a449.
MIT License, Copyright 2022-present Iceflower S (see LICENSE.md).

Copied: `qr_code.gd`, `bit_stream.gd`, `reed_solomon.gd`. Not copied: the editor
plugin, `qr_code_rect.gd` and `shift_jis.gd`.

Changed: Kanji mode is removed, because it needs `shift_jis.gd` (a 23,000-line
lookup table we'd parse at start-up for nothing). `put_kanji()` now logs an error
and encodes nothing. Numeric, alphanumeric and byte modes are unchanged.

GameCove uses it through `app/scripts/ui/settings/qr.gd` to show store sign-in
addresses as QR codes.
