#!/bin/bash
# Read-only schema + content dump for Control4 Director SQLite DBs.
# Usage:
#   bash analyze_db.sh [path-to-db-or-dir]
# If no arg, searches better_composer/ and the scratchpad for *.db.
#
# Safe: opens every DB read-only + immutable (never writes, never takes a lock),
# so it will not disturb the files or need the -wal/-shm sidecars.

set -uo pipefail
SQLITE="$(command -v sqlite3)"
REPO="$(cd "$(dirname "$0")" && pwd)"
SCRATCH="/private/tmp/claude-501/-Users-davewoychek-Library-CloudStorage-OneDrive-Personal-Documents-GitHub-Control4/63e3b431-a831-4b27-824e-85f9ab2ce8f5/scratchpad"

# --- locate DBs ---------------------------------------------------------------
ARG="${1:-}"
CAND=()
if [[ -n "$ARG" && -f "$ARG" ]]; then
  CAND=("$ARG")
elif [[ -n "$ARG" && -d "$ARG" ]]; then
  while IFS= read -r f; do CAND+=("$f"); done < <(find "$ARG" -maxdepth 3 \( -name '*.db' -o -name '*.c4p' \) 2>/dev/null)
else
  while IFS= read -r f; do CAND+=("$f"); done < <(find "$REPO" "$SCRATCH" -maxdepth 3 \( -name '*.db' -o -name '*.c4p' \) 2>/dev/null)
fi

if [[ ${#CAND[@]} -eq 0 ]]; then
  echo "No .db or .c4p files found. Drop project.db or your project .c4p into:"
  echo "  $REPO"
  echo "  or pass a path:  bash analyze_db.sh /path/to/project.c4p"
  exit 1
fi

# Resolve candidates to actual SQLite files. A .c4p may be raw SQLite OR a zip
# containing the project DB(s); unpack zips into a temp dir and use what's inside.
EXTRACT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/c4p_extract.XXXXXX")"
trap 'rm -rf "$EXTRACT_ROOT"' EXIT
DBS=()
for c in "${CAND[@]}"; do
  magic="$(head -c 16 "$c" | LC_ALL=C tr -cd '[:print:]')"
  if [[ "$magic" == SQLite* ]]; then
    DBS+=("$c")
  elif head -c 2 "$c" | grep -q 'PK'; then
    echo ">> $c looks like a zip (.c4p archive) — extracting..."
    d="$EXTRACT_ROOT/$(basename "$c").d"; mkdir -p "$d"
    if unzip -oq "$c" -d "$d" 2>/dev/null; then
      found=0
      while IFS= read -r inner; do
        if head -c 16 "$inner" | LC_ALL=C tr -cd '[:print:]' | grep -q '^SQLite'; then
          echo "     found DB: ${inner#$d/}"; DBS+=("$inner"); found=1
        fi
      done < <(find "$d" -type f 2>/dev/null)
      [[ $found -eq 0 ]] && echo "     !! no SQLite DB inside; contents:" && find "$d" -type f | sed 's/^/       /'
    else
      echo "     !! could not unzip $c"
    fi
  else
    echo ">> $c is neither SQLite nor zip (magic: $(head -c 8 "$c" | xxd -p)); skipping"
  fi
done

if [[ ${#DBS[@]} -eq 0 ]]; then
  echo "No usable SQLite databases resolved from the candidate files."
  exit 1
fi

# read-only + immutable URI (no locking, no sidecar files needed)
roq() { # roq <dbfile> <sql>
  "$SQLITE" "file:${1}?immutable=1" "$2" 2>&1
}

for DB in "${DBS[@]}"; do
  echo "################################################################################"
  echo "# DB: $DB"
  echo "#     size: $(ls -lh "$DB" | awk '{print $5}')   sqlite: $("$SQLITE" --version | awk '{print $1}')"
  echo "################################################################################"

  echo; echo "===== TABLES + ROW COUNTS ====="
  tables=$(roq "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
  if [[ -z "$tables" || "$tables" == *"Error"* || "$tables" == *"malformed"* ]]; then
    echo "!! Could not read schema: $tables"
    echo "!! If the DB was copied from a live controller, also copy its -wal and -shm"
    echo "!! sidecars, OR run 'VACUUM INTO' on the controller for a clean snapshot."
    continue
  fi
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    c=$(roq "$DB" "SELECT count(*) FROM \"$t\";")
    printf "  %-40s %s rows\n" "$t" "$c"
  done <<< "$tables"

  echo; echo "===== FULL SCHEMA (tables, indexes, views, triggers) ====="
  roq "$DB" ".schema" 2>/dev/null || roq "$DB" "SELECT sql FROM sqlite_master WHERE sql NOT NULL ORDER BY type,name;"

  echo; echo "===== SAMPLE ROWS from tables of interest ====="
  # heuristic: anything about devices, bindings, programming/code, rooms, variables, agents
  interest=$(echo "$tables" | grep -iE 'device|bind|item|code|program|event|room|proj|var|agent|command|connect' )
  if [[ -z "$interest" ]]; then interest="$tables"; fi
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    echo; echo "----- $t (first 8 rows) -----"
    printf '.mode line\n.headers on\nSELECT * FROM "%s" LIMIT 8;\n' "$t" \
      | "$SQLITE" "file:${DB}?immutable=1" 2>&1
  done <<< "$interest"
  echo
done
