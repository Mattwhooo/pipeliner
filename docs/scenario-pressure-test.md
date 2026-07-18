# Pipeliner — Scenario Pressure Test

> Adversarial design review. This doc invents 20 concrete, realistic units of
> development work, traces each through the Pipeliner model as currently
> specified (README, concepts, execution-model, architecture, artifact-schema,
> worker, tech-stack, phase-playbooks, data-model), and records where the design
> is **underspecified**, **contradictory**, or **breaks**. It ends with a ranked
> cross-cutting findings list and a "what held up" section.
>
> Goal is to find real problems, not to validate. Citations point at the doc and
> section that the trace exercises.

---

## How to read a trace

Each scenario gives: the work, the phase-by-phase trace (steps as `type/role`,
claiming, git flow, loops, gates, finalization), and **per-scenario findings**
tagged `[GAP]` (underspecified), `[CONTRA]` (contradiction between docs), or
`[BREAK]` (the model has no path). Cross-cutting IDs (C#, M#) reference the
ranked list at the end.

---

## Scenario 1 — One-line bugfix (is 4-phase machinery overkill?)

**Work:** `off_by_one` in a pagination helper; a one-character fix in one file.

**Trace.** Pipeline created → branch `pipeliner/pl_x` cut from master; four phases
seeded (data-model `phases`, exactly four rows). Even for a typo:
- **Define** must run and, per execution-model §Gates, *"Phase 1 (Define) always
  has a human in the loop."* So a trivial fix forces a human gate + a Manager
  consensus loop (Explore→Requirements→critics) over "fix the off-by-one."
- **Plan** produces `technical_approach`/`technical_design`/`build_task_plan` for
  a one-line change; Scope Critic checks a one-task partition.
- **Build** one implementer edits one line; C1 Test Critic runs the suite.
- **Review** runs 3–4 critics + a report writer + final human gate, then
  finalization zips `.pipeliner/` to S3 and strips it.

**Findings.**
- `[GAP]` The four phases are **fixed and always present** (concepts.md "exactly
  four Phases (fixed, ordered, always present)"). Steps inside are dynamic, but
  the *phase rails, Managers, and the mandatory Define human gate* are not
  collapsible. There is no documented "fast path" for trivial work. A Planner can
  select a minimal step-set, but cannot remove a phase or the Phase-1 human gate.
  → **M12** (overkill / no phase-collapse).
- Cost/latency: five+ LLM steps, two+ gates, an S3 archive, and branch/worktree
  churn for a one-character diff. The design has no notion of "effort tier."

---

## Scenario 2 — Large multi-module feature, parallel builders (disjoint scopes)

**Work:** add "team billing" spanning API, service layer, and a settings UI panel.

**Trace.** Plan's **B2 Work Partitioner** (`planner/code`) writes `build_task_plan`
with disjoint scopes (execution-model §Parallel Builder rule); C3 Scope Critic
verifies disjointness. Build fans out: `B_api` (paths `app/controllers/billing/**`),
`B_svc` (`app/services/billing/**`), `B_ui` (`app/views/settings/**`). Each is a
separate `step_run`, claimed by any `code`-role worker via
`FOR UPDATE SKIP LOCKED` (data-model). Each runs in its own worktree/step branch;
control plane merges each disjoint diff back with no conflict (architecture
§branch-per-step). **B9 Integrator** wires modules; critics run.

**Findings.**
- `[BREAK]` Real multi-module features almost always touch **shared registration
  files**: `config/routes.rb`, a DI container, `package.json`, an i18n file, a nav
  menu. Path-based disjoint scopes (`step.json.scope.paths`) cannot express
  "every builder appends its route." Worse, the **server `pre-receive` hook
  rejects any diff touching paths outside the step's declared subtree/scope**
  (worker.md §Branch write rules #3b). So a builder that legitimately needs to add
  a route is *hard-blocked*. The Integrator (fan-in) is the only place allowed to
  touch shared files, but it cannot know each builder's needed route unless the
  builders emit that intent as an artifact — which is unspecified. → **M4**.
- Confirmation: for genuinely disjoint code, the fan-out + control-plane-merge
  story is clean. The problem is only the shared surface.

---

## Scenario 3 — UI-heavy task, `ui-tests` role, no browser worker connected (stuck)

**Work:** revamp a dashboard; workflow includes C2 UI Test Critic (`critic/ui-tests`).

**Trace.** Planner includes the conditional `ui-tests` step (phase-playbooks
Finding 5). At Build, C2's `step_run` is `ready` with `required_role='ui-tests'`.
No connected worker advertises `ui-tests` (worker.md §Stuck detection), so the
control plane flags the run (and pipeline) **stuck** and surfaces it (data-model
§Stuck detection, pipeline status `stuck`).

**Findings.**
- `[GAP]` Grace period before flagging is explicitly `[OPEN]` (worker.md).
- `[BREAK]` **Recovery is not specified.** The claim query is
  `WHERE state='ready' …` (data-model §Claiming), but a stuck run is set to
  `state='stuck'`. When a browser-capable worker later connects/heartbeats with
  `ui-tests`, **nothing flips `stuck → ready`.** The run can stay stuck forever.
  → **M7**.
- `[GAP]` Interaction with the Manager loop: while C2 is stuck, do the other Build
  critics (C1 Test, C3 Coverage) still run and can the Manager reach consensus
  without C2, or does the whole phase block? Undefined. → **M7**.

---

## Scenario 4 — Review discovers a requirement was never implemented (rework → Build)

**Work:** R-7 "export to CSV" specified in Define, designed in Plan, but Build
never produced it.

**Trace.** Review C1 Requirements-Conform (`critic/review`) emits
`verdict: needs_work`, finding targets R-7. Manager/Gate raises a **rework**
outcome `target_phase: 03-build` (execution-model §Inter-phase rework routing),
mode `automated` (info was present, just missed). `rework.json` appended in the
Build phase dir; `rework_events` row; `phase.status='reworking'`;
`phase.rework_count++` (cap check). Build re-opens with prior artifacts + feedback,
adds an implementer for CSV export, flows forward to Review again.

**Findings.**
- Structurally supported — this is the clean case the primitive was designed for
  (phase-playbooks Finding 1, RESOLVED). Confirmation.
- `[GAP]` Build was already **squashed to one phase commit** at its first gate
  (architecture §Phase-boundary squashing). Re-opening Build cuts new step
  branches from the *current* pipeline branch (which has the squashed, incomplete
  Build). Adding CSV export on top is fine here because it's purely additive.
  Contrast Scenario 5, where it is not.

---

## Scenario 5 — Review discovers the requirement itself was wrong (rework → Define)

**Work:** Review realizes R-3 mandated the wrong behavior; the built (and merged)
code implements R-3 faithfully but R-3 must change, invalidating Plan and Build.

**Trace.** Review raises `rework{ target_phase: 01-define, mode: human }`.
Define re-opens with a human adding context; requirements change; then
"flows forward again" → Plan re-runs → Build re-runs → Review.

**Findings.**
- `[BREAK]` **The already-merged, now-wrong code sits on the pipeline branch.**
  Rework re-opens Define but there is **no revert/supersede primitive** for the
  code Build already committed. Re-Build's implementers cut branches from the
  current pipeline branch (still carrying the wrong code) and are **additive and
  scope-limited** — deleting/rewriting the prior implementation isn't modeled, and
  the `pre-receive` scope hook may even block touching the old files if the new
  scope differs. → **C3**.
- `[CONTRA]` The clean ~4-commit history goal (README; architecture §squashing)
  assumes each phase's commit is authoritative. After a Define→…→Build rework, the
  pipeline branch has stale-then-corrected layers; "re-squashed on completion"
  collapses history but **does not remove the wrong code from the tree** — squash
  is "history-only, never touches the working tree" (artifact-schema P2). So the
  bad code persists in the working tree unless something explicitly reverts it. → **C3**.
- `[GAP]` Do Plan/Build **fully re-run** or diff against changed requirements?
  "Flows forward again" is the only guidance. Full re-run is wasteful; incremental
  is unspecified. → **C3**.

---

## Scenario 6 — Two parallel builders whose scopes turn out to overlap (merge conflict)

**Work:** Planner partitioned into `B_a` (paths `app/models/order/**`) and `B_b`
(`app/services/checkout/**`), but both must edit `app/models/order/line_item.rb`
to add the same field.

**Trace.** Both run in parallel (declared disjoint). One of two things happens:
(1) both diffs touch `line_item.rb`; the second control-plane merge **conflicts**;
or (2) `B_b`'s push touches a path outside its declared scope → **`pre-receive`
hook rejects the whole push** (worker.md #3b), failing the step.

**Findings.**
- `[GAP]/[BREAK]` architecture.md explicitly leaves this `[OPEN]`: *"auto-resolve
  strategy if a scope-partition proves imperfect and a merge conflicts anyway."*
  There is **no recovery path**: no re-partition, no serialize-and-retry, no
  human hand-off defined at Build merge time. → **M4**.
- `[GAP]` Who detects the overlap and when? The Scope Critic (Plan C3) is supposed
  to guarantee disjointness statically, but real overlaps often only surface at
  Build merge. On failure, does Build rework→Plan to re-partition? The rework
  primitive *could* express it, but it is not wired to merge-conflict detection. → **M4**, **M9-adjacent**.

---

## Scenario 7 — Worker crashes mid-Build after committing/pushing but before releasing lease

**Work:** implementer finishes, commits to step branch, pushes, then the VM dies
before signaling `done`.

**Trace.** Lease expires; the sweeper resets the run to `ready` with a new
`attempt` (data-model §Heartbeat/reclaim; worker.md §Clean restart). A new worker
claims iteration N, gets a **new lease → new step branch ref**
(`step/<phase>/<wf>/<slug>/<lease>`), re-runs from scratch, pushes, and the
control plane merges *that* branch. The first push is orphaned.

**Findings.**
- `[GAP]` **Double-completion is explicitly `[OPEN]`** (worker.md): "ensure the app
  treats a re-dispatched duplicate as a no-op (idempotency key = step id +
  iteration)." But the guard is described only for the *report* path; the *merge*
  path can see **two pushed branches for one iteration** (attempt-1 orphan +
  attempt-2). The control plane must fence to merge exactly one. → **M10**.
- `[CONTRA]` "Steps are idempotent … re-running overwrites cleanly … reproduces the
  step" (worker.md §Clean restart) is **false for LLM builders** — a re-run
  produces *different code*. Idempotency here can only mean "at-most-one-merge,"
  not "deterministic reproduction." The doc conflates the two. → **M10**.
- Confirmation: because durability = commit + report, and reclaim discards
  uncommitted worktrees, the *pre-push* crash case is genuinely clean.

---

## Scenario 8 — A phase never converges (hits max-iterations)

**Work:** two critics keep disagreeing; the Manager can't reach consensus.

**Trace.** Manager loops (execution-model §Manager consensus loop); on
`max_iterations` (workflow.max_iterations) it "escalates to a human."

**Findings.**
- `[GAP]` **"Escalate to a human" is undefined.** No documented actions (edit an
  artifact directly? force-pass consensus? raise the cap? edit prompts and retry?
  abort?), and no distinct pipeline/phase state for it — the enums have `blocked`
  and `awaiting_human` but no explicit "cap-exhausted" state, and phase status has
  no equivalent. execution-model §Open questions lists this as `[OPEN]`. → **M13**.
- `[GAP]` **Manager placement is `[OPEN]`** (architecture §"Where does the Manager
  run"). Whether "consensus judgment" is deterministic control-plane code or an LLM
  invocation is undecided — and this scenario is entirely about that judgment. → **M5**.

---

## Scenario 9 — Security-sensitive change: OpenAI critic while Claude builds

**Work:** auth token handling change; want a non-Claude second opinion on the diff.

**Trace.** Build implementers carry role `code` (Claude workers advertise it).
Review C3 Code Quality/Sec carries role `code-review` advertised only by an OpenAI
worker (phase-playbooks Phase 4; architecture §model-agnostic). Role matching
routes C3 to the OpenAI worker; C1/C2 (`review`) can go to either.

**Findings.**
- Confirmation — this is exactly what role/type separation buys (phase-playbooks
  Finding 5). Works cleanly.
- `[GAP]` If the OpenAI `code-review` worker isn't connected, C3 goes **stuck**
  (Scenario 3's recovery gap applies). And identity roles are arbitrary strings
  (`claude`, and by convention `openai`), with no registry — two teams could pick
  different labels, silently breaking routing. Minor.

---

## Scenario 10 — Refactor touching 50 files (rename a core symbol)

**Work:** rename `Account` → `Tenant` across 50 files — one semantic change,
non-partitionable.

**Trace.** The change can't be split into disjoint scopes (it's one rename), so the
Planner assigns **one builder** with a 50-path scope, running in series
(execution-model §Parallel Builder rule: "unclear ownership ⇒ series"). The
`pre-receive` hook must allow all 50 paths (declared scope). C1 Test Critic runs
the suite.

**Findings.**
- `[GAP]` A single agent editing 50 files may exceed context/time. There is **no
  step-level wall-clock timeout** — only the lease TTL, which the worker's
  heartbeat keeps alive indefinitely. A step that runs for hours is invisible to
  the reclaim sweeper (it's heartbeating). No chunking primitive short of
  `fan_out`, which doesn't fit a single atomic rename. → **M15**.
- `[GAP]` Repo-clone-per-step (architecture §Deployment: workers "clone the
  pipeline branch") is expensive for large repos on ephemeral VMs; caching is
  unspecified. Minor. → **M15**.

---

## Scenario 11 — Ambiguous initial prompt

**Work:** "make the onboarding better" — no acceptance criteria.

**Trace.** Define is the designed home for this: Explore→Requirements iterate with
a **human in the loop** (execution-model §Worked example, §Gates) until
`business_requirements` are atomic/testable; C1 Completeness gates ambiguity.

**Findings.**
- Confirmation — Define's mandatory human loop is the right tool; the model handles
  ambiguity well.
- `[GAP]` If Define itself never converges (human keeps changing their mind),
  max-iterations behavior is the same `[OPEN]` as Scenario 8. → **M13**.

---

## Scenario 12 — Task requiring a DB migration

**Work:** add a `status` column with a data backfill.

**Trace.** Build implementer writes a migration under `db/migrate/` and model code.
C1 Test Critic "runs tests / typecheck / lint on the branch" (phase-playbooks
Phase 3) — which requires **migrating a real database and running the suite**.

**Findings.**
- `[BREAK]` **Worker execution environment is unspecified.** Running a migration +
  test suite needs a provisioned runtime, an ephemeral database, and installed
  deps. worker.md only specifies "launch a Claude Code agent against the worktree."
  Nothing covers dependency install, DB provisioning, service dependencies, or
  seed data. A "run tests" critic **cannot function** without this. → **C2**.
- `[GAP]` If two parallel builders each add a migration, they land in the **same
  `db/migrate/` dir** with timestamp-ordered filenames → potential filename/order
  collision (a shared-surface variant of Scenario 6). Migration ordering across
  step branches isn't modeled. → **M4**, **C2**.

---

## Scenario 13 — Dependency / 3rd-party bump

**Work:** bump a library across a security advisory; regenerate the lockfile.

**Trace.** Build edits `Gemfile`/`package.json` + the **lockfile**, then must run
install and the suite.

**Findings.**
- `[BREAK]` Same as Scenario 12 — needs a real environment to resolve/install and
  to run tests. → **C2**.
- `[GAP]` Lockfiles are **shared, machine-generated, merge-hostile** files. If any
  other parallel builder also regenerates the lockfile, merges conflict and the
  hook may reject out-of-scope writes. → **M4**.

---

## Scenario 14 — Two pipelines on the same project touch the same files concurrently

**Work:** Pipeline A refactors `user.rb`; Pipeline B, opened a day later, also edits
`user.rb`.

**Trace.** Each pipeline has its own branch cut from master at creation
(concepts §Git binding). Within each pipeline no conflict. But **the pipeline
branch is never re-synced with master** — there is no rebase/merge-from-base step
anywhere in the docs. When A merges to master (human), B's branch is now stale;
B's final PR conflicts with master.

**Findings.**
- `[BREAK]` **No "update from base" primitive.** Pipeline branches are cut once and
  drift; long-running or concurrent pipelines accumulate divergence with no
  modeled way to pull master forward, and no conflict-resolution flow at final
  merge beyond "a human merges the PR." → **M9**.
- `[GAP]` The `.pipeliner/` artifacts (Plan's `technical_design`) may be based on a
  now-stale view of the code that A changed — Review has no signal that the base
  moved. → **M9**.

---

## Scenario 15 — Long-running pipeline; a worker's `supported_roles` change mid-flight

**Work:** a worker holding a running `ui-tests` step loses its browser (crash),
dropping `ui-tests` from its next heartbeat.

**Trace.** Roles are refreshed every heartbeat (worker.md §Roles). But **role
matching only gates *claiming*, not continued execution** (worker.md: "Eligibility:
`step.role ∈ worker.roles`"). The in-flight run keeps its lease as long as
heartbeats continue.

**Findings.**
- `[GAP]` A worker can be **running a step whose role it no longer supports**, with
  nothing tying the running `step_run` to the lost capability. The step will likely
  fail at execution time, but that's incidental, not modeled. → **M14**.
- `[GAP]` Conversely (Scenario 3), a worker *gaining* a role does not re-evaluate
  **stuck** runs. Role changes are tracked but not acted upon on either edge. → **M7**.

---

## Scenario 16 — Plan produces a bad scope partition

**Work:** Partitioner declares two scopes disjoint that actually share a module.

**Trace.** Scope Critic (Plan C3) "checks whether scopes are truly disjoint &
complete." If it passes a bad partition, Build discovers the overlap at merge
(Scenario 6). Ideally Build rework→Plan to re-partition.

**Findings.**
- `[GAP]` **Disjointness/completeness are not statically decidable** from a task
  list; the Scope Critic is an LLM heuristic that will miss real overlaps. The
  design leans on it as load-bearing (phase-playbooks Finding 4) but has no
  runtime backstop. → **M4**.
- `[GAP]` No wiring from "Build merge conflict / hook rejection" → "rework to Plan
  to re-partition." The rework primitive exists but isn't connected to this
  trigger. → **M4**.

---

## Scenario 17 — Fan-out step with dynamic (runtime-discovered) shard keys

**Work:** "update every feature-flag doc" where the *set* of flags is only known
after a discovery step reads the codebase.

**Trace.** `step.json.fan_out { key_source: "topics", max: 4 }` implies keys come
from an artifact (artifact-schema §step.json). But the shard `step_runs` must exist
to be claimed, and the DAG/`step_edges` are compiled **before** the run.

**Findings.**
- `[BREAK]` **Dynamic fan-out breaks static DAG/`step_run` materialization.** If
  shard keys are discovered at runtime, the control plane must **mint new
  `step_runs` and a fan-in dependency after a step completes** — but the scheduler
  assumes a compiled workflow (data-model `steps`/`step_edges`; workflow manifest
  "the compiled DAG"). artifact-schema §Open questions lists exactly this as
  `[OPEN]` ("enumerated by the planner up front, or discovered at runtime?"). → **M6**.
- `[GAP]` `shard_key` exists on `step_runs`, but there's no mechanism/outcome for a
  step to *return* a key list that expands the graph. → **M6**.

---

## Scenario 18 — Pipeline aborted mid-Build (cleanup of worktrees/branches)

**Work:** user hits "abort" while three implementers are running on remote VMs.

**Trace.** Pipeline status → `aborted` (data-model enum). But **the control plane
is outbound-unreachable** — workers connect outbound-only (architecture
§Deployment: "the cloud never needs to reach into a worker"). The control plane
**cannot tell a running worker to stop** or clean its worktree.

**Findings.**
- `[BREAK]` **No cooperative cancellation channel.** The poll/heartbeat *response*
  shape is not specified to carry a "canceled/abort" flag, so an in-flight worker
  keeps running the agent, finishes, pushes, and tries to report/merge into an
  aborted pipeline. Remote worktrees/branches on the worker can't be cleaned by the
  control plane at all. → **M8**.
- `[GAP]` On the control-plane git remote, orphaned step branches from aborted runs
  need GC; unspecified. Minor. → **M8**.

---

## Scenario 19 — Human rejects at the final gate

**Work:** reviewer looks at the finished PR and says "no, this whole approach is
wrong."

**Trace.** Final Gate approval `decision: send_back` (data-model `approvals`) with a
`target_phase_id` (e.g. Plan), or `abort`. This creates a rework and re-opens the
target phase.

**Findings.**
- Confirmation — the approval enum (`approve | send_back | abort`) + rework covers
  it structurally.
- `[GAP]` `send_back` requires a `target_phase_id`, but "the whole approach is
  wrong" may not map to one phase. And sending back to Plan/Define after Build has
  merged code triggers the **Scenario 5 code-revert `[BREAK]`**. → **C3**.
- `[GAP]` Finalization ordering: if the human rejects *after* finalization already
  ran (zip+strip), `.pipeliner/` is gone from the branch. The doc runs finalization
  **on approval** (artifact-schema §Finalization), so reject-before-finalize is
  fine — but a reject that arrives late (or a re-open after a completed pipeline)
  has no story for restoring `.pipeliner/` from S3. Minor.

---

## Scenario 20 — Trivial docs-only change

**Work:** fix a typo in `README.md`. No code, no tests.

**Trace.** Same fixed four phases as Scenario 1. Build's output is a doc edit
(`kind: code`? it's a repo file but not "source"). Test critics have nothing to run.

**Findings.**
- `[GAP]` **Overkill** identical to Scenario 1 — full Define human gate, four
  Managers, finalization, for a typo. → **M12**.
- `[GAP]` `outputs[].kind` is `artifact` (a `.pipeliner/` file) or `code` (repo
  diff). A docs change to a **repo** file (not under `.pipeliner/`) is `kind: code`
  by elimination, but "code" is described as "real **source** changes"
  (artifact-schema §step.json) — a naming/semantic mismatch for repo docs. Minor.
- `[GAP]` Test/UI critics are inapplicable; the Planner must know to omit them.
  Fine if the Planner is good, but there's no "no-op critic" fallback if a required
  critic template has nothing to check. Minor.

---

## Scenario 21 — Project whose repo is a documentation *wiki*, not code

**Work:** the Project's git repo is a Markdown **wiki** (docs pages + a nav/index).
Ask: *"Add a section on our refund policy across the relevant wiki pages and keep
the nav/index consistent."* No compiler, no test suite, no browser.

**Trace.**
- **Define** works well and is arguably the *most* natural fit: Explore reads the
  wiki, Requirements captures "which pages must mention the refund policy, in what
  terms," human gate. Nothing code-specific here.
- **Plan** is **awkward for prose.** `technical_approach` / `technical_design`
  (phase-playbooks Phase 2: "components, data model, APIs, file-level plan") assume
  software. For a wiki the useful Plan output is an **editorial outline** — which
  pages get which section, tone, cross-links, nav placement. The canonical
  artifacts are misnamed but the *shape* (partition the work, plan it) still holds:
  `build_task_plan` becomes "page/section assignments." Feasibility/Coverage
  critics map to "does the outline cover every required page / is it consistent."
- **Build** is where the code-centrism bites. phase-playbooks frames Build as
  *"real code changes in the repo — not `.pipeliner/` documents"* and its critics
  are **C1 Test (runs tests/typecheck/lint)** and **C2 UI Test (browser)** — none
  of which apply. The **useful** builders here are `writer`/`editor` steps editing
  Markdown pages, and useful critics are **style/consistency/link-check/tone**, not
  compile/test. The output is repo files, so `outputs[].kind: code` is used — but
  "code" is a misnomer for prose.
- **Review** generalizes fine: Requirements-Conform ("does every required page now
  cover the refund policy?") and a report writer. Verification critic ("adequate
  tests") is inapplicable and must be omitted.
- **Finalization** works unchanged: zip `.pipeliner/` → S3, strip it, leave a clean
  Markdown diff PR for a human to merge.

**Findings.**
- **Four-phase spine:** holds structurally. Define/Review are natural; Plan/Build
  are *usable* but their **canonical artifact names and critic templates are
  code-biased** (`technical_design`, "file-level plan," Test/UI critics). The
  awkwardness is naming/templating, not the phase model itself. → **M17**.
- **Roles:** work perfectly — the whole point of arbitrary roles. `writer`,
  `editor`, `copy-review`, `link-check` slot in with zero type changes; no
  `code`/`ui-tests` needed. This is a **confirmation** of the two-axis design.
- **Branch-per-step + disjoint scope:** holds, and is arguably *cleaner* for prose
  — `scope.paths` naturally partitions by **page** (`docs/refunds/**`,
  `docs/billing/faq.md`). The **shared-file problem (M4) recurs**, though: the
  **nav/index** (`_sidebar.md` / `SUMMARY.md`) is exactly the shared registration
  file every page-writer wants to touch — same hard-block by the scope hook, same
  need for a fan-in Integrator (here a "nav updater"). → **M4** (domain-general, not
  code-specific).
- `[GAP]` **`outputs[].kind: code` is a misnomer.** The only meaningful distinction
  is "a `.pipeliner/` artifact file" vs. "a change to the **actual repo tree**."
  For a wiki the latter isn't "code." → **M17**.
- `[GAP]` **Verification degrades but not gracefully.** The Build/Review critic
  templates assume something to "run." With nothing runnable, a naively-included
  Test critic either errors or vacuously passes. The Planner must **know to omit**
  code critics — there's no "no-op / not-applicable" verdict and no capability
  gate ("only include a Test critic if the project has a test command"). → **M17**,
  **M18(new)**.
- **"Build only code changes" framing:** too code-centric as written
  (concepts §"Phase 3 (Build) commits code"; phase-playbooks "real code changes").
  The *mechanics* (repo-tree changes tracked by the step-branch diff) are
  domain-general; only the **prose** is narrow.

---

# Cross-cutting findings (ranked)

## Critical

### C1 — Git topology is contradictory and the mirror lifecycle is undocumented
**Exposed by:** 2, 6, 7, 14, 18 (all git flow).
**Problem:** Two docs describe incompatible git mechanics. architecture.md says
*"the control plane cuts a step branch (via `git worktree add`) … **hands the
worktree to the worker**"* — impossible across the network to an outbound-only,
NAT'd, ephemeral worker. worker.md says the **worker** "ensures a clean worktree …
cut from the pipeline branch" by **cloning from the git remote** and later
**pushes** to a ref governed by a server-side `pre-receive` hook + ref-scoped
token. A `pre-receive` hook and ref-scoped push tokens imply a **control-plane-
hosted git server**, yet a Project is bound to an external `repo_url`
(GitHub) whose PR merges to master. The initial mirror (origin→control-plane), the
final push (control-plane→origin) for the PR, and **who owns worktrees** are never
reconciled. This is foundational and blocks nearly every scenario.
**Fix:** Decide a **control-plane-hosted bare mirror per project** as the workers'
remote (enables the hook + ref-scoped tokens). Workers clone/worktree **locally**;
the control plane merges on its server-side copy and **pushes the pipeline branch
to origin** to open/update the PR. Delete the "control plane hands a worktree to the
worker" language. Document the origin↔mirror sync (initial clone, ongoing base
updates — see M9).

### C2 — Worker execution environment (build/test/DB/browser/deps) is unspecified
**Exposed by:** 1, 3, 10, 12, 13 (any critic that "runs tests / lint / UI").
**Problem:** worker.md specifies only "launch a Claude Code agent against the
worktree." But Build/Review critics **run tests, typecheck, lint, migrations, and
browser UI tests** (phase-playbooks Phases 3–4). That requires an installed
toolchain, third-party deps, an ephemeral database + services, seed data, and (for
`ui-tests`) a browser. None of this provisioning is modeled. Without it, the
verification critics — the backbone of "reviewed, merge-ready" — cannot run.
**Fix:** Add a **workspace-provisioning contract**: per-project setup (container
image or setup script: install deps, provision ephemeral DB/services, browser for
`ui-tests`), tied to roles that advertise environment capabilities. Specify where
provisioning runs (worker) and its lifecycle relative to the worktree.

### C3 — Rework to an earlier phase after code is merged has no revert/supersede story
**Exposed by:** 5, 16, 19 (and 4's boundary).
**Problem:** Rework can re-open Define/Plan (execution-model §Inter-phase rework),
but Build has **already committed code to the pipeline branch**, and squashing is
"history-only, never touches the working tree" (artifact-schema P2). Re-Build's
implementers are additive and scope-limited and cut branches from the current
(wrong-code-bearing) pipeline branch. There is no primitive to **revert or
supersede** already-merged code when upstream intent changes — so the wrong code
persists and can even be blocked from edits by the scope hook. This directly
undermines the "clean, correct PR" end state.
**Fix:** Define rework-through-Build semantics: when a rework targets a phase at or
before Build, **roll the pipeline branch back to the target phase's boundary
commit** (snapshot phase-boundary commits so they're addressable) before flowing
forward, and re-derive downstream. Record the rollback in `rework.json`. Decide
full-re-run vs. incremental explicitly.

## Major

### M4 — Disjoint path-scopes can't model shared/integration files; imperfect-partition conflicts are unhandled
**Exposed by:** 2, 6, 12, 13, 16.
**Problem:** Path-based `scope` + the `pre-receive` scope hook **hard-block**
builders from touching shared registration/generated files (routes, DI,
`package.json`, lockfiles, `db/migrate/`) that realistic parallel features require.
And architecture.md leaves the merge-conflict-on-imperfect-partition case `[OPEN]`
with no recovery path or trigger to re-partition.
**Fix:** Introduce a **shared/append-only integration surface**: route all
shared-file edits to the fan-in Integrator (builders emit their needed
route/registration as an artifact the Integrator applies), OR allow declared shared
paths with a serialized append/patch merge. Specify the conflict fallback
(serialize + re-run owning builder, or auto-trigger rework→Plan to re-partition)
instead of `[OPEN]`.

### M5 — Manager (and automated-gate) placement/executor is undecided — the loop backbone has no committed executor
**Exposed by:** every multi-step scenario, esp. 8.
**Problem:** architecture §"Where does the Manager run" is `[OPEN]` (control-plane
logic vs. agent step vs. hybrid). The consensus judgment, routing, and automated
gates ("critic-style check") all hinge on this; it affects claiming, roles, cost,
and scaling. Undecided means the central loop is unimplementable as written.
**Fix:** Commit to the **hybrid**: deterministic scheduling/queue in the control
plane + a dedicated **Manager LLM invocation the control plane makes directly**
(not a pollable `code`/`review` worker step). Define its inputs/outputs
(`manager.json` consensus rationale — currently `[OPEN]` in three docs) and its
trigger points.

### M6 — Dynamic (runtime-discovered) fan-out breaks static DAG / `step_run` materialization
**Exposed by:** 17.
**Problem:** `step_runs` and `step_edges` are compiled before execution, but
`fan_out.key_source` implies keys can come from a runtime artifact. The scheduler
has no way to expand the graph mid-run.
**Fix:** Add a **fan-out expansion outcome**: a step returns a shard-key list; the
control plane materializes shard `step_runs` + a fan-in dependency dynamically.
Extend the workflow manifest to allow **deferred-expansion** nodes.

### M7 — Stuck runs aren't recovered when a capable worker appears; stuck↔phase interaction undefined
**Exposed by:** 3, 9, 15.
**Problem:** The claim query selects `state='ready'`, but stuck runs are set to
`state='stuck'`; nothing flips them back when a worker with the needed role
connects/heartbeats. And whether a stuck step pauses the whole phase or just its
branch is undefined.
**Fix:** On worker connect/heartbeat role change, **re-evaluate stuck runs** whose
`required_role` is now covered → flip to `ready`. Define phase behavior while a
step is stuck (block the gate but let independent critics proceed).

### M8 — No cooperative cancellation channel; aborted/superseded work can't be stopped or cleaned
**Exposed by:** 18 (abort); also 5/16 (superseded iterations).
**Problem:** Control plane is outbound-unreachable, and no "canceled" flag is
specified in the poll/heartbeat **response**, so in-flight workers keep running,
finish, and try to merge into an aborted/superseded pipeline. Remote worktrees
can't be cleaned by the control plane.
**Fix:** Add a **cancellation flag to the heartbeat/poll response**; workers check
it, self-abort, and discard the worktree. Control plane **fences merges** for
canceled/superseded runs via an epoch/lease-id check; GC orphaned mirror branches.

### M9 — Pipeline branches never re-sync with base; concurrent/long pipelines drift with no reconcile primitive
**Exposed by:** 14, 10.
**Problem:** Branches are cut from master once and never updated; there's no
rebase/merge-from-base operation, and no conflict flow at final merge beyond "a
human merges the PR." Plan/Review reason against a base that may have moved.
**Fix:** Add a controlled **"update from base"** operation (control plane
merges/rebases origin's default branch into the pipeline branch, re-squashing),
with a defined conflict path (human or a dedicated reconcile step) and a signal to
Review that the base moved.

### M10 — "Idempotent steps" is false for LLM work; double-completion merge fencing is `[OPEN]`
**Exposed by:** 7.
**Problem:** worker.md claims re-running "reproduces the step / overwrites
cleanly," but LLM builders are **non-deterministic**. After a push-before-release
crash, one iteration can have **two pushed branches** (orphan + retry). The
idempotency guard is described only for the report path, not the merge path.
**Fix:** Redefine the guarantee as **at-most-one-merge**, not deterministic
reproduction. Control plane merges exactly one winning attempt's branch and
**fences** later/duplicate completions by epoch/lease-id (extend the `(step_id,
iteration)` key with attempt fencing at merge time). Drop the "deterministic
re-run" language.

### M11 — "Versioned artifacts / history retained" contradicts "only latest kept"
**Exposed by:** 4, 5, 8 (iterating steps).
**Problem:** execution-model §Artifact Workspace: *"nothing is overwritten
destructively; history is retained."* artifact-schema P2: *"today only the latest
content of each path is kept"* and squashing removes the granular timeline;
`input.json` (with feedback) is overwritten per iteration on a stable path. These
directly contradict, and rework/iteration cases need prior context that latest-only
discards.
**Fix:** Reconcile: either commit to **latest-only** and delete "history retained"
language, or add **file-based iteration snapshots** for artifacts/inputs. Pick one
and state it normatively.

## Minor

### M12 — Four fixed phases + mandatory Define human gate are overkill for trivial work
**Exposed by:** 1, 20.
**Fix:** Keep the four rails but allow a **minimal preset**: phases compile to a
single pass-through step, gates auto-pass (including Define) under a project policy
for low-risk changes. Add an effort tier.

### M13 — Max-iterations / cap escalation is underspecified
**Exposed by:** 8, 11.
**Fix:** Define the human's escalation actions (edit artifact/prompt, force-pass,
raise cap, abort) and a distinct pipeline/phase state for cap-exhausted.

### M14 — Worker losing a role mid-run isn't tied to the running `step_run`
**Exposed by:** 15.
**Fix:** On role loss for an in-flight run's `required_role`, mark that run for
reclaim rather than relying on incidental execution failure.

### M15 — No step wall-clock timeout; repo-clone-per-step cost
**Exposed by:** 10.
**Fix:** Add an optional max step duration (independent of lease TTL, which
heartbeats keep alive) and worktree/repo caching on workers.

### M16 — Multiple workflows per phase vs. one Manager: ordering undefined
**Exposed by:** structural (concepts allows "1+" workflows/phase; execution-model
says "one Manager per phase").
**Fix:** Define Manager sequencing across multiple workflows, or restrict to one
workflow per phase in v1.

### M17 — Build/Plan vocabulary and `outputs[].kind: code` are code-biased (not domain-general)
**Exposed by:** 21 (documentation-wiki repo).
**Problem:** The phase model, roles, branch-per-step, scope, rework, and
finalization are all **domain-general**, but a thin layer of **naming** is not:
Plan's canonical artifacts (`technical_design`, "file-level plan"), Build's "real
**code** changes" framing, and `outputs[].kind: code` all assume software. On a
prose/wiki (or config, or infra) repo these are usable but misleading.
**Fix (small, high-leverage):** Rename `kind: code` → **`kind: repo`** (a change to
the actual repo tree, format-agnostic) and treat `artifact` vs. `repo` as the only
real distinction. Make Plan/Build's canonical artifact names and critic set
**project-type-parameterized** (a `project.kind`/template pack: `software`, `docs`,
…) rather than hard-coded. No structural change to the four phases or roles.

### M18 — No "not-applicable"/capability-gated critic; verification doesn't degrade gracefully
**Exposed by:** 21, 20; related to 12/13 (C2 environment).
**Problem:** Build/Review verification critics assume something runnable (tests,
typecheck, lint, browser). On a repo with no such command they either error or
vacuously "pass," and the design relies entirely on the Planner remembering to omit
them. There's no capability gate and no explicit not-applicable verdict.
**Fix:** Add a **project capability declaration** (has-test-command, has-lint,
has-browser) and gate conditional critics on it (like `ui-tests` is gated on a
browser role); add a `not_applicable` verdict distinct from `pass` so an included
critic can bow out honestly.

---

# Verdict — does Pipeliner generalize to non-code git-repo projects?

**Yes, structurally — with a thin naming layer as the only real obstacle.**

Scenario 21 (a Markdown wiki) exercised every core mechanism and the **spine held**:
the four phases (Define/Review are *more* natural for prose, Plan/Build are usable),
**arbitrary roles** absorbed `writer`/`editor`/`copy-review`/`link-check` with zero
new step types (a clean confirmation of the two-axis design), **branch-per-step +
page-level disjoint scope** worked (and is arguably tidier than for code), and
**rework + finalization** were unchanged. The shared-file issue recurred only as the
**nav/index** — the same M4 problem, confirming M4 is domain-general rather than
code-specific.

**The only things that are genuinely code-biased are names and defaults, not model:**
1. `outputs[].kind: code` → should be a neutral **`repo`** kind. (M17)
2. Plan/Build canonical artifacts (`technical_design`, "file-level plan") and the
   default critic set (Test/UI) are software-specific and should be a
   **swappable per-project-type template pack**. (M17)
3. Verification critics need a **capability gate + `not_applicable` verdict** so
   they degrade honestly when there's nothing to run. (M18)

**Is the change worth doing?** **Yes, and it is cheap** — it is renaming + making a
few defaults data-driven, with **no change to the phase spine, roles, git model, or
data model.** The payoff is large: the exact same engine covers docs/wikis,
IaC/Terraform, config repos, data/notebook repos, and prose — all "structured
agentic change to a git repo." Recommendation: adopt the neutral `repo` kind and the
project-type template pack now (before code is written), since retrofitting the
`code` naming later would be a schema migration. Keep `software` as the default
template pack so nothing regresses.

---

# What held up (confirmations)

- **Role/type separation** cleanly routes model-specific work (OpenAI critic +
  Claude builder, Scenario 9) and composes conditional capability steps like
  `ui-tests` (Scenario 3) without new step types — the two-axis design is sound
  (phase-playbooks Finding 5).
- **Pull-based claiming** with `FOR UPDATE SKIP LOCKED` + role-indexed `step_runs`
  is a correct, contention-free work-queue design for heterogeneous, NAT'd,
  ephemeral workers (data-model §Claiming).
- **Lease/heartbeat/reclaim** cleanly handles the *pre-commit* crash case:
  durability = commit + report, uncommitted worktrees are discarded, the run is
  re-dispatched (Scenario 7's happy sub-case). The core crash-safety intuition is
  right; only the *post-push* fencing needs work (M10).
- **Branch-per-step isolation** for genuinely disjoint writes gives conflict-free
  merges; the `.pipeliner/` exclusive-subtree rule makes artifact fan-in trivially
  clean (Scenario 2's disjoint sub-case).
- **Rework as a first-class primitive** structurally covers the "requirement
  missing" (Scenario 4) and "reject at gate" (Scenario 19) cases; the automated vs.
  human modes are a good distinction. Its gap is only the *code-revert* semantics
  (C3), not the routing concept.
- **Structured verdicts** (`verdict.json`) make intra-phase looping automatable —
  the right call to standardize early.
- **Git = durable / DB = ephemeral** split is a clean, defensible boundary that
  keeps the runtime state out of history and the audit trail in files + S3.
- **Infra-enforced branch write rules** (ref-scoped token + `pre-receive` hook) are
  the right security posture for no-human-escalation agents — the enforcement
  design is strong *given* a control-plane-hosted git remote is committed to (C1).
- **Domain-generality of the core model** (Scenario 21): the four-phase spine,
  arbitrary roles, branch-per-step, scope, rework, and finalization all carry over
  to a non-code (documentation-wiki) repo unchanged. Only *names and default
  templates* are code-biased (M17/M18) — the engine itself generalizes.

---

*Generated as an adversarial design review over the 9 design docs. 21 scenarios,
3 Critical / 8 Major / 7 Minor cross-cutting findings.*
