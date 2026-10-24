#!/usr/bin/env bash
#
# check-theme-mirror.sh — compare the frontend's theme-token registry
# with the backend's Go mirror of it.
#
# WHY THIS LIVES AT THE WORKSPACE ROOT AND NOT IN skein-api/.
#
#   skein-api and skein-frontend are separate git repositories. The
#   backend's CI clones only its own tree, so themeTokens.ts is simply
#   not on disk when its tests run — a Go test that read it would be
#   permanently red there, or skipped, and vacuous either way. That
#   argument is sound, and it is an argument about THE BACKEND'S CI. It
#   was then generalised into "nothing can compare the two", which does
#   not follow: in the multi-repo WORKSPACE both trees sit side by side,
#   and comparing them is a shell script away.
#
#   So this script runs HERE, where both sides exist, and never in the
#   backend's pipeline. It turns "mirror the registry in the same wave"
#   from a discipline someone has to remember into one command.
#
#   It is not hypothetical. The mirror was exact when it was read and
#   stale 72 seconds later, because the frontend's next commit landed in
#   between; ten roles and two values diverged and every test in both
#   repositories stayed green. This script finds that in about a second.
#
# WHEN TO RUN IT
#
#   - after changing TOKEN_SECTIONS in the frontend;
#   - after changing TokenSchema in the backend;
#   - before closing any task that touched either.
#
# WHAT IT COMPARES
#
#   Frontend side: TOKEN_SECTIONS in
#     projects/skein-frontend/src/lib/themeTokens.ts
#   evaluated as a literal by node (not regexped — the values include
#   commas, parens and nested quotes).
#
#   Backend side: internal/themes/testdata/token_catalogue.tsv — the
#   golden rendering of themes.TokenSchema. Reading the golden rather
#   than regexping schema.go is deliberate: Go struct literals wrap
#   across lines and a regex over them is exactly the kind of parser
#   that fails quietly on a reformat. The golden cannot drift from
#   TokenSchema unnoticed, because TestCatalogueGolden in the backend
#   suite renders the live catalogue and compares it byte for byte —
#   and this script RUNS that test first (when a Go toolchain is
#   present) so the substitution is verified, not assumed.
#
#   Compared: the set of role keys, each role's section, kind, label,
#   light and dark defaults, and the order of the whole catalogue.
#
#   SECOND COMPARISON — the retired-role table (sk-285.7.4 / sk-285.7.5).
#
#   Frontend side: LEGACY_TO_NEW in
#     projects/skein-frontend/src/lib/themeMigration.ts, restricted to the
#     names the CURRENT dictionary no longer declares. The restriction is
#     the whole subtlety: the redesign KEPT fourteen of the old names, so
#     LEGACY_TO_NEW has 61 entries where the retired set has 47, and a
#     comparison of the raw tables would report fourteen phantom
#     differences on a tree that is perfectly in sync.
#
#   Backend side: internal/themes/testdata/retired_roles.tsv — the golden
#     rendering of themes.RetiredRoles, pinned by TestRetiredRolesGolden,
#     which this script also runs first for the same reason it runs the
#     catalogue's.
#
#   Compared: the set of retired names, and each name's successor.
#
#   Why this needs a CROSS-REPO check when skein-api already guards the
#   table: its guards can see that a successor IS a live role, never that
#   it is the RIGHT one. `--bg-hover → --surface` passes every test in
#   that repository and makes skein_theme point agents at a role the
#   migration never chose. Only this script can say otherwise.
#
# EXIT CODES
#   0  the two agree
#   1  they disagree (the report names every difference)
#   2  the check could not be performed (missing file, missing node,
#      unparseable input, or either side yielding zero roles)
#
# Exit 2 is never "everything matched". A comparison of two empty sets
# is vacuously true and is the one result this script must never print
# as success — the failure mode it exists to catch is a guard that
# cannot go red.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS_REGISTRY="$ROOT/projects/skein-frontend/src/lib/themeTokens.ts"
GO_GOLDEN="$ROOT/projects/skein-api/src/internal/themes/testdata/token_catalogue.tsv"
TS_MIGRATION="$ROOT/projects/skein-frontend/src/lib/themeMigration.ts"
GO_RETIRED_GOLDEN="$ROOT/projects/skein-api/src/internal/themes/testdata/retired_roles.tsv"
GO_SRC="$ROOT/projects/skein-api/src"

