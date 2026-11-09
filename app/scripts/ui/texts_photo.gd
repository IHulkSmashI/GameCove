extends RefCounted
## Strings for the real device photo (DevicePhoto) and its setting.

const SETTING_CARD := "Device photo"
const SETTING_TITLE := "Show a real photo of my device"
const SETTING_HELP := {
	true: "Uses a free photo from Wikimedia Commons when there is one for your handheld. It's downloaded once, then kept.",
	false: "Shows our drawing of your handheld instead. Nothing is downloaded.",
}
const PHOTO_SOURCE := "Photo source"

## "Show maker photos" (DevicePhoto.maker_enabled / set_maker_enabled; ConfigFile
## user://settings.cfg [device] maker_photo, default on). For the Settings > Device
## card under SETTING_TITLE; the UI wave places the toggle.
const MAKER_SETTING_TITLE := "Show maker photos"
const MAKER_SETTING_HELP := {
	true: "Downloads your handheld's picture from the maker's website when there's no free photo of it. That one picture is the only request this panel makes to a maker's site.",
	false: "Uses the free photo or our drawing. Nothing is requested from the maker's website.",
}
