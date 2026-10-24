# Deployment notes

The non-obvious parts of installing and releasing Skein, the ones an operator
would not guess: short entries with verified facts.

Entry format: **what is required** → **why** → **how to check/do it**.

---

## 1. PostgreSQL locale and encoding

**Required:** encoding `UTF8`; database locale — **anything except `C` and `POSIX`**.

**Recommendation (the same for everyone, whatever language your organisation uses):**

| PostgreSQL version | What to set |
|---|---|
| 17+ | **`pg_c_utf8`** — builtin provider |
| 16 and below | any UTF-8 locale, for example `en_US.utf8` |

**Why.** Locale is not encoding. Encoding decides which bytes represent a
character (`UTF8` is correct, and the data is intact under any locale). Locale
(`ctype`) answers the question "is this a letter?" — and `C` says "letter" only
for `a-z A-Z 0-9`. To the database, everything else is punctuation.

The line is drawn **by ASCII, not by language**. What breaks is not "Russian
text" but any non-ASCII letter — German `Müller`, French `café`, Spanish
`mañana`, Polish `Łódź`, Scandinavian `Malmö` included. An organisation without
a single Russian character hits this just the same.

**What `C` turns off, specifically** (measured on PostgreSQL 17.6, `C / C / UTF8`):

- **Duplicate issue detection** — the trigram layer (`pg_trgm`) drops non-ASCII
  characters before splitting a string into trigrams. `Привет Мир` → 0 of 10
  characters remain, 0 trigrams. The duplicate detector is blind to non-ASCII titles.
- **Five GIN indexes** (`issues.title`, `projects.name`, `project_aliases.alias`,
  `users.username`, `users.name`) — built on what is left, useless on non-ASCII
  data.
- **Case-insensitive search** (`ILIKE`) — degrades to case-sensitive.
  `'Ёлка' ILIKE 'ёлка'` → `false`. This affects issue-title search, full-name
  search in the user directory, and project names.
- **Case folding** — and it fails silently: only the ASCII part is folded.
  `lower('MÜLLER')` → `mÜller`, with no error.
- **Sort order** — by code points, not alphabetically:
  `Zebra, apple, Банан, Яблоко, арбуз`.

**What still works under `C`** (none of this needs changing):
data storage; full-text search `skein_search` (`to_tsvector` dictionaries
do not depend on `ctype`); the semantic layer of duplicate detection (the embedding
is computed outside the database); everything that works on ASCII — issue
identifiers, usernames, emails, statuses, labels.

**Why `C` is the default in the first place.** It is not an operator oversight.
glibc locales change their sort rules between OS versions: update the base
image, and indexes on text columns silently become incorrect and need a
`REINDEX`. `C` never changes. The default is a trade-off between version
stability and Unicode correctness, and stability wins by default. In particular,
CloudNativePG's `localeCollate` and `localeCType` fields have an **active default
of `C`** — so the cluster ends up on `C` not because the manifest author forgot,
but because the operator chose it for them; that applies to `template1` too, and
therefore to every database created in the cluster afterwards.

`pg_c_utf8` removes the trade-off: it knows Unicode properties (letters, case,
trigrams work for any alphabet) and is still version-stable, because it depends
on neither libc nor ICU.

**How to create:**

```sql
-- PostgreSQL 17+
CREATE DATABASE skein
  TEMPLATE template0
  ENCODING UTF8
  LOCALE_PROVIDER builtin
  BUILTIN_LOCALE 'C.UTF-8'
  LC_COLLATE 'C.UTF-8'   -- REQUIRED
  LC_CTYPE   'C.UTF-8';  -- REQUIRED: this is what includes non-ASCII in pg_trgm
```

**Two fields are not enough — all four are required.** `LOCALE_PROVIDER` + `BUILTIN_LOCALE`
fix `ILIKE`, `lower()`/`upper()` and sort order, but **not** `pg_trgm`: the flag
`database_ctype_is_c` is read from `pg_database.datctype` regardless of the
provider, and `pg_trgm` calls single-byte libc functions without passing them a
collation OID. Setting a collation on the argument does not help either —
`similarity(… COLLATE "pg_c_utf8", …)` gives the same wrong result.

Measured on PostgreSQL 17.6, three databases that differ only in locale fields:

| provider / BUILTIN_LOCALE | LC_CTYPE | `'Ёлка' ILIKE 'ёлка'` | `lower('MÜLLER')` | trigrams in `'Привет'` | similarity of different titles |
|---|---|---|---|---|---|
| libc | `C` | false | `mÜller` | 0 | **1.0** |
| builtin `C.UTF-8` | `C` | true | `müller` | **0** | **1.0** |
| builtin `C.UTF-8` | `C.UTF-8` | true | `müller` | 7 | 0.625 |

The middle row is a database configured only halfway. It passes a cursory
check and is still broken: `datlocale` shows `C.UTF-8`, case folding works, and
duplicate detection is blind. Without an explicit `LC_COLLATE`/`LC_CTYPE`, both
are inherited from `template0`, and on an affected cluster that means `C`.

