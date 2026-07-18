# Pipeliner — Execution & Iteration Model

> Working draft. Defines how Steps run, how Workflows iterate, and how feedback
> loops converge within a Phase. Builds on [concepts.md](./concepts.md).
> **[OPEN]** marks unresolved items.

## The core pattern: a Manager-driven consensus loop

**Each Phase is its own loop, run by a single Manager whose job is to reach
consensus among that phase's planners, builders, and critics.**

Within a phase, a **planner** decides how to approach the work, **builder** steps
produce it, and **critic** steps judge it. A **Manager** orchestrates the whole
loop: it sequences the workers, routes feedback, decides what re-runs, weighs
critic disagreement, and declares when the phase has reached **consensus**. This
is the plan/act/reflect pattern with an explicit orchestrator, and it is the
backbone of every phase.

Exit is a **judgment by the Manager**, not a mechanical "all critics passed" —
though unanimous critic pass is the common signal for consensus.

## Three ingredients

### 1. Artifact Workspace (shared memory)

Each Pipeline has a set of **named artifacts** (e.g. `discovery_notes`,
`business_requirements`, `documentation`). Steps read some artifacts and write
others. Re-running a step reads the *current* artifact content plus any feedback
and **overwrites the same stable path** — the workspace holds **latest content
only** (no intermediate iteration snapshots). The durable trail is the artifact
files + `result.json`/`verdict.json`/`rework.json` (and the S3 archive at
finalization), per [artifact-schema.md](./artifact-schema.md).

### 2. Step type (behavior) vs. role (matching) — two axes

A Step is described by **two independent things**:

- **Type — what it *does* in the loop.** A fixed, small set that drives loop
  logic (e.g. only a Critic emits a verdict). This is *not* used for worker
  matching.
- **Role — an arbitrary label naming the *capability* the step needs** (e.g.
  `code`, `review`, `ui-testing`, `requirements`). Used **only** to route the
  step to an eligible Worker. Free-form; see [worker.md](./worker.md).

> Keep these separate: a step of **type** `critic` might carry **role** `review`
> or `security-review` — the type says "it judges," the role says "who can run
> it." "Worker" remains reserved for the runtime *process* that executes a step.

Every Step also has its own **system prompt**, declared **inputs** (artifacts it
reads), and **outputs** (artifacts it writes and/or the verdict it emits).

**Step types** — worker-executed (pulled by Workers):

| Type        | Purpose                                                  | Emits                          |
|-------------|---------------------------------------------------------|--------------------------------|
| **Planner** | Decide how to approach the work; decompose & sequence.  | A plan artifact                |
| **Builder** | Produce or update an artifact (do the work).            | New artifact version(s)        |
| **Critic**  | Evaluate artifacts against a standard.                  | Structured verdict + findings  |

**Step types** — controllers (not pulled by Workers):

| Type        | Scope         | Purpose                                                              |
|-------------|---------------|---------------------------------------------------------------------|
| **Manager** | One per Phase | Orchestrates the workers, routes feedback, decides re-runs, weighs disagreement, **declares consensus**. |
| **Gate**    | Boundaries    | Approval checkpoint — **human or automated**; ratifies before advancing. |

- A **Planner is distinct from a Builder** because its output is *strategy about
  the work* (a plan), not the work product — and a plan is itself an artifact a
  Critic can check before any building starts (early-catch loop).
- **Manager vs Gate:** the Manager *builds* consensus (an agent driving the
  loop); the Gate *ratifies* it (a checkpoint, often human). Manager runs
  continuously through the phase; Gate fires at the boundary.
- The type set is intentionally small; **roles** carry all the open-ended
  variety, so new capabilities don't require new types.

**Structured verdict (standardize early):**
```
verdict: pass | needs_work | not_applicable
findings:
  - target_artifact: business_requirements
    issue: "Requirement R-4 is not atomic; split into two."
    severity: blocker | major | minor
    route_to: <builder/planner step id>        # optional hint
```
Structured (not prose) verdicts are what make looping automatable.
**`not_applicable` (M18)** lets verification **degrade gracefully** — e.g. a
test-runner critic on a docs/wiki project with nothing to run returns
`not_applicable` (treated as non-blocking) rather than failing.

### 3. The Manager's consensus loop (iteration primitive)

