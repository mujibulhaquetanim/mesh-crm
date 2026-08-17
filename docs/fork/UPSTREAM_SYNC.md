# Syncing the Fork with Upstream Chatwoot (Runbook)

**Who this is for:** you, the next time GitHub says *"This branch has conflicts
that must be resolved / Discard N commits to make this branch match the upstream
repository."* on the fork's `develop`.

**TL;DR:** When the banner offers to **discard commits**, do **not** click it —
that variant deletes your fork work. (When it offers a plain **"Update branch"**
merge instead, it is safe — see §1.) Do the merge by hand (§6). Expect **a small
number of conflicts** from the three classes in §2 — the `db/schema.rb` version
line (A), an OSS file the fork branded (B), or both sides appending at the same
anchor (C). Each has a standing resolution rule, and **the rules differ**: B says
take upstream, C says keep both. Then **bring the running stack back up (§6a)** —
migrate, let Vite rebuild, restart rails if the bundle hash changed. A pushed
merge is not a working stack.

This doc records the **2026-07-08** sync, the **2026-07-20** one which conflicted
in a way the original version of this doc said was impossible (§3b), the
**2026-07-28** one which merged clean but broke the stack twice on the way back
up (§3c, §6a), the **2026-08-11** one — 25 commits / 1238 files carrying the
**Rails 7.2.3.1 upgrade**, which introduced conflict class C and needs a
`bundle install` before the stack will boot at all (§3d) — and the
**2026-08-18** one, 57 commits / 285 files with **zero** conflicts, where the
candidate set was *measured before merging* instead of guessed (§3e).

> **This doc has twice asserted a closed set of conflict classes and been wrong
> both times** (§2). When you hit something that fits none of the three, resolve
> it on the merits — additive or competing? — and add a §3x entry rather than
> forcing it into an existing class.

- **`upstream`** = `github.com/chatwoot/chatwoot` (the original repo).
- **`origin`**  = `github.com/mujibulhaquetanim/mesh-crm` (your fork).

Related: [`UPSTREAM_DIFF.md`](./UPSTREAM_DIFF.md) (what the fork changes and why it
stays conflict-friendly), [`ARCHITECTURE.md`](./ARCHITECTURE.md) (the `custom/`
overlay mechanism).

---

## 1. What actually happened

GitHub's fork page showed, on `develop`:

> This branch has conflicts that must be resolved.
> Discard 31 commits to make this branch match the upstream repository.
> 31 commits will be removed from this branch.

This looks alarming, but it is **not** a code problem. It is GitHub's **"Sync
fork"** feature talking. Here is the real state we measured with git:

| Ref | Relationship to `upstream/develop` |
|---|---|
| `origin/develop` (your fork) | **31 ahead**, 14 behind |
| merge-base (last common commit) | `8818d27`, dated **2026-07-02** |

The two histories had simply **diverged**: your fork had 31 commits of fork work
(the `custom/` overlay, docs, super-admin, quota, branding) that upstream doesn't
have, and upstream had 14 new commits that your fork didn't have yet.

### Why GitHub offered to "discard 31 commits"

GitHub's **Sync fork** button has two modes, picked automatically:

1. **Clean case → "Update branch."** If upstream's new commits merge into your
   branch without conflicts, the button performs a real **merge** (commit
   message *"Merge branch 'chatwoot:develop' into develop"*) — or a fast-forward
   when your branch has no commits of its own. This is safe: it is the same
   merge §6 does by hand. It happened on **2026-07-10** (merge commit
   `cc717c6`, 13 upstream commits, zero conflicts, fork columns verified
   intact afterwards).
2. **Conflict case → "Discard N commits."** If the merge *would conflict*
   (here: the `db/schema.rb` version line, §2), GitHub cannot resolve it in the
   web UI, so its only remaining offer is: **throw away your N commits so the
   branch matches upstream exactly.** That would erase the entire fork.
   **Never accept the discard offer.**

So the button itself is not the trap — the **"discard commits"** fallback is.
When you see "conflicts must be resolved / discard N commits", close the page
and do the manual merge below; the conflicts are few and each has a standing
resolution rule (§2).

---

## 2. The three things that can conflict

> **Corrected 2026-07-20.** This section used to claim `db/schema.rb` was the
> *only* possible conflict and that there were "zero conflicts in any actual
> code." That is wrong, and it set the wrong expectation: the 2026-07-20 sync
> conflicted on a **`.vue` file** while `schema.rb` merged clean — the exact
> inverse of what this doc promised. See §3b for that case.
>
> **Corrected again 2026-08-11.** This section then claimed there were "exactly
> **two**" classes. Also wrong. The 2026-08-11 sync hit a **third**: both sides
> *added a different thing at the same anchor*, which is neither a generated-file
> collision (A) nor an edit to a line the fork had changed (B). Class C is listed
> below and worked through in §3d. The lesson is not the specific class — it is
> that this section has now been wrong twice by asserting a closed set. Treat the
> table as **the classes seen so far**, not an exhaustive list.

