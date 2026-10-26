# Setting up a Skein development workspace — runbook for an AI agent

You are a coding agent. A person handed you this file to set up a working
Skein development workspace on their machine. Follow it top to bottom. Talk to
the person where the steps say so; do everything else yourself.

Skein lives in four repositories under https://github.com/tryskein:

| Repository | What it is |
|---|---|
| https://github.com/tryskein/skein | the top of the workspace: README, CLAUDE.md, LICENSE, CONTRIBUTING.md, ARCHITECTURE.md, RELEASING.md, compose files, test harnesses |
| https://github.com/tryskein/skein-api | backend (Go): REST API and MCP server |
| https://github.com/tryskein/skein-web | BFF (.NET): sessions, proxy, live updates |
| https://github.com/tryskein/skein-frontend | web UI (React, served by nginx) |

The finished workspace must look like this (the reference tree):

```
skein/
├── README.md, CLAUDE.md, LICENSE, CONTRIBUTING.md, ARCHITECTURE.md, RELEASING.md, …
├── docker-compose.*.yml
├── scripts/
└── projects/
    ├── skein-api/
    ├── skein-web/
    └── skein-frontend/
```

`projects/` is ignored by the `skein` repository's git. Each of the three
directories inside it is its own git repository. All three are always cloned:
the compose files and harnesses reference `./projects/skein-api`,
`./projects/skein-web` and `./projects/skein-frontend`.

---

## 1. Ground rules

- **Do not invent.** Every command, version, port and credential in this
  runbook comes from the repositories. If something you see contradicts this
  file, the repository wins — tell the person what differs.
- **Ask before installing anything system-wide** (a toolchain, Docker, a
  package manager). Say what you want to install, the version, and why.
  Installing project dependencies inside the cloned repositories
  (`npm ci`, `go mod download`, `dotnet restore`) needs no extra permission.
- **Do not push anywhere.** Do not create branches on remotes, open pull
  requests, or change repository settings. Setting up remotes locally is fine.
- **Do not delete what you did not create** — volumes, containers, networks,
  directories. Never run `docker system prune` or `docker volume prune`: on a
  shared machine they destroy other people's caches and data.
- Report what you did and what failed, with the real output. A step that did
  not run is "not run", not "passed".

---

## 2. Check the machine

Run the checks and collect the results into one short report for the person.

| Tool | Check | Needed for | Version the repositories use |
|---|---|---|---|
| git | `git --version` | everything | any recent |
| Docker Engine | `docker version` | local stack, integration, e2e | — |
| Docker Compose v2 plugin | `docker compose version` | local stack, harnesses (they call `docker compose`, and the e2e harness uses `up --wait`) | v2, 2.23.1 or newer (the local stack uses inline `configs`) |
| Go | `go version` | skein-api unit tests; `check-theme-mirror.sh` verifies goldens with it when present | `go 1.26.1` in `skein-api/src/go.mod`; images build on `golang:1.26-alpine` |
| .NET SDK | `dotnet --list-sdks` | skein-web unit tests | `net10.0` in `skein-web/src/SkeinWeb.csproj`; image builds on `mcr.microsoft.com/dotnet/sdk:10.0-alpine` |
| Node.js + npm | `node --version`, `npm --version` | skein-frontend unit tests, `check-theme-mirror.sh` | no `.nvmrc` or `engines` field; the Dockerfile and the dev container use `node:22-alpine`, so use Node 22 |
| Python 3 | `python3 --version` | optional: skein-api's Python runner tests; some Go tests skip without it | stdlib only |
| Disk | `df -h .` | images, Go/npm caches, volumes | the repositories state no figure — report free space to the person |

The local stack itself only needs git and Docker: the published images need no
toolchain, and with the build overlay the three services are built inside
containers. The language toolchains are needed to run unit tests on the host.

If something is missing or older than listed: tell the person, propose how to
install it, and **wait for a yes** before installing.

Also check that the ports the local stack publishes are free:
**8080** (UI), **3900** (Garage S3 API), **5173** (Vite dev server). For example `ss -ltn` or `lsof -i :8080`.

---

## 3. Ask the person

Ask exactly one question:

