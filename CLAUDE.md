# Fuel — Project Context

Personal nutrition + weight tracking app. Single-file build.

## Architecture
- Entire app is one file: `index.html` (HTML/CSS/JS together).
- Served locally via a Python HTTP server; accessed on a Pixel 10 in Chrome over home WiFi.
- `config.js` holds the USDA FoodData Central API key and is gitignored — it is NOT in the repo. Anything that hosts the app (e.g. GitHub Pages) won't have it, so USDA lookup breaks without a separate plan for the key (Open Food Facts needs no key and still works).
- Data sources: USDA FoodData Central + Open Food Facts (database foods), plus user-created custom foods.
- Carbon Diet Coach seed data is embedded in code (weights 2021→2026; ~12 months of diary entries). Seeded once per version flag — skips any date/day already in storage; does not regenerate on each load.

## ⚠️ Data storage — READ BEFORE TOUCHING STORAGE
- All logged data (weights, meals, custom foods) lives in **browser localStorage** on the device. There is **no backend** — data is device-local and unbacked-up.
- Clearing Chrome **"site data" / cookies WIPES all logged data.** This has already caused real data loss. Only ever clear *cache*, never site data.
- A **hard refresh** (e.g. Cmd+Shift+R on desktop, or DevTools "Disable cache") bypasses stale JS WITHOUT deleting data — that's the correct way to pick up code changes. Never suggest clearing site data to "refresh."
- Interim backup habit: Excel/JSON export (SheetJS) after meaningful logging sessions.

## Top backlog item: backend
- Highest-priority item. A backend with a **persistent database** solves both data-loss risk and away-from-home access in one move (these are the same architectural step).
- This is a genuine architecture decision (DB choice, data model, sync/conflict resolution between Pixel + laptop, auth) — plan it carefully (Opus-tier reasoning) before implementing.

## Conventions

### Food units (non-obvious — implemented the hard way)
- For foods that offer **gram AND ounce** units (database/USDA/Open Food Facts foods), the "serving" option is removed from the unit dropdown, and the "1 serving = 1 g" descriptor line is omitted. Default unit falls back to `g`.
- **Detect this by the presence of g/oz options — NOT by trying to classify the food's origin (custom vs database).** Origin-based detection was attempted repeatedly and kept failing; the g/oz-presence rule is the robust one.
- Custom foods use arbitrary units (e.g. "burger", "piece", "serving"). Those are correct and are the only valid unit for that food — leave them completely untouched.

### Meals
- Up to 6 meal slots per day.
- Default labels are `Meal #1`–`Meal #6`. Renaming a slot sets that slot's label **globally across all days** (labels are not stored per-day).
- Copy-meals: launched from a meal's ⋮ menu (single meal) or the date-row copy icon (whole day) → one or more multi-selected target dates picked via an in-modal calendar. Prompts on conflict (shows which dates/slots). Copies as independent data, not references.

### Nav icon style split
- **Top row = screens/destinations → color emoji** (e.g. weight chart icon, 📅 calendar, ⚙️ settings).
- **Date row = actions on the current day → monochrome line icons** (`<` `>` date arrows, copy icon for copying the day's meals).
- Place new icons in the style matching their row's role.

### Weight screen
- Reached via the chart nav icon (left of the calendar icon).
- Week/Month/Year toggle; rolling window anchored on today (not fixed calendar buckets).
- Chevron arrows beside the date range advance by a full period (week/month/year); swiping/dragging the chart itself nudges the window by ONE day at a time, unlimited either direction → sliding rolling average. The visible average recomputes from whatever's in view (the only average shown).
- Logged entries show as dots; unlogged days show a faded line, not a gap. Empty state still renders the full chart (axes/gridlines/tabs) — never a "no data" placeholder.
- Entry supports back-dating via `<` `>` day arrows only (no date picker): unlimited days back, forward arrow disabled at today (no future entries). One entry per date; re-entering updates rather than duplicates.

## Workflow
- Plan in Claude.ai chat; implement in Claude Code. Default build setting: Sonnet 4.6 at Medium effort.
- Confirm model choice rather than assuming — reach for Opus only for genuine architecture decisions (e.g. the backend).