There are **three** classes of conflict seen so far, with different causes:

| # | Surface | Cause | Frequency |
|---|---|---|---|
| **A** | `db/schema.rb` version line | Both sides added migrations since the split | Only when *both* sides migrated |
| **B** | The OSS files the fork **edits directly** | Upstream changes a line the fork also changed | Rare, and shrinking — see below |
| **C** | An OSS **extension point** the fork appends to | Both sides *add* something at the same anchor; neither edited the other's line | Whenever upstream adds a sibling to a list the fork also extends |

**Class C does not mean either side is wrong**, and it is the one class where the
"take upstream's side" reflex is actively harmful — doing so silently deletes a
fork feature. The resolution is almost always **keep both**. See §3d.

**Class B is the one to actually watch.** The reassuring version of this doc was
right about `custom/`: fork *behavior* lives there, upstream never touches that
tree, so it cannot textually collide. But the fork does not live *entirely* in
`custom/`. It edits a small, catalogued set of OSS files directly — chiefly the
**white-label pass** (`432483c`), which replaced literal "Chatwoot" strings in
`en.json` / `en.yml` and a handful of `.vue` literals. Those lines are OSS lines,
so upstream can and does edit them too. See
[`UPSTREAM_DIFF.md` §0](./UPSTREAM_DIFF.md) for the full catalogue of the fork's
OSS touchpoints — **that list is your conflict surface**, not `schema.rb`.

The good news: class B is **self-liquidating**. Upstream is independently
migrating its own hardcoded brand strings to `replaceInstallationName()`. Every
time it does, the fork's corresponding hardcode should be *dropped* in favour of
upstream's dynamic version (§3b) — which permanently removes that line from the
conflict surface.

### Why `db/schema.rb` conflicts every time

`db/schema.rb` is a **generated file**. Its first meaningful line is a version
stamp equal to the timestamp of the newest migration that has been applied:

```ruby
ActiveRecord::Schema[7.1].define(version: 2026_07_06_215758) do
```

Both sides added migrations since the 2026-07-02 split, so both sides bumped this
line to a *different* value — and git can't auto-pick one:

| Side | Newest migration added | schema version line |
|---|---|---|
| merge-base (2026-07-02) | — | `2026_06_20_000000` |
| **your fork** | `20260704000000_add_platform_managed_to_platform_resources` | `2026_07_04_000000` |
| **upstream** | `20260706215758_add_feature_flags_ext_2_to_accounts` (+2 index migs) | `2026_07_06_215758` |

The **table/column bodies** of `schema.rb` merged cleanly on their own, because
each side's new columns live in different, non-overlapping sections of the file.
Only the single version line at the top actually conflicts. **This recurs on any
sync where *both* sides added migrations since the last one** — it is normal and
trivial. (When only upstream added migrations — the common case once the fork's
schema work settles — the merge is conflict-free, as on 2026-07-10.)

---

## 3. How it was fixed (exact steps)

```bash
# 0. Make sure upstream is fetched
git fetch upstream develop

# 1. Get local develop to the fork's tip, then merge upstream in
git checkout develop
git merge --ff-only origin/develop      # local develop -> fork tip (0f8c9ba)
git merge --no-ff upstream/develop       # conflicts ONLY on db/schema.rb
```

The conflict looked like this:

```
<<<<<<< HEAD
ActiveRecord::Schema[7.1].define(version: 2026_07_04_000000) do
=======
ActiveRecord::Schema[7.1].define(version: 2026_07_06_215758) do
>>>>>>> upstream/develop
```

**Resolution rule: keep the newer (higher) timestamp.** After a full merge the
newest applied migration is upstream's `2026_07_06_215758`, so that line wins:

```ruby
ActiveRecord::Schema[7.1].define(version: 2026_07_06_215758) do
```

Then verify **both** sides' schema changes survived the auto-merge (they did),
finish the merge, and push **to the fork only**:

```bash
git grep -nE '^(<<<<<<<|=======|>>>>>>>)'   # -> nothing: no markers left
grep -c platform_managed db/schema.rb        # -> 3  (fork columns present)
grep -c index_calls_on_account_id_and_created_at db/schema.rb  # -> 1 (upstream present)

git add db/schema.rb
git commit --no-edit                         # merge commit 745be5b
git push origin develop                      # to YOUR fork, never upstream
```