fail_setup() { printf 'check-theme-mirror: %s\n' "$*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || fail_setup "node is required to evaluate TOKEN_SECTIONS but is not on PATH"
[ -f "$TS_REGISTRY" ] || fail_setup "frontend registry not found: $TS_REGISTRY"
[ -f "$GO_GOLDEN" ]   || fail_setup "backend golden catalogue not found: $GO_GOLDEN
  (regenerate: cd $GO_SRC && SKEIN_UPDATE_TOKEN_CATALOGUE=1 go test ./internal/themes/ -run TestCatalogueGolden)"
[ -f "$TS_MIGRATION" ] || fail_setup "frontend migration table not found: $TS_MIGRATION"
[ -f "$GO_RETIRED_GOLDEN" ] || fail_setup "backend golden retired-role table not found: $GO_RETIRED_GOLDEN
  (regenerate: cd $GO_SRC && SKEIN_UPDATE_RETIRED_ROLES=1 go test ./internal/themes/ -run TestRetiredRolesGolden)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── 1. Prove the golden still equals the live Go catalogue ────────────
#
# Without this the script compares the frontend against a FILE, and a
# stale golden would let a real drift pass. The test is pure Go, needs
# no database and runs in milliseconds.
if command -v go >/dev/null 2>&1; then
  if ! (cd "$GO_SRC" && go test ./internal/themes/ \
        -run 'TestCatalogueGolden|TestRetiredRolesGolden' -count=1) >"$WORK/gotest.log" 2>&1; then
    echo "check-theme-mirror: a backend golden guard is RED — the golden catalogue"
    echo "  or the golden retired-role table no longer matches its live Go source,"
    echo "  so neither can stand in for the mirror here. Fix that first:"
    echo
    sed 's/^/  /' "$WORK/gotest.log"
    exit 2
  fi
else
  echo "check-theme-mirror: WARNING — no Go toolchain on PATH, so the goldens are"
  echo "  trusted rather than verified against themes.TokenSchema and"
  echo "  themes.RetiredRoles. A schema.go or roles.go edit that was never"
  echo "  accompanied by a golden regeneration would be invisible to this run."
fi

# ── 2. Frontend side: evaluate the TOKEN_SECTIONS literal ─────────────
#
# The array is plain data, but it references module-level constants
# (font presets). Rather than stub them by name — which breaks the next
# time someone adds one — the literal is evaluated in a vm context whose
# global object answers every unknown identifier with an empty array.
node - "$TS_REGISTRY" > "$WORK/ts.tsv" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const src = fs.readFileSync(process.argv[2], 'utf8');
const marker = 'export const TOKEN_SECTIONS';
const start = src.indexOf(marker);
if (start < 0) {
  console.error('check-theme-mirror: "' + marker + '" not found in the registry — ' +
                'the declaration was renamed or removed; this script must be updated');
  process.exit(2);
}
const open = src.indexOf('[', src.indexOf('=', start));
if (open < 0) {
  console.error('check-theme-mirror: TOKEN_SECTIONS declaration has no array literal');
  process.exit(2);
}

// Walk to the matching close bracket, skipping strings and comments so
// a `]` inside a hint or a docblock does not end the literal early.
let depth = 0, i = open, end = -1;
while (i < src.length) {
  const c = src[i];
  if (c === '/' && src[i + 1] === '/') { i = src.indexOf('\n', i); if (i < 0) break; continue; }
  if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i); if (i < 0) break; i += 2; continue; }
  if (c === '"' || c === "'" || c === '`') {
    const quote = c;
    i++;
    while (i < src.length && src[i] !== quote) { if (src[i] === '\\') i++; i++; }
    i++;
    continue;
  }
  if (c === '[') depth++;
  else if (c === ']') { depth--; if (depth === 0) { end = i; break; } }
  i++;
}
if (end < 0) {
  console.error('check-theme-mirror: could not find the end of the TOKEN_SECTIONS literal');
  process.exit(2);
}

