extends "res://scripts/ui/settings/page.gd"
## Device: embeds the device panels (About this device, Controller, Storage,
## Updates) from app/scripts/ui/device/ when they exist. Each panel script is
## expected to have
##
##     static func build(services: Dictionary) -> Control
##
## and may add, on the Control it returns:
##     func focusables() -> Array   # its focus chain, top to bottom
##     func opened() / func closed() # Device page shown / hidden (e.g. Storage.watch)
##
## A panel that isn't there yet shows a placeholder card instead. The page is
## built the first time it's shown, so nothing runs at start-up.

## Panel -> script names we look for, first found wins.
const PANELS := {
	"about": ["about_device.gd", "about_panel.gd", "about.gd"],
	"controller": ["controller_page.gd", "controller_panel.gd", "controller.gd"],
	"storage": ["storage_page.gd", "storage_panel.gd", "storage.gd"],
	"updates": ["updates_page.gd", "updates_panel.gd", "updates.gd"],
}
const ORDER := ["about", "controller", "storage", "updates"]
const DIR := "res://scripts/ui/device/"

var panels := {}   # id -> Control (loaded panels only)
## Folder the panel scripts are looked up in (tests point it at fixtures).
var panel_dir := DIR
var _built := false
var _shown := false


## Script path for a panel, or "" when none is installed.
static func panel_script(id: String, dir := DIR) -> String:
	for f in PANELS.get(id, []):
		var p: String = dir + f
		if ResourceLoader.exists(p):
			return p
	return ""


func build() -> void:
	panels.clear()
	if not _built:
		return
	for id in ORDER:
		var path := panel_script(id, panel_dir)
		var c: Control = null
		if path != "":
			var s: Script = load(path)
			if s != null and s.has_method("build"):
				c = s.build(services)
			elif s != null and s.can_instantiate():
				c = s.new() as Control
		if c == null:
			_placeholder(id)
			continue
		c.name = "Panel_" + id
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		add_child(c)
		panels[id] = c
		var chain: Array = c.focusables() if c.has_method("focusables") else focusable_children(c)
		_focusables.append_array(chain)


## Focusable controls under `n`, in tree order.
static func focusable_children(n: Node, out: Array = []) -> Array:
	for ch in n.get_children():
		if ch is Control and ch.focus_mode != Control.FOCUS_NONE and ch.visible:
			out.append(ch)
		focusable_children(ch, out)
	return out


func _placeholder(id: String) -> void:
	var box := add_card(TS.DEVICE_PANEL_TITLES[id], TS.DEVICE_PANEL_ICONS[id])
	box.get_parent().name = "Placeholder_" + id
	if id == "about":
		var dev := svc("device")
		if dev != null and dev.has_method("display_name"):
			var p: Dictionary = dev.profile if "profile" in dev else {}
			box.add_child(SKit.fact("Device", dev.display_name()))
			box.add_child(SKit.fact("Chip", str(p.get("chip", "Unknown"))))
			box.add_child(SKit.fact("Support", dev.support_level().capitalize() if dev.has_method("support_level") else "Generic"))
			return
	box.add_child(Kit.label(TS.DEVICE_PANEL_SOON, "QuietLabel", true))


## Called by the settings screen when the Device page shows / hides.
func on_shown() -> void:
	_shown = true
	if not _built:
		_built = true
		rebuild()
	for c in panels.values():
		if c.has_method("opened"):
			c.opened()


func on_hidden() -> void:
	if not _shown:
		return
	_shown = false
	for c in panels.values():
		if c.has_method("closed"):
			c.closed()