The fix only arrives in PostgreSQL 19: PG18 moved `lower()` inside `pg_trgm` onto
a provider-aware path, but tokenisation still looks at
`database_ctype_is_c`. Until then, an explicit non-`C` `LC_CTYPE` is required on every
version.

CloudNativePG:

```yaml
bootstrap:
  initdb:
    database: skein
    owner: skein
    encoding: UTF8
    localeProvider: builtin
    builtinLocale: C.UTF-8
    localeCollate: C.UTF-8   # REQUIRED
    localeCType: C.UTF-8     # REQUIRED — includes non-ASCII in pg_trgm
```

On CloudNativePG, `localeCollate` → `--lc-collate` and `localeCType` → `--lc-ctype`
have a **default of `C`**. So `C` comes not from the manifest author forgetting
something but from the operator's active default — which is why a cluster
bootstrapped with `initdb` without these two fields ends up on `C` even with a
correct `builtinLocale`.

**How to check an existing installation:**

```sql
SELECT datname,
       pg_encoding_to_char(encoding) AS encoding,
       datlocprovider,
       datlocale,          -- populated when provider = b (builtin) or i (ICU)
       datcollate, datctype
  FROM pg_database
 WHERE datname = current_database();
```

It is wrong if `datctype = 'C'` — **whatever the provider**. When
`datlocprovider = 'b'`/`'i'`, `datlocale` holds the provider's locale, which
governs sort order, `lower()`/`upper()` and `ILIKE`; but `datctype` is **not
decorative** — `pg_trgm` and tsearch take their character classification from
it. A correct database has a non-`C` value in **both** places.

A quick functional check that works without knowing the provider — it
deliberately tests both mechanisms, because the first can work while the second
is broken:

```sql
SELECT 'Ёлка' ILIKE 'ёлка' AS ilike_ok,          -- should be true
       coalesce(array_length(show_trgm('Привет'),1),0) AS trgm;  -- should be > 0
```

**Caveat on sorting.** `pg_c_utf8` sorts by code points, not
alphabetically (`Банан, Яблоко, арбуз` — uppercase before lowercase). If a
particular list needs human alphabetical order, solve it in the query
(`ORDER BY name COLLATE "ru-RU-x-icu"`), not by changing the locale of the whole database.
Do not change the locale for the sake of sorting: ICU and glibc bring back the
version-drift problem for indexes.

**Changing the locale of an existing database.** It cannot be done in place — the
locale is fixed when the database is created. You need `dump` → create a new database
with the correct locale → `restore`. A separate `REINDEX` after a logical restore is
**not needed**: `pg_restore` runs `CREATE INDEX` again, and the indexes are built under
the new rules (verified on a real migration: all 126 indexes, including five GIN
`gin_trgm_ops` ones, came out valid). `REINDEX` is needed on other paths — editing
the catalog directly or making a physical clone — which are exactly the paths you
must not take.

**Check before the window:** unique functional indexes on `lower()`. Under the new
locale `lower()` starts folding non-ASCII characters, so strings that are distinct
today collapse into one, `CREATE UNIQUE INDEX` fails during the restore, and the
restore stops halfway. Count the conflicts in advance, on live data:

```sql
SELECT count(*) FROM (
  SELECT lower(name COLLATE "pg_c_utf8") FROM projects GROUP BY 1 HAVING count(*) > 1
) x;   -- expected 0
```

Tell users about the change in behaviour explicitly: after the migration `Проект` and
`ПРОЕКТ` are no longer different names.

**Plan the window.** Dump and restore time grows with the size of the database, so
measure both on a copy before choosing the window. Most of the downtime is usually
spent on stopping and starting the services and on the checks, not on the copy itself.

See issue sk-303.11.