const literal = src.slice(open, end + 1);
// Any identifier the literal references but does not define (font preset
// tables today, whatever tomorrow) resolves to an empty array. Nothing
// this script compares comes from them.
const sandbox = new Proxy({}, {
  has: () => true,
  get: (_t, prop) => (prop === Symbol.unscopables ? undefined : []),
});
let sections;
try {
  sections = vm.runInNewContext('(' + literal + ')', vm.createContext(sandbox));
} catch (e) {
  console.error('check-theme-mirror: TOKEN_SECTIONS did not evaluate: ' + e.message);
  process.exit(2);
}
if (!Array.isArray(sections)) {
  console.error('check-theme-mirror: TOKEN_SECTIONS did not evaluate to an array');
  process.exit(2);
}
const out = [];
for (const s of sections) {
  for (const t of (s.tokens || [])) {
    out.push([s.id, t.key, t.kind, t.label, t.light, t.dark].join('\t'));
  }
}
process.stdout.write(out.length ? out.join('\n') + '\n' : '');
NODE

cp "$GO_GOLDEN" "$WORK/go.tsv"

# ── 3. Compare the catalogue ──────────────────────────────────────────
#
# `|| rc=$?` rather than a bare call: this is no longer the last thing the
# script does, and under `set -e` a non-zero exit here would skip section
# 4 entirely — so a catalogue drift would HIDE a retired-role drift
# instead of being reported beside it.
rc_catalogue=0
node - "$WORK/ts.tsv" "$WORK/go.tsv" "$TS_REGISTRY" "$GO_GOLDEN" <<'NODE' || rc_catalogue=$?
const fs = require('fs');
const [, , tsPath, goPath, tsLabel, goLabel] = process.argv;

function load(p, side) {
  const raw = fs.readFileSync(p, 'utf8');
  const rows = new Map();
  const order = [];
  raw.split('\n').forEach((line, n) => {
    if (!line.trim()) return;
    const f = line.split('\t');
    if (f.length !== 6) {
      console.error(`check-theme-mirror: malformed ${side} row ${n + 1} (${f.length} fields, want 6): ${line}`);
      process.exit(2);
    }
    const [section, key, kind, label, light, dark] = f;
    if (rows.has(key)) {
      console.error(`check-theme-mirror: ${side} declares ${key} twice`);
      process.exit(2);
    }
    rows.set(key, { section, kind, label, light, dark });
    order.push(key);
  });
  return { rows, order };
}

const ts = load(tsPath, 'registry');
const go = load(goPath, 'mirror');

// Vacuity guard. Neither side may be empty: two empty sets match, and a
// script that reports "in sync" because it parsed nothing is worse than
// no script at all.
if (ts.order.length === 0) {
  console.error(`check-theme-mirror: parsed ZERO roles from the frontend registry (${tsLabel}).
  Either the file changed shape or the extraction is broken. Refusing to
  report agreement between two empty sets.`);
  process.exit(2);
}
if (go.order.length === 0) {
  console.error(`check-theme-mirror: parsed ZERO roles from the backend catalogue (${goLabel}).
  Refusing to report agreement between two empty sets.`);
  process.exit(2);
}

const problems = [];

for (const key of ts.order) {
  if (!go.rows.has(key)) {
    const r = ts.rows.get(key);
    problems.push(`MISSING FROM MIRROR  ${key}  (registry: section=${r.section} light=${JSON.stringify(r.light)} dark=${JSON.stringify(r.dark)})
    → agents never see this role: skein_theme(describe) does not list it, and a
      forked theme is seeded without it.`);
  }
}
for (const key of go.order) {
  if (!ts.rows.has(key)) {
    const r = go.rows.get(key);
    problems.push(`EXTRA IN MIRROR      ${key}  (mirror: section=${r.section} light=${JSON.stringify(r.light)} dark=${JSON.stringify(r.dark)})
    → the frontend has no such role: writing it changes nothing, and a fork
      seeds a dead variable onto :root.`);
  }
}
for (const key of ts.order) {
  const a = ts.rows.get(key), b = go.rows.get(key);
  if (!b) continue;
  for (const field of ['section', 'kind', 'label', 'light', 'dark']) {
    if (a[field] !== b[field]) {
      problems.push(`VALUE DIFFERS        ${key}.${field}
    registry: ${JSON.stringify(a[field])}
    mirror:   ${JSON.stringify(b[field])}
    → a fork writes the MIRROR's value onto :root, overriding the stylesheet.`);
    }
  }
}

