extends VBoxContainer
## Stand-in for the s-hw Storage panel: the shape device_page.gd expects.

var opened_count := 0
var closed_count := 0
var got := {}


static func build(services: Dictionary) -> Control:
	var p = load("res://tests/fixtures/settings/device/storage_page.gd").new()
	p.got = services
	var b := Button.new()
	b.name = "Refresh"
	b.focus_mode = Control.FOCUS_ALL
	p.add_child(b)
	return p


func opened() -> void:
	opened_count += 1


func closed() -> void:
	closed_count += 1