**Session audit trail (SHAs):**

| Thing | SHA |
|---|---|
| merge-base (2026-07-02) | `8818d27` |
| fork `develop` before merge | `0f8c9ba` |
| `upstream/develop` tip merged in | `b9536fb` |
| the merge commit | `745be5b` |
| develop after PR #8 squash-merged on top | `c7d17c8` |

> **Note on regenerating instead of hand-editing:** the 100%-correct way to
> produce `schema.rb` is to run the migrations and let Rails re-dump it
> (`db:migrate` / `db:schema:dump`). Hand-picking the version line is the fast,
> safe shortcut *when the column bodies already auto-merged cleanly* — which is
> the normal case. If you ever see conflicts inside the table bodies (not just
> the version line), don't hand-merge: finish the merge taking either side, then
> run migrations in dev and commit the regenerated `schema.rb`.

---

## 3b. Worked example of a class-B conflict (2026-07-20)

The sync of **14 upstream commits** (`5af26e4` → `160732c`, Chatwoot 4.16.0)
behaved the opposite way to everything above:

- `db/schema.rb` **merged clean** — the fork added no migrations that cycle, so
  upstream's newer stamp (`2026_07_13_184351`) won uncontested.
- The one conflict was in
  `app/javascript/dashboard/routes/dashboard/settings/inbox/components/SenderNameExamplePreview.vue`.

Upstream PR **#15076** ("apply installation name to sender name preview") changed
the same two lines the fork's white-label pass had changed:

```
<<<<<<< HEAD
      businessName: 'Meta CRM',                        ← fork: hardcoded
=======
      businessName: replaceInstallationName('Chatwoot'), ← upstream: dynamic
>>>>>>> upstream/develop
```

**Resolution rule for class B: when upstream implements the branding properly,
take upstream's side and drop the fork's hardcode.**

Here that was strictly better on three counts:

1. It is the pattern the fork's own `CLAUDE.md` prescribes — route brand strings
   through `replaceInstallationName` from `shared/composables/useBranding`
   instead of hardcoding.
2. It still renders the installation's brand: the composable substitutes
   `globalConfig.installationName`, which `Custom::BrandingSetup`
   (`custom/app/services/custom/branding_setup.rb`) populates from
   `INSTALLATION_NAME`.

   > The diff above is quoted **verbatim from 2026-07-20**, when the fork's
   > brand string was `Meta CRM`. On 2026-08-11 the brand was renamed to
   > **Mesh CRM** to match the product register in
   > `../../../agentic-str/docs/README.md` §Naming — "Meta CRM" was a fifth
   > name that register never listed. The quote is left as-is because it is
   > evidence of what that conflict actually looked like; everywhere else in
   > `docs/fork/` now says Mesh CRM. See [`WHITE_LABEL.md`](./WHITE_LABEL.md).
3. It **removes** a fork edit to an OSS file, so those two lines can never
   conflict again.

Before taking upstream wholesale, confirm the fork's edit to that file was
*only* the branding lines:

```bash
git diff <merge-base> develop -- <the-conflicted-file>
```

If the fork made other changes to the file, resolve hunk-by-hunk instead of
`git checkout --theirs`.

### Verify the overlay still binds (do this every sync)

A clean text merge does **not** prove the `custom/` overlay still works —
`prepend` silently breaks if upstream renames or removes the method being
`super`'d. Cross-reference what upstream touched against what the fork overlays:

```bash
git diff <merge-base> upstream/develop --name-only > /tmp/up.txt
git ls-files custom/ | grep -E '\.rb$' | while read f; do
  oss=$(echo "$f" | sed 's|^custom/||; s|/custom/|/|')
  grep -qxF "$oss" /tmp/up.txt && echo "OVERLAP: $oss"
done
```

For each overlap, confirm the method the overlay calls `super` on still exists.
On 2026-07-20 there was one — `app/models/inbox.rb` — and it was benign:
upstream added `InboxBrandedEmailLayoutable` and an `email_templates`
association, neither of which touches `assignable_agents`, the method
`Custom::Inbox` overrides.

Also confirm the white-label pass did not regress — upstream's new strings can
reintroduce "Chatwoot" into files the fork de-branded:

```bash
grep -ci chatwoot app/javascript/dashboard/i18n/locale/en/*.json
# compare against the same counts before the merge; they should be unchanged
```

**Audit trail:**

| Thing | SHA |
|---|---|
| merge-base | `5af26e4` |
| `upstream/develop` tip merged in | `160732c` |
| the merge commit on `develop` | `8d48f57` |
| merge into `fork/super-admin-privilege-separation-spec` | `f2fe7e3` |

---

