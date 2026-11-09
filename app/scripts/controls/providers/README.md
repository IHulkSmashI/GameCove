One provider script per area (power.gd, display.gd, perf.gd, audio.gd,
system.gd, controller.gd...). Each: `extends RefCounted`, optional
`setup(ctx)`, and `controls() -> Array` of Control objects
(res://scripts/controls/control.gd). Controls loads every script here at
startup, so nobody edits a shared list.
