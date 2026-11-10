extends RefCounted
## Words for the everyday extras people otherwise add with plugins: per-app
## volume, media controls, Bluetooth devices, clean-up, Proton versions and
## automatic app updates. Plain and short; every setting gets one help line.

# ---- per-app volume ------------------------------------------------------------------
const MIXER_TITLE := "Apps"
const MIXER_LINE := "Turn one app down without touching the others: the game, music, a voice chat."
const MIXER_EMPTY := "No app is playing sound right now."
const MIXER_LOADING := "Looking for apps playing sound…"
const MIXER_HELP := "This app's own volume. The main volume still sets the overall level."
const MIXER_FAILED := "Couldn't change that app's volume. It may have stopped playing."

# ---- media controls --------------------------------------------------------------------
const MEDIA_TITLE := "Now playing"
const MEDIA_UNKNOWN := "Something's playing"
const MEDIA_PREV := "Previous"
const MEDIA_PLAY := "Play"
const MEDIA_PAUSE := "Pause"
const MEDIA_NEXT := "Next"
const MEDIA_HELP := "Controls the music or video app playing in the background, like Spotify or a browser."
const MEDIA_FAILED := "%s didn't answer."