**Check at service startup (sk-303.12).** Right after applying migrations,
skein-api runs the functional check described above against its own database —
`internal/dependencies.ClusterReadsUnicodeLetters` reuses the same
probe and the same SQL as the runtime duplicate check
(sk-228, `duplicateCtypeProbe` / `trigramLegibilitySQL` in
`internal/dependencies/duplicates.go` — not a second source of truth). On
`C`/`POSIX` (in any variant, including a database configured halfway as in
the table above) the service logs `slog.Warn` that spells out the consequence
("trigram-based duplicate-issue detection will not compare non-ASCII titles
at all", not merely the fact) and **carries on starting** — the degradation
deliberately does not become a refusal to start: purely ASCII content works
correctly under locale `C`, and crashing on anything but non-`C` would repeat
the sk-304 mistake (a required variable that took the whole API down). No
separate degradation flag is added to API responses either: the per-title
`degraded`/`degradedReason` from sk-228 is already more precise (it reacts to a specific
title, not to the cluster as a whole) — the decision and its rationale are recorded
next to the check code.

Since sk-303.12, the compose files of this repository (`docker-compose.local.yml`,
`docker-compose.test.yml`, `docker-compose.e2e.yml` and `docker-compose.production.yml`) set the locale explicitly —
`POSTGRES_INITDB_ARGS: "--locale-provider=builtin --builtin-locale=C.UTF-8
--lc-collate=C.UTF-8 --lc-ctype=C.UTF-8"` — instead of relying on the
`initdb` default of the base image. This only takes effect on a **new** volume, when
the cluster is first initialised — an existing developer database
is not reinitialised (see "Changing the locale of an existing database"
above).

**Related issues:** sk-303.11 (locale migration of an existing database),
sk-303.12 (locale check at service startup — so that a third-party installation learns about
the problem at once, not after months of duplicate detection silently failing; closed).

---

## 2. Releasing schema migrations

skein-api applies its own migrations at startup: `cmd/api/main.go` calls
`runMigrations` **before** it builds the router, and on a migration error the
process exits non-zero without ever opening the port. So "deploy the image" and
"migrate the database" are one event, and the shape of the release window is
decided by what sits in the pending migration chain — not by the size of the
code change.

### 2.1 Read the chain before you plan the window

**Required:** before every release, list the migrations that will apply on top
of the running schema, and read the header of each corresponding `.down.sql`.

**Why.** Reversibility is a property of the individual migration, not of the
release, and only the down-file states it. Three kinds, and the operator has to
know which of them is in the chain *before* the window opens:

| Kind | Rollback | Cost |
|---|---|---|
| additive — a new index, a new column with an inert default, a new table | unconditional | query performance only; not one row is lost |
| widening a closed set — a new value in a `CHECK` constraint, a new enum member | **conditional** — fails while a row carries the new value (2.5) | a human decision about those rows |
| destructive — `DELETE`, `DROP COLUMN`, `DROP TABLE` | **irreversible** | data, silently: the command exits 0 and nothing in its output says what left the database |

**How to check.** Diff the migration directory between the deployed tag and the
release tag, then read every `*.down.sql` header in the result:

```bash
git diff --name-only <deployed-tag>..<release-tag> -- src/migrations
```

Skein keeps the authoritative list of what a rollback drops in the down-file
header itself and **nowhere else**. A list retold in a second document drifts
from the original in silence, and the divergence is discovered *after* the
rollback, when there is nothing left to reconcile. Link to the header; do not
copy it.

### 2.2 One migrator, and never a mixed fleet

**Required:** exactly one API pod applies the migrations. When the chain deletes
rows or changes what existing rows mean, no other version of the service may be
running while it does.

**Why.** One direction is already guarded by the code: a new pod cannot serve on
an unmigrated schema, because migrations run before the router exists. The
reverse direction has no guard at all — old pods keep serving on the new schema,
and a rolling update makes exactly that state the normal case for the duration
of the rollout. For an additive chain that is tolerable. For a chain that
deletes history it is not: a statement like "the release must not reveal records
that were hidden under the rules in force when they were created" cannot be
shown to hold on a fleet running two rule sets at once. And rolling the image
back does not roll the data back, so the mixed window is not even cheap to
abandon.

**How to do it** — stop-all, in this order:

1. Scale every serving component (API, BFF, frontend) to zero replicas.
2. Confirm there is no pod in `Running` **and none in `Terminating`**. A
   terminating pod still holds its connections and still serves; the state to
   wait for is an empty listing across all three selectors, not a small one. If
   a pod hangs, deal with that pod — do not start the migrations around it.
3. If the chain contains an irreversible migration, execute the backup gate
   (2.3) now, with the database quiescent.
4. Change the image and bring the API up with **one** replica. That pod is the
   migrator; watch its log for the applied version and a clean (non-dirty)
   state. Never let two pods migrate concurrently.
5. Check the migrator's `/healthz` and `/ready`, and reconcile the migration's
   own counters with the preflight numbers (2.8).
6. Only then bring up the remaining API replicas and the other components.
7. Traffic last — once every new pod is ready, not just the first.

Infrastructure that neither reads nor writes the Skein schema (the message bus,
the cache) stays up throughout: nothing about stop-all requires breaking its
uptime, and queued outbox rows simply wait in the database until the service
returns.

### 2.3 The backup gate before an irreversible migration

**Required:** before a migration that deletes rows — preflight counts, a full
backup, a *proven* restore, and a recorded expiry date for the artifact. Until
all four exist, the new image does not start.

**Why.** After such a migration the only way back is a restore, and a restore is
only a way back if somebody has already proved that this particular artifact
restores. An untested backup is a belief, not a rollback plan.

**The four steps, and what each one actually proves:**

- **Preflight counts — taken while the database is quiescent and *before* the
  copy**, so the numbers describe exactly the state the copy freezes. The query
  must be strictly read-only: no DDL, no DML, no temporary tables, safe to run
  on live data. Naming the volume in advance is what the post-migration counters
  are later reconciled against; without it, "the migration completed normally"
  has nothing to be compared with. A zero in some class is not an error and not
  a reason to stop — a small installation legitimately has empty classes. Not
  taking the numbers is the error.
- **The whole database, not the affected table.** A single-table dump is not a
  backup here: recovery from an irreversible migration is the recovery of a
  database whose schema has since moved on, not of one table's rows.
- **Readable ≠ restorable.** Reading the artifact's listing and size back out of
  the object store proves the file exists and is legible; it does not prove the
  database unfolds. Restore it into a **separate** cluster — its own name, its
  own storage, never written into any service's `DATABASE_URL`, and never given
  the working cluster's archive identity (or it will start writing WAL into the
  same prefix as the working cluster). Then check that it holds data rather than an empty
  schema: the row counts must match the preflight report, and the recorded
  schema version must be the pre-release one. A mismatch means this is not the
  copy you think it is. Delete the check cluster the moment it has been
  confirmed — it costs storage and it misleads whoever finds it next.
