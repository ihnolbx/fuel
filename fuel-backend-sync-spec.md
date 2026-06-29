# Fuel Ihno — Backend Sync Spec (Cloudflare Workers + D1)

Implementation reference for Claude Code. Frontend stays on GitHub Pages
(`index.html`); a Cloudflare Worker in front of a D1 (SQLite) database provides
a single batched sync endpoint. The app remains local-first and fully usable
offline; sync reconciles in the background.

---

## 1. Sync model (read this first)

Every synced row carries **two distinct bookkeeping columns** that serve
different jobs — keeping them straight is the whole design:

- **`rev`** — a single **global, server-allocated** integer counter. It defines
  a total order of changes and is the basis for the sync **cursor**. The client
  never sets it; the Worker stamps it. This makes the cursor immune to device
  clock skew.
- **`updated_at`** — epoch-ms timestamp set by the **client at user-edit time**.
  This is the basis for **conflict resolution (last-write-wins)**. It must be
  the moment the user actually made the edit, *not* server-receipt time — a
  phone edit made offline at 9am that syncs at 5pm should still lose to a laptop
  edit made at noon. User-edit time gets that right; receipt time doesn't.

Deletes are **tombstones** (`deleted_at` set, row retained), never hard deletes —
absence from a pull must never be interpreted as a deletion.

LWW rule, applied identically on server and client: an incoming row wins iff
`incoming.updated_at >= existing.updated_at`. Ties are harmless (write is
idempotent). For a single user this conflict window is tiny.

---

## 2. Schema (D1 / SQLite DDL)

```sql
-- Single-row server counter that allocates global revisions.
CREATE TABLE sync_state (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  current_rev INTEGER NOT NULL DEFAULT 0
);
INSERT INTO sync_state (id, current_rev) VALUES (1, 0);

-- Personal food database.
CREATE TABLE foods (
  id           TEXT PRIMARY KEY,        -- client-generated UUID
  name         TEXT NOT NULL,
  brand        TEXT,
  source       TEXT,                    -- 'off' | 'usda' | 'manual'
  external_id  TEXT,                    -- OFF/USDA id when applicable
  serving_qty  REAL,                    -- maps from localStorage `servingSize`
  serving_unit TEXT,
  default_unit TEXT,
  kcal         REAL, protein REAL, carbs REAL, fat REAL,  -- per serving
  -- Optional micros present on custom foods in localStorage (nullable).
  sat_fat      REAL, fiber REAL, sugar REAL, sodium REAL, cholesterol REAL,
  updated_at   INTEGER NOT NULL,        -- client edit time (epoch ms) — LWW
  deleted_at   INTEGER,                 -- tombstone (epoch ms) or NULL
  rev          INTEGER NOT NULL         -- server-allocated
);

-- Food log. Macros are SNAPSHOTTED at log time so editing a food later
-- never rewrites history. food_id is a soft pointer (nullable for quick-add /
-- dictation); NO foreign key is enforced.
CREATE TABLE log_entries (
  id         TEXT PRIMARY KEY,          -- client-generated UUID
  local_date TEXT NOT NULL,             -- 'YYYY-MM-DD' from DEVICE-LOCAL time
  meal       INTEGER NOT NULL,          -- meal slot 1..6 (slot NAMES live in settings)
  logged_at  INTEGER NOT NULL,          -- epoch ms (UTC) for intra-day ordering
  food_id    TEXT,                      -- soft reference, nullable
  food_name  TEXT,                      -- snapshot, so display survives deletion
  qty        REAL NOT NULL,             -- maps from localStorage `servings`
  serving_size REAL,                    -- maps from localStorage `servingSize`
  unit       TEXT NOT NULL,             -- maps from localStorage `servingUnit`
  kcal       REAL, protein REAL, carbs REAL, fat REAL,  -- SNAPSHOT
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  rev        INTEGER NOT NULL
);

-- Weight entries. Carbon migration (kg->lbs, May 2021 onward) lands here.
CREATE TABLE weight_entries (
  id           TEXT PRIMARY KEY,        -- client-generated UUID
  local_date   TEXT NOT NULL,           -- 'YYYY-MM-DD' device-local
  measured_at  INTEGER NOT NULL,        -- epoch ms
  weight_lbs   REAL NOT NULL,
  body_fat_pct REAL,                    -- nullable (Carbon data has none)
  notes        TEXT,                    -- nullable
  updated_at   INTEGER NOT NULL,
  deleted_at   INTEGER,
  rev          INTEGER NOT NULL
);

-- Settings / targets as a key-value table so they sync with the same machinery.
-- Keys map from localStorage: 'targets' (profile macro goals), 'meal_names'
-- (the six renameable slot labels, from `fuel_meal_names`), 'favorites'
-- (from `fuel_favs`), 'active_profile'. Each value is a JSON blob.
CREATE TABLE settings (
  id         TEXT PRIMARY KEY,          -- setting key, e.g. 'targets' | 'meal_names'
  value      TEXT,                      -- JSON blob
  updated_at INTEGER NOT NULL,
  deleted_at INTEGER,
  rev        INTEGER NOT NULL
);

-- Cursor pulls hit `rev`; day grouping hits `local_date`.
CREATE INDEX idx_foods_rev          ON foods(rev);
CREATE INDEX idx_log_rev            ON log_entries(rev);
CREATE INDEX idx_log_local_date     ON log_entries(local_date);
CREATE INDEX idx_weight_rev         ON weight_entries(rev);
CREATE INDEX idx_weight_local_date  ON weight_entries(local_date);
CREATE INDEX idx_settings_rev       ON settings(rev);
```