> **Will you contribute changes back to Skein (open pull requests)?**

- **Yes.** You cannot push to `tryskein/*` directly, so a pull request comes
  from a fork. Ask which of the four repositories they expect to change, and
  ask them to fork those on GitHub (or, if they use the GitHub CLI and agree,
  `gh repo fork tryskein/<repo> --clone=false`). Ask for their GitHub user or
  organisation name. A forked repository is cloned from the fork, which becomes `origin`,
  with `upstream` pointing at `tryskein/<repo>`. A repository they do not fork
  is cloned from `tryskein` directly; they can fork it later and re-point
  `origin`.
- **No.** Clone all four from `tryskein`.

Then find out yourself — ask only if you cannot tell — whether you run inside
a devcontainer or any setup where the Docker daemon is not on the same
filesystem as you (Docker-in-Docker, Docker Desktop on WSL2, Codespaces, a
socket mounted into a container). Hints: `/.dockerenv` exists, or the path you
work in is not the path the daemon sees.

If so, you need **`HOST_WORKSPACE`**: the path of the `skein` directory **as
the Docker daemon sees it**. The compose files bind-mount sources such as
`${HOST_WORKSPACE:-.}/projects/skein-api/src`, and bind-mount paths are
resolved on the daemon side, not in your working directory. On a plain host
the default (`.`) is right and nothing is needed. One way to find the value
from inside a devcontainer: `docker inspect $(hostname)` and read the mount
whose destination contains your workspace; map your `skein` path through it.
Write the value into `skein/.env` (ignored by git):

```
HOST_WORKSPACE=/path/on/the/daemon/host/to/skein
```

The harnesses read `.env` from the directory you run them in — the top of
`skein/`. The local stack commands below pass `--env-file versions.env`, and an
explicit `--env-file` turns off the automatic load of `.env`: when you have
created `.env` (for `HOST_WORKSPACE`, `OLLAMA_URL`, VAPID keys), add it as a
second file: `--env-file versions.env --env-file .env`.

---

## 4. Clone

Ask the person where the workspace should live. Clone `skein` first, then the
three services into `skein/projects/<name>`.

Without forks:

```bash
git clone https://github.com/tryskein/skein.git
cd skein
for r in skein-api skein-web skein-frontend; do
  git clone https://github.com/tryskein/$r.git projects/$r
done
```

For each forked repository (replace `<user>`), instead of the plain clone:

```bash
git clone https://github.com/<user>/<repo>.git <dir>      # <dir>: skein, or projects/<repo>
git -C <dir> remote add upstream https://github.com/tryskein/<repo>.git
git -C <dir> fetch upstream
```

Verify the result against the reference tree:

```bash
ls README.md CONTRIBUTING.md docker-compose.local.yml scripts/
for r in . projects/skein-api projects/skein-web projects/skein-frontend; do
  echo "== $r: $(git -C $r rev-parse --is-inside-work-tree) $(git -C $r branch --show-current)"
  git -C $r remote -v
done
git status --short    # in skein/: projects/ must not show up (it is ignored)
```

Each of the four must be a git work tree on `main`, with the remotes you
intended. `git status` in `skein/` must not list `projects/`.

---

## 5. Bring up the local stack

If an older local stack is still running (compose project `skein`, from the
earlier version of these files), stop it first or it keeps ports 8080, 3900 and
5173: check that it is the local stack and not a production installation
(`docker compose -p skein ps`), then `docker compose -p skein stop` (no `-v`).

From the top of `skein/`:

```bash
docker compose --env-file versions.env -f docker-compose.local.yml \
  -f docker-compose.local.build.yml up -d --build
```

This is the development stack: the build overlay (`docker-compose.local.build.yml`)
builds the three services from `projects/`, and the images are named
`skein-*:local-dev`, so the stack runs what you just built and a released image
is never picked up by mistake. To run the published images without any sources,
use `docker-compose.local.yml` alone (see the Quick start of the README).

