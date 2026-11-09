extends RefCounted
## Strings for the real device photo (DevicePhoto) and its setting.

const SETTING_CARD := "Device photo"
const SETTING_TITLE := "Show a real photo of my device"
const SETTING_HELP := {
	true: "Uses a free photo from Wikimedia Commons when there is one for your handheld. It's downloaded once, then kept.",
	false: "Shows our drawing of your handheld instead. Nothing is downloaded.",
}
const PHOTO_SOURCE := "Photo source"
