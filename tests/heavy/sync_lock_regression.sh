#!/usr/bin/env bash
# tests/heavy/sync_lock_regression.sh
# Sync writer-lock concurrency regression test.
#
# Holds the real source-scoped writer lock while N-1 sync contenders run; asserts:
#   1. The holder excludes every contender on `gbrain-sync:default`.
#   2. N-1 lose with "Another sync is in progress" — they fail FAST, they don't queue.
#      (Per src/commands/sync.ts:377 — performSync uses `tryAcquireDbLock`, no wait.)
#   3. A sync succeeds after release and leaves zero source-lock rows.
#
# Why the test matters: the eng-review-flagged v1 plan was wrong — the original
# plan asserted the wrong semantics ("N-1 wait then complete one at a time")
# and snapshot the wrong table (`pg_locks` instead of `gbrain_cycle_locks`).
# Both reviewers caught it; this script tests the actual contract.
#
# Postgres-only (no DATABASE_URL = graceful skip with hint).

set -euo pipefail

cd "$(dirname "$0")/../.."

if [ -z "${DATABASE_URL:-}" ]; then
  echo "[sync_lock_regression] DATABASE_URL not set; skipping (informational)." >&2
  echo "  Local: docker run -d --name gbrain-test-pg -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=gbrain_test -p 5434:5432 pgvector/pgvector:pg16" >&2
  echo "  Then: export DATABASE_URL=postgresql://postgres:postgres@localhost:5434/gbrain_test" >&2
  exit 0
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "[sync_lock_regression] psql required. Install postgresql-client." >&2
  exit 2
fi

TS=$(date -u +%Y%m%d-%H%M%SZ)
# Isolate from the developer's real ~/.gbrain so writing sync.repo_path doesn't
# clobber their config. Restored on exit.
TMP_GBRAIN_HOME=$(mktemp -d -t gbrain-sync-lock-home-XXXXXX)
export GBRAIN_HOME="$TMP_GBRAIN_HOME"
LOG_DIR="$GBRAIN_HOME/audit"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/heavy-sync_lock_regression-$TS.log"
# Surface the log path so it survives the EXIT trap that nukes GBRAIN_HOME.
SURFACE_LOG="${TMPDIR:-/tmp}/heavy-sync_lock_regression-$TS.log"
trap 'cp -f "$LOG" "$SURFACE_LOG" 2>/dev/null || true; rm -rf "$TMP_GBRAIN_HOME"' EXIT

NUM_PARALLEL="${NUM_PARALLEL:-4}"
echo "[sync_lock_regression] using configured test database"
echo "[sync_lock_regression] log=$LOG"
echo "[sync_lock_regression] spawning $NUM_PARALLEL parallel sync processes..."

# Step 1: ensure schema is up-to-date by running doctor once. Doctor exits
# non-zero when ANY check warns (e.g. missing embedding provider on a fresh
# CI runner) so we ignore its exit status — the schema-migration side effect
# is what we want here, and the migration runs regardless of check verdicts.
echo "[sync_lock_regression] init schema via gbrain doctor..." | tee -a "$LOG"
timeout 180s bun run src/cli.ts doctor --json > /dev/null 2>>"$LOG" || true

# Step 2: create a tiny brain dir + register it as sync.repo_path so each sync
# call has something legitimate to do.
BRAIN_DIR=$(mktemp -d -t gbrain-sync-lock-XXXXXX)
# Compose with the earlier GBRAIN_HOME-cleanup trap (NOT overwrite it).
trap 'cp -f "$LOG" "$SURFACE_LOG" 2>/dev/null || true; rm -rf "$BRAIN_DIR" "$TMP_GBRAIN_HOME"' EXIT

# Seed two markdown pages so sync has real (but trivial) work
mkdir -p "$BRAIN_DIR"
cat > "$BRAIN_DIR/page-a.md" <<'EOF'
---
title: Lock Test Page A
---
# Lock Test Page A
Trivial content for sync-lock-regression heavy test.
EOF
cat > "$BRAIN_DIR/page-b.md" <<'EOF'
---
title: Lock Test Page B
---
# Lock Test Page B
Trivial content for sync-lock-regression heavy test.
EOF

# git-init so sync's diff-walk has something to anchor (sync expects a git repo)
(cd "$BRAIN_DIR" && git init -q && git add . && git -c user.email=test@test -c user.name=test commit -q -m "seed" >/dev/null 2>&1) || true

# Tell gbrain to use this brain dir. v0.41 introduced the source registry
# (sources table) as the canonical "where do pages come from" surface;
# `sync.repo_path` is the legacy key and sync now reads the source row's
# `local_path` column. Update the default source's local_path directly via
# psql (mirrors how fm_wallclock.sh registers via the engine API — same
# semantics, lower process-spawn overhead).
psql "$DATABASE_URL" -c "INSERT INTO sources (id, name, local_path) VALUES ('default', 'default', '$BRAIN_DIR') ON CONFLICT (id) DO UPDATE SET local_path = EXCLUDED.local_path;" >>"$LOG" 2>&1
# Keep the legacy config key set too — some code paths still read it, and
# setting both is the belt-and-suspenders shape downstream callers expect.
bun run src/cli.ts config set sync.repo_path "$BRAIN_DIR" >/dev/null 2>&1 || true

# Step 3: exercise contention with a held lock, then verify a real sync can
# acquire it after release. Keep subprocess exits and the source-scoped leak
# check in one harness so every path gets bounded waits and cleanup.
bun run tests/heavy/_sync_lock_contention.ts "$BRAIN_DIR" 2>&1 | tee -a "$LOG"
