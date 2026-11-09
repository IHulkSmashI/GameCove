extends RefCounted
## Strings for the real device photo (DevicePhoto) and its setting.

const SETTING_CARD := "Device photo"
const SETTING_TITLE := "Show a real photo of my device"
const SETTING_HELP := {
	true: "Shows a real photo of your handheld: a free photo when there is one, otherwise the maker's own picture. It's downloaded once, then kept, so it shows offline too.",
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

## A family row ("MSI Claw (unknown model)"): GameCove knows the maker, not the
## model, so it shows that maker's most common current model and says so.
## DevicePhoto.family_caption / photo_for(family)["caption"], ["pictured"].
const UNKNOWN_MODEL_SUFFIX := "(unknown model)"
const FAMILY_CAPTION := "%s (model not identified)"
const FAMILY_PICTURED := "Pictured: %s"
