extends RefCounted
## Runs a program and returns what it printed. Power and Controls code reach
## programs only through this (and exec_safe.gd under it, which passes every
## argument byte for byte), so tests can swap in fake_runner.gd.

const ExecSafe := preload("res://scripts/system/exec_safe.gd")


## {"code": exit code (127 not found, -1 when it couldn't start), "out": stdout
## only as text (stderr is dropped so it can't spoil parsed output)}.
func run(program: String, args: PackedStringArray) -> Dictionary:
	return ExecSafe.run(program, args, false)
