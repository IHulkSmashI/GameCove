# Controller UX rules

GameCove is used with a pad first, a finger second and a keyboard almost never. These are the rules every screen, sheet and dialog keeps. They're taken from the platforms that solved this already (sources at the end); where those disagree we picked one and wrote it down. Each rule has an id: the focus walk (below) reports problems by the rule they break, and a review note can just say "breaks CUX-5".

## The rules

**CUX-1. One highlight.** Exactly one thing on screen wears the focus look (the theme's accent ring and glow, a filled key on the keyboard, a lifted tile). Nothing else may look like it: not a hovered button, not a selected card, not today's date. A finger tap moves focus to what was tapped.

**CUX-2. Focus is not selection.** Selected, chosen, open or "on" has its own look that can never be mistaken for focus: a filled segment, a tick, a dot, a quiet surface fill, a bar under a tab. It never uses an outline in the ring colour 2 px or wider. A focused selected item shows both (the ring around the filled thing).

**CUX-3. The D-pad moves, it doesn't change.** D-pad and left stick only move focus. The exceptions are controls that look like they change sideways: a slider and a `‹ value ›` stepper change with left / right while focused (never with up / down). Switches, segmented choices, radio groups, check boxes and cards change only with A. A D-pad press never opens, closes, starts or confirms anything. Tab strips are the one place moving focus also shows what's under it (the top bar, Settings' categories, section tabs: tvOS and Android TV tab bars work this way); the open tab still looks different from the focused one (CUX-2).

**CUX-4. Buttons mean the same everywhere.** A activates the focused control: presses a button, toggles a switch, picks a radio choice and stays on the page (picking is not continuing; a separate Continue / Done button moves on). B goes back or cancels and is never destructive: it never deletes, uninstalls, signs out or confirms. On the on-screen keyboard Menu (Start) is Done. X and Y are secondary actions and the hint bar names them. Confirm is A in every region (Sony moved PS5 to cross-confirm everywhere; Nintendo layouts follow the button position). The one screen where any button answers is the low-battery countdown ("any button keeps it awake").

**CUX-5. Order follows what you see.** A press goes to the nearest control in that direction, in the same row or column first: rows left to right, then down; a button row in its visual order, never skipping one in the middle; never the opposite way. A press into a list lands on the item that list last had focused (shelves, tvOS / Leanback rows); a press into a tab strip lands on the open tab. A linear list or a keyboard row may wrap end to start; a 2D grid never wraps (XAG 112).

**CUX-6. Entering puts focus somewhere useful.** A new screen, sheet or dialog focuses its first actionable control, top left, unless it is one decision with a single primary action (then that). While a sheet, dialog or the keyboard is open, focus can't leave it. There is always something focused when there is something to press.

**CUX-7. Only things that do something take focus.** Labels, headings, read-only cards, credits and disabled controls take no focus, by pad or by touch. A control that is unavailable for a reason either explains itself where it is (and isn't focusable) or stays focusable and says why on A.

**CUX-8. Focus is always fully on screen.** The focused control and its ring are wholly inside the window, not under a bar, sheet or fade, and not faded out. Every scroller with controls in it follows focus, keeping a margin (FocusScroll's 18 px, more above a "More below" fade). Focus never moves to something hidden or off screen.

**CUX-9. Everything is reachable two ways.** Every control on screen can be reached with the D-pad alone from where focus starts, and tapped with a finger. Nothing actionable sits clipped past the window's edge or below content that can't scroll.

**CUX-10. Hints are honest and readable.** The hint bar shows the glyphs of the pad in use (Xbox, PlayStation, Steam Deck sets) for what the focused control does, never keyboard keys while a pad is used. Text at least the layout's readable minimum (Valve: 9 px at 1280x800 and readable at 30 cm; the layout checks hold every screen to it), glyphs and their labels at 4.5:1 contrast, the glyph disc at 3:1 against its bar.

**CUX-11. Long lists are virtual.** The library grid, ROM lists, deals and anything that can run into hundreds build only the rows on screen (suite_perf.gd holds the budgets).

**CUX-12. No physical keyboard, ever.** Every text field opens our on-screen keyboard on A and can be finished with the pad alone (Valve requires it of Deck Verified games and their launchers). We don't trigger system password prompts from the app; where root is needed the installer asks once, says so first, and makes sure a working keyboard is in front of that prompt.

**CUX-13. Touch targets are at least 48 x 48.** Every actionable control is at least 48 layout px in both directions (Android's 48 dp; WCAG 2.2's 24 px is the floor, not the goal), or carries `ux_small_ok` with the reason (a key row of the keyboard is wider than tall, a slider's track has a taller row around it).

**CUX-14. Sound and rumble are optional.** Every cue is also visible; sounds and haptics can be switched off and nothing depends on them.

**CUX-15. The primary action sits in the same place.** In a sheet or dialog the button row is at the bottom, primary first (left), the safe or Back choice last; on a page the primary pill leads the action row. A destructive action is never the default focus.

## The focus walk

`app/tests/layout/focus_walk.gd` checks CUX-1, 2, 3, 5, 6, 7, 8, 9 and 13 on every screen the screenshot sets show (every screen, sheet, dialog, quick menu tab, settings page, setup and installer step), on every CI layout, in the `layout` CI job (`tools/layout/run.py --ci`, which runs it after each shot unless `FOCUS_WALK=0`). From every control the pad can focus it presses each D-pad direction with real joypad events, so the app's own handlers run, notes where focus went and what changed, puts everything back, and reports by kind:

| kind | rule | what it means |
|---|---|---|
| `pad-skip` | CUX-5 | the press jumps over a control between, in the same line |
| `pad-order` | CUX-5 | the press leaves its line while a control in line is nearer |
| `pad-direction` | CUX-5 | the press moves focus the other way (outside a list that wraps) |
| `pad-stuck` | CUX-5, 9 | nothing happens though a control is right there |
| `pad-lost` / `pad-hidden` | CUX-8 | focus is gone, or lands on something under a sheet, faded or off screen |
| `pad-value` | CUX-3 | a press changed a value on something that isn't a slider or stepper |
| `pad-action` | CUX-3 | a press changed the screen |
| `pad-dead` | CUX-7 | something that does nothing takes focus (pad or touch) |
| `pad-unreachable` | CUX-9 | a control the D-pad can't get to from where focus is |
| `pad-offscreen` | CUX-8, 9 | a control that can't be shown whole (no scroller brings it in) |
| `pad-scroll` | CUX-8 | a scroller with controls that doesn't follow focus |
| `pad-double` | CUX-1, 2 | something not focused wears the focus look |
| `pad-nofocus` | CUX-6 | controls on screen, nothing focused |
| `pad-target` | CUX-13 | a touch target under 48 x 48 |

Declarations a control can make (each one is a claim the walk then holds it to, and says why): `ux_stepper` (left / right change it), `ux_tab` (a tab strip), `ux_action` (a custom control that does something on A, or `false`), `ux_wrap` (a list that wraps), `ux_modal` (owns the pad while open), `ux_follows` (a scroller that follows focus with its own code), `ux_small_ok` (a small target, with the reason), `ux_any_key` (the countdown dialog). Accepted findings go in `tools/layout/known.json` with a reason, like every layout finding.

What a walk can't see is checked elsewhere: the journeys (`app/tests/e2e/suite_journeys.gd`) do every flow with the pad alone and check focus stays visible after scrolling; `tools/ux_walk/sheets.sh` renders those journeys one picture per press for a person to look at (`docs/TESTING.md`).

## Sources

- Valve, [Steam Deck compatibility review](https://partner.steamgames.com/doc/steamdeck/compat): full controller navigation including launchers, glyphs matching the input in use, controller-only text entry, text no smaller than 9 px at 1280x800 and readable at 30 cm.
- Microsoft, [Xbox Accessibility Guideline 112: UI navigation](https://devdocs.xbox.com/gaming/accessibility/xbox-accessibility-guidelines/112): logical, consistent order; linear menus wrap, grids don't; consistent "A to select, B to go back" prompts; fully navigable by digital input alone. [XAG 113: UI focus handling](https://learn.microsoft.com/en-us/gaming/accessibility/xbox-accessibility-guidelines/113): a highly visible focus indicator that never moves off screen or to invisible elements; a dialog takes focus to its first control and keeps it.
- Google, [Android TV navigation](https://developer.android.com/training/tv/get-started/navigation): the D-pad goes to the nearest object in that direction; every visible control reachable; a uniform focus look; something focused at all times; top and side navigation focus the active item. [Touch target size](https://support.google.com/accessibility/android/answer/7101858): at least 48 dp.
- Apple, [Focus and selection (HIG)](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection): focus moves directionally to every element; selection is a separate gesture where it would change context; distinct unfocused, focused, selected and unavailable looks; don't move focus without the player.
- W3C, [What's new in WCAG 2.2](https://www.w3.org/WAI/standards-guidelines/wcag/new-in-22/): 2.4.11 Focus Not Obscured, 2.4.13 Focus Appearance (2 px perimeter, 3:1), 2.5.8 Target Size (24 px minimum).
- Sony made cross the confirm button in every region on PS5 ([Push Square](https://www.pushsquare.com/news/2020/10/sony_abandons_decades-old_japanese_controller_logic_for_ps5)); GameCove's A is always the bottom face button.
