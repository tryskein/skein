# Releases and versioning

Skein is built from three services, each in its own repository:
[skein-api](https://github.com/tryskein/skein-api),
[skein-web](https://github.com/tryskein/skein-web) and
[skein-frontend](https://github.com/tryskein/skein-frontend). Each service has
its own version. A **Skein release** is a set of service versions that work
together; it is published from this repository.

## Two kinds of versions

| | Service version | Skein release |
|---|---|---|
| Where | git tag in the service repository | git tag in this repository |
| Format | `X.Y.Z` | `X.Y.Z` |
| What it means | one service changed | the set of the latest service versions |
| Example | `skein-api 1.3.0` | `Skein 1.5.0` = api 1.3.0 + web 1.0.3 + frontend 1.3.1 |

Both follow [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

## The rule that holds it together

**The latest released versions of all services always work together.**

- A Skein release is always the set of the latest service versions.
- A change that breaks compatibility between services is released in all the
  services it touches at the same time.

## Service version

A service gets a new version only when its own code changes. A service that
did not change is not rebuilt and gets no new tag.

| Bump | When |
|---|---|
| `PATCH` | a fix; external behaviour does not change |
| `MINOR` | something new; everything that worked keeps working |
| `MAJOR` | an external contract breaks: the REST API or MCP tools of skein-api, an environment variable, a database migration that cannot be rolled back |

## Skein release version

A Skein release is cut right after every service release — nothing is held
back, so the latest images and the latest Skein release are always the same
set.

Its version bump follows the largest change among the services it includes:

- any service got a `MAJOR` bump → `MAJOR`;
- otherwise any service got a `MINOR` bump → `MINOR`;
- otherwise → `PATCH`.

A change to this repository alone (docs, compose files, Kubernetes examples)
is a `PATCH`, unless it breaks something for people who run Skein — for
example a change to the format of `.env` — which makes it a `MAJOR`. Changes
to the workflows in `.github/`, to `CHANGELOG.md` and to `versions.env` do not
count as changes for this purpose.

`versions.env` in the root of this repository lists the service versions of
the latest Skein release (`SKEIN_VERSION`, `SKEIN_API_VERSION`,
`SKEIN_WEB_VERSION`, `SKEIN_FRONTEND_VERSION`). The release workflow writes
it and reads it back to tell what changed since the previous release; do not
edit it by hand. It is not your `.env`: your `.env` holds your secrets and
settings and only needs `SKEIN_VERSION` from it.

## How a release is made

1. **Release candidate.** A changed service gets a tag `X.Y.Z-rc.N`. The
   maintainers test it together with the latest released versions of the
   other services. Release candidates are not published as images.
2. **Final release of the service.** When the candidate passes, the final tag
   `X.Y.Z` goes on the same commit. GitHub Actions build the image for amd64
   and arm64, push it to the GitHub Container Registry and create a GitHub
   Release of the service.
3. **Skein release.** The release workflow of this repository is started. It:
   1. finds the latest release of each service;
   2. stops if nothing changed since the previous Skein release;
   3. computes the new Skein version by the rule above;
   4. checks that every image exists in the registry;
   5. commits the pinned versions (`versions.env`) and the changelog;
   6. tags this repository and adds the `skein-X.Y.Z` tag to the three images;
   7. creates the GitHub Release with upgrade notes.

   If any step fails, no release is created. How to start it, and what to do
   after a failure, is in [Starting a Skein release](#starting-a-skein-release).

## Image tags

Images: `ghcr.io/tryskein/skein-api`, `ghcr.io/tryskein/skein-web`,
`ghcr.io/tryskein/skein-frontend`.

| Tag | Points to | Moves? |
|---|---|---|
| `X.Y.Z` | that version of the service | never |
| `skein-X.Y.Z` | the image of this service included in Skein release `X.Y.Z` | never |
| `latest` | the newest version of the service | yes, on every release |

An image that did not change in a Skein release is not rebuilt: the
`skein-X.Y.Z` tag is added to its existing image.

**To run a tested set, pin `skein-X.Y.Z` on all three images** — or read
`versions.env` of that Skein release, which pins the exact service versions. `latest` is
for trying Skein out.

Git tags and `X.Y.Z` image tags are never moved, deleted or reused. A mistake
in a release is fixed by the next release.

## Starting a Skein release

Do this after the final release of every service you want in the set has
finished (its image is in the registry and its GitHub Release exists). The
workflow takes the **latest final release** of each service, so there is
nothing to choose.

Start it from the default branch with the [GitHub CLI](https://cli.github.com):

```bash
# Check first (publishes nothing): every check runs, the result is shown in the run summary
gh workflow run release.yml --repo tryskein/skein -f dry_run=true

# The real release
gh workflow run release.yml --repo tryskein/skein

# Very first Skein release only: this repository has no release tag yet
gh workflow run release.yml --repo tryskein/skein -f first_version=1.0.0

# Only this repository changed, and it breaks something for people who run Skein
gh workflow run release.yml --repo tryskein/skein -f bump_override=major
```

Then follow the run. The run waits for a maintainer to approve the `release`
environment, so it may sit in the "waiting" state for a while:

```bash
gh run list --repo tryskein/skein --workflow release.yml --limit 1
gh run watch --repo tryskein/skein --exit-status <run-id>
```

`gh run watch --exit-status` exits non-zero if the run failed, including when
it stopped because nothing changed. When it succeeds, check the result:

```bash
gh release view --repo tryskein/skein            # the latest release, with its upgrade notes
git fetch --tags && git show <X.Y.Z>:versions.env # the service versions inside it
docker buildx imagetools inspect ghcr.io/tryskein/skein-api:skein-<X.Y.Z>
```

### What the workflow refuses to do

| Situation | Result |
|---|---|
| Not started from the default branch | stops |
| No service has a new release and this repository has no changes since the previous Skein release | stops with "Nothing changed": no release |
| A service has no final `X.Y.Z` release, or its image is missing or lacks `amd64` or `arm64` | stops before anything is published |
| `bump_override=major` while a service changed | stops: the bump is computed from the services |
| The tag `X.Y.Z` or a GitHub Release of that name already exists | stops: tags are never moved or reused |
| A `skein-X.Y.Z` image tag already exists on a different image | stops: tags are never moved |
| The secret `GHCR_RELEASE_TOKEN` is not set | stops before anything is published (a dry run only warns) |

### Order of work and what to do after a failure

Everything that can be checked is checked first. Then, in this order:

1. the `skein-X.Y.Z` tag is added to the three images (same manifest, no rebuild);
2. the release commit (`versions.env`, `CHANGELOG.md`) and the tag `X.Y.Z` are pushed in one atomic push;
3. the GitHub Release is created.

A failure before step 1 leaves nothing behind. After a failure in a later
step:

- **Step 1 or 2 failed**: some `skein-X.Y.Z` image tags may exist without a
  Skein release. Start the workflow again. It computes the same version, accepts
  the tags that already point to the right images and finishes the rest. If a
  newer service release appeared in between and the version would now point to
  different images, the run stops instead of moving a tag; fix the situation
  with the next release.
- **Step 3 failed**: the tag and the image tags are already final. Create the
  Release by hand: `gh release create <X.Y.Z> --verify-tag --title "Skein <X.Y.Z>" --notes "<upgrade notes>"`.
  Starting the workflow again would stop with "Nothing changed".

### One-time setup for maintainers

- **Secret `GHCR_RELEASE_TOKEN`** in this repository. The workflow adds a tag
  to images that belong to the three service repositories, so the token of the
  run (`GITHUB_TOKEN`) may not be allowed to; this is not guaranteed by
  GitHub. Use a personal access token (classic) with the `write:packages` scope,
  owned by an account that has write access to the packages `skein-api`,
  `skein-web` and `skein-frontend` (package settings, "Manage Actions access"
  and the package's collaborators). GitHub documents classic tokens for
  signing in to the container registry. The workflow uses it only for signing in to
  the registry. It is the only secret it needs.
- **Environment `release`** in this repository (Settings, Environments), with
  required reviewers. The workflow runs in it, so every release waits for an
  approval.
- If the default branch is protected by a ruleset, allow the workflow to push the release
  commit (a bypass for GitHub Actions); otherwise the push in step 2 is rejected.

## Tag protection

Release tags are never moved, so make GitHub enforce it. In **every**
repository (this one and the three services) maintainers configure tag
rulesets (Settings, Rules, Rulesets, target "Tag"):

- one for `X.Y.Z` (pattern `[0-9]*.[0-9]*.[0-9]*`) and one for `X.Y.Z-rc.N`
  (pattern `[0-9]*.[0-9]*.[0-9]*-rc.*`);
- restrict creation to maintainers;
- block updates and block deletion.

Without these rules the promise "tags are never moved or deleted" depends on
people being careful. The `release` environment with required reviewers
(see above) must exist in every repository that publishes images: the three
services as well as this one.
