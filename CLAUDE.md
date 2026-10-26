# Skein

Task tracker for AI agents and humans. Agents work through MCP, people through
the web UI (REST, cookie sessions, live updates over SignalR). The product is
three services, each in its own git repository, plus this umbrella repository.

## Workspace layout

```
skein/                    this repository — the top of the workspace
├── CLAUDE.md             this file
├── README.md, ARCHITECTURE.md, RELEASING.md, INSTALL.md, DEVELOPMENT.md, CONTRIBUTING.md, …
├── docker-compose.*.yml  local / test / e2e stacks
├── scripts/              integration and e2e harnesses, cross-repo checks
└── projects/             not tracked by this repository
    ├── skein-api/        Go backend — REST /api/v1 + MCP /mcp, DB migrations
    ├── skein-web/        .NET BFF — cookie + Redis sessions, proxy, SignalR hub
    └── skein-frontend/   React SPA served by nginx — the only public entry point
```

**Each service has its own `CLAUDE.md`** with its stack, commands, tests and
pitfalls. Before changing a service, read `projects/<service>/CLAUDE.md`.
Setting up this layout from scratch: [`DEVELOPMENT.md`](DEVELOPMENT.md).

## Local stack

```bash
# published images, nothing to build (installing, trying out, testing):
docker compose --env-file versions.env -f docker-compose.local.yml up -d
# built from projects/* with a Vite dev server (development only):
docker compose --env-file versions.env -f docker-compose.local.yml \
  -f docker-compose.local.build.yml up -d --build
# UI:  http://localhost:8080   (seeded admin: admin@test.com / qwerty12)
# MCP: http://localhost:8080/mcp  (header X-Skein-Api-Key: ska_...)
```

Unless the person explicitly asks for source development or a build of modified
code, use the published images for installing, trying out and testing Skein; do
not clone the service repositories for that.

Only the frontend nginx (8080) is the application entry point. Garage's S3
port (3900) is also published, for the browser's presigned URLs; Garage has no
console. Both ports are bound to `127.0.0.1`. Postgres, Redis, NATS, skein-api and skein-web stay on the internal
compose network. The credentials above are for local development only.

## Docs

| File | What |
|---|---|
| [`README.md`](README.md) | overview, deploy, development, links |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | components, communication flows, auth, deployment |
| [`RELEASING.md`](RELEASING.md) | service versions, Skein releases, image tags |
| [`INSTALL.md`](INSTALL.md) | installing Skein on a server — runbook for an agent |
| [`DEVELOPMENT.md`](DEVELOPMENT.md) | setting up the development workspace — runbook for an agent |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | how to contribute, pull requests, Contributor Certificate |
| `projects/<service>/docs/env-reference.md` | every environment variable of that service |

## Working rules

- **Do not invent.** No made-up numbers, outputs, endpoints, flags, variables
  or versions. If you have not verified something, say so or look it up in the
  code.
- **No hacks.** No temporary workarounds or stubs "to fix later". If the right
  solution is too large, stop and ask the person.
- **One repository, one change.** Every service has its own git history,
  branch, commits and pull request. A change that touches two services is two
  commits in two repositories and two pull requests. Check the current branch
  of each repository with `git -C projects/<service> branch --show-current`;
  do not assume one branch name for all.
- **Compatibility between services.** The latest released versions of all
  services must work together. A change that breaks the contract between
  services ships in every service it touches — see
  [`RELEASING.md`](RELEASING.md).
- **Git tags are never moved, deleted or reused.** A mistake in a release is
  fixed by the next release.
- **Migrations** (skein-api, golang-migrate, applied at startup):
  `projects/skein-api/src/migrations/000NNN_name.{up,down}.sql`. Never edit a
  migration that has been released — add the next one.
- **References to code** in comments and docs use a name anchor
  (`lib/widthBudget.ts#DETAILS_MIN_READABLE_PX`), not a line number. The
  anchor must be a literal that occurs in the named file.
