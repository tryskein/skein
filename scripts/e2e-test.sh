#!/usr/bin/env bash
#
# e2e-test.sh — the e2e level (sk-442) in one command: bring up a throwaway
# LIVE stack (skein-frontend nginx → skein-web → skein-api + Postgres, Redis,
# NATS, Garage), run the Playwright group `e2e` against it from a container
# on the same network, tear everything down (volumes included). Always
# cleans up — on success, on failure, on Ctrl-C — via an EXIT trap.
#
# Usage:
#   ./scripts/e2e-test.sh                         # build images from ./projects/*
#   ./scripts/e2e-test.sh -- -g 'blocker'         # Playwright flags after `--`
#   E2E_REGISTRY=<registry host>/<org>/skein E2E_API_TAG=… E2E_WEB_TAG=… E2E_FRONTEND_TAG=… \
#     ./scripts/e2e-test.sh --images registry     # published images by tag
#
# Images:
#   build    (default) — docker-compose.e2e.build.yml builds all three from
#            the working trees. This is what the local level is for: it
#            tests your change, and a deliberate mutation of the frontend
#            reaches the browser.
#   registry — pulls $E2E_REGISTRY/skein-{api,web,frontend}:<tag>, the same
#            published images; you must be logged in to that
#            registry (`docker login`). No defaults for the registry or tags.
#
# The exit code is the Playwright harness's (projects/skein-frontend
# scripts/browser-test.mjs): 0 only when group e2e executed ≥1 test and all
# passed; zero executed is red there. On top, this script reds when the
# harness's own success line is missing or reports zero.
#
# Isolation — the pattern of scripts/integration-test.sh (sk-482): own
# compose project `skein-e2e-<run id>`, own network on the first free
# 10.212.N.0/24, own anonymous volumes; `down -v` touches only this run.
# No host port is published, so a dev stack on :8080 is neither touched nor
# in the way.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGES=build
PASSTHROUGH=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --images)
      [ "$#" -ge 2 ] || { echo "✗ --images needs a value: build | registry"; exit 2; }
      IMAGES="$2"; shift 2 ;;
    --images=*) IMAGES="${1#--images=}"; shift ;;
    --) shift; PASSTHROUGH=("$@"); break ;;
    *) echo "✗ unknown argument $1 — usage: $0 [--images build|registry] [-- <playwright flags>]"; exit 2 ;;
  esac
done

TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'
COMPOSE_FILES=(-f docker-compose.e2e.yml)
case "$IMAGES" in
  build)
    # Fixed tags, not per run: a per-run tag would leave one image per run
    # behind. Two parallel build-mode runs share these tags, so each builds
    # the same working tree — run them from different trees and the later
    # build wins for both.
    export E2E_API_IMAGE=skein-e2e-api:worktree
    export E2E_WEB_IMAGE=skein-e2e-web:worktree
    export E2E_FRONTEND_IMAGE=skein-e2e-frontend:worktree
    COMPOSE_FILES+=(-f docker-compose.e2e.build.yml)
    ;;
  registry)
    : "${E2E_REGISTRY:?E2E_REGISTRY is not set (e.g. <registry host>/<org>/skein) - registry mode has no default}"
    for v in E2E_API_TAG E2E_WEB_TAG E2E_FRONTEND_TAG; do
      val="${!v:-}"
      if ! [[ "$val" =~ $TAG_RE ]]; then
        echo "✗ $v=${val:-<unset>} — registry mode needs a release tag X.Y.Z or X.Y.Z-rc.N"
        exit 2
      fi
    done
    export E2E_API_IMAGE="$E2E_REGISTRY/skein-api:$E2E_API_TAG"
    export E2E_WEB_IMAGE="$E2E_REGISTRY/skein-web:$E2E_WEB_TAG"
    export E2E_FRONTEND_IMAGE="$E2E_REGISTRY/skein-frontend:$E2E_FRONTEND_TAG"
    ;;
  *) echo "✗ --images $IMAGES — expected build or registry"; exit 2 ;;
esac

RUN_ID="$(date -u +%Y%m%d%H%M%S)-$$"
PROJECT="skein-e2e-$RUN_ID"
export SKEIN_E2E_NETWORK="$PROJECT-net"
COMPOSE=(docker compose "${COMPOSE_FILES[@]}" -p "$PROJECT")
STACK=(postgres redis nats garage skein-api skein-web skein-frontend)
LOG_DIR="$ROOT/projects/skein-frontend/reports/e2e"

TEST_LOG=""
NETWORK_CREATED=""
RUNNER_CID=""

