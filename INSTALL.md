# Installing Skein — runbook for an AI agent

This file is written **for you, the agent** that installs Skein on behalf of a
person. Follow it top to bottom. It tells you what to ask, what to explain, what
to decide yourself and what never to do.

The authoritative description of every setting is the per-service environment
reference. When this runbook and a reference disagree, the reference wins:

- skein-api — <https://github.com/tryskein/skein-api/blob/main/docs/env-reference.md>
- skein-web — <https://github.com/tryskein/skein-web/blob/main/docs/env-reference.md>
- skein-frontend — <https://github.com/tryskein/skein-frontend/blob/main/docs/env-reference.md>

Read the skein-api reference in full before the interview. You will need it.

## Ground rules

- **Do not invent values.** Domains, mail servers, identity-provider addresses
  and credentials come from the person. Random secrets come from you (section 5).
  Nothing else is guessed.
- **Do not invent variables.** Only variables named in the three references
  exist. A variable you "remember" from another product does nothing here.
- **Ask before you change the server.** Reading (`docker ps`, `df`, `uname`)
  needs no permission. Installing packages, opening ports, writing files outside the install
  directory or touching an existing reverse proxy needs the person's yes.
- **Never print secrets back** into the chat, logs you paste, or command lines
  that end up in shell history. Write them straight into `.env`.
- **Explain, then recommend.** The person may not know what "OIDC" or "S3"
  means. For every decision say in plain words what each option does, what it
  costs, and which one you recommend.
- **Do not set an empty variable to mean "off".** In skein-api and skein-web an
  empty value is not the same as an absent one. Leave the line out instead.

---

## 1. Goal and targets

**Goal:** a running Skein installation reachable at the person's own HTTPS
address, with a working administrator account, ready for people (web UI) and
AI agents (MCP at `<public URL>/mcp`).

What gets installed:

| Part | Image / source | Role |
|---|---|---|
| skein-frontend | `ghcr.io/tryskein/skein-frontend` | nginx + web UI; **the only public entry point** |
| skein-web | `ghcr.io/tryskein/skein-web` | sessions, login, live updates, proxy to skein-api |
| skein-api | `ghcr.io/tryskein/skein-api` | business logic, REST, MCP; applies database migrations on start |
| PostgreSQL 18 | stock `pgvector/pgvector:pg18` image; the compose file creates the `pg_trgm` and `vector` extensions on the first start | all data |
| Redis-compatible store (Valkey) | stock image | sessions and cookie-encryption keys |
| NATS | stock image | live-update bus |
| S3-compatible storage | one bundled single-node store (Garage by default, SeaweedFS or RustFS as alternatives; stock images) or an external service | attachments |
| Ollama (optional) | a server you or the person already run, outside this compose file | embeddings for semantic search |

Images are published for amd64 and arm64. Tags: `X.Y.Z` (one service version),
`skein-X.Y.Z` (the image that belongs to Skein release `X.Y.Z`), `latest`.
**Always pin `skein-X.Y.Z`** through `SKEIN_VERSION` — `latest` is only for
trying Skein out.

### Target A — single server / VPS with Docker Compose (this runbook)

Everything runs on one host from `docker-compose.production.yml` with values in
`.env`. Sections 2–9 describe this path.

> The production compose file and `.env.example` are in the root of
> <https://github.com/tryskein/skein>. Use the copies at the tag of the release
> you install. Where this runbook names a compose service, a volume, a published
> port or an `.env` key that is not a service variable, check it against those
> files — they win. The compose file needs Docker Compose v2.23.1 or newer.

### Target B — Kubernetes

Example manifests are in [`deploy/kubernetes/`](deploy/kubernetes/) of
<https://github.com/tryskein/skein>; use the copy at the tag of the release you
install. They are plain manifests applied with `kubectl apply -k`, not a chart.
They deploy the three application services (skein-api, skein-web,
skein-frontend) with Services, PodDisruptionBudgets, probes, resource settings,
a non-root security context and an Ingress. **PostgreSQL, Redis, NATS and the
object storage are separate services that the person runs or rents**; the
manifests only take their addresses. For people who have none of the first
three there is a minimal example in
[`deploy/kubernetes/optional-dependencies/`](deploy/kubernetes/optional-dependencies/),
marked in every file as not for production without more work.

Everything in sections 3–5 (the interview, validating the answers, generating
secrets) applies unchanged; only the place where the answers go is different
(B3). Sections 6–7 are replaced by B4–B6. Do not improvise manifests: change the
example files, and keep the guarantees listed in their comments.

**B1. Ask and check**

- Which cluster, which namespace, and may you create things there. Check
  `kubectl version` and that the person's context is the intended one.
- Which **ingress controller** (`kubectl get ingressclass`). The Ingress in the
  example has no class; you set it (B3). If the cluster has none, installing one
  is the person's decision.
- A **storage class** only if the person wants the optional PostgreSQL and Redis
  examples.
- Where PostgreSQL, Redis, NATS and S3 come from (B2).
- The DNS name and a TLS certificate for it (section 2, points 3–4 apply; TLS
  terminates at the Ingress), and a second public name for the object storage (B2).

**B2. What the external services must provide**

| Service | Requirements |
|---|---|
| PostgreSQL | The extensions `pg_trgm` and `vector`, created in the application database by a privileged role before the first start (the application role cannot `CREATE EXTENSION`). Encoding UTF8 and a **non-C locale, all four fields**: provider `builtin`, builtin locale `C.UTF-8`, `lc-collate` `C.UTF-8` and `lc-ctype` `C.UTF-8`. A partial setup (a locale provider without `lc-ctype`) looks right but still breaks non-ASCII search and duplicate detection; the locale cannot be changed without a dump and restore. [DEPLOYMENT-NOTES.md](DEPLOYMENT-NOTES.md) section 1 has the reasoning, a CloudNativePG snippet and the check query; run the check of section 7 point 3 against the real database. The compose file uses PostgreSQL 18 with pgvector. Size the server so that `DATABASE_MAX_CONNS` x (replicas + 1) of skein-api fits `max_connections`. |
| Redis or Valkey | **Persistent** (append-only file or equivalent). It holds the browser sessions and the cookie-encryption keys of skein-web; a Redis that starts empty signs everybody out. Losing it loses no business data. The bundled Compose stack and the Kubernetes example ship Valkey, which is what we test with; Redis works too. Any other Redis-compatible server needs the `redis://` URL form and persistence, without a guarantee. |
| NATS | NATS Core, one node is enough. No JetStream, no volume. It carries change notifications; durability is in PostgreSQL. Restrict who can connect. |
| Object storage | An S3-compatible service reachable by the pods **and by the people's browsers**: the browser uploads and downloads directly with presigned links. It must support **path-style** addressing, presigned POST and GET, and CORS on the bucket. `S3_PUBLIC_URL` must be an address the browser can open and must be `https` when the UI is. The service in front of it (ingress, load balancer) must pass the `Host` header unchanged, because the signature covers it, and must accept request bodies up to `SKEIN_ATTACHMENT_MAX_SIZE_BYTES` (500 MB by default) without buffering them to a small limit. skein-api sets the bucket CORS rule itself at start from `S3_CORS_ALLOWED_ORIGINS` (in Compose the default is the public address; in the Kubernetes example the ConfigMap sets it), so its key needs the right to do that, or you set the rule by hand and set the variable empty. Create the bucket and give the key read and write on it, or give the key the right to create it; if `S3_URL` is set and the store is unreachable or the key is wrong, skein-api exits at start. The variables are listed in the skein-api reference and explained in group F below. Garage is the single-node store the Compose installation bundles and tests; any service that meets the points above will do. |