- **Retention bounds the rollback window.** The artifact's lifetime *is* the
  period in which a data rollback is possible at all, and managed object stores
  commonly expire backups within days. Decide **before** the new image starts:
  either raise retention to cover the observation period, or take an independent
  copy outside that policy. Write down which of the two was chosen and **until
  what date the artifact is guaranteed to exist**. A release after which
  rollback is impossible, and nobody knows since when, is no better than a
  release with no backup at all.

**Two rules about people and code that are easy to skip and expensive to skip:**

- The person who confirms the restore should not be the person who starts the
  new image. One pair of eyes reading its own evidence is not a check.
- **The gate is deliberately external to the service.** No environment variable
  checked at startup, no permission row in the database, no lock inside the
  migration. A migration has no way to know whether a backup was taken, and a
  service that refuses to start turns a refused release into a riddle at the
  worst possible moment. Checkability comes from every step of the gate being a
  command with an observable result and a written-down outcome — not from the
  program declining to run.

**Practical note.** Keep the preflight query inside the image. Skein's Dockerfile
copies the whole of `src/migrations`, and `src/migrations/preflight/` rides along
with it, so in the release window the query is available from the running
container without cloning the repository onto the host. golang-migrate
ignores the subdirectory, so the file never enters the migration chain.

### 2.4 GitOps reconciliation will undo the procedure

**Required:** if the Deployments are reconciled by a GitOps controller, suspend
both the reconciliation and any automated image updates **before** the release
tags are published — and lift the suspension as an explicit last step of the release.

**Why.** `kubectl scale --replicas=0` is undone by the next reconciliation, so
the fleet quietly comes back up mid-window. Worse, a new semver tag that lands
in the registry while automated image updates are live is rolled out automatically, as a
**rolling update** — which violates the stop-all by itself, with nobody having
done anything wrong.

**Caveat in the other direction.** Suspending a shared reconciliation stops
*everyone else's* changes too, silently: already-running pods keep running, but
no other commits to that repository are applied while the window is open. That is the price
of stop-all — keep the window short, and treat a suspension left behind as an
incident of its own rather than as cleanup for later.

### 2.5 A rollback that fails on purpose, and the dirty state after it

**Required:** before launching a rollback, know whether it can succeed at all.
That is a query on live data, not a guess.

**Why.** A migration that widens a closed set rolls back by restoring the narrow
one, and `ADD CONSTRAINT` will not validate while a single row carries the new
value. The failure is deliberate: silently rewriting those rows into some other
value would write into the database a fact that did not happen. The tool must
stop and demand a human decision instead of choosing one.

```sql
-- Rows that block the rollback. Zero — the rollback will pass.
SELECT count(*) FROM notifications WHERE push_outcome = 'superseded';
```

**And if the rollback was launched anyway and failed, the migration tool is
completely stuck.** `schema_migrations` is left marked dirty, and in that state neither
`up` nor `down` works — both answer the same and do nothing:

```
error: Dirty database version 43. Fix and force version.
```

The fact you need to get out correctly: golang-migrate runs each
migration in a single transaction, so a failed statement rolled the *whole*
migration back — **the schema did not change**. The version the tool recorded
and the version the schema actually carries can therefore differ, and the one to
force is the one the **schema** carries. Forcing the other declares a rollback
that never happened, and the next `up` then tries to apply that migration on top
of objects that already exist.

Recovery, in this order:

1. **Ask the database what it actually holds** — the objects the migration
   creates, and the rows that blocked the rollback. Only the database answers
   "which version do I force"; a migration split across several transactions
   fails into an intermediate state and the answer is different again.
2. `migrate … force <the version the schema carries>`. `force` rewrites the
   bookkeeping row and touches nothing else.
3. **Decide about the blocking rows.** A human decision, not a step in a guide:
   those rows are a recorded fact, and deleting them loses it. The rollback
   becomes possible only when none remain.
4. Repeat the rollback — or `migrate … up` to return to the head. After step 2
   both directions work again.

### 2.6 State a rollback's consequences, not only its DROP list