- **API changes** — an endpoint's documentation (purpose, parameters,
  responses, side effects, errors) is updated in the same commit as the
  endpoint itself. Each service's `CLAUDE.md` says how it is documented there.

### Service conventions

- Business errors are **422**; 400 only for malformed input, 401 for bad
  credentials, 404 only for unknown routes, 500 only for real failures.
- Every service exposes `/healthz` (liveness, no dependency checks) and
  `/ready` (readiness, checks dependencies).
- Every web service honours an optional `PORT` variable.
- Environment variables with addresses, keys or connection strings have **no
  fallback in code**: if one is missing, the service fails at startup. `PORT` is the only
  exception.
- Logs go to stdout: logfmt for info and below, JSON with full context for
  errors. Secrets never reach logs.

## Testing

Each repository has its own `## Testing` section in its `CLAUDE.md` with the
exact commands. Run tests as those sections describe; do not reconstruct the
commands from the code.

| Repository | unit | integration | e2e |
|---|---|---|---|
| skein-api | yes | yes (Postgres) | covered by the e2e suite of skein-frontend |
| skein-web | yes | no | covered by the e2e suite of skein-frontend |
| skein-frontend | yes | no | yes, manual |

The harnesses live here because the stack spans repositories. Run them from
the top of `skein/`:

- `./scripts/integration-test.sh` — integration tests of skein-api against a
  throwaway Postgres. Narrowed runs must pass `-p 1` explicitly:
  `./scripts/integration-test.sh -p 1 ./internal/<package>/...`.
- `./scripts/e2e-test.sh` — the end-to-end suite for the whole product; builds
  the three images from `projects/*`.
- `scripts/s3-contract-check/` — checks an S3-compatible storage against what
  skein-api needs (presigned POST policy, CORS, presigned GET, listing). It is
  run by hand, in a container on a test machine, when you change the image of a
  bundled store or add a new one; see its README.
- `./scripts/check-theme-mirror.sh` — the theme token registry of the frontend
  must match its mirror in skein-api. Run it after changing either side.

GitHub Actions in this repository (`.github/workflows/`): `ci.yml` validates
the compose files (`docker compose config -q`), runs `shellcheck` on
`scripts/*.sh`, renders the Kubernetes kustomizations and vets the S3 checker;
it runs no e2e or integration tests. `release.yml` ("Release Skein") is started
by hand; see `RELEASING.md`.

Inside a devcontainer, export `HOST_WORKSPACE` — the path of this directory as
the Docker daemon sees it — before running the harnesses.

### Definition of done

- unit tests — after every round of edits, in the repository you changed;
- integration (skein-api) — before finishing a change that touched the
  database, handlers or MCP: a narrowed run with `-p 1`; the full suite before
  the feature is done;
- a bug fix comes with a regression test;
- e2e — when the change touches a path an e2e scenario covers, or when e2e is
  part of the acceptance criteria: a green run with at least one executed
  test.

## Frontend: `Delegated` mode is a global lens

The header toggle `Delegated` (`outboxMode` in `useLayoutState`)
narrows the whole UI to "issues the caller created and delegated to others"
(`createdBy = me AND assignee != me`). Every surface that shows counts, lists
or filters derived from issues must honour it on every counter, filter and
list it exposes — never partially:

1. read `outboxMode` from `useLayoutState`;
2. either ask the backend for a parallel scoped counter (`{metric}Count` plus
   `myOutbox{Metric}Count` on the same DTO) and pick by `outboxMode`, or
   derive the metric on the frontend by filtering visible data with
   `createdBy === callerUserId && assignee !== callerUsername`.

Reference surfaces: `useTasks.ts`, `ProjectRow.tsx`, `ComponentRow.tsx`.
Surfaces already scoped to the caller (header badges, inbox count, per-issue
counts) need nothing. New backend fields use the explicit `myOutbox{Metric}Count`
name; never change the meaning of an existing `{metric}Count` by user mode — it
breaks read-only consumers such as MCP tools.
