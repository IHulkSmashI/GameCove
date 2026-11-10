extends RefCounted
## Words for favourites, hidden games, collections, the Library's filter
## sheet and the Emulation page. Casual, "we", one plain line per setting.

# ------------------------------------------------------------ favourites / hidden / collections
const FAVOURITE := "Favourite"
const FAVOURITED := "Favourited"
const ADD_FAVOURITE := "Add to favourites"
const REMOVE_FAVOURITE := "Remove from favourites"
const FAVOURITE_DETAIL := "Their own shelf on Home and view here."
const FAVOURITE_ADDED := "%s is in your favourites"
const FAVOURITE_REMOVED := "%s left your favourites"
const HIDE := "Hide this game"
const HIDE_DETAIL := "It stays installed; it just leaves Home and the Library. Find it again under Filter > Hidden games."
const UNHIDE := "Show this game again"
const UNHIDE_DETAIL := "Back on Home and in the Library."
const HIDDEN_TOAST := "%s is hidden"
const HIDDEN_TOAST_LINE := "Library > Filter > Hidden games brings it back."
const UNHIDDEN_TOAST := "%s is back in your library"
const COLLECTIONS := "Collections"
const ADD_TO_COLLECTION := "Add to a collection"
const ADD_TO_COLLECTION_DETAIL := "Group games your way: couch co-op, short ones, the backlog."
const COLLECTIONS_OF := "In %d collection%s"
const PICK_COLLECTION := "Collections"
const PICK_COLLECTION_SUB := "Pick one to add or remove this game."
const NEW_COLLECTION := "New collection"
const NEW_COLLECTION_DETAIL := "Name it and this game goes in."
const NEW_COLLECTION_TITLE := "New collection"
const NEW_COLLECTION_HELP := "A short name, like Couch co-op or Backlog."
const RENAME_TITLE := "Rename collection"
const RENAME_HELP := "The new name for this collection."
const IN_IT := "In this collection"
const NOT_IN_IT := "Not in it yet"
const STEAM_READ_ONLY := "From Steam: change it in Steam"
const FROM_STEAM := "Steam collection"
const YOUR_COLLECTION := "Your collection"
const ADDED_TO := "Added to %s"
const REMOVED_FROM := "Removed from %s"
const CREATED := "Made %s"
const RENAMED := "Renamed to %s"
const DELETED := "Deleted %s"
const DELETE_LINE := "The games stay in your library."
const COULDNT_SAVE := "Couldn't save that"
const COULDNT_SAVE_LINE := "Your collections file couldn't be written. Check that the drive has free space."
const MANAGE_COLLECTIONS := "Manage collections"
const MANAGE_COLLECTIONS_DETAIL := "Rename or delete the collections you made."
const MANAGE_ONE_RENAME := "Rename"
const MANAGE_ONE_DELETE := "Delete collection"
const CONFIRM_DELETE := "Delete %s?"
const CONFIRM_DELETE_YES := "Delete it"
const CONFIRM_DELETE_NO := "Keep it"
const NO_COLLECTIONS := "No collections yet"
const NO_COLLECTIONS_LINE := "Press Menu on any game and pick Add to a collection."
const GAME_OPTIONS := "Options"
const OPEN_PAGE := "Open game page"
const GAMES_N := "%d game%s"

# ------------------------------------------------------------ Library filter sheet
const FILTER_TITLE := "Filter"
const FILTER_SUB := "Pick what the Library shows. X still changes the order."
const VIEW_ALL := "All games"
const VIEW_ALL_DETAIL := "Everything you haven't hidden"
const VIEW_FAVOURITES := "Favourites"
const VIEW_HIDDEN := "Hidden games"
const VIEW_HIDDEN_DETAIL := "Games you hid. Press Menu on one to show it again."
const VIEW_EMULATION := "Emulation"
const VIEW_EMULATION_DETAIL := "Every game in your ROM folder, by system"
const VIEW_EMULATION_PAGE := "Emulation page"
const EMU_SHOW_IN_LIBRARY := "Show them in the Library"
const VIEW_EMULATION_PAGE_DETAIL := "Your consoles, ES-DE and EmuDeck in one place"
const SORT_ROW := "Order"
const SORT_TITLE := "Order"
const SORT_SUB := "How the Library lines your games up."
const VIEW_NAMES := {"favourites": "Favourites", "hidden": "Hidden", "emulation": "Emulation"}
const EMPTY_FAVOURITES := "No favourites yet. Press Menu on a game, or the star on its page, to add one."
const EMPTY_HIDDEN := "Nothing hidden. Press Menu on a game and pick Hide this game to tuck it away."
const EMPTY_EMULATION := "No emulated games yet. Copy your game backups into the ROM folder EmuDeck made, and they show up here."
const EMPTY_COLLECTION := "This collection is empty. Press Menu on a game and pick Add to a collection."

# ------------------------------------------------------------ Settings > Stores
const COLLECTIONS_CARD := "Collections"
const COLLECTIONS_CARD_LINE := "Favourites, hidden games and collections work for every store, emulated games too."
const STEAM_COLLECTIONS := "Show Steam's collections"
const STEAM_COLLECTIONS_HELP := {true: "We read your Steam collections, favourites and hidden games and show them here. We never change them; edit them in Steam.",
	false: "Only the favourites, hidden games and collections you make in GameCove."}
const STEAM_DYNAMIC := "%d dynamic Steam collection%s stay in Steam: their rules only work there."

# ------------------------------------------------------------ Quick menu
const QM_FAVOURITE := "Favourite"
const QM_FAVOURITE_ON := "On Home's Favourites shelf."
const QM_FAVOURITE_OFF := "Add it to your Favourites shelf on Home."

