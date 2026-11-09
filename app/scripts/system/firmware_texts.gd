extends RefCounted
## Words for the Updates page's maker-firmware and drivers sections (updates_panel.gd).
## Plain and short: these are read on a 7-8" screen with a controller.

const MAKER_TITLE := "BIOS & device firmware"
const MAKER_LINE := "Your handheld maker's BIOS, EC and controller firmware, compared with what this device runs. GameCove never flashes these by itself."
const DRIVERS_TITLE := "Drivers & software"
const DRIVERS_LINE := "On Linux, drivers come with the kernel, Mesa and linux-firmware, so they update with the system. Shown here next to the newest upstream release."
const UNSUPPORTED_MAKER := "This handheld isn't in GameCove's device list, so there's no maker firmware to compare."
const INDEX_UNAVAILABLE := "Couldn't get the firmware list yet. It downloads once a week on Wi-Fi or with the charger in."
const STALE := "The maker's site didn't answer last night: this is the newest list we have."
const NOTHING := "Nothing to show yet. Press Check."
const CHECK := "Check"
const SHOW_LINK := "Open on phone"
const HIDE_LINK := "Hide link"
const PREPARE_USB := "Put it on the USB drive"
const NEEDS_USB := "Plug in a FAT32 USB drive to have GameCove put the file on it."
const YOURS := "yours: %s"
const NEW_AVAILABLE := "New %s %s available (%s)"
const UPSTREAM_NOTE := "A newer SteamOS brings BIOS %s."
const SERVICE_OFF := "Automatic BIOS updates are off on this system."

const STATUS := {"update": "Update", "current": "Up to date", "unknown": "Can't compare", "upstream": "Newer upstream", "info": ""}
const STATUS_TONES := {"update": "info", "current": "good", "unknown": "", "upstream": ""}
const HOW := {"auto": "Installs here", "guided": "Step by step", "link": "Maker's page"}

## Why a firmware install or USB preparation didn't start.
const REASONS := {
	"needs_ac": "Plug in the charger first: firmware is only written on AC power.",
	"low_battery": "Charge to at least 50% first: firmware is only written with enough battery.",
	"no_usb": "Plug in a FAT32 USB drive first.",
	"download_failed": "The download failed. Check the connection and try again.",
	"checksum_mismatch": "The download didn't match the maker's checksum, so it wasn't used.",
	"bad_archive": "The maker's file didn't contain a BIOS image.",
	"write_failed": "Couldn't write to the USB drive. Is it full or read-only?",
	"guided": "This one is installed by hand: follow the steps.",
}
const USB_DONE := "Ready: %s is on the USB drive. Follow the steps to flash it."

## Step-by-step instructions per flash method. %s = the maker's page.
const STEPS := {
	"ez-flash": [
		"Plug in the charger. Keep it plugged in until the update finishes.",
		"Put the BIOS file on a FAT32 USB drive (GameCove can do this for you).",
		"Turn the handheld off. Hold Volume Down and press Power to open the BIOS (UEFI).",
		"Open Advanced Mode, then Tool > ASUS EZ Flash Utility, and pick the .CAP file on the USB drive.",
		"Wait: the screen may go dark and the device restarts by itself. Don't press anything.",
	],
	"msi-usb": [
		"Plug in the charger. Keep it plugged in until the update finishes.",
		"Open MSI's support page on your phone (button below) and follow the BIOS update steps for this model.",
		"MSI's own updater runs on Windows; if MSI lists a USB method for this model, use their file and steps exactly.",
		"Don't turn the device off while it updates; it restarts by itself.",
	],
	"steamos": [
		"Plug in the charger.",
		"SteamOS installs the BIOS from the system image at start-up. Restart to let it run.",
		"On Bazzite, turn on Steam Deck BIOS updates once in Desktop Mode: ujust enable-deck-bios-firmware-updates",
		"To run it now from Desktop Mode instead: sudo jupiter-biosupdate",
	],
	"windows": [
		"This maker only ships a Windows updater for this part.",
		"Open the maker's page on your phone (button below) for the file and instructions.",
		"Run it from Windows (for example Windows To Go on a USB drive), with the charger in.",
	],
	"link": [
		"This maker doesn't publish a list GameCove can read.",
		"Open the maker's page on your phone (button below) to see if there's a newer BIOS.",
		"Your BIOS version is shown above to compare.",
	],
}

const DRIVER_HOW := {
	"auto": "Comes with system updates.",
	"guided": "GameCove ships the tested version; newer builds arrive with GameCove updates.",
	"link": "Update it with its own installer.",
}