**Required:** the release notes for a rollback say what the drop *implies at
runtime*, not merely which objects disappear.

**Why.** The list of dropped objects lives in the down-file and is derivable
from it. What is not derivable from it is the behaviour on the way back up. When
a rollback drops a rate-limiting table, it drops the frozen deadlines stored in
it, so a second `up` recreates the table empty and opens every window at once —
the worker's first tick is then entitled to notify everyone who has a reason.
For the operator that is a burst immediately after the second `up`, not a
gradual return, and no line in the DROP list says so.

Rollbacks are applied in the reverse order of their migrations.

### 2.7 Additive migrations still have a release-day question

**Required:** a new flag on historical rows takes the **inert** value by default,
and the migration asserts that it did before the next migration lands on top.

**Why.** Default such a flag to "on" and the entire archive enters the new
mechanic in a single tick on release day: counters, reminders and inboxes fill
with years of history at once. Skein's `issues.review_required` is
`NOT NULL DEFAULT false` for exactly this reason; the personal default that
applies to *newly created* issues is a separate setting, and that one is "on".
The two are easy to conflate and they are not the same knob.

**How to check.** Put the post-condition inside the migration — a
`RAISE EXCEPTION` if even one historical row came out on the wrong side. A
divergence then stops the release at the migration that caused it, instead of
being discovered several migrations later on top of a schema that has moved.

### 2.8 A data migration counts what it touched

**Required:** a migration that rewrites or deletes rows writes per-class counters
into a journal table, and the release reconciles them against the preflight
numbers.

**Why.** "The migration completed" and "the migration did what was expected" are
different statements, and only the second one is worth a release window. A count
taken by the migration itself, in the same transaction, against the live
database is the only number that the preflight figure can honestly be compared
with. Reading the counters is also how the migrator pod's log becomes evidence
rather than reassurance.

```sql
SELECT metric, value
  FROM migration_counters
 WHERE migration = '<migration name>'
 ORDER BY metric;
```

The rollback of such a migration removes its counter rows, so that a re-apply
does not double them — the up/down/up smoke test checks chain integrity, not the
return of data.

### 2.9 The first half-hour after the release

**Required:** read a newly enabled background mechanic's metrics as a **set**,
not one at a time.

**Why.** No single counter distinguishes "the worker is not running" from "there
is nobody to serve". Read them together, and each answers what its neighbour
cannot:

- a **tick** counter that grows says the worker is alive and walking its
  candidates; not growing means it is not working, whatever the others say;
- a **candidates selected** counter at zero *beside a growing tick counter*
  means the set is genuinely empty — normal, not broken;
- a **sweep failures** counter is what separates "broken" from "empty" when
  candidates are zero;
- a **work formed** counter at zero with non-zero candidates means the work is
  being selected but not produced;
- a **schedule lag** with a growing tail means the worker is falling behind its
  own schedule rather than failing outright;
- a **lost segment** counter is the visible side of duplicate protection between
  replicas. A steady low level is healthy; a level comparable to the work
  actually done means the replicas are walking the same candidates in lock-step
  and their tick phase should be spread.

The same reading applies to the transport side of a release: an outcome counter
broken down by outcome tells apart a delivery that was refused by configuration
from one that was superseded by a newer notification — the two look identical in
an undifferentiated failure count.

## 3. Installation settings and the release that introduces spaces

Since the spaces release an installation is shaped by skein-api environment
variables — the choices are walked through in
[`INSTALL.md`](INSTALL.md), the meaning of each variable is in the
`docs/env-reference.md` of each service repository. This section is about what
those settings do to a release window.

### 3.1 The release that introduces spaces is stop-all for api and web (D-11)

**Required:** the release that moves an existing installation to spaces runs the
stop-all procedure of 2.2 — no old api **and no old web** pod is running when the
first new api pod starts — and the backup gate of 2.3 runs before it.

**Why.** The chain of this release moves every existing project into a space
(`000071_spaces_transition`) and replaces the access rule the database applies
(`000073`, `000075`). An old api pod serving on that schema would answer with the
rules of the previous release on data the new rules govern — the very "mixed
fleet" 2.2 forbids. The old web cannot run next to the new api either, and the new
web cannot run next to the old api: the new web asks the api for the installation
settings at startup (`GET /api/v1/internal/instance-config`); an old api answers
404, and the new web exits at once without becoming ready.

The rollback is not free, which is what makes the backup gate mandatory here even
though nothing is deleted on the way up: `projects/skein-api/src/migrations/000071_spaces_transition.down.sql`
deletes every space, membership, invitation (with its tokens and emails) and
storage counter, and takes projects out of their spaces — whatever users created
after the release is gone. `projects/skein-api/src/migrations/000072_spaces_constraints.down.sql` fails while two
spaces hold projects with the same name, or a deleted account has no way to log
in. The down-file headers are the
authoritative list (2.1).

**How to do it:**

1. Before the window, write down the settings of the new release
   (`INSTALL.md`) and check them against the startup refusals (3.2). A
   contradiction found in the window costs the window.