## 3c. The clean case, and what the missing guards cost (2026-07-28)

Sync of **15 upstream commits** (`19c96fc` → `ce8cbf2`). **Zero conflicts** — the
first sync where neither class A nor class B fired.

- **`db/schema.rb` merged clean.** The fork added no migrations this cycle, so
  its version line still read `2026_07_18_000000` at the merge-base and only
  upstream moved it (to `2026_07_24_000100`). One-sided change, nothing to
  resolve. This is the "common case once the fork's schema work settles" that §2
  predicts.
- **No class-B conflict.** Upstream touched 50 files; none were files the fork
  overlays or brands.

Verification (all from §3b, run before pushing):

| Check | Result |
| --- | --- |
| Conflict markers in tree | none (the hits in this file are its own examples) |
| Overlay overlap (`custom/*.rb` vs upstream's 50 files) | none |
| Branding counts, en locale JSON | 10 before → 10 after, same files |
| `platform_managed` in `schema.rb` | 3 |
| `custom/` · `spec/custom/` · `docs/fork/` | 37 · 14 · 50 files |

> **Sort before diffing the branding counts.** `grep -c … en/*.json` does not
> emit a stable file order, so a naive `diff` of two runs reports dozens of
> phantom changes. Sort both sides; only then does "identical" mean anything.

### The guards were missing, and it cost a real mistake

Both §4 guards were **absent on this machine** when this sync started:
`upstream`'s push URL was the live Chatwoot URL, and no `gh` default repo was
set. §4 already warns they are machine-local and must be re-applied per clone —
but nothing *checks*, so the gap is invisible until it bites.

It bit: with no default repo, `gh pr create` defaulted the base to the **parent**
repo and opened a PR against **public `chatwoot/chatwoot` (#15219)** carrying
this fork's internal docs. Closed within a minute, but closed PRs are permanent
public record.

Two lessons, both now folded into §4/§5:

1. **Run the §5 guard verification *before* any sync or PR work**, not "anytime".
2. This doc said `gh repo set-default mujibulhaquetanim/meta-crm` — the repo is
   `mesh-crm`. Following it literally sets nothing (that repo does not exist),
   which is exactly how the guard came to be missing. Corrected throughout.

Also: pass `--repo` explicitly on `gh pr create` in this repo. It costs nothing
and does not depend on machine-local state that a fresh clone silently lacks.

**Audit trail:**

| Thing | SHA |
|---|---|
| merge-base | `19c96fcc0` |
| fork `develop` before merge | `de9d386fb` |
| `upstream/develop` tip merged in | `ce8cbf216` |
| the merge commit | `8754b1c9e` |

---

## 3d. Class C, and the biggest sync so far (2026-08-11)

Sync of **25 upstream commits** (`ce0612158` → `2fbcc715c`) — **1238 files,
+35 274/−7 760**. Every prior sync in this doc was 13–15 commits and ~50 files;
this one is an order of magnitude larger because it carries the **Rails 7.2.3.1
upgrade** (#13437). Budget accordingly: the merge itself is still fast, but the
bring-up (§6a) is not, because the bundle changes.

### The conflict was class C — keep BOTH sides

One conflict, in `app/javascript/dashboard/App.vue`, at all three banner anchors:

```
<<<<<<< HEAD
import AgenticAiLimitBanner from './fork/AgenticAiLimitBanner.vue';
=======
import LowBackupCodesBanner from './components/app/LowBackupCodesBanner.vue';
>>>>>>> upstream/develop
```

Upstream #14103 added a low-backup-codes banner; the fork has its agentic-AI
quota banner. **Neither touched the other's line** — both merely *appended* to
the same three lists (import, `components:`, template). Git reports it as a
conflict only because the insertions are adjacent.

**Resolution: keep both**, fork's line **last** in each block, so the next
upstream insertion lands above it and this stays a trivial re-resolve:

```js
import LowBackupCodesBanner from './components/app/LowBackupCodesBanner.vue';
import AgenticAiLimitBanner from './fork/AgenticAiLimitBanner.vue';
```

> ⚠️ **§3b's rule does not apply here.** "Take upstream's side and drop the
> fork's hardcode" is correct for class B, where upstream reimplements something
> the fork had hacked. Applying it to class C would have **silently deleted the
> agentic-AI quota banner** — a shipped fork feature — and nothing downstream
> would have failed loudly. Before taking upstream wholesale, always ask whether
> the two sides are *competing* (B) or *additive* (C).

### Verification (§3b checks, all run before commit)

| Check | Result |
| --- | --- |
| Conflict markers in tree | none |
| Overlay overlap (`custom/*.rb` vs upstream's 1238 files) | **2**, both benign — see below |
| Branding counts, en locale JSON | 20 before → 20 after, no file changed |
| `platform_managed` in `schema.rb` | 3 |
| `custom/` · `spec/custom/` · `docs/fork/` | 37 · 15 · 51 files |
| `db/schema.rb` | merged clean — neither side migrated (§3c case) |

The two overlay overlaps, and why neither breaks:

- **`app/services/mfa/management_service.rb`** — the overlay overrides
  `two_factor_provisioning_uri`, which still exists upstream (line 23). Upstream
  only **added** `remaining_backup_codes_count` alongside it. No collision.
- **`app/models/integrations/hook.rb`** — the overlay overrides *no method at
  all*; it only injects `Custom::Concerns::QuotaGuard` via `self.prepended`.
  Upstream narrowed `before_validation :ensure_hook_type` to `on: :create`,
  which cannot affect an overlay with no `super` target. (QuotaGuard's own
  `validate :ensure_quota_capacity` was already `on: :create`.)

### Rails 7.2.3.1 — what to check, and what is NOT done by merging

The merge lands the upgrade textually. It does **not** prove it runs:

| Check | Value after merge |
| --- | --- |
| `Gemfile` / `Gemfile.lock` | both `7.2.3.1` |
| `config.load_defaults` | still **7.0** — upstream kept the runtime upgrade separate from the behaviour changes, deliberately |
| sidekiq / connection_pool | `7.3.10` / `2.5.5` (upstream pinned these) |
| Azure Active Storage | unmaintained fork replaced with `azure-blob`, service name `microsoft` preserved |

⚠️ **`bundle install` must run before the stack will boot** — the lockfile moved
a whole dependency set. §6a's `db:migrate` will fail with a bundle error before
it ever reaches the database if you skip it. A merge this size is not "done" at
push time; it is done when `doctor.sh` is green.

> Upstream also added `docs/rails_upgrade_assessment.md` in the same commit. It
> is **upstream-owned** — do not edit it to reflect fork state, or it becomes
> permanent conflict surface. Its step 1 (move to 7.2.3.1, keep 7.0 defaults) is
> what this sync landed; steps 2–4 (8.0.5, 8.1.3, then defaults) remain upstream's
> roadmap, not the fork's.

### Also landed in this pass: the brand rename

Unrelated to the merge but committed alongside it: the fork's white-label brand
was **`Meta CRM` → `Mesh CRM`** across 23 code files (44 strings) and the
`docs/fork/` set. "Meta CRM" was a fifth name that
`../../../agentic-str/docs/README.md` §Naming never listed — that register says
the vendor-facing product is **Mesh CRM**. `INSTALLATION_NAME` is unset in every
env file, so the hardcoded literals were live vendor-visible copy, not defaults.
See [`WHITE_LABEL.md`](./WHITE_LABEL.md).

**Audit trail:**

| Thing | SHA |
|---|---|
| merge-base | `ce0612158` |
| fork `develop` before merge | `5f8aaeeee` |
| `upstream/develop` tip merged in | `2fbcc715c` |
| the merge commit | `e3db63a41d` |

---

## 3e. Stop guessing the conflict set — measure it (2026-08-18)

Sync of **57 upstream commits** (`2fbcc715c` → `89a933f76`) — 285 files,
+9 677/−3 051. More than twice the commit count of any previous sync, and it
produced **zero conflicts**.

### The technique: compute the candidate set before merging

Every previous entry in this doc discovered its conflicts by running the merge
and reading what broke. You don't have to. Only files changed on **both** sides
can conflict, and both lists are available before you touch anything:

```sh
git fetch https://github.com/chatwoot/chatwoot.git develop
BASE=$(git merge-base HEAD FETCH_HEAD)
git diff --name-only "$BASE" FETCH_HEAD | sort > /tmp/up.txt      # upstream's side
git diff --name-only "$BASE" HEAD \
  | grep -vE '^(custom/|docs/fork/|spec/custom/)' | sort > /tmp/fork.txt
comm -12 /tmp/up.txt /tmp/fork.txt        # <- the ONLY files that can conflict
```

On 2026-08-18 that printed exactly four names, and all four auto-merged:

| Candidate | Why it did not conflict |
|---|---|
| `db/schema.rb` | Fork added no migration this cycle, so its version line still read the merge-base's `2026_08_04_000003`; only upstream moved it (→ `2026_08_07_133000`). One-sided — the §3c case, not class A. |
| `.../en/conversation.json` | Upstream edited different keys than the white-label pass |
| `.../en/generalSettings.json` | same |
| `.../en/integrations.json` | same |

This turns §6's vague "expect 0-2 conflicts" into a number you know **before**
you start, and it tells you in advance which standing rule (A/B/C) you'll need.
Run it first on every future sync.

### The scoped hotspots that did not fire

This sync was planned expecting trouble in `db/schema.rb`, `Gemfile.lock`,
`config/routes.rb`, the compose/devcontainer files, and the JS lockfile. The
`comm` output above is why none of it happened: upstream **did not touch**
`docker-compose.yaml`, `.devcontainer/devcontainer.json`, `config/database.yml`,
either dockerfile, `config/application.rb`, `config/locales/en.yml`,
`app/javascript/dashboard/App.vue`, or the webhooks jbuilder views.
`config/routes.rb`, `Gemfile.lock` and `pnpm-lock.yaml` moved on upstream's side
only and were taken verbatim — **no lockfile was hand-edited or regenerated**,
which is the correct handling: the fork does not modify them, so there is never
anything of its own to preserve.

> **A one-sided lockfile still changes your containers.** `Gemfile.lock`'s whole
> delta here was #15500 (hairtrigger 1.0.0→1.3.1, ruby_parser 3.20.0→3.22.0), and
> the very next `run --rm test` died with `Bundler::GemNotFound`. That is not a
> merge error — it is
> [2026-07-20-rspec-test-service-loses-installed-gems](./error-log/2026-07-20-rspec-test-service-loses-installed-gems.md)
> firing exactly as that entry predicted ("will keep failing after any sync that
> touches `Gemfile.lock`"). Use its `sh -c "bundle install && …"` one-liner.

### `#15500` is a lockfile fix, not a schema rewrite

"fix: restore Rails 7.2 schema dumps (#15500)" reads like it rewrites
`db/schema.rb`. It does not — `git show --stat 8d263a06a0` is **`Gemfile.lock`
only**, 4 insertions / 3 deletions. It repairs the *dumper* (a hairtrigger that
accepts `activerecord < 9`, a ruby_parser that parses Ruby 3.4) so that
`db:schema:dump` completes with triggers intact. The fork already ran 7.2.3.1,
so there was **no dump-format reconciliation to do**. Read the stat before
believing a commit subject.

### Verification (§3b checks, plus schema-load as loadable truth)

| Check | Result |
| --- | --- |
| Conflict markers in tree | none |
| Overlay overlap (`custom/*.rb` vs upstream's 285 files) | **0** |
| All 17 `prepend_mod_with` extension points + `application.rb` bootstrap | present |
| Branding counts, en locale JSON | 20 before → 20 after, no file changed |
| `platform_managed` in `schema.rb` / webhooks jbuilder (#15) | 3 / intact |
| `custom/` · `spec/custom/` · `docs/fork/` | 37 · 16 · 52 files |

**Don't stop at grepping `schema.rb` — load it.** A merged generated file can be
textually plausible and still not load. On a *freshly recreated* tmpfs test DB
(`docker compose … rm -sf postgres-test` first, since the DB survives `run --rm`):

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c "bundle install && bundle exec rails db:create db:schema:load"
```

→ 100 tables, `max(schema_migrations.version) = 20260807133000` (identical to the
merged version line), 4 hairtrigger triggers retained. All three new upstream
migrations confirmed *in the database*, not just in the file — `campaign_recipients`
(+8 indexes), `campaigns.started_at/completed_at`,
`index_conversations_on_account_id_status_created_at`,
`index_agent_sessions_on_document_ids` — alongside all three fork
`platform_managed` columns.

Suites (the rspec runs are also the Rails-boot proof; the dev stack was not booted):

| Suite | Result |
| --- | --- |
| `spec/custom` | 124 examples, **1 failure** — byte-identical to the pre-sync baseline |
| Upstream specs over the fork's overlay surfaces | 96 examples, **0 failures** |

> **Capture the baseline *before* you merge.** The tree is bind-mounted into the
> test container, so once you merge you can no longer measure the "before". The
> pre-sync run on `develop` gave 124/1, and the post-merge failure block diffs
> clean against it except the timing line — which is what makes "pre-existing"
> a measurement instead of an assumption.

Overlay surfaces exercised: webhooks controller + request specs, platform
`account_users` / `accounts` / `users` controllers, and both the OSS and
enterprise agents controllers (including the fork-adjusted cap-exact spec from
`UPSTREAM_DIFF.md` §6). Scope note: the **full** upstream suite was not run.

**Audit trail:**

| Thing | SHA |
|---|---|
| merge-base | `2fbcc715c` |
| fork `develop` before merge | `12d8d7b890` |
| `upstream/develop` tip merged in | `89a933f763` |
| the merge commit | `305988f383` |

---

## 4. The guards that stop you pushing fork code into Chatwoot

Two guards were installed on **2026-07-08** so your project code can never
accidentally land in `chatwoot/chatwoot`.

### Guard 1 — `git push upstream` is disabled

The `upstream` remote's **push** URL was pointed at an invalid sentinel, so any
push to upstream fails instantly and locally (no network, no accident). **Fetch
still works** (fetch URL unchanged).

```bash
git remote set-url --push upstream DISABLE_PUSH_TO_CHATWOOT_UPSTREAM
```

### Guard 2 — `gh pr create` targets the fork

```bash
gh repo set-default mujibulhaquetanim/mesh-crm
```

Without this, `gh pr create` defaults a new PR's base to the **parent** repo
(chatwoot). With it, PRs go to your fork's `develop`.

### ⚠️ The web UI is the one hole these guards don't cover

Opening a PR on **github.com** still defaults the *base repository* to the parent
(chatwoot). When you create PRs in the browser, **check the "base repository"
dropdown says `mujibulhaquetanim/mesh-crm`** before clicking create.

### ⚠️ These guards are machine-local, not committed

Both guards live in **local git/gh config on this machine only** — they are *not*
part of the repo. On a **fresh clone** (or a new machine) you must re-apply them,
then re-verify.

---

## 5. Verify the guards — FIRST, before any sync or PR

Run this **before** §6 and before any `gh pr create`, not "anytime". The guards
are machine-local (§4), so a fresh clone or new machine silently has none — and
the failure mode is a PR opened against public upstream (§3c), which cannot be
undone.

```bash
# Guard 1: push URL must be the sentinel, and a push must fail
git remote -v | grep upstream
#   upstream  https://github.com/chatwoot/chatwoot.git (fetch)
#   upstream  DISABLE_PUSH_TO_CHATWOOT_UPSTREAM (push)      <- correct
git push upstream develop --dry-run    # must FAIL ("repository does not exist")

# Guard 2: default repo must be the fork
gh repo set-default --view             # -> mujibulhaquetanim/mesh-crm
```

Both were confirmed working on 2026-07-08.

---

## 6. The routine for every future upstream sync

Do this whenever you want upstream's latest, or when GitHub nags about the fork
being behind:

```bash
# 0. Guards FIRST (§5) — machine-local, absent on any fresh clone.
git remote -v | grep upstream          # push URL must be the sentinel
gh repo set-default --view             # must be mujibulhaquetanim/mesh-crm

git fetch upstream develop             # NOT bare `git fetch upstream` — that pulls
                                       # every branch and can take many minutes
git checkout develop
git merge --ff-only origin/develop     # only if local is behind the fork remote

# Capture the spec/custom baseline NOW — the tree is bind-mounted into the test
# container, so after the merge the "before" is gone for good (§3e).
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c "bundle install && bundle exec rspec spec/custom" | tail -20

# Measure the conflict candidate set BEFORE merging (§3e) — only files changed on
# BOTH sides can conflict, so this is the complete list, known in advance.
BASE=$(git merge-base HEAD upstream/develop)
comm -12 <(git diff --name-only "$BASE" upstream/develop | sort) \
         <(git diff --name-only "$BASE" HEAD \
             | grep -vE '^(custom/|docs/fork/|spec/custom/)' | sort)

git merge --no-ff upstream/develop     # conflicts ⊆ the list above, see §2:
                                       #  A) db/schema.rb version line -> keep the higher timestamp
                                       #  B) an OSS file the fork branded -> usually take upstream (§3b)
git commit --no-edit
# then verify the overlay still binds + no branding regressions (§3b)
git push origin develop                # fork only
```

### 6a. Bring the running stack back up (do not skip)

**A pushed merge is not a working stack.** The merge changes files under the
running containers, so a sync is only done once the stack agrees. Both steps
below were needed on 2026-07-28 and both surfaced as hard failures.

```bash
# 1. Apply any migrations upstream brought.
docker compose -p mesh-crm exec -T rails bundle exec rails db:migrate
```

Skip it and every Chatwoot page 500s with `ActiveRecord::PendingMigrationError`.
Note `doctor.sh` reports a bare "500" and *guesses* Vite — read the log, do not
follow the guess:

```bash
docker compose -p mesh-crm logs --tail=60 rails | grep -iE 'migration|pending|vite'
```

**`db:migrate` re-dumps `db/schema.rb` and will dirty your tree.** That diff is
usually pure environment churn — index re-ordering, and Postgres normalizing
`where: "(a AND b)"` into `"((a AND b))"`. Discard it. Committing it adds
permanent conflict surface against upstream for no gain. Before discarding,
confirm the migration's real effect is already represented:

```bash
git diff db/schema.rb                       # version line should be UNCHANGED
git show HEAD:db/schema.rb | grep <new_index_name>   # already committed via the merge?
docker compose -p mesh-crm exec -T rails bundle exec rails runner \
  'puts ActiveRecord::Base.connection.indexes(:conversations).map(&:name).inspect'
git checkout db/schema.rb                   # only once both confirm
```

If the version line *did* change, or the new object is missing from both, do not
discard — commit the regenerated dump instead (§3 note).

```bash
# 2. Let Vite rebuild, then decide whether rails needs a restart.
docker compose -p mesh-crm logs --tail=6 vite     # wait for "built in <n>ms"
```

`bin/vite build --watch` empties `public/vite-dev/assets/` and rebuilds on every
start (~110-170 s). During that window the SPA bundle 404s and the page renders
blank — that is the rebuild, not a fault. **Then compare the hash:**

| Bundle hash after rebuild | Action |
|---|---|
| **unchanged** (no frontend commits in the sync) | nothing — Rails' memoized manifest is still valid |
| **changed** (upstream touched frontend) | `docker compose -p mesh-crm restart rails` — Rails memoized the OLD manifest at boot and will 404 forever otherwise |

A sync almost always changes the hash. 2026-07-28: `v3app-yqLgjwUB` →
`v3app-CGqUyaT6`, restart required.

```bash
# 3. Confirm.
../agentic-str/scripts/setup/doctor.sh      # want: Healthy, exit 0
```

Then bring feature branches up to date off the fork, not upstream:

```bash
git checkout <feature-branch>
git merge develop                      # usually zero conflicts (schema already resolved)
```

### Do / Don't

- ✅ **After pushing, bring the stack back up (§6a):** `rails db:migrate`, let Vite
  finish, `restart rails` if the bundle hash changed, then `doctor.sh`. A pushed
  merge is not a working stack.
- ✅ **Discard the `schema.rb` re-dump churn** after `db:migrate` (index order,
  `where:` parenthesization) — but only once the version line is unchanged and
  the new object is confirmed present (§6a).
- ✅ **Merge** `upstream/develop` into your `develop`, resolve the conflicts in §2, push to `origin`.
- ✅ Expect conflicts **only** in `db/schema.rb` and in the OSS files the fork edits
  directly (catalogued in [`UPSTREAM_DIFF.md` §0](./UPSTREAM_DIFF.md)) — mostly branding strings.
- ✅ When upstream implements a brand string via `replaceInstallationName`, take
  **upstream's** version and delete the fork's hardcode (§3b).
- ✅ Run the overlay-binding and branding-regression checks in §3b after every sync.
- ✅ `git fetch upstream develop`, not bare `git fetch upstream`.
- ✅ GitHub's **Sync fork → "Update branch"** (the clean-merge offer) is fine — it does this same merge.
- ✅ Verify guards after any fresh clone.
- ❌ **Never** click **"Discard N commits"** (Sync fork's conflict fallback) — it deletes the fork's commits.
- ❌ **Never** `git push upstream ...` (Guard 1 blocks it, but don't fight it).
- ❌ **Never** hand-edit `schema.rb` table bodies — if those conflict, regenerate via migrations.

---

## 7. Why this stays cheap forever

The fork keeps **all** real behavior in `custom/` (plus `docs/fork/` and
`spec/custom/`) — trees upstream never touches — and only ever touches OSS files
in the four inert ways catalogued in
[`UPSTREAM_DIFF.md` §0](./UPSTREAM_DIFF.md) (the fourth, dev-env/tooling files
like `docker-compose.yaml` and `database.yml`, is the one surface that *can*
conflict when upstream reworks those files — see `UPSTREAM_DIFF.md` §6).
That is *why* syncs of 13-14 upstream commits resolve in minutes rather than
turning into merge battles.

But "cheap" is not "zero" — the honest claim is narrower than the one this
section used to make:

- **`custom/`, `spec/custom/`, `docs/fork/` can never conflict.** Upstream does
  not know those trees exist. This is the architecture doing its job, and it
  covers the overwhelming majority of fork code.
- **The fork's direct OSS edits can conflict, and periodically will.** That is
  the white-label string pass plus the dev-env/tooling files. It is a small,
  enumerable surface — but it is not empty, and 2026-07-20 proved it (§3b).

The surface also **shrinks over time**: each time upstream converts one of its
own hardcoded brand strings to `replaceInstallationName`, the fork deletes its
corresponding hardcode and that line leaves the conflict surface permanently.
The way to keep syncs cheap is therefore to keep taking upstream's dynamic
implementation whenever it appears — never to re-hardcode a brand string that
upstream now handles through config.
