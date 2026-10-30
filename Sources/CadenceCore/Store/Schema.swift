/// The schema migrations, in order (docs/SPEC.md section 7.3). Migration N takes the store from
/// `user_version` N-1 to N. Never edit a shipped migration: add a new one.
public enum Schema {
    /// The newest schema this binary understands.
    public static var currentVersion: Int { migrations.count }

    /// Projection tables, emptied and refilled by `cadence rebuild`.
    public static let projectionTables = ["entries", "plan_tasks", "presence_spans", "genai_sessions", "genai_usage", "days"]

    public static let migrations: [String] = [v1]

    /// Version 1, identical to Sources/CadenceCore/Store/Schema.sql.
    static let v1 = #"""
-- Cadence schema v1 (docs/SPEC.md section 7.3).
-- Connection settings (journal_mode = WAL, foreign_keys = ON, busy_timeout = 3000) are applied
-- when a connection opens. PRAGMA user_version holds the schema version; a binary refuses to
-- write to a newer schema. This file must stay identical to Schema.swift (a test checks it).

CREATE TABLE events (
  seq         INTEGER PRIMARY KEY,      -- 1, 2, 3 … no gaps
  id          TEXT NOT NULL UNIQUE,     -- ULID
  v           INTEGER NOT NULL DEFAULT 1,
  at          TEXT NOT NULL,            -- recorded time, RFC 3339 UTC with ms
  actor       TEXT NOT NULL,            -- app | cli | mcp | hook | collector:<name> | import:<name>
  type        TEXT NOT NULL,
  subject     TEXT,
  data        TEXT NOT NULL,            -- canonical JSON
  data_digest TEXT NOT NULL,
  prev        TEXT NOT NULL,
  hash        TEXT NOT NULL UNIQUE
);
CREATE TRIGGER events_no_update BEFORE UPDATE ON events BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON events BEGIN SELECT RAISE(ABORT, 'ledger is append-only'); END;
CREATE INDEX events_subject ON events(subject);
CREATE INDEX events_type_at ON events(type, at);

-- projections: rebuildable from events with `cadence rebuild`
CREATE TABLE days (
  date TEXT PRIMARY KEY, tz TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'workday',   -- workday | weekend | holiday | leave_planned | leave_unplanned
  label TEXT, first_activity TEXT, last_activity TEXT,
  focus TEXT, note TEXT, on_call INTEGER NOT NULL DEFAULT 0,
  sealed_at TEXT, seal_event TEXT, updated_seq INTEGER NOT NULL
);
CREATE TABLE entries (
  id TEXT PRIMARY KEY, day TEXT NOT NULL REFERENCES days(date),
  kind TEXT NOT NULL, family TEXT NOT NULL, title TEXT NOT NULL,
  occurred_at TEXT, duration_s INTEGER, quantity INTEGER NOT NULL DEFAULT 1,
  ticket_key TEXT, ticket_class TEXT,     -- assigned | self | NULL
  links TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]', attrs TEXT NOT NULL DEFAULT '{}',
  origin TEXT NOT NULL,                   -- observed | collected | agent | self (never changes)
  source TEXT, source_ref TEXT UNIQUE,    -- idempotency key for collectors
  status TEXT NOT NULL DEFAULT 'accepted',-- proposed | accepted | dismissed | deleted
  backfilled INTEGER NOT NULL DEFAULT 0, after_seal INTEGER NOT NULL DEFAULT 0,
  export TEXT NOT NULL DEFAULT 'include', -- include | digest | exclude
  created_seq INTEGER NOT NULL, updated_seq INTEGER NOT NULL
);
CREATE INDEX entries_day ON entries(day);
CREATE INDEX entries_kind_day ON entries(kind, day);
CREATE TABLE plan_tasks (
  id TEXT PRIMARY KEY, day TEXT NOT NULL REFERENCES days(date),
  position INTEGER NOT NULL, title TEXT NOT NULL,
  ticket_key TEXT, ticket_class TEXT, estimate_min INTEGER,
  origin TEXT NOT NULL,                   -- self | suggested | carried
  carried_from TEXT REFERENCES plan_tasks(id),
  status TEXT NOT NULL DEFAULT 'open',    -- open | done | slipped | dropped | moved
  reason TEXT, reason_note TEXT, linked_entries TEXT NOT NULL DEFAULT '[]',
  planned_at TEXT NOT NULL, resolved_at TEXT,
  created_seq INTEGER NOT NULL, updated_seq INTEGER NOT NULL
);
CREATE TABLE presence_spans (
  id INTEGER PRIMARY KEY, day TEXT NOT NULL,
  start_at TEXT NOT NULL, end_at TEXT NOT NULL,
  source TEXT NOT NULL                    -- input | wake | unlock | powerlog | manual | collected
);
CREATE TABLE genai_sessions (
  session_id TEXT PRIMARY KEY, tool TEXT NOT NULL, day TEXT NOT NULL,
  started_at TEXT, ended_at TEXT, end_reason TEXT, project_alias TEXT,
  models TEXT NOT NULL DEFAULT '[]', turns INTEGER
);
CREATE TABLE genai_usage (
  day TEXT NOT NULL, tool TEXT NOT NULL, model TEXT NOT NULL DEFAULT '*', source TEXT NOT NULL,
  sessions INTEGER, requests INTEGER,
  tokens_in INTEGER, tokens_out INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
  cost_micros INTEGER,
  PRIMARY KEY (day, tool, model, source)
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

"""#
}