The first build takes a while (three images; Postgres is the stock pgvector
image). The compose project is named `skein-local`; it starts Postgres 18
(pgvector), Valkey (Redis-compatible), NATS, Garage (the S3 store), skein-api, skein-web,
skein-frontend (nginx) and skein-frontend-dev (Vite with hot reload, from the
overlay). If you had a local stack from an earlier version of these files, its
data lives in the volumes `skein_postgres-data` and `skein_garage-data` of the
old project name `skein`. The new project starts with an empty database and
empty attachments; the old data is not carried over. Remove the two old volumes
when you no longer need them.

How to tell it is up:

```bash
docker compose --env-file versions.env -f docker-compose.local.yml -f docker-compose.local.build.yml ps    # postgres, redis, garage, skein-api, skein-web, skein-frontend: healthy
curl -fsS http://localhost:8080/healthz           # nginx of skein-frontend
curl -fsS http://localhost:8080/version.json
```

skein-api and skein-web are internal only (no host port); their health is
visible through `ps`. Garage creates its own layout, access key and bucket at
start (see `garage/garage.dev.yml`); it is `healthy` once the bucket exists, and
skein-api waits for that. There is no console for Garage.

Where things are:

| What | Address |
|---|---|
| UI (production-built bundle) | http://localhost:8080 |
| UI with hot reload (Vite) | http://localhost:5173 |
| MCP endpoint for agents | http://localhost:8080/mcp, header `X-Skein-Api-Key: ska_…` |
| S3 API (Garage), used by the browser for attachments | http://localhost:3900 — key `skeinlocal` / `skein-local-dev-secret-key` (no console) |

If you run inside a devcontainer, `localhost` is your container, not the
daemon host; the published ports are on the daemon host (from a devcontainer
on Docker Desktop that is usually `host.docker.internal`).

Seeded admin (from `SKEIN_INITIAL_ADMIN_*` in `docker-compose.local.yml`):
email **`admin@test.com`**, password **`qwerty12`**. It is created only when
the users table is empty, i.e. on a fresh `postgres-data` volume. An API key
for MCP is created in the UI (settings → API keys).

Search: `OLLAMA_URL` defaults to a deliberately non-existent host, so search
runs full-text only. That is expected; set `OLLAMA_URL` in `skein/.env` if the
person has an embedding server.

Stop: `docker compose --env-file versions.env -f docker-compose.local.yml -f docker-compose.local.build.yml down`.
Add `-v` only if the person agrees to lose the local data (database, attachments).

---

## 6. Prove the workspace works

Run each level once and report the real result of each.

### Unit tests, per service

The exact commands, prerequisites and pitfalls are in the `## Testing`
section of each service's `CLAUDE.md` and in its
`README.md`. Read those; do not reconstruct commands from the code. The plain
ones:

```bash
(cd projects/skein-api/src && go test -count=1 ./...)        # DB-backed tests skip without TEST_DATABASE_URL
(cd projects/skein-web/src/Tests && dotnet test --nologo)
(cd projects/skein-frontend && npm ci && npm test)
```

skein-api also has Python runner tests; their command is in its `CLAUDE.md`.

### Integration tests (skein-api against a real Postgres)

From the top of `skein/`:

```bash
./scripts/integration-test.sh                         # full suite: go test -p 1 ./...
./scripts/integration-test.sh -p 1 ./internal/users/...   # narrowed run
```

The harness builds a throwaway Postgres, applies the production migrations,
runs `go test` in a container, and always tears its own stack down. Rules, as
the script defines them:

- **`-p 1` is mandatory.** All packages share one database. Any argument you
  pass replaces the default `-p 1 ./...` entirely, so a narrowed run must
  repeat `-p 1` itself.
- `-count=1` and `-v` are forced by the harness.
- A run where zero top-level tests reached `--- PASS:` is red.
- Each run has its own compose project (`skein-itest-<run id>`) and network on
  `10.211.N.0/24`, so it does not touch the local stack.

### e2e (optional, slow)

```bash
(cd projects/skein-frontend && npm ci)     # the Playwright container uses this tree's node_modules
./scripts/e2e-test.sh                      # builds all three images from ./projects/*
./scripts/e2e-test.sh -- -g '<pattern>'    # Playwright flags after --
```