Extending later (fiber, sugar, micros, etc.) is just adding nullable columns —
the sync machinery doesn't care. Use Wrangler migrations for any schema change.

---

## 3. `/sync` endpoint contract

Single batched endpoint. One round trip does push + pull atomically.

### Request — `POST /sync`

```
Authorization: Bearer <token>
Content-Type: application/json
```

```json
{
  "cursor": 0,
  "changes": {
    "foods":         [ /* row objects, no rev */ ],
    "log_entries":   [ ... ],
    "weight_entries":[ ... ],
    "settings":      [ ... ]
  }
}
```

- `cursor` — the highest `rev` this client has already seen (global, one number).
- `changes` — the client's pending/dirty rows since last sync. Each row includes
  its `id`, all payload columns, `updated_at`, and `deleted_at` (null or ms).
  The client does **not** send `rev`.
- A pure pull (no local changes) sends `"changes": {}` (or empty arrays).

### Server algorithm (single transaction)

1. Validate bearer token; reject 401 otherwise.
2. If the request carries any changes, allocate a new rev:
   `UPDATE sync_state SET current_rev = current_rev + 1 RETURNING current_rev;`
   Call it `newRev`. (Skip this bump on pure-pull requests.)
3. For each incoming row, UPSERT with the LWW guard, stamping winners with
   `newRev`:

   ```sql
   INSERT INTO log_entries
     (id, local_date, logged_at, food_id, food_name, qty, unit,
      kcal, protein, carbs, fat, updated_at, deleted_at, rev)
   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)  -- last bind = newRev
   ON CONFLICT(id) DO UPDATE SET
     local_date=excluded.local_date, logged_at=excluded.logged_at,
     food_id=excluded.food_id, food_name=excluded.food_name,
     qty=excluded.qty, unit=excluded.unit,
     kcal=excluded.kcal, protein=excluded.protein,
     carbs=excluded.carbs, fat=excluded.fat,
     updated_at=excluded.updated_at, deleted_at=excluded.deleted_at,
     rev=excluded.rev
   WHERE excluded.updated_at >= log_entries.updated_at;
   ```

   Rows that lose the guard are left untouched and keep their old `rev`.
