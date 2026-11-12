-- Schema `play`: cross-game play sessions and events. Applied by remote.sh provision_db as the superuser,
-- after the per-app roles exist. Idempotent. Each game writes its own rows (row-level security on `writer`);
-- Nova's game reporter reads everything through the read-only LAN role `play_reader`.
--
-- A session is FINISHED when ended_at is set. A session whose last_seen_at is older than the reader's idle
-- threshold and ended_at is NULL was abandoned (app quit, tab closed). Otherwise it is in progress.
DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='play_owner') THEN CREATE ROLE play_owner NOLOGIN; END IF; END$$;
ALTER ROLE play_owner WITH NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;

CREATE SCHEMA IF NOT EXISTS play AUTHORIZATION play_owner;
REVOKE ALL ON SCHEMA play FROM PUBLIC;

CREATE TABLE IF NOT EXISTS play.sessions (
  id           uuid        PRIMARY KEY,
  game         text        NOT NULL CHECK (game ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  client       text        NOT NULL CHECK (client ~ '^[a-z0-9][a-z0-9_.-]{0,31}$'),
  player       text        NOT NULL CHECK (char_length(player) BETWEEN 1 AND 64),
  writer       name        NOT NULL DEFAULT current_user,
  started_at   timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  ended_at     timestamptz,
  outcome      text        CHECK (char_length(outcome) <= 64),
  score        double precision CHECK (score IS NULL OR score BETWEEN -1e12 AND 1e12),
  actions      integer     NOT NULL DEFAULT 0 CHECK (actions BETWEEN 0 AND 10000000),
  summary      jsonb       NOT NULL DEFAULT '{}'::jsonb
               CHECK (jsonb_typeof(summary) = 'object' AND octet_length(summary::text) <= 65536),
  created_at   timestamptz NOT NULL DEFAULT now(),
  CHECK (last_seen_at >= started_at),
  CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE INDEX IF NOT EXISTS sessions_ended_idx ON play.sessions (ended_at);
CREATE INDEX IF NOT EXISTS sessions_open_seen_idx ON play.sessions (last_seen_at) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS sessions_game_player_idx ON play.sessions (game, player, started_at DESC);

CREATE TABLE IF NOT EXISTS play.events (
  session_id uuid        NOT NULL REFERENCES play.sessions (id) ON DELETE CASCADE,
  seq        integer     NOT NULL CHECK (seq BETWEEN 0 AND 10000000),
  ts         timestamptz NOT NULL,
  kind       text        NOT NULL CHECK (kind ~ '^[a-z0-9][a-z0-9_.-]{0,47}$'),
  detail     jsonb       NOT NULL DEFAULT '{}'::jsonb
             CHECK (jsonb_typeof(detail) = 'object' AND octet_length(detail::text) <= 4096),
  writer     name        NOT NULL DEFAULT current_user,
  PRIMARY KEY (session_id, seq)
);

ALTER TABLE play.sessions OWNER TO play_owner;
ALTER TABLE play.events OWNER TO play_owner;
ALTER TABLE play.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE play.events ENABLE ROW LEVEL SECURITY;

-- Writers: each game's DML role, plus blompie_mac, stuntdriver_mac and gtnwchess_mac (the standalone Blompie, Stunt Driver and GTNW Chess Mac apps; GTNW Chess writes game 'gtnwchess': play rows only, no schema). Insert and update only their own rows; no DELETE (history is kept).
GRANT USAGE ON SCHEMA play TO gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac;
REVOKE ALL ON play.sessions, play.events FROM gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac;
GRANT SELECT, INSERT, UPDATE ON play.sessions, play.events TO gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac;
DROP POLICY IF EXISTS own_rows ON play.sessions;
CREATE POLICY own_rows ON play.sessions FOR ALL TO gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac
  USING (writer = current_user) WITH CHECK (writer = current_user);
DROP POLICY IF EXISTS own_rows ON play.events;
CREATE POLICY own_rows ON play.events FOR ALL TO gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac
  USING (writer = current_user) WITH CHECK (writer = current_user);

-- Review consent: whether a site account wants to be named (by display_name) in Nova's reviews of a game.
-- Written only by games-saves (role saves) for the signed-in account; read by play_reader. Default is NOT named.
CREATE TABLE IF NOT EXISTS play.consent (
  account         text        NOT NULL CHECK (account ~ '^[a-z0-9_]{3,24}$'),
  game            text        NOT NULL CHECK (game ~ '^[a-z0-9][a-z0-9_-]{0,31}$'),
  name_in_reviews boolean     NOT NULL DEFAULT false,
  display_name    text        CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 40),
  writer          name        NOT NULL DEFAULT current_user,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account, game)
);
ALTER TABLE play.consent OWNER TO play_owner;
ALTER TABLE play.consent ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON play.consent FROM PUBLIC, gtnw, cartest, casting, blompie, mush, saves, blompie_mac, stuntdriver_mac, gtnwchess_mac;
GRANT SELECT, INSERT, UPDATE ON play.consent TO saves;
DROP POLICY IF EXISTS own_rows ON play.consent;
CREATE POLICY own_rows ON play.consent FOR ALL TO saves USING (writer = current_user) WITH CHECK (writer = current_user);

-- Reader: Nova's game reporter. Read-only, play schema only.
DO $$BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='play_reader') THEN CREATE ROLE play_reader LOGIN; END IF; END$$;
GRANT CONNECT ON DATABASE games TO play_reader;
GRANT USAGE ON SCHEMA play TO play_reader;
REVOKE ALL ON play.sessions, play.events FROM play_reader;
GRANT SELECT ON play.sessions, play.events TO play_reader;
DROP POLICY IF EXISTS read_all ON play.sessions;
CREATE POLICY read_all ON play.sessions FOR SELECT TO play_reader USING (true);
DROP POLICY IF EXISTS read_all ON play.events;
CREATE POLICY read_all ON play.events FOR SELECT TO play_reader USING (true);
REVOKE ALL ON play.consent FROM play_reader;
GRANT SELECT ON play.consent TO play_reader;
DROP POLICY IF EXISTS read_all ON play.consent;
CREATE POLICY read_all ON play.consent FOR SELECT TO play_reader USING (true);