const common = ts.order.filter((k) => go.rows.has(k));
const goCommon = go.order.filter((k) => ts.rows.has(k));
for (let i = 0; i < common.length; i++) {
  if (common[i] !== goCommon[i]) {
    problems.push(`ORDER DIFFERS        position ${i}: registry has ${common[i]}, mirror has ${goCommon[i]}
    → the editor renders the catalogue in this sequence; a reorder shuffles
      the user-visible sidebar.`);
    break;
  }
}

if (problems.length === 0) {
  console.log(`check-theme-mirror: catalogue OK — ${ts.order.length} roles across ` +
              `${new Set(ts.order.map((k) => ts.rows.get(k).section)).size} sections agree.`);
  console.log(`  registry: ${tsLabel}`);
  console.log(`  mirror:   ${goLabel}`);
  process.exit(0);
}

console.error(`check-theme-mirror: MIRROR OUT OF SYNC — ${problems.length} difference(s).`);
console.error(`  registry: ${tsLabel}  (${ts.order.length} roles)`);
console.error(`  mirror:   ${goLabel}  (${go.order.length} roles)`);
console.error('');
for (const p of problems) console.error('  ' + p + '\n');
console.error(`Fix: edit internal/themes/schema.go to match the registry, then
  cd projects/skein-api/src && SKEIN_UPDATE_TOKEN_CATALOGUE=1 go test ./internal/themes/ -run TestCatalogueGolden
  and update the counts in internal/mcp/tools/theme_instructions.md.`);
process.exit(1);
NODE

# ── 4. Compare the retired-role table ─────────────────────────────────
#
# Same shape as section 3: evaluate the frontend's object literal, load
# the backend's golden, diff. Two differences worth stating.
#
# The frontend's table is keyed by ALL 61 pre-redesign names, of which 14
# are still live roles today; the backend's is only the 47 that are not.
# So the frontend side is FILTERED by the catalogue that section 3 just
# compared — which is why this section runs second and why it reads
# ts.tsv rather than re-deriving the role set.
#
# The frontend spells "no successor" as `null` and the golden spells it
# as an empty field. They are normalised to the empty string on both
# sides, once, here — rather than teaching either side about the other's
# spelling.
rc_retired=0
node - "$TS_MIGRATION" "$GO_RETIRED_GOLDEN" "$WORK/ts.tsv" <<'NODE' || rc_retired=$?
const fs = require('fs');
const vm = require('vm');
const [, , tsPath, goPath, catalogueTsvPath] = process.argv;

// The live role set, straight from the catalogue this run already
// parsed. Re-deriving it here would be a second parser of the same file
// and a second thing to keep right.
const live = new Set(
  fs.readFileSync(catalogueTsvPath, 'utf8')
    .split('\n')
    .filter((l) => l.trim())
    .map((l) => l.split('\t')[1]),
);
if (live.size === 0) {
  console.error('check-theme-mirror: the catalogue TSV yielded no roles, so the ' +
                'retired set cannot be derived. Refusing to compare.');
  process.exit(2);
}

const src = fs.readFileSync(tsPath, 'utf8');
const marker = 'export const LEGACY_TO_NEW';
const start = src.indexOf(marker);
if (start < 0) {
  console.error('check-theme-mirror: "' + marker + '" not found in ' + tsPath +
                ' — the declaration was renamed or removed; this script must be updated');
  process.exit(2);
}
const open = src.indexOf('{', src.indexOf('=', start));
if (open < 0) {
  console.error('check-theme-mirror: LEGACY_TO_NEW declaration has no object literal');
  process.exit(2);
}
// Same brace walk as section 2, skipping strings and comments so a `}`
// inside either does not end the literal early.
let depth = 0, i = open, end = -1;
while (i < src.length) {
  const c = src[i];
  if (c === '/' && src[i + 1] === '/') { i = src.indexOf('\n', i); if (i < 0) break; continue; }
  if (c === '/' && src[i + 1] === '*') { i = src.indexOf('*/', i); if (i < 0) break; i += 2; continue; }
  if (c === '"' || c === "'" || c === '`') {
    const quote = c;
    i++;
    while (i < src.length && src[i] !== quote) { if (src[i] === '\\') i++; i++; }
    i++;
    continue;
  }
  if (c === '{') depth++;
  else if (c === '}') { depth--; if (depth === 0) { end = i; break; } }
  i++;
}
if (end < 0) {
  console.error('check-theme-mirror: could not find the end of the LEGACY_TO_NEW literal');
  process.exit(2);
}
let table;
try {
  table = vm.runInNewContext('(' + src.slice(open, end + 1) + ')', vm.createContext({}));
} catch (e) {
  console.error('check-theme-mirror: LEGACY_TO_NEW did not evaluate: ' + e.message);
  process.exit(2);
}