4. Pull each table: `SELECT * FROM <table> WHERE rev > :cursor ORDER BY rev;`
   (using the client's **original** `cursor`). This naturally includes the rows
   just written at `newRev` plus anything another device wrote since.
5. Respond with `newCursor = current_rev` (the post-bump value).

### Response

```json
{
  "cursor": 7,
  "changes": {
    "foods":         [ /* rows with rev > old cursor, each incl. server rev */ ],
    "log_entries":   [ ... ],
    "weight_entries":[ ... ],
    "settings":      [ ... ]
  }
}
```

### Client algorithm

1. Apply returned rows locally using the **same** LWW rule
   (`incoming.updated_at >= local.updated_at`).
2. Set the stored cursor to `response.cursor`.
3. Clear successfully-pushed rows from the pending queue.
4. Idempotency note: retries are safe because UPSERT is keyed on UUID `id`; a
   re-sent identical row is a harmless no-op write. Volume is low enough that
   no pagination is needed — return everything above the cursor.

### Sync triggers (client)

On app open, on tab/app regaining focus, on regaining connectivity, debounced
after writes, plus a manual "sync now" button. All tunable.

---

## 4. Auth & CORS

- Single shared **bearer token**. Stored server-side as a Wrangler secret;
  entered once per device on the client (kept in localStorage). **Never
  committed** — the repo and Pages site are public.
- Worker validates the token on every request.
- CORS: allow the GitHub Pages origin only; handle the preflight `OPTIONS`.

---

## 5. Cutover / seed sequence (do not skip the order)

The dangerous moment is the first sync — protect existing local data.

1. Deploy schema (`current_rev = 0`).
2. **One-time seed** from the device holding canonical data, reading
   **localStorage directly** (NOT the xlsx export — see ID strategy note). For
   each row, ensure a stable `id` (most already have one; see below) and a
   **synthesized `updated_at`** — no existing entry carries a timestamp, so the
   seed assigns a baseline (e.g. derived from `local_date`, else now). Then push
   them all. Guard the seed with a one-time `seeded` flag so it can't run twice.
3. **Verify**: compare local counts against `SELECT COUNT(*)` per table in D1.
   Do not proceed until they match.
4. **Then** enable two-way sync on all devices, with the **first-sync union
   guardrail**: a device must push its un-synced local rows; a pull must never
   delete a local row merely because it's absent from the pull. Deletion only
   ever comes from an explicit `deleted_at` tombstone.
5. **Weight migration (backlog #1)** rides along in the seed: transform the
   Carbon export (kg -> lbs, May 2021 onward, no body fat %, notes optional)
   into `weight_entries` rows (mint a UUID, local_date, measured_at, weight_lbs)
   and include them in the seed push.

### ID strategy (LOCKED)

Verified against the live `index.html`: the app **already** follows this strategy,
so the backfill is much smaller than first assumed.

- **Log entries:** already carry a stable `id` — live entries get `uid()`, the
  Carbon-seeded entries get `"seed_N"`. **No backfill needed.**
- **Custom foods:** already carry `id: "user_"+uid()`. **No backfill needed.**
- **External food refs (OFF / USDA):** already deterministic — `"off_"+…` /
  `"usda_"+…`, where identity is the point and dedup is desired. Unchanged.
- **Weight entries:** the ONE gap. `fuel_weight_<date>` is `{ lb }` keyed by date
  with **no `id`** — so the seed mints a fresh **random UUID** per weight row.

The principle behind minting random (not content-derived) ids stands: duplicate
content is legitimate (two identical coffees in a day are two real rows), so a
content hash would silently merge distinct entries. Persisting the random id is
what makes it stable across syncs. Decision locked; the only id-minting work is
weight, and it happens during the seed.

---

## 6. Backups (belt and suspenders)

- **D1 Time Travel** — point-in-time restore to any minute in the last 30 days.
  Free safety net; no setup.
- **Export/import** — keep the existing manual path as the off-platform backstop.
- Optional: a weekly scheduled Worker that dumps an export (e.g. to R2 or a
  downloadable) so there's always a copy outside the platform.

---

## 7. Decide-now vs. hand-to-Sonnet

**Settled in this spec (schema/migration — costly to reverse):** day-keying via
device-local `local_date` + UTC timestamp; `rev` cursor + `updated_at` LWW split;
single batched `/sync` shape; snapshot macros; tombstones; seed/cutover order;
`log_entries.meal` slot + meal-name setting; `foods` micro columns; ID strategy
(ids already present except weight, which the seed mints; deterministic for
external food refs).

**Implementation details for Sonnet (obvious right answers):** exact sync-trigger
wiring, Wrangler migration setup, CORS/preflight + token plumbing, the pending-
queue data structure on the client (localStorage stays for now; IndexedDB is a
later, isolated swap if data grows).

---

## 8. Open items to confirm before coding

*(none blocking)* — The former open item (export JSON shape) is **resolved**: the
export is xlsx and lossy, so the seed reads **localStorage directly**. The
localStorage shapes, verified against `index.html`, are:

- `fuel_log_<YYYY-MM-DD>` → `{ meal1..meal6: [ entry ] }`, entry =
  `{ id, foodId, name, brand, servings, servingSize, servingUnit,
  calories, protein, carbs, fat }`.
- `fuel_weight_<YYYY-MM-DD>` → `{ lb: number }` (no id, no timestamp).
- `fuel_db` → `[ { id, name, brand, servingSize, servingUnit, calories, protein,
  carbs, fat, saturatedFat?, fiber?, sugar?, sodium?, cholesterol? } ]`.
- `fuel_favs` → `[ foodKey ]`; `fuel_meal_names` → six slot labels; profiles.
