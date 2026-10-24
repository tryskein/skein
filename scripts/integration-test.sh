#!/usr/bin/env bash
#
# integration-test.sh — spin up a throwaway Postgres, migrate it, run the
# skein-api Go integration tests against it, then tear the whole thing down
# (volumes included). Always cleans up — on success, on test failure, and
# on Ctrl-C — via an EXIT trap.
#
# Usage:
#   ./scripts/integration-test.sh                      # full suite (go test -p 1 ./...)
#   ./scripts/integration-test.sh ./internal/users/... # scope to package(s)
#   ./scripts/integration-test.sh -run TestListDirectory ./internal/handler/...
#
# Anything you pass is forwarded to `go test` (replacing the default
# `-p 1 ./...`). The exit code is the test exit code — except that a run in
# which go test exits 0 but zero tests executed is red (exit 1); see the
# zero-tests guard at the end.
#
# Isolated from the dev stack AND from any other run of this script: every
# run gets its own compose project `skein-itest-<run id>`, its own network
# and its own volumes, so its `down -v` can delete neither dev data nor the
# database of a run going on in parallel (sk-482).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Per-run identity (sk-482). The project name used to be the fixed
# `skein-itest`, and so were the network name and its subnet. Two runs at
# once — two agents, or an agent and a human — then shared one Postgres, and
# whichever finished first ran `down -v` under the other: the survivor went
# red on a vanished database, which reads exactly like a code defect. The
# run id is timestamp + PID: unique on this host, and readable in
# `docker compose ls` if a killed run ever leaves something behind.
RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$"
PROJECT="skein-itest-$RUN_ID"
export SKEIN_ITEST_NETWORK="$PROJECT-net"

COMPOSE=(docker compose -f docker-compose.test.yml -p "$PROJECT")

TEST_LOG=""
NETWORK_CREATED=""