// Restrict to the names that are no longer roles, and normalise "none".
const ts = new Map();
for (const [name, successor] of Object.entries(table)) {
  if (live.has(name)) continue;               // kept by the redesign
  ts.set(name, successor === null || successor === undefined ? '' : String(successor));
}

const go = new Map();
for (const line of fs.readFileSync(goPath, 'utf8').split('\n')) {
  if (!line.trim()) continue;
  const [name, successor] = line.split('\t');
  if (go.has(name)) {
    console.error(`check-theme-mirror: the retired-role golden declares ${name} twice`);
    process.exit(2);
  }
  go.set(name, successor === undefined ? '' : successor);
}

// Vacuity guard, as in section 3: two empty sets agree, and reporting
// that as success is the one outcome this script must never produce.
if (ts.size === 0) {
  console.error(`check-theme-mirror: derived ZERO retired roles from ${tsPath}.
  Either LEGACY_TO_NEW changed shape or every old name is now a live role.
  Refusing to report agreement between two empty sets.`);
  process.exit(2);
}
if (go.size === 0) {
  console.error(`check-theme-mirror: parsed ZERO rows from ${goPath}.
  Refusing to report agreement between two empty sets.`);
  process.exit(2);
}

const problems = [];
const show = (v) => (v === '' ? '(no successor)' : v);
for (const [name, successor] of ts) {
  if (!go.has(name)) {
    problems.push(`MISSING FROM MIRROR  ${name} → ${show(successor)}
    → skein_theme calls this name "unknown" instead of "retired", so the agent
      is told to look it up rather than told what replaced it.`);
    continue;
  }
  if (go.get(name) !== successor) {
    problems.push(`SUCCESSOR DIFFERS    ${name}
    migration: ${show(successor)}
    mirror:    ${show(go.get(name))}
    → the tool names a successor the migration never chose: an agent that
      follows the advice writes a role the value would not have gone to.`);
  }
}
for (const name of go.keys()) {
  if (!ts.has(name)) {
    problems.push(`EXTRA IN MIRROR      ${name}
    → not a pre-redesign role at all (or one the redesign kept): set_variables
      reports it as retired and offers a migration that never happened.`);
  }
}

if (problems.length === 0) {
  console.log(`check-theme-mirror: retired roles OK — ${ts.size} names and their successors agree.`);
  process.exit(0);
}
console.error(`check-theme-mirror: RETIRED-ROLE TABLE OUT OF SYNC — ${problems.length} difference(s).`);
console.error(`  migration: ${tsPath}  (${ts.size} retired names)`);
console.error(`  mirror:    ${goPath}  (${go.size} rows)`);
console.error('');
for (const p of problems) console.error('  ' + p + '\n');
console.error(`Fix: edit internal/themes/roles.go to match LEGACY_TO_NEW, then
  cd projects/skein-api/src && SKEIN_UPDATE_RETIRED_ROLES=1 go test ./internal/themes/ -run TestRetiredRolesGolden
  and re-check the retired-roles block in internal/mcp/tools/theme_instructions.md.`);
process.exit(1);
NODE

# ── 5. One verdict ────────────────────────────────────────────────────
#
# Setup failures (2) outrank disagreements (1): a run that could not be
# performed is not a run that found a difference, and collapsing the two
# would let a broken extraction read as a red comparison.
if [ "$rc_catalogue" = "2" ] || [ "$rc_retired" = "2" ]; then
  exit 2
fi
if [ "$rc_catalogue" != "0" ] || [ "$rc_retired" != "0" ]; then
  exit 1
fi
echo "check-theme-mirror: OK — both comparisons agree."
exit 0
