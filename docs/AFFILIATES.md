# Affiliate links

GameCove can add an affiliate id to some store links so purchases support the project. It's off in practice until the owner joins a program: `app/data/affiliates.json` ships empty.

## Rules

- Only links GameCove builds itself (today: Epic store pages for calendar entries that have an Epic id and no Steam id). Code: `app/scripts/discover/affiliates.gd`.
- Never Steam (Steam has no affiliate program; Steam links stay `steam://store/<appid>`).
- Never CheapShark rows: their terms require their redirect links and forbid using your own affiliate links for any store they track.
- Never GG.deals rows: their terms forbid altering or removing their referral links.
- Prices never change. A link carrying an id shows a small "Supports GameCove" note (`link.note`), and users can turn affiliate links off in Settings (`affiliate_links`).

## Adding an id

1. Join the program and read its link rules:
   - Humble Partner Program (Humble Store)
   - Green Man Gaming affiliate program
   - Fanatical affiliate program
   - Epic Games Store affiliate / Support-A-Creator
   - GOG affiliate program
2. Fill in the store's entry in `app/data/affiliates.json`:
   ```json
   "humble": {"program": "Humble Partner Program", "template": "https://www.humblebundle.com/store/{slug}?partner={id}", "id": "gamecove"}
   ```
   The template must start with `https://`. Placeholders: `{url}` (the plain store URL we built), `{url_encoded}` (the same, URL-encoded, for redirect-style programs) and `{id}`. The example template is illustrative: use the exact format the program gives you.
3. If the store isn't linked anywhere yet, build its plain store URL where Discover knows the store's product id and pass it through `Affiliates.link(store, url, Discover.affiliates, settings.affiliate_links)`.
4. Add a test in `app/tests/test_discover_ggdeals.gd` (affiliate section) and mention the program in CREDITS.md.

## Later: regional prices from affiliate feeds

Affiliate programs often come with product feeds or partner APIs (prices per country and currency). Once a program is joined, its feed could give real local prices for that store, which would replace the "See price" rows for it. Check the feed's own terms first; it would be a new source in `app/scripts/discover/`, shaped like `ggdeals.gd`.