2. Suspend GitOps reconciliation and automated image updates (2.4), then steps 1–3 of
   2.2: scale api, web and frontend to zero, wait for an empty listing, run the
   backup gate (2.3).
3. Steps 4–7 of 2.2: one api pod migrates. The transition needs an owner for the
   common space — the earliest **active admin** (defined in 3.2); without one the
   pod refuses before migrating (3.2) and the database is untouched.
4. Start web once api is ready: it reads the authentication mode from the api and
   waits for it at most `SKEIN_API_STARTUP_TIMEOUT_SECONDS` (default 60).
5. Lift the GitOps suspension as the last step (2.4), with the settings of the new
   release committed to the GitOps repository — a reconciliation must not bring
   back the old values.

### 3.2 Startup refusals — every condition, and where it stops

**Required:** know where each refusal stops the process, because that decides
whether the schema has already moved.

**Why.** skein-api checks settings in three places, and only the first two leave
the database untouched. Every refusal exits with code 1 before the HTTP listener
opens; a refusal caused by a contradiction is logged as
`contradictory settings (VAR, VAR, …): <reason>`, naming the variables.

**An active admin**, wherever this section says so, is a user with role `admin`
that is not deactivated, not deleted and not external. One definition serves
three places: the owner choice of the transition migration (`000071`), account
creation (`projects/skein-api/src/internal/accounts/create.go#ensureCommonSpaceOnce`)
and the startup check
(`projects/skein-api/src/internal/config/startup_checks.go#activeAdminExists`).
The startup check reads "not deleted" only once the `deleted_at` column exists
(migration 000069); on an older schema nobody is deleted. External admins cannot
exist (`CHECK users_external_not_admin`, migration 000033), so "not external" only
keeps the definitions identical.

**skein-api, `config.Load()` — before the database is opened.**
Contradictions decided by the variables alone (`projects/skein-api/src/internal/config/config.go#checkSettingConflicts`):

- `SKEIN_INSTANCE_ADMIN_ENABLED=false` and any of `SKEIN_INITIAL_ADMIN_EMAIL`,
  `SKEIN_INITIAL_ADMIN_PASSWORD`, `SKEIN_INITIAL_ADMIN_USERNAME`,
  `SKEIN_INITIAL_ADMIN_NAME`, `SKEIN_BOOTSTRAP_ADMIN_EMAIL`,
  `SKEIN_BREAKGLASS_ADMIN` set;
- `SKEIN_INSTANCE_ADMIN_ENABLED=false` and `SKEIN_OIDC_DEFAULT_ROLE=admin`;
- `SKEIN_INSTANCE_ADMIN_ENABLED=false` and `SKEIN_SPACE_CREATION=admin`;
- `SKEIN_SIGNUP_ENABLED=true` and `SKEIN_EMAIL_ENABLED=false`;
- `SKEIN_EMAIL_ENABLED=false`, `SKEIN_INSTANCE_ADMIN_ENABLED=false` and
  `SKEIN_AUTH_MODE` `local` or `hybrid`;
- `SKEIN_SIGNUP_ENABLED=true` and `SKEIN_AUTH_MODE` other than `local`.

Values of the installation settings (`projects/skein-api/src/internal/config/config.go#validateInstanceSettings`):
`SKEIN_SPACE_CREATION` outside `all`/`admin`/`none`;
`SKEIN_PROJECT_DEFAULT_VISIBILITY` outside `space`/`members`;
`SKEIN_SPACE_INVITE_TTL` or `SKEIN_EMAIL_DELIVERY_TTL` not above zero;
`SKEIN_SPACE_MEMBER_LIMIT` below 1; a negative owned-spaces limit, invitations-per-day
limit or quota; `SKEIN_PROJECT_PREFIX_MIN_LENGTH` outside 1–50; only one of the two
Turnstile keys; `SKEIN_TERMS_URL` or `SKEIN_PRIVACY_URL` not an absolute http(s)
URL; a blank `SKEIN_INSTANCE_NAME`; with `SKEIN_EMAIL_ENABLED=true` — any missing
`SKEIN_SMTP_*` or `SKEIN_APP_BASE_URL` (all named in one message), a port outside
1–65535, a TLS mode other than `implicit`/`starttls`, a `SKEIN_SMTP_FROM` that is not one
email address (a display name is allowed: `Skein <skein@example.com>`) or contains a line
break, a `SKEIN_APP_BASE_URL` that is not an absolute http(s) address of the web UI or carries
credentials (`user@`), a query (a bare `?` included) or a fragment (a bare `#` included)
(`projects/skein-api/src/internal/config/config.go#validateAppBaseURL`); with `SKEIN_OPERATOR_API_ENABLED=true` — a key shorter
than 16 characters, a port outside 1–65535 or equal to `PORT`. The older checks of
`config.Load()` (internal secret, monitor and MCP timings, VAPID, …) are described
with their variables in the api reference.