# ------------------------------------------------------------ Emulation page
const EMU_TITLE := "Emulation"
const EMU_OPEN := "Open %s"
const EMU_OPEN_LINE := "Runs full screen like a game. Guide brings up the quick menu; Exit game closes it."
const EMU_APP_EMUDECK := "EmuDeck"
const EMU_APP_EMUDECK_LINE := "Update emulators, change their settings, set up BIOS folders and cloud saves."
const EMU_APP_RETRODECK := "RetroDECK settings"
const EMU_APP_RETRODECK_LINE := "RetroDECK's configurator: emulator settings, BIOS check, updates."
const EMU_SRM := "Add ROMs to Steam too"
const EMU_SRM_LINE := "Opens Steam ROM Manager, which adds each ROM to Steam's own library as well. We already list every ROM here, so you only need it for Steam. Close Steam first when it asks."
const EMU_SRM_MISSING := "Steam ROM Manager isn't installed. EmuDeck installs it: open EmuDeck > Manage emulators."
const EMU_SYSTEMS := "Systems"
const EMU_SYSTEMS_LINE := "ROM folders with games in them, in %s. Pick one to see its games in the Library."
const EMU_SYSTEM_COUNT := "%d game%s"
const EMU_NO_ROMS := "No ROMs yet. Copy your own game backups into the system folders in %s and they show up in the Library."
const EMU_RECENT := "Recently played in %s"
const EMU_NO_RECENT := "Nothing played in %s yet."
const EMU_IN_LIBRARY := "In your library"
const EMU_IN_LIBRARY_LINE := "%d emulated game%s, each with its own page, art, play time and Play button. They're in the Library under Filter > Emulation."
const EMU_IN_LIBRARY_NONE := "None yet. Every game you copy into the ROM folder shows up in the Library with ES-DE's art."
const EMU_SETUP := "Your setup"
const EMU_KIND := {"emudeck": "EmuDeck", "retrodeck": "RetroDECK", "esde": "ES-DE"}
const EMU_FACT_SETUP := "Setup"
const EMU_FACT_ROMS := "ROM folder"
const EMU_FACT_FRONTEND := "Front end"
const EMU_NO_FRONTEND := "ES-DE isn't installed. EmuDeck can add it."
const EMU_LEGAL := "GameCove never downloads or ships games or BIOS files. Play backups of games you own."
const EMU_EMPTY_TITLE := "Play your console games here"
const EMU_EMPTY_LINE := "Install EmuDeck (or RetroDECK) from desktop mode. It sets up the emulators, ES-DE and Steam ROM Manager, and everything shows up here."
const EMU_EMPTY_QR := "Scan to open emudeck.com on your phone"
const EMU_EMPTY_STEPS := ["Switch to desktop mode and open emudeck.com.", "Install EmuDeck and pick your systems.",
	"Copy your own game backups into Emulation/roms, then come back."]
const EMUDECK_URL := "https://www.emudeck.com/"
const EMU_GET := "Open emudeck.com"
const EMU_IN_LIBRARY_SRM := "%d emulated game%s Steam ROM Manager added. They're in the Library under Filter > Emulation."
const EMU_IN_LIBRARY_OFF := "Emulated games are off in the Library. Turn on Show emulated games in the Library in Settings > Stores to list every ROM."
const EMU_ROOT_OFFLINE := "not connected: its games come back when it is"
const EMU_UNKNOWN_SYSTEM := "ES-DE doesn't know this folder's name, so its games can't start"
const EMU_ALL_SYSTEMS := "All systems"
const EMU_GAMES := "Games"
const EMU_GAMES_LINE := "Every game in your ROM folders. Pick a console; A plays, Menu opens the game's page."
const EMU_HINT_PLAY := "Play"
const EMU_HINT_PAGE := "Game page"
const EMU_ALL_SYSTEMS_DETAIL := "Every emulated game"
const EMU_SYSTEMS_TITLE := "Emulation"
const EMU_SYSTEMS_SUB := "Pick a system"
const EMU_RECENT_OURS := "Recently played"
const EMU_NOTHING_PLAYED := "Nothing played yet. Pick a game in the Library and press Play."
const EMULATION_CARD := "Emulation"
const EMULATION_CARD_LINE := "Your ROM folder from EmuDeck, RetroDECK or ES-DE."
const SHOW_ROMS := "Show emulated games in the Library"
const SHOW_ROMS_HELP := {true: "Every game in your ROM folder gets a page, art, play time and a Play button, like your Steam games.",
	false: "Only ES-DE and the games Steam ROM Manager added to Steam show in the Library."}
const SHOW_ROMS_NONE := "No ROM folder found yet. Install EmuDeck or RetroDECK from desktop mode."
const SHOW_ROMS_FACT := "%d game%s in %d system%s, in %s"
## Game page facts for a ROM.
const FACT_SYSTEM := "System"
const FACT_RUNS_IN := "Runs in"
const FACT_PLAYERS := "Players"
const FACT_RATING := "Rating"
const FACT_PLAYED_ESDE := "Played in ES-DE"
const RATING_OF := "%s / 5"
const TIMES := "%d time%s"
const EMU_COULDNT_START := "Couldn't start %s"
const EMU_COULDNT_START_LINE := "Its file wasn't found. Open EmuDeck in desktop mode to repair it."
const EMU_STARTED := "%s is opening"


static func plural(n: int) -> String:
	return "" if n == 1 else "s"


## "4 favourites · 1 hidden · 2 collections" (Settings > Stores > Collections).
static func collections_fact(fav: int, hidden: int, cols: int) -> String:
	return "%d favourite%s · %d hidden · %d collection%s" % [fav, plural(fav), hidden, cols, plural(cols)]


static func games_n(n: int) -> String:
	return GAMES_N % [n, plural(n)]
