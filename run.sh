#!/usr/bin/env bash
# Crée la base, charge le schéma et les données, puis lance les analyses et les tests.
# Usage : ./run.sh            (base locale "ged_demo")
#         DB=autre_base ./run.sh
set -euo pipefail
cd "$(dirname "$0")"
DB="${DB:-ged_demo}"

dropdb --if-exists "$DB"
createdb "$DB"

for f in sql/01_schema.sql sql/02_triggers.sql sql/03_seed.sql sql/04_views.sql; do
  echo "→ $f"
  psql -q -X -v ON_ERROR_STOP=1 -d "$DB" -f "$f" > /dev/null
done

echo "→ sql/05_analyses.sql"
psql -X -v ON_ERROR_STOP=1 -d "$DB" -f sql/05_analyses.sql

echo "→ sql/06_tests.sql"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f sql/06_tests.sql
