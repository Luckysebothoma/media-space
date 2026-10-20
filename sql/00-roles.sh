#!/bin/bash
# Runs once on an EMPTY postgres_data volume. Passwords come from Swarm secrets.
set -e
for pair in hms:hms_pass ffmpeg:ffmpeg_pass media:media_pass; do
  u="${pair%%:*}"; pw="$(cat "/run/secrets/${pair##*:}")"
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v pw="$pw" <<SQL
CREATE ROLE ${u} LOGIN PASSWORD :'pw';
CREATE DATABASE ${u} OWNER ${u};
ALTER DATABASE ${u} SET timezone TO 'Africa/Johannesburg';
SQL
done
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d hms -f /docker-entrypoint-initdb.d/registry/remotion_registry.sql
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d hms -c "GRANT ALL ON ALL TABLES IN SCHEMA public TO hms;"
