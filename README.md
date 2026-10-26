# Skein

[![Release](https://img.shields.io/github/v/release/tryskein/skein?label=release)](https://github.com/tryskein/skein/releases/latest)
[![License: BSL 1.1](https://img.shields.io/badge/license-BSL%201.1-blue)](LICENSE)
[![skein-api image](https://img.shields.io/badge/ghcr.io-skein--api-2496ED?logo=docker&logoColor=white)](https://github.com/tryskein/skein-api/pkgs/container/skein-api)
[![skein-web image](https://img.shields.io/badge/ghcr.io-skein--web-2496ED?logo=docker&logoColor=white)](https://github.com/tryskein/skein-web/pkgs/container/skein-web)
[![skein-frontend image](https://img.shields.io/badge/ghcr.io-skein--frontend-2496ED?logo=docker&logoColor=white)](https://github.com/tryskein/skein-frontend/pkgs/container/skein-frontend)

Skein is a task tracker for AI agents and people. Agents work through MCP, people
through the web UI, and both see the same tasks, comments and live updates. It runs
on your own server from a single Compose file.

**Website:** https://skein.net

## Contents

- [What is in this repository](#what-is-in-this-repository)
- [Quick start](#quick-start)
- [Deploy on your server](#deploy-on-your-server)
- [Configuration](#configuration)
- [Upgrading](#upgrading)
- [Development](#development)
- [Releases and versioning](#releases-and-versioning)
- [Support](#support)
- [Architecture](#architecture)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## What is in this repository

Skein is split across four repositories. This one is the umbrella: the compose
files, the test harnesses and the project-wide documentation. The code lives in
three service repositories, which are cloned into `projects/` of this one.

| Repository | What it is |
|---|---|
| [skein](https://github.com/tryskein/skein) | this repository: deployment, test harnesses, project docs |
| [skein-api](https://github.com/tryskein/skein-api) | backend (Go): REST API and MCP server |
| [skein-web](https://github.com/tryskein/skein-web) | BFF (.NET): sessions, proxy, live updates |
| [skein-frontend](https://github.com/tryskein/skein-frontend) | web UI (React) |

## Quick start

### Install from the registry

You need Docker with Compose 2.23.1 or newer and curl. Ports 8080 and 3900 must
be free.

```bash
mkdir -p skein/garage && cd skein
B=https://raw.githubusercontent.com/tryskein/skein/main
curl -fsSLO $B/docker-compose.local.yml
curl -fsSLO $B/versions.env
curl -fsSL $B/garage/garage.dev.yml -o garage/garage.dev.yml
curl -fsSL $B/garage/ports-local.yml -o garage/ports-local.yml
docker compose --env-file versions.env -f docker-compose.local.yml up -d
```

Open <http://localhost:8080> and log in as `admin@test.com` with the password
`qwerty12`. These are local values: the stack listens on `127.0.0.1` only, and
you must never use them on a server.

### Build from source

You need the same Git and Docker (Compose 2.23.1 or newer); ports 8080, 3900
and 5173 must be free.

```bash
git clone https://github.com/tryskein/skein.git
cd skein
for r in skein-api skein-web skein-frontend; do
  git clone https://github.com/tryskein/$r.git projects/$r
done
docker compose --env-file versions.env -f docker-compose.local.yml \
  -f docker-compose.local.build.yml up -d --build
```

This also starts a Vite dev server with hot reload on
<http://localhost:5173>. More in [Development](#development).

### On a server

See [Deploy on your server](#deploy-on-your-server).

### On Kubernetes

See [Kubernetes](#kubernetes).

### Using the local stack

- **Agents** connect through MCP at `http://localhost:8080/mcp` with the header
  `X-Skein-Api-Key: ska_…`. Create the key in the UI.
- **Your own settings** (Web Push keys `SKEIN_VAPID_PUBLIC` and
  `SKEIN_VAPID_PRIVATE`, `OLLAMA_URL`, …) go in `.env`, see
  [`.env.example`](.env.example). Pass it as a second file:
  `--env-file versions.env --env-file .env`.
- **Stop:** the same command with `down` instead of `up -d`; after a build from
  source, with both `-f` files, so the dev server stops too. Add `-v` to also
  delete the local database and attachments.
- **Update:** download the four files again (`versions.env` carries the release),
  then run the full `docker compose … up -d` command again. Read the release
  notes first, as for any [upgrade](#upgrading).

## Deploy on your server

### Docker Compose

The main path is to give [INSTALL.md](INSTALL.md) to your AI agent and let it
do the installation. The guide is written for the agent: it explains how the
environment variables fit together, asks you the questions only you can answer
(address, how people sign in, who the first administrator is, mail, file
storage), generates the secrets, fills `.env`, starts
[`docker-compose.production.yml`](docker-compose.production.yml) and checks
that the installation works. It also lists what to hand over to you afterwards:
backups, how to upgrade, how agents connect.

What you need:

- a Linux server with Docker and the Compose v2 plugin, version 2.23.1 or newer;
- a public HTTPS address for Skein. The guide asks who terminates HTTPS in front
  of it;
- access for the agent to the server (SSH), or run the agent on the server itself.

Pin the version: set `SKEIN_VERSION` in `.env` to a Skein release such as
`1.0.0`. The `latest` image tag is only for trying Skein out.

### Kubernetes

Example manifests for the three application services, with a runbook for the
PostgreSQL, Valkey (Redis-compatible), NATS and S3-compatible storage they depend on, are in
[`deploy/kubernetes/`](deploy/kubernetes/). The step-by-step guide is Target B
in [INSTALL.md](INSTALL.md). Give it to your agent, as for Docker Compose.

## Configuration

The settings that matter for a first installation:

- **Sign-in mode** (`SKEIN_AUTH_MODE`): `local` (email and password stored in
  Skein, the default), `keycloak` (single sign-on only) or `hybrid` (SSO for
  staff and passwords for external accounts). AI agents use per-user API keys in
  every mode.
- **First administrator**: created at the first start from `SKEIN_INITIAL_ADMIN_*`.
- **Mail**: optional SMTP for invitations and password resets.
- **File storage** for attachments: one bundled single-node store (Garage by
  default, SeaweedFS or RustFS as alternatives) or any external S3-compatible
  service.
- **Semantic search**: optional, needs an Ollama server that you run.

Every variable of each service is described in its own reference:

- [skein-api](https://github.com/tryskein/skein-api/blob/main/docs/env-reference.md)
- [skein-web](https://github.com/tryskein/skein-web/blob/main/docs/env-reference.md)
- [skein-frontend](https://github.com/tryskein/skein-frontend/blob/main/docs/env-reference.md)

## Upgrading

1. Always read the release notes of the new Skein release first, and read them
   with extra care before moving to a new major version. Some releases need all of skein-api and
   skein-web stopped before the new version starts, or a backup, because a
   migration cannot be undone.
2. Back up the database and the attachments.
3. Set the new `SKEIN_VERSION` in `.env`, apply any `.env` changes the release
   notes list, then `docker compose -f docker-compose.production.yml pull` and
   `docker compose -f docker-compose.production.yml up -d`.

Database migrations run automatically when skein-api starts. Never run two
versions of skein-api against the same database at the same time. Rolling the
image back does not roll the database back: fix a failed upgrade forward or
restore the backup. The details, with the backup commands, are in
[INSTALL.md](INSTALL.md). On Kubernetes you change the image tags and apply the
manifests.

## Development

Skein is split across four repositories. This one is the top level of the
workspace: it holds this README, `CLAUDE.md`, the license, compose files and
test harnesses. The three code repositories are cloned **into `projects/`**
inside it (that directory is ignored by this repository's git):

```
skein/                    this repository — the top of the workspace
├── README.md
├── CLAUDE.md             entry point for coding agents; links to the CLAUDE.md of each service
├── LICENSE, CONTRIBUTING.md, ARCHITECTURE.md, RELEASING.md, …
├── docker-compose.*.yml
├── scripts/              integration and e2e harnesses
└── projects/
    ├── skein-api/        backend (Go) — its own git repository
    ├── skein-web/        BFF (.NET) — its own git repository
    └── skein-frontend/   web UI (React) — its own git repository
```

```bash
git clone https://github.com/tryskein/skein.git
cd skein
for r in skein-api skein-web skein-frontend; do
  git clone https://github.com/tryskein/$r.git projects/$r
done
```

Each repository is versioned on its own and has its own `main` branch.
Commands below run from the top of `skein/`.

**Local stack.** Build it from the three repositories in `projects/` with the
overlay, as in [Build from source](#build-from-source):
`docker compose --env-file versions.env -f docker-compose.local.yml -f docker-compose.local.build.yml up -d --build`.
The UI is at <http://localhost:8080>; the Vite dev server with hot reload is at
<http://localhost:5173>. The locally built images are named `skein-*:local-dev`,
so they are never mistaken for a release.

**Unit tests**, per repository. The exact commands and pitfalls are in the
`Testing` section of each repository's `CLAUDE.md`. The plain ones:

```bash
(cd projects/skein-api/src && go test -count=1 ./...)
(cd projects/skein-web/src/Tests && dotnet test --nologo)
(cd projects/skein-frontend && npm ci && npm test)
```

**Integration tests** of skein-api run against a throwaway Postgres:

```bash
./scripts/integration-test.sh
./scripts/integration-test.sh -p 1 ./internal/users/...   # a narrowed run must pass -p 1 explicitly
```

**End-to-end tests** cover the whole product and build the three images from
`projects/*`. They are slow, so run them by hand when you change a path they
cover:

```bash
(cd projects/skein-frontend && npm ci)
./scripts/e2e-test.sh
```

Inside a devcontainer, export `HOST_WORKSPACE` (the path of this directory as the
Docker daemon sees it) before running the harnesses. The full workspace setup
guide, written for an agent, is [DEVELOPMENT.md](DEVELOPMENT.md).

## Releases and versioning

Every service has its own version; a Skein release pins a set of service
versions that work together. See [RELEASING.md](RELEASING.md).

## Support

Report bugs and ask questions in the GitHub Issues of the repository the problem
belongs to. If you are not sure which one, use this repository. Do not report
security problems there; see [Security](#security). Questions about licensing:
<https://skein.net/licensing>, or info@sebocorp.com for a commercial license.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[Contributor Certificate](CONTRIBUTOR-CERTIFICATE.md).

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md).

## License

Skein is licensed under the [Business Source License 1.1](LICENSE).
Licensing FAQ: https://skein.net/licensing.
Trademarks: [TRADEMARKS.md](TRADEMARKS.md).