The phase **Manager** runs the workers, reads the critics' structured verdicts,
and **routes feedback back to the responsible builder/planner** to re-run. It
repeats until the Manager declares the phase resolved, on one of:

- **consensus** — the Manager judges the workers aligned (typically all critics
  `pass`, but the Manager may weigh partial/dissenting findings), or
- **max iterations** reached (safety cap, configurable per phase/workflow) —
  escalate to a human, or
- **Gate** decides (approve / send-back / abort).

The Manager is what makes exit a judgment rather than a mechanical tally.

## Workflow composition (configurable + agentic)

The steps in a phase are not hard-coded. A workflow is **composed** — manually,
agentically, or both — from the **Step Library** (see
[concepts.md](./concepts.md)) before/while it runs.

- **Manual (UI):** the user adds/removes/orders Step Instances, edits their system
  prompts, and wires dependencies.
- **Agentic (Planner):** a Planner step reads the task and the **available Step
  Templates** and **selects which steps this task needs**, emitting the workflow
  DAG. Conditional steps (e.g. "UI Testing") are included **only when relevant** —
  they may not be needed for every task.
- **Hybrid (expected default):** the user pins required steps; a Planner adds
  conditional ones.

Implications:
- **Step selection is itself a step** (a Planner). Its output artifact *is* a
  workflow DAG — which a Critic can then check ("did we include the steps this
  task needs? any missing/redundant?") before the phase runs in earnest.
- Templates carry a **required | conditional** flag; conditional templates are
  candidates the Planner includes on demand.
- Compiling a workflow (resolving the DAG) therefore happens **after** composition.

## Parallel Builder rule (scope delineation)

Builders may run in parallel **only if their scopes are disjoint and explicitly
declared.** Otherwise they run in **series**.

- For `.pipeliner/` artifacts this is automatic — each step owns its own subtree.
- For **real source code (Phase 3)** it is not automatic: two builders can edit
  the same files. So each parallel Builder must declare an explicit **scope**
  (the responsibilities / files / areas it owns), and parallel scopes must not
  overlap.
- **Partitioning scope is the Planner's responsibility.** The Planner decomposes
  the work into non-overlapping builder assignments; the compiled workflow DAG
  encodes which builders may fan out and which must serialize.
- If work cannot be cleanly partitioned, the Planner sequences it (series), or
  inserts a fan-in **combine** step to reconcile overlapping outputs.

### Shared / integration files — the Integrator (M4 — decided)

Some files are inherently **shared**: route tables, DI/container wiring,
`package.json`/lockfiles, `db/migrate`, a wiki **nav/index**. Disjoint scopes
can't assign these to one builder. Rule:

- Parallel Builders **never edit shared files.** Instead they emit **structured
  intents** (e.g. `register route /billing`, `add nav entry "Refunds"`).
- The workflow declares its **`shared_paths`**, and a fan-in **Integrator** step
  **owns those paths exclusively** and applies all intents **serially** — so
  shared-file edits are conflict-free by construction.
- The pre-merge scope check enforces this: an edit to a `shared_path` is only
  allowed from the Integrator; from a parallel Builder it is rejected.

Rule of thumb: **parallel ⇒ clearly delineated ownership; unclear ownership ⇒
series.**

## Gates & human-in-the-loop

- **Phase 1 (Define) always has a human in the loop.**
- **Between-phase gates are configurable** (require human approval to advance, or
  auto-advance on convergence).
- Gates are just Steps of type `Gate`; automated gates use a critic-style check.

### Trivial work — scale down, don't skip (M12 — decided)

The four phases are always present, but they **scale to the work.** For a trivial
change (typo, one-line docs fix) the Define planner detects triviality and emits
**minimal, auto-composed workflows** with **auto-gates**, so the pipeline flows
`define(min) → plan(min) → build → review(auto)` with 1–2 steps per phase and no
human stops. No phase is skipped — the **fixed-four invariant holds** — the
ceremony just collapses. Non-trivial work keeps full workflows + human gates.

## Inter-phase rework routing

The Manager loop resolves work *within* a phase. But a later phase often
discovers a problem rooted in an **earlier** phase — this is the top-level "loop"
of the whole pipeline. Review, especially, may find:
- a requirement not implemented → send back to **Build**;
- a design that was wrong → send back to **Plan**;
- a requirement that was itself wrong → send back to **Define**.

So a phase can emit a **rework outcome** targeting an earlier phase:

```
rework:
  target_phase: 03-build          # any earlier phase
  reason: "R-7 (export to CSV) is unimplemented."
  feedback: [ ...structured findings... ]
  mode: automated | human
```

The target phase **re-opens** with its prior artifacts **plus** the new feedback,
then flows forward again.

**Unwind is forward-only (C3 — decided).** We do **not** rewrite history / roll the
pipeline branch back. The target phase re-runs and layers **new corrective
commits** forward (`… build | review | build' | review'`); phase-squashing still
produces one commit per phase-run. Consequences:
- A rework-triggered Builder's **`scope` must expand to cover the code being
  corrected or reverted** (not just new additions) — otherwise the pre-merge scope
  check would block the fix.
- The **coverage/verification critics on the re-run guard completeness** — they
  are what catch an incomplete correction (the known risk of forward-only).

Two modes — **both must be supported**:

- **Automated rework** — used when the deciding agent *already has the
  information it needs and something was simply missed*. The critic/Manager routes
  straight back to the target phase with structured feedback; no human needed.
  (Configurable, like intra-phase auto-advance.)
- **Human-in-the-loop rework** — used when the gap is *missing context only a
  person can supply*. The pipeline pauses at a gate, surfaces the finding, and
  asks the human to add context / make a decision **before** the target phase
  re-opens.

Which mode fires can be decided per finding (the critic/Manager flags whether it
has enough to proceed) or per configured policy.

Guardrails:
- A **max-rework cap** per target (and overall) prevents infinite cycles (e.g.
  Define↔Review); on cap → escalate to a human.
- Each bounce is recorded (a **rework record** — see `rework.json` in
  [artifact-schema.md](./artifact-schema.md)) so the trail shows *why* the
  pipeline went backward.

## Routing decision (who re-runs on critic failure)

**Resolved: the Manager is the orchestrator.** It reads critic feedback and
decides what re-runs — orchestrator-driven routing is the design center.
Configured routing edges (explicit "C1 fail → re-run A2") remain available as an
override/fallback and as guardrails the Manager operates within. **[OPEN]** how
much routing is fixed config vs. left to Manager discretion.

## Routing decision (who re-runs on critic failure)

**Resolved: the Manager is the orchestrator.** It reads critic feedback and
decides what re-runs — orchestrator-driven routing is the design center.
Configured routing edges (explicit "C1 fail → re-run A2") remain available as an
override/fallback and as guardrails the Manager operates within. **[OPEN]** how
much routing is fixed config vs. left to Manager discretion.

## Worked example — Phase 1 (Define), non-technical

```
Workspace: discovery_notes, business_requirements, documentation

Steps:
  A1 Explore       builder reads: initial_prompt, codebase   writes: discovery_notes
  A2 Requirements  builder reads: discovery_notes, feedback  writes: business_requirements
                            format: atomic, testable "When X, then Y"
  A3 Docs Updater  builder reads: business_requirements       writes: documentation
  C1 Completeness  critic  reads: business_requirements        verdict + findings
  C2 Docs Match    critic  reads: business_requirements, documentation  verdict + findings
  G1 Human Gate    gate    human approval before Phase 2

Loop: A1 → A2 → A3 → C1 → C2
  C1 needs_work → route to A2 (with findings)
  C2 needs_work → route to A3 (or A2 if requirements are the problem)
  Repeat until C1 & C2 pass → G1 (human) approves → advance to Phase 2
```

Constraint: **Phase 1 stays non-technical.** Enforce via step system prompts and
optionally a critic that flags technical leakage.

## Open questions

- **Convergence caps (decided).** Default **max-iterations = 10** (configurable
  per workflow). On cap-without-convergence, **pause and escalate to a human**:
  the phase goes `awaiting_human` with the latest verdicts/sticking-point
  surfaced; the human gives guidance / approves-anyway / aborts, and the loop
  resumes from there. (Not a silent failure.)
- **[OPEN] Routing latitude.** How much routing is fixed config vs. left to
  Manager discretion (within the `route_to` guardrails).

*Resolved:* "compiled workflow" = resolving Steps into an executable DAG
(ordering, routing edges, exit conditions); executor = model-agnostic Workers;
step-at-runtime = the unit a Worker pulls (see [worker.md](./worker.md)).