It brings up the whole product on its own network (`10.212.N.0/24`, no host
ports), runs the Playwright group `e2e` in `mcr.microsoft.com/playwright`,
and tears down. Green means at least one test executed and all passed. On a
red run, stack logs are written to `projects/skein-frontend/reports/e2e/`.
`--images registry` tests published images by release tag instead; see the
script header.

### Cross-repository check

```bash
./scripts/check-theme-mirror.sh
```

Compares the frontend's theme-token registry with skein-api's Go mirror.
Needs `node`; with `go` on `PATH` it also verifies skein-api's golden files
first. Exit code 0 means in sync, 1 means out of sync (each difference is
listed), 2 means the check could not run.

---

## 7. Hand over to the person

Tell them, briefly:

- where the workspace is and the four repositories with their remotes
  (`origin` / `upstream` for forks);
- what is running (local stack, addresses from section 5, seeded admin) and
  how to stop it;
- the result of each test level from section 6 — passed, failed (with the
  failing output), or not run;
- anything you installed, and anything you skipped and why;
- that `HOST_WORKSPACE` was written to `skein/.env`, if it was.

Explain how to work in the workspace:

- **Which instructions an agent reads.** `skein/CLAUDE.md` for the workspace;
  `projects/<service>/CLAUDE.md` for work inside a service — it holds that
  service's conventions and its `## Testing` section.
- **Each repository is independent:** its own branch, its own commits, its own
  pull request. A change that spans services is several pull requests.
  Compose files and harnesses live in `skein` and run from its top.
- **Contributing:** read [CONTRIBUTING.md](CONTRIBUTING.md) first — it
  explains the licensing terms for contributions
  (`CONTRIBUTOR-CERTIFICATE.md`). Keep forks current with
  `git fetch upstream` and rebase or merge from `upstream/main`.

---

## 8. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Integration: migrate step fails with `error: first .: file does not exist` | Running from a devcontainer without `HOST_WORKSPACE`; the daemon cannot see the migrations path. Set it in `skein/.env` (section 3). |
| Bind-mounted service has an empty tree (skein-frontend-dev cannot `npm install`, e2e runner finds no tests) | Same cause: wrong or missing `HOST_WORKSPACE`. |
| Integration: `Dirty database version …` or `SQLSTATE 40001` in unrelated packages | Narrowed run without `-p 1`. Re-run as `./scripts/integration-test.sh -p 1 <packages>`. |
| Integration: `ZERO tests executed` | Every test skipped, `-run` matched nothing, or the scope has no tests. Check the package path and pattern. |
| `docker compose -f docker-compose.test.yml …` complains `SKEIN_ITEST_NETWORK is not set` | That file is meant to be driven by `scripts/integration-test.sh`; use the script. Same for `docker-compose.e2e.yml` and `scripts/e2e-test.sh`. |
| `up` fails with `port is already allocated` | 8080, 3900 or 5173 is taken. Find the owner (`ss -ltnp`, `docker ps`) and ask the person before stopping anything. |
| `could not create … on any 10.211.N.0/24` (or `10.212.N`) | No free subnet in that range on this daemon. Show `docker network ls` to the person; do not delete networks you did not create. |
| A killed harness run left `skein-itest-*` / `skein-e2e-*` behind | Visible in `docker compose ls -a`. Remove it only once you are sure it is your run, not another live run. |
| Garage stops at start: `Access key skeinlocal is associated with a secret key different…` | A `garage-data` volume left over from a run with different dev credentials. Dev data is disposable — with the person's consent remove only that volume (`docker volume ls \| grep garage-data`) and `up` again. Same for a `replication_factor` change: it cannot be changed on an existing volume. |
| Cannot log in as `admin@test.com` | The admin is seeded only on an empty users table. An existing `postgres-data` volume keeps its old users. |
| e2e: Playwright/browser version mismatch | The runner image tag must equal `@playwright/test` in `projects/skein-frontend/package.json`; both are pinned. Pull the current `main` of skein and skein-frontend together. |
| `check-theme-mirror.sh` exits 2 | A setup problem, not a difference: `node` missing, a file missing, or a skein-api golden test red. The message says which. |
| Search returns only exact-text matches | Expected without an embedding server (`OLLAMA_URL`). |
