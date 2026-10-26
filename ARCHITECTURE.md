# Skein — Architecture

This document describes how Skein is put together: its parts, how they talk to
each other, where state lives, how a request and an event travel through the
system, how authentication is layered, and how it is deployed. It deliberately
does not catalogue features, endpoints, environment variables, tables or MCP
tools — those live next to the code (see [Configuration](#configuration)).

## Principles

1. **Single public edge.** One HTTP entry point faces the outside. Neither
   backend is exposed publicly.
2. **Few moving parts.** Two backend services (`skein-api` in Go, `skein-web` in
   .NET) and one frontend (`skein-frontend`, a React SPA served by nginx).
3. **Stateless services.** State lives in PostgreSQL, Redis, NATS and object
   storage; every service scales horizontally.
4. **Pluggable authentication.** Local passwords, SSO via Keycloak, or both —
   selected by installation settings.
5. **Deployable anywhere.** Docker Compose for small installations and
   development, Kubernetes for production.

## Components

| Component | Role | Public? |
|---|---|---|
| `skein-frontend` | nginx serving the SPA bundle; the public edge in Docker Compose, routing backend paths to `skein-web` | yes (Compose) / behind the gateway (k8s) |
| `skein-web` | BFF: browser sessions, login, SignalR hub, reverse proxy to `skein-api` | no |
| `skein-api` | All business logic and data access: REST API, MCP server, agent task-monitor API, background workers | no |
| PostgreSQL | System of record, including the event log / outbox, full-text and vector search | no |
| Redis | `skein-web` state: sessions, cookie-encryption keys, login throttling, SignalR backplane | no |
| NATS (Core) | Live-event bus from `skein-api` to `skein-web` | no |
| S3-compatible object storage (bundled Garage, SeaweedFS or RustFS single node, or any external S3) | Attachments; browsers upload and download directly via presigned URLs | reached by browsers via presigned URLs |
| Ollama (external) | Embeddings for semantic search and duplicate detection | no |
| Keycloak (external, optional) | Identity provider for SSO modes | yes, as the IdP |
| SMTP relay (external, optional) | Outgoing mail sent by `skein-api` | — |
| Web Push services (external) | Browser push delivery, called by `skein-api` | — |

### `skein-api` (Go)

The primary backend. Go with `chi`, `pgx/v5` + `pgxpool`, `golang-migrate`,
`mark3labs/mcp-go` (MCP Streamable HTTP), `nats.go`, `minio-go`, `log/slog`.

- **Code shape.** Flat domain packages under `src/internal/` (issues, projects,
  users, notifications, spaces, …) hold the business logic; `handler/` holds the
  HTTP handlers and `mcp/` the MCP tools. SQL is written by hand over `pgx` in
  the domain packages; a small part of it is generated with `sqlc`
  (`internal/storage/queries` → `internal/storage/generated`). There is no ORM.
- **Surfaces.** The REST API under `/api/v1`, the MCP server under `/mcp`, a
  read-only agent task-monitor API under `/agent/v1` (short-lived `skm_`
  tokens), RFC 9728 protected-resource metadata under `/.well-known/` (only when
  authorization servers are configured), and `/healthz`, `/ready`, `/metrics`.
  An **operator API** for account administration is a second, optional listener
  on its own port, guarded by its own key; it is never routed through the public
  edge ([DEPLOYMENT-NOTES §3.4](DEPLOYMENT-NOTES.md)).
- **Schema.** Migrations are applied by the service itself at startup, guarded by
  golang-migrate's advisory lock so concurrent replicas do not race. The
  `migrate` CLI is also shipped in the image for manual operation. Settings that
  contradict each other or the existing data stop the process before the listener opens
  ([DEPLOYMENT-NOTES §3.2](DEPLOYMENT-NOTES.md)).
- **Background workers** run as goroutines inside the same process: the outbox
  dispatcher (events → NATS), Web Push delivery, mail delivery and cleanup,
  embedding backfill, reminders, invitation expiry, stale-lock release and
  retention / cleanup jobs. They coordinate through PostgreSQL, so there is no
  separate worker deployment.

### `skein-web` (.NET 10)

The BFF between the browser and `skein-api`. It does not serve the SPA.

- **Sessions.** Cookie authentication with the ticket stored server-side in
  Redis; cookie-encryption keys are in Redis too, so any replica can serve any
  session.
- **Own endpoints.** `/api/auth/*` (login, logout, current user, client
  configuration, account flows such as sign-up and password reset), the OIDC
  challenge `/oauth2/start` in native-OIDC mode, and the SignalR hub at `/hub`.
- **Reverse proxy.** `/api/v1/*`, `/mcp`, `/agent/v1/*` and the
  `/.well-known/oauth-protected-resource*` documents are forwarded to
  `skein-api` by our own small middleware rather than YARP: one upstream and a
  fixed identity-forwarding shape do not justify the dependency, and it keeps the
  trust boundary readable in a couple of files (rationale in the
  `ApiProxyMiddleware` doc comment).
- **Settings come from `skein-api`.** `skein-web` keeps no installation settings
  of its own: it reads the authentication mode from `skein-api` before the host
  is built and refuses to start without an answer; behaviour flags are fetched
  per request ([DEPLOYMENT-NOTES §3.3](DEPLOYMENT-NOTES.md)).

### `skein-frontend` (React)

React 18 + TypeScript, Vite, Mantine, TanStack Query, `@microsoft/signalr`.
`npm run build` produces a static bundle that is baked into an
`nginx-unprivileged` image. It is a separate image from `skein-web` on purpose:
a frontend release does not restart the BFF or drop live SignalR connections,
and the "new version available" banner tracks the SPA version alone.

## High-level diagram

```
 Browser (SPA + SignalR)     MCP clients / agents        Task-monitor runner
          │ HTTPS                    │ HTTPS                    │ HTTPS
          ▼                          ▼                          ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Public edge: skein-frontend nginx (Compose) / cluster gateway (k8s)      │
│   SPA static files                                                       │
│   /api/  /hub  /mcp  /oauth2/  /.well-known/oauth-protected-resource*    │
│        └──────────────────────────► skein-web                            │
└──────────────────────────────────────┬───────────────────────────────────┘
                                       ▼ HTTP (internal)
┌──────────────────────────────────────────────────────────────────────────┐
│ skein-web (BFF)                                                          │
│   /api/auth/*   /oauth2/start   /hub (SignalR)                           │
│   proxy: /api/v1/*  /mcp  /agent/v1/*  /.well-known/…                    │
└────┬──────────────────────────┬─────────────────────────────▲────────────┘
     │ sessions, keys,          │ HTTP + X-Skein-* headers    │ subscribe
     │ backplane                ▼                             │
  ┌──┴───┐   ┌──────────────────────────────────────────┐   ┌─┴────┐
  │Redis │   │ skein-api                                │──►│ NATS │
  └──────┘   │   REST /api/v1   MCP /mcp   /agent/v1    │pub└──────┘
             │   domain packages + background workers   │
             └──┬─────────────┬──────────────┬──────────┘
                ▼             ▼              ▼
          ┌──────────┐  ┌──────────┐  ┌────────────────────────────────┐
          │PostgreSQL│  │ S3 store │  │ External: Ollama, Keycloak,    │
          │+pgvector │  │  Garage  │  │ SMTP relay, Web Push services  │
          │+pg_trgm  │  └──────────┘  └────────────────────────────────┘
          └──────────┘
   Browsers also talk to the S3 store directly, using presigned URLs.
```

## Communication flows

### Browser → REST API

```
SPA ──GET /api/v1/…, session cookie──► edge ──► skein-web
  skein-web: validates the cookie, strips any inbound X-Skein-* headers,
             adds X-Skein-Internal-Secret and the X-Skein-User-* identity headers
  ──► skein-api: checks the internal secret, resolves the user, runs the query
  ◄── JSON ── skein-web ◄── edge ◄──
```

`skein-api` trusts identity headers only on a request that carries the shared
internal secret, so the browser cannot reach it except through `skein-web`.
The link between them is plain HTTP inside the private network; the secret,
not the transport, authenticates the caller.

### Write → event → live update

```
1. A write in skein-api changes rows, appends an event row and, in the same
   transaction, materializes notifications for watchers and mentioned users.
2. The outbox dispatcher polls unpublished events (FOR UPDATE SKIP LOCKED),
   publishes them to NATS Core and marks them published. Delivery is
   at-least-once; subscribers deduplicate by event id.
3. Subjects:
     skein.events.project.{projectId}.{entity}.{action}.{entityId}   project-scoped
     skein.user.{userId}.{action}                                     user-scoped
4. Every skein-web replica subscribes to skein.events.> and skein.user.> in one
   queue group (each message is handled once), decides the audience, and
   pushes into SignalR project groups or to the specific user. The Redis
   backplane carries the push to whichever replica holds the connection.
5. The SPA invalidates the affected TanStack Query caches and refetches.
```

The events table is the source of truth: NATS only carries notifications of
change, so a NATS outage delays live updates but loses nothing — the backlog is
published once NATS is back. Notifications and mentions do not depend on NATS at
all. Web Push and mail are separate transports driven by their own workers from
PostgreSQL, not by NATS.

Access to a project's live stream is checked against `skein-api` when the hub
admits a connection to a project group; access changes are propagated over the
same bus.

### Agent → MCP

```
MCP client ──POST /mcp, X-Skein-Api-Key: ska_… (or Authorization: Bearer ska_…),
             Mcp-Session-Id──► edge (no buffering) ──► skein-web ──► skein-api
  skein-api: validates the key, identifies the owning user and the agent
             session, runs the tool, streams the response back
```

### Agent task-monitor

A small runner script, fetched from `/agent/v1/monitor-script`, polls
`/agent/v1/notifications/poll` with a short-lived read-only `skm_` token.
`skein-web` forwards this path ahead of cookie authentication (the token is not a
cookie); `skein-api` re-checks the visibility of every event it returns.

## Authentication

### Modes

`SKEIN_AUTH_MODE` on `skein-api` selects the identity source; `skein-web` reads
it from `skein-api` and configures itself accordingly.

| Mode | Browser login |
|---|---|
| `local` (default) | Email + password. `skein-web` forwards the credentials to `skein-api`, which verifies the bcrypt hash; `skein-web` then issues the session cookie. |
| `keycloak` | SSO. Either **native OIDC** — `skein-web` runs the OIDC flow itself (`/oauth2/start` → Keycloak → callback) — or **legacy** — oauth2-proxy in front of `skein-web` authenticates and passes trusted identity headers. Users can be provisioned on first login. |
| `hybrid` | SSO for internal users and password login for external accounts at the same time. |

In SSO modes a single configured break-glass admin may still log in with a
password, so a misconfigured IdP cannot lock the installation.

### Agents

- **API key.** Agents authenticate with a per-user `ska_` key in
  `X-Skein-Api-Key`; `skein-api` verifies it against a bcrypt hash. The key
  identifies the owning user (the permission boundary); `Mcp-Session-Id`
  identifies the individual agent session for audit.
- **Bearer compatibility.** MCP clients that only send `Authorization: Bearer`
  are supported at the boundary: `skein-web` translates a `Bearer ska_…` value
  into `X-Skein-Api-Key` and never forwards `Authorization` upstream. A
  non-`ska_` bearer token is not translated and is stripped; two different
  credentials on one request are rejected with `400 invalid_request`
  (RFC 6750).
- **Discovery.** When authorization servers are configured, `skein-api`
  publishes RFC 9728 protected-resource metadata and advertises it in
  `WWW-Authenticate` on a 401 from `/mcp`. It does not serve authorization-server
  metadata itself; the client fetches that from the IdP. Validating IdP-issued
  JWTs on `/mcp` is not implemented — agents use API keys.

## Data and tenancy

PostgreSQL 18 with the `vector` (pgvector) and `pg_trgm` extensions. The
extensions are created when the cluster is initialized, not by migrations
(migrations run without `CREATE EXTENSION` rights). The development stacks
build a Postgres image that does this, from `skein-api/infra/postgres` in the
neighbouring `skein-api` repository; `docker-compose.production.yml` runs the
stock `pgvector/pgvector:pg18` image and creates the extensions with an inline
SQL script on the first start of an empty volume. Database locale requirements are in
[DEPLOYMENT-NOTES §1](DEPLOYMENT-NOTES.md).

The tenant boundary is the **space**: one installation, one database, many
spaces, each with its own members and projects. External users (accounts
outside the SSO directory), self-service sign-up and invitations are built on
the same model and leave the service topology unchanged.

## Deployment

### Repository layout

Skein is split across four repositories. `skein` is the top of the workspace;
the three code repositories are cloned into its `projects/` directory:

```
skein/                    Compose files, test harnesses, release and project docs
└── projects/
    ├── skein-api/        Go backend; also the Postgres image (infra/postgres)
    ├── skein-web/        .NET BFF
    └── skein-frontend/   React SPA + nginx image
```

The development overlay `docker-compose.local.build.yml` builds the images
straight from those working trees (`build: context: ./projects/skein-api` and so
on); the test and end-to-end stacks build from them too. The integration and
end-to-end harnesses live in [`scripts/`](scripts/).

### Docker Compose

[`docker-compose.local.yml`](docker-compose.local.yml) runs the whole stack:
PostgreSQL, Valkey (Redis-compatible), NATS, Garage (S3), `skein-api`, `skein-web` and `skein-frontend`.

```bash
docker compose --env-file versions.env -f docker-compose.local.yml up -d
```

It starts the published images of the release pinned in `versions.env`; adding
`-f docker-compose.local.build.yml` builds them from `projects/` instead and adds a
Vite dev-server service for frontend development.

The application is reached through `skein-frontend` on host port 8080;
`skein-web` and `skein-api` have no host ports. Garage's S3 port is also
published to the host so that browsers can follow presigned URLs. Both ports
are bound to `127.0.0.1`. Ollama, Keycloak and SMTP are not part of the stack
and are configured as external addresses.

### Kubernetes

```
Internet → Ingress / Gateway (TLS)
             ├─ /api/  /hub  /mcp  /agent/v1  /oauth2/  /.well-known/oauth-protected-resource*
             │        → skein-web Service
             └─ everything else → skein-frontend Service
           skein-web → skein-api Service (cluster-internal)
           skein-api operator port → no route; reachable only from the operator's workload
```

`skein-api`, `skein-web` and `skein-frontend` are stateless Deployments with
ordinary ClusterIP Services. PostgreSQL, Redis, NATS and object storage are
treated as external stateful dependencies, provisioned and operated separately
and passed in as addresses. A single NATS node is sufficient: it carries only
change notifications, and durability is in PostgreSQL. Example manifests and the
installation guide are in `deploy/kubernetes/` and
[INSTALL.md](INSTALL.md) (Target B).

The example runs one `skein-web` replica. With more than one, the SignalR hub
(`/hub`) needs session affinity at the ingress: a connection lives only in the
memory of the pod that handled its negotiation.

Ordinary releases are rolling updates. A release whose migrations change the
meaning of existing rows requires a stop-all of `skein-api` and `skein-web`
([DEPLOYMENT-NOTES §2](DEPLOYMENT-NOTES.md), [§3.1](DEPLOYMENT-NOTES.md)).

## Configuration

This document intentionally lists no environment variables. Each service keeps
its own reference next to its code, changed in the same commit as the code
that reads a variable; they are in the neighbouring repositories:

| Service | Reference (in the service repository) |
|---|---|
| `skein-api` | `skein-api/docs/env-reference.md` |
| `skein-web` | `skein-web/docs/env-reference.md` |
| `skein-frontend` | `skein-frontend/docs/env-reference.md` |

Release-time and operational detail is in [DEPLOYMENT-NOTES.md](DEPLOYMENT-NOTES.md).

## Open questions

- **Several installations.** Tenancy is settled within one installation (spaces).
  Still open: routing spaces across several installations ("cells"), for when
  a single database can no longer keep up or data must reside in a particular region.
