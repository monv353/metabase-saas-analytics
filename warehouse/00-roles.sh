#!/bin/sh
# Runs once, on the warehouse's first boot (postgres entrypoint runs /docker-entrypoint-initdb.d in name order).
# Creates a read-only login for Metabase. BI tools should never connect as the owner of the data.
set -eu

psql -v ON_ERROR_STOP=1 -v reader_pw="$READER_PASSWORD" \
     --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
CREATE ROLE metabase_reader LOGIN PASSWORD :'reader_pw';
GRANT CONNECT ON DATABASE saas TO metabase_reader;
GRANT USAGE ON SCHEMA public TO metabase_reader;
-- Tables/views are created by 01-schema.sql afterwards, so grant on future objects too.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO metabase_reader;
-- Guard rail: a runaway dashboard query gets cancelled instead of hogging the warehouse.
ALTER ROLE metabase_reader SET statement_timeout = '60s';
SQL