**skein-api, before migrations** (`projects/skein-api/src/internal/config/startup_checks.go#PreMigration`) — some
project has no space (on the schema before spaces: any project at all), and either
`SKEIN_INSTANCE_ADMIN_ENABLED=false`, or no active admin exists. **The database is
left exactly as it was**; fix the settings or reactivate an admin and start again.

**skein-api, after migrations** (`projects/skein-api/src/internal/config/startup_checks.go#PostMigration`) — **the
schema has already moved**; fix the settings, do not roll back:

- `SKEIN_INSTANCE_ADMIN_ENABLED=false` and a user with role `admin` exists,
  deactivated included;
- `SKEIN_INSTANCE_ADMIN_ENABLED=false`, no user exists, and either
  `SKEIN_SIGNUP_ENABLED=false` with `SKEIN_AUTH_MODE=local`, or
  `SKEIN_AUTH_MODE=keycloak` with `SKEIN_AUTO_PROVISION=false` — nobody could
  enter the installation;
- `SKEIN_COMMON_SPACE_ENABLED=true`, no common space exists, and
  `SKEIN_INSTANCE_ADMIN_ENABLED=false`;
- `SKEIN_COMMON_SPACE_ENABLED=true`, no common space exists, no active admin, and
  none is certain to appear: `SKEIN_INITIAL_ADMIN_EMAIL` into an empty user base,
  or SSO auto-provisioning (`keycloak`/`hybrid` with `SKEIN_AUTO_PROVISION=true`)
  that creates `SKEIN_BOOTSTRAP_ADMIN_EMAIL` (no account with that email yet) or
  gives every new user `SKEIN_OIDC_DEFAULT_ROLE=admin`.

**skein-api, writing the flags** (`projects/skein-api/src/internal/config/startup_checks.go#SyncInstanceSettings`)
— `SKEIN_INSTANCE_ADMIN_ENABLED` and `SKEIN_COMMON_SPACE_ENABLED` are written into
the single `instance_settings` row and read back; a read-back that differs means
another api process is writing a different value at the same moment, and the pod
refuses.

**skein-web, at startup** — no valid answer from
`GET /api/v1/internal/instance-config` within `SKEIN_API_STARTUP_TIMEOUT_SECONDS`
(retried with backoff); and, without waiting for the timeout: 401 (the two
`SKEIN_INTERNAL_SECRET` values differ), 404 (wrong `SKEIN_API_URL`, or an api
without the route — an old release), or a 200 body that is not the contract, an
unknown `authMode` included. The pod never becomes ready; there is no web-side
default mode.

### 3.3 Changing a setting: what has to restart

**Required:**

- **The authentication mode** (`SKEIN_AUTH_MODE`) is set on skein-api only, and
  changing it restarts **both** services: stop web, restart api, start web. web
  reads the mode once, at startup, and builds its authentication scheme from it;
  a web started before the change keeps the old scheme. skein-web has no mode
  setting of its own — `Authentication__Mode` and `Authentication__Hybrid` are not
  read any more.
- **A behaviour flag handed to the browser** (registration, mail, the Turnstile
  site key, the minimum prefix length, the terms and privacy URLs) needs a restart
  of skein-api only: web answers `GET /api/auth/config` with the values the api
  holds at the moment of the request.
- **`SKEIN_INSTANCE_ADMIN_ENABLED` and `SKEIN_COMMON_SPACE_ENABLED`** are changed on
  every api replica at once (scale to zero, then up), never by a rolling update.
  They live in one database row that each starting replica overwrites with its own
  value, and the code reads that row, not its own environment: the database access
  function reads the admin flag on every request, account creation reads the
  common-space flag. During a rolling update the value of the last replica to
  start applies to all of them.

**Not supported:** switching an installation that has admins to
`SKEIN_INSTANCE_ADMIN_ENABLED=false`. Startup refuses while any user holds role
`admin`, and the last admin cannot be demoted. A SaaS installation is a new
installation.

### 3.4 The operator port never goes through the ingress

**Required:** with `SKEIN_OPERATOR_API_ENABLED=true` the operator API listens on
its own port (`SKEIN_OPERATOR_API_PORT`, default 5101, never equal to `PORT`). That
port is not published through the Ingress / Gateway, and a NetworkPolicy admits it
only from the operator's own workload. In docker-compose the port is not published
to the host.

**Why.** The operator API blocks, unblocks and deletes accounts (US-11). Its only
guard in the application is one key (`SKEIN_OPERATOR_API_KEY`, at least 16
characters, from your secret store); the network boundary is the second one, and it is the
deployment's job. The public port does not serve the operator API, and the
operator port does not serve the public one — so routing the operator port
through the public gateway gains nothing and exposes a privileged surface.

**How to do it (Kubernetes):**

- Declare the operator port on the api container, but keep it out of the Service
  the gateway routes to — a separate ClusterIP Service (or none, if the operator
  reaches pods directly) that no Ingress / HTTPRoute references.