# Tears down ONLY this run's project and network — never a sibling run's.
cleanup() {
  if [ -n "$TEST_LOG" ]; then rm -f "$TEST_LOG"; fi
  echo "▶ tearing down $PROJECT (down -v)…"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  if [ -n "$NETWORK_CREATED" ]; then
    docker network rm "$SKEIN_ITEST_NETWORK" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "▶ run $RUN_ID (compose project $PROJECT)"

# External caches survive `down -v` (see compose) — create them once,
# idempotently, so the first run can populate and later runs reuse them.
docker volume create skein-itest-gomod   >/dev/null
docker volume create skein-itest-gobuild >/dev/null

# The network is created here, not by compose — see the note at the bottom
# of docker-compose.test.yml. Subnets are 10.211.N.0/24: outside
# 192.168.0.0/16 (home-router LAN) and outside 172.16/12 (where other stacks
# live on these hosts). No pre-check of "is N free": the daemon refuses an
# overlapping subnet atomically, so two runs racing for the same N cannot
# both win — the loser simply tries N+1.
echo "▶ network $SKEIN_ITEST_NETWORK"
NET_ERR=""
for n in $(seq 0 255); do
  if NET_ERR="$(docker network create --driver bridge --subnet "10.211.$n.0/24" \
      "$SKEIN_ITEST_NETWORK" 2>&1 >/dev/null)"; then
    NETWORK_CREATED=1
    echo "  subnet 10.211.$n.0/24"
    break
  fi
done
if [ -z "$NETWORK_CREATED" ]; then
  echo "✗ could not create $SKEIN_ITEST_NETWORK on any 10.211.N.0/24 — last error: $NET_ERR"
  exit 1
fi

echo "▶ postgres up (build + healthcheck)"
"${COMPOSE[@]}" up -d --build postgres

# The Go runner image (golang + python3, projects/skein-api/infra/test-runner): built here so a
# Dockerfile change is picked up; unchanged, it is a cache hit.
echo "▶ test-runner image (build)"
"${COMPOSE[@]}" build -q test-runner

echo "▶ migrate (golang-migrate up)"
"${COMPOSE[@]}" run --rm -T migrate

echo "▶ go test"
# Caller args (test flags / packages) replace the default `-p 1 ./...`.
#
# They are forwarded as SEPARATE ARGUMENTS, never re-joined into a string.
# The previous shape built `TEST_ARGS="$*"` and ran `sh -c "go test $TEST_ARGS"`,
# which loses the caller's quoting before `sh` ever sees it:
#
#   ./scripts/integration-test.sh -p 1 -run 'A|B' ./pkg/...
#     → sh -c "go test -p 1 -run A|B ./pkg/..."
#     → the inner shell reads `|` as a PIPE
#     → `sh: B: not found`, `no Go files in /src`, exit 127
#
# and that exit 127 is printed by this script as an ordinary red run, so a
# quoting mistake is indistinguishable from a failing test. Observed while
# fixing review findings.
if [ "$#" -eq 0 ]; then
  set -- -p 1 ./...
fi

# `-count=1` is FORCED, not defaulted — the caller cannot opt out.
#
# Every test this harness exists for is DB-backed, and go's test cache does
# not know that. Its key is the test binary plus flags, env and the files the
# test read — the contents of an external Postgres are none of those. So a
# DB-backed package that passed once keeps replaying `ok … (cached)` on every
# later run, on a database that `down -v` has since destroyed and recreated
# with different data. Nothing about that is visible in the exit code.
#
# Observed on this repo, same tree, one run apart:
#
#   with -count=1 : FAIL skein-api/internal/outbox   → ✗ FAILED, exit 1
#   without       : ok   skein-api/internal/outbox   (cached) → ✓ passed, exit 0
#                   25 of 28 packages served from cache
#
# The failing package was reported as passing from a cache entry made when
# the fixtures were smaller. A harness whose green means "nothing was run"
# is precisely the "green ≠ actually ran" failure the engineering guidelines
# forbid, so the flag is appended after the caller's args and wins.
set -- "$@" -count=1

# `-v` is FORCED too, for the zero-tests guard below: without it `go test`
# prints one `ok <pkg>` line per package and nothing per test, and an `ok`
# line is printed just the same for a package whose every test called
# t.Skip, or for `-run` matching nothing (`ok … [no tests to run]`).
# Only the per-test `--- PASS:` lines of -v say that a test actually ran.
set -- "$@" -v

# Why detached + `docker logs` instead of the obvious `run --rm -T`:
# `docker compose run` (v5.1.1) DROPS the container's stdout whenever the
# command outlives the attach — reproducible in isolation:
#
#   compose run -T --no-deps test-runner sh -c "sleep 0; echo X"  → prints X
#   compose run -T --no-deps test-runner sh -c "sleep 3; echo X"  → prints nothing
#
# Any real test run is far slower than that threshold, so the old shape
# surfaced only the exit code and swallowed every line go test produced —
# including the failure that explains a red run, and including the `ok …` /
# `--- FAIL` lines you need to tell "test failed" apart from "did not
# compile". That silence is exactly the "green ≠ actually ran" trap the
# engineering guidelines warn about: a run that cannot show what it did.
#
# `docker logs` is not affected by that race, and `docker wait` returns the
# real exit status, so the script's documented contract (exit code == test
# exit code) is preserved. `-d` and `--rm` don't combine, hence the explicit
# rm; the EXIT trap's `down -v` would also sweep it.
#
# The runner refuses to start without TEST_DATABASE_URL: every DB-backed test
# t.Skip's without it, and a full-suite run would then still show PASS lines
# from the pure-logic tests — the zero-tests guard below cannot see that case.
TEST_CID="$("${COMPOSE[@]}" run -d test-runner sh -c '
  if [ -z "${TEST_DATABASE_URL:-}" ]; then
    echo "✗ TEST_DATABASE_URL is empty inside test-runner — every DB-backed test would t.Skip"
    exit 1
  fi
  exec go test "$@"' sh "$@" | tail -n1)"

# The stream is also kept in a file so the guard below can count it; the
# EXIT trap removes the file.
TEST_LOG="$(mktemp)"
docker logs -f "$TEST_CID" 2>&1 | tee "$TEST_LOG"
TEST_RC="$(docker wait "$TEST_CID")"
docker rm -f "$TEST_CID" >/dev/null 2>&1 || true

if [ "$TEST_RC" -ne 0 ]; then
  echo "✗ integration tests FAILED (go test exit $TEST_RC) — see output above"
  exit "$TEST_RC"
fi

# Zero-tests guard ("green ≠ executed"): exit 0 from go test is not proof
# that anything ran. A test counts as EXECUTED when it reached `--- PASS:`;
# a FAIL already made the run red above, a SKIP did not run. Only TOP-LEVEL
# tests are counted (the line starts at column 0; subtests are indented),
# so the number is comparable to the Test* functions in scope.
#
# Red when that count is 0 — every test skipped, `-run` matched nothing, or
# the scope has no tests at all. What it does NOT catch: a run where SOME
# tests skipped and others passed. Skips are reported for that reason, not
# enforced — plenty of tests skip legitimately (e.g. requireSerialPackages).
PASS_N="$(grep -c '^--- PASS: ' "$TEST_LOG" || true)"
SKIP_N="$(grep -c '^--- SKIP: ' "$TEST_LOG" || true)"

if [ "$PASS_N" -lt 1 ]; then
  echo "✗ integration tests FAILED: go test exited 0 but ZERO tests executed" \
       "(top-level --- PASS: 0, --- SKIP: $SKIP_N) — every test skipped, -run matched nothing, or the scope has no tests"
  exit 1
fi

echo "✓ integration tests passed (top-level tests executed: $PASS_N, skipped: $SKIP_N)"
