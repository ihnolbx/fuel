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
  serving_qty  REAL,                    -- the serving the macros describe
  serving_unit TEXT,
  default_unit TEXT,
  kcal         REAL, protein REAL, carbs REAL, fat REAL,  -- per serving
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
  logged_at  INTEGER NOT NULL,          -- epoch ms (UTC) for intra-day ordering
  food_id    TEXT,                      -- soft reference, nullable
  food_name  TEXT,                      -- snapshot, so display survives deletion
  qty        REAL NOT NULL,
  unit       TEXT NOT NULL,
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
CREATE TABLE settings (
  id         TEXT PRIMARY KEY,          -- setting key, e.g. 'targets'
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