- A NetworkPolicy on the api pods: ingress on the operator port only from the
  operator's namespace/pod selector; the existing rules for `PORT` stay as they are.
- Check from outside: a request to the public host on the operator paths does not
  reach the operator API, and the operator port is not reachable from a pod outside
  the allowed selector.

**What listens there** (`projects/skein-api/src/internal/operator/contract.go`, T042):
`POST /operator/v1/accounts/block`, `/unblock` and `/delete`, the account named by
`{"email": …}` in the body. Every request, to any path, must carry the header
`X-Skein-Operator-Key` equal to `SKEIN_OPERATOR_API_KEY`; otherwise 401
`operator_unauthorized` before routing. Requests are counted in
`skein_operator_requests_total{operation,result}`. The operator server starts and stops with
the main one, in the same shutdown window; if its port cannot be bound, the api process
exits with an error, just as it does for the main port.

### 3.5 Outgoing mail: the queue and the delivery worker

**Required:** with `SKEIN_EMAIL_ENABLED=true` the api pods may reach the SMTP relay
(`SKEIN_SMTP_HOST`:`SKEIN_SMTP_PORT`) — an egress NetworkPolicy, if one is in
force, must allow it; the SMTP credentials come from your secret store; the relay's
certificate must be trusted by the system roots of the api image (there is no
plaintext mode: `implicit` is TLS from the first byte, `starttls` refuses a relay
that does not offer STARTTLS); `SKEIN_APP_BASE_URL` is the address users open the
UI at — every link in an email is built on it.

**Why and what to expect.** An email is not sent by the request that caused it.
The action writes a row into `outgoing_emails` in its own transaction
(`projects/skein-api/src/internal/mail/enqueue.go#Enqueue`), so a committed action always has its email queued and a
rolled-back one never does. The row holds no token and no rendered text. Two
background workers inside every api process take it from there
(`projects/skein-api/src/cmd/api/email_workers.go#startEmailWorkers`):

- **the mail worker** (`projects/skein-api/src/internal/mail/runner.go#Runner`) runs
  only with `SKEIN_EMAIL_ENABLED=true`. Every 5 s it leases up to 20 ready emails
  with `FOR UPDATE SKIP LOCKED` for 2 minutes, so several replicas share the queue;
  a lease that runs out (a pod killed mid-attempt) returns the email to the queue.
  The link token is issued at the start of each attempt, not when the email is
  queued, so an email queued before a restart goes out after it with a valid link;
  an action no longer open (invitation revoked, newer request) ends the email as
  `cancelled`. One SMTP session is bounded by 15 s to connect and 60 s overall.
- **failures** are classified in one place
  (`projects/skein-api/src/internal/mail/smtp.go#Classify`). A 5xx reply to
  `MAIL FROM`, `RCPT TO` or `DATA`, or an address that is not an address, ends the
  email as `rejected` at once. Everything else — 4xx, network, TLS, timeout, a relay
  without STARTTLS, a 5xx to the greeting, `EHLO`, `STARTTLS` or `AUTH` (a wrong
  password is a relay problem, not the email's) — is retried after 30 s, doubling
  up to 10 min, with no attempt limit, until the email's deadline:
  `SKEIN_EMAIL_DELIVERY_TTL` after it was queued (default `24h`). Then it ends as
  `expired`.
- **the mail cleanup** (`projects/skein-api/src/internal/mail/cleanup.go#CleanupRunner`)
  runs always, once at start and then hourly. It ends as `expired` every queued
  email past its deadline — so turning mail off does not leave emails pending
  forever — and deletes final emails 30 days after their outcome, and at once
  those addressed to a deleted account.
- **the invitation expiry** (`projects/skein-api/src/internal/invitations/expiry.go#Expirer`,
  T040) runs always, once a minute, wired with the two above
  (`projects/skein-api/src/cmd/api/email_workers.go#startEmailWorkers`). A pending
  invitation past its `SKEIN_SPACE_INVITE_TTL` gets the status `expired`, and its tokens
  and unsent emails are retired, whether or not mail is on. The same tick deletes the
  journal of invitation sends older than 24 hours.
- **delivery is at least once:** a pod that dies after the relay accepted an email
  but before recording it sends it again on the next lease, with a new link; the
  first link then stops working.
- **what to watch:** `skein_email_deliveries_total` (by kind and outcome),
  `skein_email_retries_total` (a sustained rate means the relay is unreachable or
  misconfigured), `skein_email_runner_errors_total` (failed passes — the database).

At shutdown the api waits for the workers it started — the mail cleanup and the invitation
expiry always, the delivery worker only with `SKEIN_EMAIL_ENABLED=true`: an attempt in flight
records its outcome before the process exits.

For a release window this means: queued emails wait in the database through a
stop-all, like the outbox rows (2.2) — but their deadline keeps running. A window
longer than `SKEIN_EMAIL_DELIVERY_TTL` expires everything queued before it: the
first api pod to start runs the cleanup and ends them as `expired`, even with mail
turned off.
