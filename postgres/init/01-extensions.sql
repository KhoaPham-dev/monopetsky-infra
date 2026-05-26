-- Enable extensions required by MonoPetSky backend migrations.
-- Runs only on first DB initialization (empty data dir).
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "unaccent";  -- diacritic-insensitive product search