**B3. Put the answers in the files**

Work on a copy of `deploy/kubernetes/` kept in the person's own repository.

1. `kustomization.yaml`: set the three `newTag` values to `skein-X.Y.Z` of the
   chosen release (the tags are the same as in Target A).
2. `configmap.yaml`: the public address (`SKEIN_AGENT_PUBLIC_URL`,
   `SKEIN_APP_BASE_URL`), `SKEIN_AUTH_MODE`, `S3_URL`, `S3_PUBLIC_URL`,
   `S3_BUCKET`, `S3_CORS_ALLOWED_ORIGINS` (the public address; remove the line
   if you set the bucket's CORS rule yourself), `NATS_URL`, `SKEIN_TRUSTED_PROXIES` (B5). Any other variable of
   the three references goes in as a new key of the ConfigMap of that service;
   the same rules apply as in Target A (no empty values to mean "off"). Settings
   that carry a secret (SMTP password, OIDC client secret, VAPID private key,
   Ollama API key) go into `skein-secrets` and are referenced from the Deployment
   by an additional `secretKeyRef` entry.
3. `secret.template.yaml` -> your `secret.yaml` with real values (section 5), or
   the same Secret `skein-secrets` created from the person's secret manager. Do
   not commit the filled file.
4. `ingress.yaml`: host name, TLS secret, `ingressClassName`. The annotations are
   for ingress-nginx; with another controller, configure the equivalent settings
   in its own terms (comments in the file say what each one is for).
5. `skein-web.yaml`: `replicas`, see B5.

**B4. Apply**

```bash
kubectl create namespace <namespace>
# only if you use the optional examples:
kubectl -n <namespace> apply -f optional-dependencies/secret.yaml
kubectl -n <namespace> apply -k optional-dependencies
kubectl -n <namespace> apply -f secret.yaml
kubectl -n <namespace> apply -k .
kubectl -n <namespace> rollout status deployment/skein-api deployment/skein-web deployment/skein-frontend
```

The first start of skein-api applies all database migrations before it opens its
port (a startup probe allows up to 10 minutes); skein-web waits for it. Several
skein-api replicas starting together are safe: migrations run under a database
advisory lock, so one applies them and the others see nothing to do.

**B5. TLS, the client address, and replicas**

- **TLS** terminates at the Ingress. The controller must send `X-Forwarded-Proto`
  (all common ones do). skein-web uses it for the `Secure` flag of the session
  cookie and the sign-in redirect.
- **`SKEIN_TRUSTED_PROXIES`** lists the peers whose `X-Forwarded-*` headers
  skein-web may trust. With the example routing, the peer of skein-web is the
  ingress controller pod, so list the **pod network** of the cluster
  (the per-node ranges from `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'` lie inside it, or read it from the CNI or cloud settings;
  `10.244.0.0/16` in the example is a common default, not a fact about their
  cluster). Do not leave it empty: that switches off every per-IP limit (login
  throttle and the limits on the public account routes). Because the range is
  the whole pod network, any pod in it could forge the headers: ask the person
  to allow connections to skein-web only from the ingress controller and
  skein-frontend with a NetworkPolicy (needs a CNI that enforces them).
  **Known limit:** the per-IP limits see the real visitor only if the ingress
  controller itself sees the visitor's address. Behind a cloud load balancer
  that hides it (source NAT, or no PROXY protocol or `externalTrafficPolicy:
  Local`) the controller, and so skein-web, sees the balancer, and all visitors
  count together. Warn the person if they are exposed to brute-force (guessing)
  attacks.
- **Replicas of skein-web and `/hub`.** The SignalR hub keeps each connection in
  the memory of the pod that answered its negotiation, so with more than one
  skein-web replica the browser must reach the same pod for the negotiation and
  the WebSocket upgrade. The example therefore runs **one** skein-web
  replica. To run more, the Ingress must pin `/hub` to a pod by cookie: the
  example does that on ingress-nginx (the `skein-hub` Ingress), and other
  controllers need their own equivalent. Without it some of the upgrade requests get a
  404 and the live feed breaks (measured: 8 of 12 on two replicas). The
  same limit applies if the person routes `/hub` through skein-frontend instead
  of straight to skein-web. skein-api and skein-frontend scale freely.
- **First start of an empty database.** Several skein-api replicas starting
  at once are safe for the migrations (advisory lock), but the creation of the
  first administrator can collide: one replica may exit once with
  `admin bootstrap failed ... SQLSTATE 40001` and is restarted by Kubernetes
  (seen once with two replicas). It recovers by itself; to avoid the noise start
  with `kubectl scale deployment/skein-api --replicas=1` and scale up after the
  first sign-in.

**B6. Shutdown window**

The three Deployments set `terminationGracePeriodSeconds` explicitly, with the
arithmetic in a comment: a `preStop` sleep (so that the Ingress stops sending
before the process stops accepting), plus the drain timeout of the service,
plus a margin. skein-api drains for up to 25 s and then tears down NATS and its
background workers for up to 10 s more; skein-web is an ASP.NET Core host with
its default 30 s shutdown timeout. The window must be longer than that sum or the
kubelet kills the process in the middle of its own drain. Do not shorten it, and
re-check it if a later release changes those timeouts (the release notes will say so).
Streams still open when the window ends (MCP, the live feed) are cut, and the
clients reconnect; the window protects requests, not hour-long streams.

**B7. Verify and upgrade**

Run section 7 with `kubectl -n <namespace> exec deploy/skein-api -- curl ...`
for the internal checks and the public address for the rest. The Ingress must
send `/agent/v1` to skein-web (check 7).

Upgrades: change the three `newTag` values and apply. Ordinary releases are a
rolling update (`maxUnavailable: 0`). A release whose notes demand stopping skein-api and
skein-web first is a stop-all: scale both and skein-frontend to zero, wait until
no pod is `Running` or `Terminating`, then bring skein-api up with one replica,
and the rest after it ([DEPLOYMENT-NOTES.md](DEPLOYMENT-NOTES.md) section 2). If
a GitOps controller reconciles these manifests, suspend it (and any image
automation) first, or it undoes the scaling. Back up PostgreSQL and the bucket
with the tools of the services that host them; Redis needs no backup.

---

## 2. Access to the server

Keep this short; you need facts, not a tour.

1. **Ask where Skein will run** and how you reach it: SSH host, port and user
   (key-based login), or whether you are already running on that machine. Ask
   whether you may use `sudo`.
2. **Check the host:**
   - `uname -m` → `x86_64` or `aarch64`; `cat /etc/os-release`.
   - `docker version` and `docker compose version` (the Compose v2 plugin, not
     the old `docker-compose`; the compose file needs v2.23.1 or newer). Missing → offer to install Docker Engine with
     the Compose plugin from Docker's official repository for that OS; install
     only after the person agrees.
   - `df -h` on the Docker data directory. Postgres and attachments grow with
     use; tell the person what is free and ask whether that is enough for them.
   - Free ports: `ss -ltnp`. You need 80/443 if you set up the TLS proxy, plus
     the host port the compose file publishes for skein-frontend: by default
     `127.0.0.1:8080` (`SKEIN_BIND_ADDRESS`, `SKEIN_HTTP_PORT`) — reachable from
     the host only, which is what a TLS proxy on the same host needs. With the
     bundled store (any of the three), `127.0.0.1:3900` is published too
     (`SKEIN_S3_BIND_ADDRESS`, `SKEIN_S3_PORT`). Nothing else is published; no
     store has its console published.
3. **Domain and DNS.** Ask for the hostname Skein will live at (for example
   `skein.example.com`). Check that it resolves to this server
   (`dig +short <host>`). If it does not, tell the person which `A`/`AAAA`
   record to create and wait until it resolves.
4. **TLS.** skein-frontend speaks plain HTTP; someone must terminate HTTPS in
   front of it. Ask which applies:
   - **They already have a reverse proxy** (nginx, Caddy, Traefik, a load
     balancer). Then they (or you, with permission) add a site that forwards
     to skein-frontend's published port, with WebSocket upgrade allowed
     (`/hub` is SignalR) and without response buffering for `/mcp` (streamed
     responses). Pass the original `Host` header through.
   - **Nothing yet.** Offer to set one up on this host (Caddy is the shortest
     path to an automatic certificate). Get a yes first: it binds 80/443.
   - HTTPS is required for a real installation: with the default
     `ENVIRONMENT=production`, skein-api refuses to start unless
     `SKEIN_AGENT_PUBLIC_URL` is `https`.
5. If attachments will use a **bundled store**, the browser must reach the store
   directly (section 3, group F) — usually a second hostname such as
   `files.example.com` through the same TLS proxy. Settle DNS for it now.

---

## 3. Interview the person

This is the central part. Ask in **groups**, one group per message, so the
person is not flooded. In each group: ask, explain the options in plain words,
give your recommendation, and note which variables the answer sets. Write the
answers down in a working note (keep secrets out of the chat history).

If the person says "just use the defaults", the recommended answers below form a
working small-team installation: local passwords, one administrator, no
self-registration, bundled Garage (the default store), no mail, no semantic search. Still ask
group A and the administrator's email — those have no default.

### Group A — address

**A1. What is the public address of Skein?**
Explain: this is the URL people type into the browser and agents use for MCP.
One origin serves the UI, the API, live updates and `/mcp`.

- Sets `SKEIN_AGENT_PUBLIC_URL` = `https://<host>` (required by skein-api;
  absolute, `https` in production; handed to agents in task-monitor commands).
- Sets `SKEIN_APP_BASE_URL` = `https://<host>` (where links in emails and push
  notifications point; required when mail is on, recommended always).
  A path is allowed if Skein is served under one (`https://example.com/skein`).
- `SKEIN_MCP_URL` (skein-web) stays **unset**: the UI then shows
  `<origin>/mcp`, which is correct when MCP is served from the same host.

**A2. Who terminates TLS?** — settled in section 2. It also decides
`SKEIN_TRUSTED_PROXIES` (skein-web): the addresses whose `X-Forwarded-*` headers
skein-web may trust. Empty is fail-closed: it works, but every per-IP limit
(login throttle, limits on sign-up and password-reset routes) is silently off.
In `docker-compose.production.yml` the default is the subnet of the compose
network (`SKEIN_NETWORK_SUBNET`, `172.29.88.0/24` unless you changed it). That is
right when skein-frontend is the only thing in front of skein-web: it is the one
peer skein-web talks to. Do not add the address of your TLS proxy on the host;
it is not a peer of skein-web. Your TLS proxy must set `X-Forwarded-Proto` to
the scheme the visitor used (`https`) and must overwrite, not pass on, any value
the visitor sent; skein-frontend forwards it to skein-web, which uses it for the
`Secure` flag of the session cookie and for the sign-in redirect.

Known limit: with a TLS proxy in front of skein-frontend, skein-web sees the
proxy's address as the visitor's address, so the per-IP limits count all visitors
together. Warn the person if they expect to be exposed to brute-force (guessing)
attacks.

Hard to change later? The hostname is **hard** to change: it is in every
emailed link and invitation already sent and in every agent's MCP config.

### Group B — how people sign in

**B1. Which login mode?** (`SKEIN_AUTH_MODE` on skein-api; skein-web reads it
from skein-api at startup and has no setting of its own.)

| Mode | What it means | Who it suits | Needs |
|---|---|---|---|
| `local` (**recommended default**) | Email + password stored in Skein (bcrypt). | Small teams, anyone without a company identity provider. | Nothing extra. |
| `keycloak` | Single sign-on only. People log in through the company identity provider; the password form is off (`/auth/login` answers 410). | Organisations that already run Keycloak (or an OIDC provider set up for it) and want one account per person. | An OIDC client for Skein (B2). |
| `hybrid` | SSO for internal staff **and** password login for accounts marked external (outside collaborators), at the same time. | Companies with SSO that also invite outsiders. | Everything `keycloak` needs. |

AI agents authenticate with per-user API keys (`ska_…`) in every mode.

**B2. Only for `keycloak` / `hybrid`.** Ask for, and explain:

- The issuer URL of the realm → `Authentication__Oidc__Authority` (skein-web),
  e.g. `https://id.example.com/realms/skein`. It must be `https://`. The
  certificate of the identity provider must be trusted by the container: a
  provider behind a private CA is not supported yet, because Skein has no
  setting to trust an extra CA (the same holds for an SMTP server with a
  private CA, group E). With it set, skein-web runs the
  OIDC login itself. (Without it, skein-web expects an `oauth2-proxy` in front
  that passes trusted identity headers — a legacy setup; do not choose it for a
  new installation unless the person already runs one.)
- Client id and client secret → `Authentication__Oidc__ClientId`,
  `Authentication__Oidc__ClientSecret`. Both required in this mode.
- The group a user must be in → `Authentication__Oidc__AllowedGroup` (default
  `skein-users`); the token's `groups` claim must carry it, or the user gets 403.
  Skein asks the provider for the scope `groups`, so the client must have a
  client scope `groups` with a group-membership mapper that has **Add to ID
  token** on (in Keycloak: Client scopes → create `groups` → mapper type
  "Group Membership" → assign the scope to the client). Without the scope the
  provider answers `invalid_scope` and nobody can sign in.
- Tell them to register these on the client: redirect URI
  `https://<host>/api/auth/oidc-callback` and post-logout redirect URI
  `https://<host>/api/auth/oidc-signout-callback` (the defaults of
  `Authentication__Oidc__CallbackPath` / `SignedOutCallbackPath`).
- **Create users automatically on first SSO login?** →
  `SKEIN_AUTO_PROVISION` (default `false`: unknown users get 403 until an admin
  creates them). Recommend `true` for a fresh installation. New users get
  `SKEIN_OIDC_DEFAULT_ROLE` (`user` by default — keep it).
- **Optional:** whether agents should discover the IdP via OAuth metadata →
  `SKEIN_OAUTH_AUTHORIZATION_SERVERS` (issuer URL list). Unset = discovery off;
  MCP with `ska_` keys works either way. Recommend leaving it unset.

Changing the mode later is possible but requires restarting **both** skein-api
and skein-web: after editing `.env`, `docker compose … up -d` recreates only
skein-api, so also run `docker compose … restart skein-web`, otherwise it keeps
the old mode. Switching an installation full of password users to SSO needs
planning. Treat it as hard to change.

### Group C — the first administrator

Explain: on a brand-new database there are no users. Someone has to become the
first administrator, and **skein-api refuses to start if no such path exists**
(with the default settings it needs an owner for the common space; the error
reads `contradictory settings (…): …` and names the variables).

Paths, by login mode:

- **`local` / `hybrid` — bootstrap account (recommended).** Ask for the admin's
  email, and optionally username and display name:
  `SKEIN_INITIAL_ADMIN_EMAIL`, `SKEIN_INITIAL_ADMIN_USERNAME` (default: the
  part of the email before `@`), `SKEIN_INITIAL_ADMIN_NAME` (default: the
  username). **You generate the password** (`SKEIN_INITIAL_ADMIN_PASSWORD`,
  section 5) and hand it over at the end. It is used only while the users table
  is empty; afterwards these variables do nothing.
- **`keycloak` (or `hybrid`) — first SSO login becomes admin.** With
  `SKEIN_AUTO_PROVISION=true`, set `SKEIN_BOOTSTRAP_ADMIN_EMAIL` to the email
  the admin has in the identity provider; that account is made admin on its
  first SSO login.
- **Break-glass (SSO modes, optional).** `SKEIN_BREAKGLASS_ADMIN` lets one admin
  email log in with a password while SSO is on — an escape hatch if the IdP is
  misconfigured. Together with the bootstrap account (same email in both) it
  gives you an admin who can sign in with a password in `keycloak` mode. Warn: it permanently leaves a
  password login open; recommend removing it once SSO works.

### Group D — who may join, and how the installation is organised

Explain the model first: Skein organises work in **spaces** (each with its own
members and projects). Every user has a personal space; there can be a
**common space** everyone joins. These settings decide whether this is a
company installation or an open service. Skein ships two presets; the defaults
of every variable are the **company** preset, and that is the recommendation.

| Question | Company (default, recommended) | Open service |
|---|---|---|
| Is there an instance administrator who sees everything? `SKEIN_INSTANCE_ADMIN_ENABLED` | `true` | `false` |
| Do users created by an admin or by SSO join a common space? `SKEIN_COMMON_SPACE_ENABLED` | `true` | `false` |
| Can anyone register themselves? `SKEIN_SIGNUP_ENABLED` | `false` | `true` (needs mail **and** `local` mode) |
| Who may create new spaces? `SKEIN_SPACE_CREATION` (`all`/`admin`/`none`) | `all` | `all` |
| Who sees a new project? `SKEIN_PROJECT_DEFAULT_VISIBILITY` | `members` (project members only) | `space` (everyone in the space) |

Ask only the questions that matter to the person: "Is this for your own
team/company, or a public service where strangers sign up?" For a company
installation, keep all defaults and move on.

Explain the consequence of `SKEIN_INSTANCE_ADMIN_ENABLED=false`: no one can
ever hold the admin role, all `SKEIN_INITIAL_ADMIN_*`, `SKEIN_BOOTSTRAP_ADMIN_EMAIL`
and `SKEIN_BREAKGLASS_ADMIN` must be unset, and **an installation that already
has admins cannot be switched to `false`** — that is a new installation. This is
the hardest-to-reverse decision in the whole interview.

Only for an open service, also ask about limits (unset = no limit):
`SKEIN_SPACE_MEMBER_LIMIT`, `SKEIN_SPACE_OWNED_LIMIT`,
`SKEIN_SPACE_INVITES_PER_DAY`, `SKEIN_QUOTA_PERSONAL_PROJECTS`,
`SKEIN_QUOTA_PERSONAL_STORAGE_BYTES`, `SKEIN_QUOTA_SPACE_PROJECTS`,
`SKEIN_QUOTA_SPACE_STORAGE_BYTES`, `SKEIN_PROJECT_PREFIX_MIN_LENGTH`; a captcha
on registration (`SKEIN_TURNSTILE_SITE_KEY` + `SKEIN_TURNSTILE_SECRET`, both or
neither — Cloudflare Turnstile); links to terms and privacy policy
(`SKEIN_TERMS_URL`, `SKEIN_PRIVACY_URL`). Invitation lifetime
`SKEIN_SPACE_INVITE_TTL` defaults to `168h` (7 days) for every installation.

Do **not** enable the operator API (`SKEIN_OPERATOR_API_ENABLED`) unless the
person runs a SaaS operator tool and asks for it. If they do: it needs
`SKEIN_OPERATOR_API_KEY` (≥ 16 characters, you generate it), listens on its own
port (`SKEIN_OPERATOR_API_PORT`, default 5101), and that port must **never** be
published to the host or routed through the TLS proxy.

### Group E — outgoing mail

Explain: Skein sends email to confirm addresses, to reset passwords and to
deliver invitations. Without mail (`SKEIN_EMAIL_ENABLED=false`, the default):

- self-registration cannot be turned on;
- nobody receives a password-reset or invitation email — an admin manages
  accounts;
- with `SKEIN_INSTANCE_ADMIN_ENABLED=false`, local/hybrid login without mail is
  refused at startup.

For a small company installation, "no mail" is acceptable. To turn it on ask for
an SMTP relay (their mail provider or a transactional mail service) and set the
following (all are required once mail is on):

- `SKEIN_EMAIL_ENABLED=true`
- `SKEIN_SMTP_HOST`, `SKEIN_SMTP_PORT`
- `SKEIN_SMTP_TLS_MODE` — `implicit` (TLS from the first byte, usually port 465)
  or `starttls` (usually 587). There is no plaintext mode.
- `SKEIN_SMTP_USERNAME`, `SKEIN_SMTP_PASSWORD` (a secret: ask the person to
  paste it into a file or the `.env` themselves if they prefer not to send it
  to you)
- `SKEIN_SMTP_FROM` — e.g. `Skein <skein@example.com>`
- `SKEIN_APP_BASE_URL` — from A1.

The server must be allowed to reach the relay on that port (check the outbound
firewall; some VPS providers block 25/465/587 by default — ask the person to check).
Mail can be turned on later with a restart of skein-api.

### Group F — file storage (attachments)

Explain: attachments are stored in S3-compatible object storage. Browsers upload
and download **directly** from the storage using short-lived signed links, so
the storage endpoint must be reachable from people's browsers, not only from
the server.

| Option | What it means | Needs |
|---|---|---|
| **Bundled Garage** (the default for one server) | A Garage container in the same compose project (profile `garage`, the default of `.env.example`), data in the Docker volume `garage-data`. One node, replication factor 1: there is no second copy, so backups matter (section 8). The replication factor is fixed at the first start and **cannot be changed** afterwards. Garage has no web console. It is the official image, pinned by digest. | A public HTTPS hostname for it (e.g. `files.example.com`) proxied to the store's S3 port (`127.0.0.1:3900`), with the `Host` header passed unchanged (signed links cover the host). |
| **Bundled SeaweedFS** (alternative) | A SeaweedFS container (profile `seaweedfs`), open edition (Apache-2.0), single node (`weed mini`), data in the volume `seaweedfs-data`. The paid SeaweedFS edition is not used. Its cluster topology needs a master and 2+ volume servers; **this compose file does not ship it**, so there is still no second copy. Needs more memory than Garage: measured about 113 MiB idle and 700-860 MiB after one 500 MB upload. Only the S3 port is published. | Same as Garage: a public HTTPS hostname proxied to `127.0.0.1:3900`, `Host` unchanged. |
| **Bundled RustFS** (alternative) | A RustFS container (profile `rustfs`), single node, data in the volume `rustfs-data`. RustFS's cluster mode is not production-ready and is not shipped here. CORS is off in RustFS until skein-api sets the rule at its start (it does). Only the S3 port is published, no console. | Same as Garage. |
| **External S3** | AWS S3, or any S3-compatible service the person already has. | Endpoint URL, access key, secret key, bucket name. |
| **No attachments** | Attachments are disabled; requests to upload or download one answer 503 `attachments_unavailable`. | Nothing. |

Choose **at most one** store profile in `COMPOSE_PROFILES` (`garage`,
`seaweedfs` or `rustfs`); all three publish `SKEIN_S3_PORT`. They share the
variables below, so switching later changes the profile and `S3_URL` only. The
data does **not** move with it: each store has its own volume, and moving
attachments means copying the bucket. Recommend Garage unless the person has a
reason: it is the smallest (about 5 MiB idle) and its image the lightest.

Variables (skein-api):

- `S3_URL` — the endpoint skein-api uses (bundled: the in-network address,
  `http://garage:3900`, `http://seaweedfs:8333` or `http://rustfs:9000`). Setting it switches attachments on; leaving it out
  switches them off.
- `S3_PUBLIC_URL` — the endpoint the **browser** uses (bundled:
  `https://files.example.com`). Defaults to `S3_URL`, which is wrong for a
  bundled store because browsers cannot resolve its container name. With the UI on HTTPS
  this must be HTTPS too, or browsers block the requests.
- `S3_USE_SSL` — only matters for an endpoint written **without** a scheme
  (`host:port`). When `S3_URL` and `S3_PUBLIC_URL` carry `http://` or
  `https://`, the scheme in the URL wins and this variable is ignored. So with
  the bundled Garage (`S3_URL=http://garage:3900`,
  `S3_PUBLIC_URL=https://files.example.com`) leave it **unset**; write every
  endpoint with its scheme.
- `S3_ACCESS_KEY`, `S3_SECRET_KEY` — for a bundled store these are the key it
  is given at start; you generate them (section 5). Garage creates the key,
  RustFS takes the pair as its root user, SeaweedFS gets a user with read, list,
  write and tagging rights only (no admin); the SeaweedFS and RustFS containers
  refuse to start when either is empty. The format rules that follow are
  Garage's; keep the pair to them for every store.
  Garage takes any key id of 8 or more characters and any secret of 16 or more;
  write them with letters, digits, `.`, `_` and `-` only. Garage cannot change
  the secret of an existing key: if you later change `S3_SECRET_KEY` it refuses
  to start (with a clear error in its log). To rotate, use a new `S3_ACCESS_KEY` (the
  old key stays in Garage, unused).
- `GARAGE_RPC_SECRET` — bundled Garage only: its cluster secret, 64 hex
  characters (section 5). Empty or malformed, Garage will not start.
- `S3_BUCKET` — default `skein-attachments`; the bundled Garage and SeaweedFS
  create it at their start, and with RustFS or an external S3 skein-api creates
  it at startup if missing.
- `S3_REGION` — default `us-east-1`, which is also the region of the bundled
  Garage (RustFS is given the same value); set it only for an external S3 that insists on another region.
- `S3_CORS_ALLOWED_ORIGINS` — the browser origins skein-api sets the bucket's
  CORS rule for at startup. skein-api itself has no default: with the variable
  unset it leaves the bucket's CORS alone. The Compose file fills it with
  `SKEIN_AGENT_PUBLIC_URL` when you do not set it, and the Kubernetes example
  sets it in the ConfigMap. Garage and RustFS
  do not allow cross-origin browser requests by themselves, so uploads depend on
  this rule (SeaweedFS answers any origin by default; skein-api still sets the
  rule). The rule replaces the bucket's whole CORS configuration at every start;
  to keep a configuration you manage yourself (an external bucket), set the
  variable empty (`S3_CORS_ALLOWED_ORIGINS=`) — in Compose only an unset variable
  falls back to `SKEIN_AGENT_PUBLIC_URL`. Do not set RustFS's own `RUSTFS_CORS_ALLOWED_ORIGINS`: it does not
  expose the file name header to the browser.
  Set it only if the UI is served from a different origin.
- `SKEIN_ATTACHMENT_MAX_SIZE_BYTES` — per-file cap, default 500 MB. Ask whether
  that suits them.

If `S3_URL` is set but the storage is unreachable or the credentials are
wrong, **skein-api exits at startup** — this is the most common first-start
failure with external S3.

Moving attachments to a different storage later means copying the bucket;
treat the choice as moderately hard to change.

### Group G — semantic search (optional)

Explain: search always works by text. With an embedding model (Ollama), Skein
also finds issues by meaning and detects duplicate issues better. Without it:
full-text search only, duplicate detection uses text similarity only, nothing
else breaks.

Ask whether they have an Ollama server or want one. If yes:

- `OLLAMA_URL` — e.g. `http://ollama:11434`. Setting it switches the feature on.
- `OLLAMA_MODEL` — default `qwen3-embedding:0.6b`; the model must be pulled on
  that Ollama (`ollama pull qwen3-embedding:0.6b`). Do **not** pick a different
  model unless it outputs 1024-dimensional vectors: the database column is
  fixed at 1024, and a mismatch shows up only at the first search.
- `OLLAMA_API_KEY` — only if their Ollama sits behind token auth.

This compose file has no Ollama service: embeddings need a model server of
their own, with a model pulled and often a GPU, and the person decides where it
runs.
Can be added later at any time; the background worker fills in embeddings for
existing data.

### Group H — small extras (offer, do not push)

- **Browser push notifications** — `SKEIN_VAPID_PUBLIC` + `SKEIN_VAPID_PRIVATE`
  (both or neither; you generate the pair, section 5) and `SKEIN_VAPID_SUBJECT`
  (`mailto:<real contact>` or an `https:` URL). Without them the UI hides the
  push option. Recommend turning it on.
- **Checking new passwords against known leaks** (Have I Been Pwned range API) —
  `SKEIN_PWNED_PASSWORDS_ENABLED=true`. Off by default because it calls a third
  party on each password change; ask whether the server may do that.
- **Instance name in monitoring** — `SKEIN_INSTANCE_NAME` (default `skein`),
  useful if several installations report to one Prometheus/Loki.

### What is easy and what is hard to change later

Tell the person this at the end of the interview:

| Easy (edit `.env`, restart) | Needs care | Effectively permanent |
|---|---|---|
| mail, semantic search, push, leaked-password check, limits and quotas, registration on/off, captcha, terms links | login mode (restart both services; user migration), storage backend (copy data), project default visibility (affects only new projects) | the hostname (in links and agent configs), `SKEIN_INSTANCE_ADMIN_ENABLED=false` (cannot be turned off once admins exist), the first admin path (used once) |

---

## 4. Validate the answers before writing `.env`

skein-api refuses to start on contradictory settings and names the variables.
Catch them yourself first. The full list is the table
"Contradictory settings refuse startup" in the
[skein-api reference](https://github.com/tryskein/skein-api/blob/main/docs/env-reference.md);
check every row against the answers. The ones that matter in practice:

1. `SKEIN_SIGNUP_ENABLED=true` requires `SKEIN_EMAIL_ENABLED=true` **and**
   `SKEIN_AUTH_MODE=local`.
2. `SKEIN_INSTANCE_ADMIN_ENABLED=false` forbids every `SKEIN_INITIAL_ADMIN_*`,
   `SKEIN_BOOTSTRAP_ADMIN_EMAIL`, `SKEIN_BREAKGLASS_ADMIN`,
   `SKEIN_OIDC_DEFAULT_ROLE=admin` and `SKEIN_SPACE_CREATION=admin`.
3. `SKEIN_INSTANCE_ADMIN_ENABLED=false` with `local`/`hybrid` requires mail.
4. **A path to the first admin.** With `SKEIN_COMMON_SPACE_ENABLED=true` (the
   default) on a fresh database, one of these must hold, or startup is refused
   after migrations:
   - `SKEIN_INITIAL_ADMIN_EMAIL` (+ password) is set; or
   - `keycloak`/`hybrid` with `SKEIN_AUTO_PROVISION=true` and
     `SKEIN_BOOTSTRAP_ADMIN_EMAIL` set (or `SKEIN_OIDC_DEFAULT_ROLE=admin`).
5. With `SKEIN_INSTANCE_ADMIN_ENABLED=false` and no users: `local` needs
   sign-up on; `keycloak` needs `SKEIN_AUTO_PROVISION=true` — otherwise nobody
   can ever get in.
6. `SKEIN_INITIAL_ADMIN_EMAIL` without `SKEIN_INITIAL_ADMIN_PASSWORD` aborts startup.
7. Pairs that must be both-or-neither: VAPID keys; Turnstile keys.
8. `SKEIN_EMAIL_ENABLED=true` requires every `SKEIN_SMTP_*` and
   `SKEIN_APP_BASE_URL`.
9. `SKEIN_AGENT_PUBLIC_URL` must be an absolute URL, `https` while
   `ENVIRONMENT=production` (the default). Do not change `ENVIRONMENT` to get
   around this on a real installation; any value other than `production` also
   switches off the other HTTPS checks.
10. `SKEIN_INTERNAL_SECRET` must be identical for skein-api and skein-web and
    at least 16 characters.

If an answer creates a contradiction, go back to the person, explain which two
answers clash and why, and let them choose.

---

## 5. Generate secrets

You generate these yourself. Never ask the person to invent them, never show
them in chat, never put them on a command line that is echoed back. Generate
them **directly into `.env`** (section 6) on the server.

| Value | Variable(s) | How |
|---|---|---|
| internal secret web → api | `SKEIN_INTERNAL_SECRET` (both services) | `openssl rand -hex 32` |
| Postgres password | `POSTGRES_PASSWORD` — the database user's password; the compose file builds `DATABASE_URL` from it | `openssl rand -hex 24` (hex: no characters that need escaping in a URL) |
| first admin password | `SKEIN_INITIAL_ADMIN_PASSWORD` | `openssl rand -base64 18` |
| S3 access key / secret (bundled store) | `S3_ACCESS_KEY` / `S3_SECRET_KEY` — the key skein-api signs with; the bundled store is given the same key | `openssl rand -hex 12` / `openssl rand -hex 32` |
| Garage cluster secret (bundled Garage only) | `GARAGE_RPC_SECRET` — exactly 64 hex characters | `openssl rand -hex 32` |
| VAPID key pair (if push is on) | `SKEIN_VAPID_PRIVATE`, `SKEIN_VAPID_PUBLIC` | see below |
| operator API key (only if enabled) | `SKEIN_OPERATOR_API_KEY` | `openssl rand -hex 32` |

VAPID pair (base64url, no padding — the format skein-api expects):

```bash
umask 077
openssl ecparam -name prime256v1 -genkey -noout -out vapid.pem
VAPID_PRIVATE=$(openssl ec -in vapid.pem -outform DER 2>/dev/null | tail -c +8 | head -c 32 | base64 | tr -d '=\n' | tr '/+' '_-')
VAPID_PUBLIC=$(openssl ec -in vapid.pem -pubout -outform DER 2>/dev/null | tail -c 65 | base64 | tr -d '=\n' | tr '/+' '_-')
rm -f vapid.pem
# write both into .env; the private key is 43 characters, the public one starts with "B"
```

Secrets the person supplies (SMTP password, OIDC client secret, external S3
keys) go into `.env` the same way. If they would rather not send them to you,
tell them the exact `.env` lines to fill in themselves.

---

## 6. Write `.env` and start

1. **Create the install directory** (ask where; `/opt/skein` is a reasonable
   suggestion) and download `docker-compose.production.yml` and `.env.example`
   of the chosen Skein release — the two files in the root of
   <https://github.com/tryskein/skein> at the release tag (for example
   `https://raw.githubusercontent.com/tryskein/skein/<tag>/docker-compose.production.yml`).
2. **Pick the release.** Ask whether to install the latest Skein release (the
   default) and set `SKEIN_VERSION=X.Y.Z` — the compose file then runs
   `ghcr.io/tryskein/<service>:skein-${SKEIN_VERSION}` for all three services.
3. **Copy `.env.example` to `.env`, then `chmod 600 .env`.** Fill it from the
   interview and section 5. Only add variables that are in the references; keep
   the defaults by leaving a variable out.
   The compose file lists, per service, every variable it passes through; a
   variable it does not list has no effect. To use one that is in a reference
   but not in the file, add a line `NAME:` under that service's `environment:`
   in the compose file: it is then taken from `.env` when present and left
   unset when not.
   A typical small-company `.env`:

   ```dotenv
   SKEIN_VERSION=X.Y.Z

   # bundled store on (the default of .env.example): garage, seaweedfs or rustfs;
   # remove the line for external S3
   COMPOSE_PROFILES=garage

   # address
   SKEIN_AGENT_PUBLIC_URL=https://skein.example.com
   SKEIN_APP_BASE_URL=https://skein.example.com
   # SKEIN_TRUSTED_PROXIES stays unset: the compose default is right (A2)

   # database password and internal channel (same secret for skein-api and skein-web)
   POSTGRES_PASSWORD=<generated>
   SKEIN_INTERNAL_SECRET=<generated>

   # sign-in and first admin
   SKEIN_AUTH_MODE=local
   SKEIN_INITIAL_ADMIN_EMAIL=alice@example.com
   SKEIN_INITIAL_ADMIN_PASSWORD=<generated>

   # attachments (bundled Garage; for seaweedfs: S3_URL=http://seaweedfs:8333,
   # for rustfs: S3_URL=http://rustfs:9000, and no GARAGE_RPC_SECRET)
   S3_URL=http://garage:3900
   S3_PUBLIC_URL=https://files.example.com
   S3_ACCESS_KEY=<generated>
   S3_SECRET_KEY=<generated>
   GARAGE_RPC_SECRET=<generated>

   # push
   SKEIN_VAPID_PUBLIC=<generated>
   SKEIN_VAPID_PRIVATE=<generated>
   SKEIN_VAPID_SUBJECT=mailto:alice@example.com
   ```

   `DATABASE_URL`, `REDIS_URL`, `NATS_URL` and `SKEIN_API_URL` are fixed in the
   compose file and point at the containers of the same compose project. Do not
   put them in `.env`; `DATABASE_URL` is built from `POSTGRES_PASSWORD`.
4. **Validate the file:** `docker compose -f docker-compose.production.yml config -q`
   (syntax and interpolation). Then re-run the checklist of section 4 against
   the actual `.env`.
5. **Pull and start:**

   ```bash
   docker compose -f docker-compose.production.yml pull
   docker compose -f docker-compose.production.yml up -d
   ```

6. **Wait for health.** `docker compose -f docker-compose.production.yml ps`
   until every service is `healthy` (or `running` for services without a
   healthcheck). The first start of skein-api applies all
   database migrations before it opens its port, so it takes longer than later
   starts. skein-web waits for skein-api (up to
   `SKEIN_API_STARTUP_TIMEOUT_SECONDS`, default 60) and exits if it gets no
   answer — if skein-api was slow, skein-web may exit and be started again by Docker's restart policy; that alone is not a failure.
7. **Set up the TLS proxy** (section 2) if not done yet, and reload it.

---

## 7. Verify

Run these checks and report each result to the person in one line.
The service names below are those of the compose file: `skein-api`, `skein-web`,
`skein-frontend`, `postgres`, `redis`, `nats` and, with the profile, `garage`, `seaweedfs` or `rustfs`.

1. **Internal readiness:**

   ```bash
   docker compose -f docker-compose.production.yml exec skein-api curl -fsS http://localhost:5100/ready
   docker compose -f docker-compose.production.yml exec skein-web curl -fsS http://localhost:8080/ready
   ```

   skein-api `/ready` checks the database (and the object storage when
   attachments are on); skein-web `/ready` checks Redis. Both answer
   `{"status":"ready"}`.
2. **Through the public edge:** `curl -fsS https://<host>/healthz` → `ok`;
   `curl -fsS https://<host>/version.json` shows the frontend version.
3. **Database locale.** Non-ASCII search and duplicate detection silently break
   on a `C` locale:

   ```bash
   docker compose -f docker-compose.production.yml exec postgres \
     psql -U skein -d skein -c "SELECT datlocprovider, datlocale, datcollate, datctype FROM pg_database WHERE datname = current_database();"
   ```

   Expected `b | C.UTF-8 | C.UTF-8 | C.UTF-8`. Anything with `C` or `POSIX` in
   the last two columns: stop and tell the person — the database must be
   recreated with the right locale before real data goes in (it is set only
   when the volume is first initialised).
4. **Log in** at `https://<host>` as the first admin (or via SSO with the
   bootstrap email). Check that the admin functions are available to this account.
5. **Smoke test:** create a project (in the UI it lands in a space you pick; over
   the API a user who belongs to more than one space must send `spaceId`,
   otherwise the answer is `422 space_required` — the admin of a default
   installation has a personal and a common space), create an issue in it, open it in a second
   browser tab and add a comment — the other tab should update without reload
   (that proves NATS → skein-web → browser). If attachments are on, upload a
   small file and download it again. Archive the test project afterwards (Skein
   archives projects; it does not delete them), or ask the person whether to
   keep it.
6. **MCP:** in the UI, create an API key (settings → API keys; the page shows a
   ready-made `.mcp.json` snippet). Then:

   ```bash
   curl -sS https://<host>/mcp \
     -H "X-Skein-Api-Key: $KEY" -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"install-check","version":"0"}}}'
   ```

   A JSON-RPC result naming the server means MCP works. Revoke this test key
   afterwards unless the person wants to keep it.
7. **Task monitors (agent API).** Agents' task monitors call
   `<SKEIN_AGENT_PUBLIC_URL>/agent/v1/…`. Check that this path reaches Skein and
   not the web UI: `curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' https://<host>/agent/v1/monitor-script`
   must **not** answer `200 text/html`. If it does, task monitors will not
   work on this installation; tell the person (everything else is unaffected).
   The skein-frontend image forwards `/agent/v1` to skein-web. If your own proxy
   sends only some paths to skein-frontend, send `/agent/v1/` there too.
8. **SSO only:** log out and in again; confirm the browser was sent to the IdP
   with an `https://<host>/api/auth/oidc-callback` redirect URI.

### If something fails

- **Logs:** `docker compose -f docker-compose.production.yml logs --tail=200 <service>`.
  skein-api errors are JSON lines; contradictions read
  `contradictory settings (VAR, VAR, …): <reason>`.
- **skein-api exits at start** — read the last lines. Common causes:
  - `required environment variable "NAME" is not set` — a required variable is
    missing (`DATABASE_URL`, `SKEIN_INTERNAL_SECRET`, `SKEIN_AGENT_PUBLIC_URL`).
  - `skein_internal_secret must be at least 16 characters`.
  - `skein_agent_public_url must be an absolute http(s) URL`, or an `http` URL
    under `ENVIRONMENT=production`.
  - `contradictory settings (…)` — go back to section 4; for "no path to the
    first admin", add the bootstrap admin (group C).
  - S3 errors — wrong endpoint, keys or TLS setting (group F). With the bundled
    store, read its own log (`docker compose … logs garage`, `… logs seaweedfs`
    or `… logs rustfs`): with Garage a short or malformed key, or a key that
    exists with another secret, is reported there; SeaweedFS and RustFS print
    `S3_ACCESS_KEY and S3_SECRET_KEY must be set in .env` when either is empty.
  - mail settings missing while `SKEIN_EMAIL_ENABLED=true` — the message names
    every missing variable.
  Refusals detected **after** migrations leave the schema already migrated: fix
  the settings and start again; do not try to roll the database back.
- **skein-web exits at start** — `<NAME> is not set` (missing `SKEIN_API_URL`,
  `SKEIN_INTERNAL_SECRET`, `REDIS_URL`, `NATS_URL`); a 401 from skein-api means
  the two `SKEIN_INTERNAL_SECRET` values differ; a timeout means skein-api is
  not up — fix skein-api first.
- **UI loads but login fails** — check skein-web logs; in SSO modes check the
  client id/secret, redirect URIs and the `groups` claim.
- **Uploads fail in the browser** — open the browser's network tab: the upload
  goes to `S3_PUBLIC_URL`. It must resolve publicly, be HTTPS when the UI is
  HTTPS, and the proxy must keep the `Host` header. A CORS error there means the
  bucket rule is missing: check `S3_CORS_ALLOWED_ORIGINS` and the skein-api log
  line `s3 bucket cors set`.
- **No live updates** — NATS is down or unreachable; nothing is lost, updates
  resume when it is back.

Do not "fix" a refusal by deleting volumes. Deleting the Postgres volume
deletes all data; do it only on a fresh installation with nothing in it, and
only after the person agrees.

---

## 8. Hand-over

Tell the person, in one short message:

1. **The address:** `https://<host>` (and the MCP endpoint `https://<host>/mcp`).
2. **The admin account:** the email, and the generated password — delivered
   the way the person chooses (not pasted into a shared channel). Ask them to
   change the password after the first login. After that, remove
   `SKEIN_INITIAL_ADMIN_PASSWORD` **and** `SKEIN_INITIAL_ADMIN_EMAIL` from `.env`
   (remove both: with the email left and the password gone, skein-api refuses to
   start, see section 4, rule 6). They are used only on an empty database and serve no
   purpose afterwards. If `SKEIN_BREAKGLASS_ADMIN` is
   set, remind them to remove it once SSO works.
3. **Where the configuration lives:** `<install dir>/.env` and
   `docker-compose.production.yml`. `.env` **holds every secret of the
   installation**: keep it `chmod 600`, never commit it, back it up
   somewhere safe.
4. **How agents connect:** each person creates their own API key in the UI and
   pastes the `.mcp.json` snippet the page shows.
5. **How to upgrade:**
   - read the release notes of the new Skein release first — always, and
     especially before a new **major** version: some releases require stopping
     all of skein-api and skein-web before the new version starts, or a backup
     because a migration cannot be undone;
   - back up (below);
   - set the new `SKEIN_VERSION` in `.env` (and apply any `.env` changes the
     release notes list), then `docker compose … pull` and `docker compose … up -d`;
   - migrations run automatically when skein-api starts; never run two
     versions of skein-api against the same database at once;
   - a failed upgrade is fixed forward or by restoring the backup — rolling the
     image back does not roll the database back.
6. **Backups** (offer to set up a nightly job):
   - PostgreSQL: `docker compose … exec -T postgres pg_dump -U skein -Fc skein > skein-$(date +%F).dump`;
   - attachments: the volume of the bundled store (`garage-data`, `seaweedfs-data`
     or `rustfs-data`; stop the store first for a consistent copy; or a bucket
     copy with an S3 client). The files in the volume belong to root, so copy
     them from a container, not with a plain `tar` on the host, e.g. for Garage:
     `docker compose … stop garage`, then
     `docker run --rm -v <project>_garage-data:/data:ro alpine tar czf - -C /data . > garage-$(date +%F).tar.gz`,
     then `docker compose … start garage`. With a bundled store this is the only copy, because
     it runs one node with no replica. The SeaweedFS volume also holds keys
     SeaweedFS generated for itself: back it up as a whole;
     or the external S3 provider's own versioning/backups;
   - `.env` itself (secrets — store encrypted);
   - Redis holds only sessions and cookie keys: losing it logs everyone out but
     loses no data. Its volume `redis-data` keeps an append-only file, so a plain
     restart does not sign anyone out; it needs no backup.
   - Volume names are the compose project name plus `_postgres-data`,
     `_garage-data` (or `_seaweedfs-data`, `_rustfs-data`), `_redis-data` (project `skein` by default; list them with
     `docker volume ls`).
   - **Restore** (into an empty installation of the same `SKEIN_VERSION`, with
     the saved `.env`): start only PostgreSQL
     (`docker compose … up -d postgres`); load the dump into the **empty**
     application database before skein-api has ever started
     (`docker compose … exec -T postgres pg_restore -U skein -d skein --no-owner < skein-DATE.dump`);
     put the storage volume back (`docker run --rm -i -v <project>_garage-data:/data alpine tar xzf - -C /data < garage-DATE.tar.gz`
     with the store stopped); then `docker compose … up -d`. Everyone is signed
     out, because Redis is not backed up. Run the checks of section 7 afterwards.
   - A backup is real only after a test restore; suggest doing one.
7. **Logs:** `docker compose … logs <service>`.

Finally, note anything you could not verify (for example task monitors in check
7, or a skipped smoke step) and what the person should do about it.