cleanup() {
  rc=$?
  # The trap runs under the script's `set -e`: one failing step here (say,
  # a log directory that cannot be created) would end the trap before
  # `down -v` and leave the whole stack running. Nothing below may abort
  # the teardown.
  set +e
  if [ -n "$RUNNER_CID" ]; then docker rm -f "$RUNNER_CID" >/dev/null 2>&1; fi
  if [ "$rc" -ne 0 ] && [ -n "$NETWORK_CREATED" ]; then
    # Evidence first: a red run without the stack's side of the story is
    # a guessing game. Full logs to a file, the tail of the app services here.
    if mkdir -p "$LOG_DIR" 2>/dev/null && [ -w "$LOG_DIR" ]; then
      STACK_LOG="$LOG_DIR/stack-$RUN_ID.log"
    else
      STACK_LOG="$(mktemp "${TMPDIR:-/tmp}/skein-e2e-stack-$RUN_ID.XXXXXX.log")"
      echo "⚠ $LOG_DIR is not writable — the stack logs go to $STACK_LOG"
    fi
    "${COMPOSE[@]}" logs --no-color "${STACK[@]}" > "$STACK_LOG" 2>&1
    echo "▶ stack logs: $STACK_LOG — tail:"
    "${COMPOSE[@]}" logs --no-color --tail 30 skein-api skein-web skein-frontend 2>&1
  fi
  if [ -n "$TEST_LOG" ]; then rm -f "$TEST_LOG"; fi
  echo "▶ tearing down $PROJECT (down -v)…"
  "${COMPOSE[@]}" --profile runner down -v --remove-orphans >/dev/null 2>&1
  if [ -n "$NETWORK_CREATED" ]; then
    docker network rm "$SKEIN_E2E_NETWORK" >/dev/null 2>&1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "▶ run $RUN_ID (compose project $PROJECT, images: $IMAGES)"

# Own network, created here and EXTERNAL in compose — see the note at the
# bottom of docker-compose.test.yml (sk-482): subnets outside 192.168/16 and
# 172.16/12, the daemon arbitrates races atomically. 10.212.N — next to the
# integration harness's 10.211.N, never the same block.
echo "▶ network $SKEIN_E2E_NETWORK"
NET_ERR=""
for n in $(seq 0 255); do
  if NET_ERR="$(docker network create --driver bridge --subnet "10.212.$n.0/24" \
      "$SKEIN_E2E_NETWORK" 2>&1 >/dev/null)"; then
    NETWORK_CREATED=1
    echo "  subnet 10.212.$n.0/24"
    break
  fi
done
if [ -z "$NETWORK_CREATED" ]; then
  echo "✗ could not create $SKEIN_E2E_NETWORK on any 10.212.N.0/24 — last error: $NET_ERR"
  exit 1
fi

T0=$SECONDS
if [ "$IMAGES" = build ]; then
  echo "▶ build images from the working trees"
  "${COMPOSE[@]}" build skein-api skein-web skein-frontend
else
  echo "▶ pull images"
  "${COMPOSE[@]}" pull "${STACK[@]}"
fi
T_IMAGES=$((SECONDS - T0))

# `--wait` returns when every service with a healthcheck is healthy (and
# fails if one turns unhealthy or exits) — readiness by probe, not by sleep.
echo "▶ stack up (--wait on healthchecks)"
T1=$SECONDS
"${COMPOSE[@]}" up -d --no-build --wait --wait-timeout 300 "${STACK[@]}"
T_UP=$((SECONDS - T1))
echo "▶ stack healthy in ${T_UP}s (images: ${T_IMAGES}s)"

echo "▶ playwright (group e2e)"
# Detached + `docker logs` instead of `run --rm -T`: compose run drops the
# stdout of a command that outlives the attach (see integration-test.sh).
RUNNER_ARGS=(node scripts/browser-test.mjs e2e)
if [ "${#PASSTHROUGH[@]}" -gt 0 ]; then RUNNER_ARGS+=(-- "${PASSTHROUGH[@]}"); fi
# The runner writes reports/ and traces into the bind-mounted frontend tree.
# As the image's root it would leave root-owned files there that the caller
# can neither remove nor overwrite (the next red run could not even write its
# stack log). So it runs as the caller, with a HOME it can write (npm's cache
# and logs). Not under rootless Docker or Podman: there the container's root
# already IS the caller, and any other uid maps to a subordinate one that may
# not write the caller's tree.
RUNNER_USER=()
if ! docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'rootless'; then
  RUNNER_USER=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
fi
RUNNER_CID="$("${COMPOSE[@]}" --profile runner run -d --no-deps ${RUNNER_USER[@]+"${RUNNER_USER[@]}"} e2e-runner "${RUNNER_ARGS[@]}" | tail -n1)"

TEST_LOG="$(mktemp)"
docker logs -f "$RUNNER_CID" 2>&1 | tee "$TEST_LOG"
TEST_RC="$(docker wait "$RUNNER_CID")"
T_TOTAL=$((SECONDS - T0))

if [ "$TEST_RC" -ne 0 ]; then
  echo "✗ e2e FAILED (harness exit $TEST_RC) — see output above"
  exit "$TEST_RC"
fi

# "Green ≠ executed", second line of defence: the harness already reds a
# zero, but exit 0 from a runner that ran something else must not pass.
EXECUTED="$(sed -n 's/.*✓ browser tests passed (groups: e2e; executed: \([0-9][0-9]*\),.*/\1/p' "$TEST_LOG" | tail -n1)"
if [ -z "$EXECUTED" ] || [ "$EXECUTED" -lt 1 ]; then
  echo "✗ e2e FAILED: runner exited 0 but did not report executed e2e tests (got: ${EXECUTED:-nothing})"
  exit 1
fi

echo "✓ e2e passed (executed: $EXECUTED; images ${T_IMAGES}s, stack up ${T_UP}s, total ${T_TOTAL}s)"
