# Pipeliner — Phase Playbooks (worked examples + pressure test)

> Working draft. Worked step-sets for all four phases, used to pressure-test the
> model in [execution-model.md](./execution-model.md) and
> [artifact-schema.md](./artifact-schema.md). The **Findings** section at the end
> lists gaps this exercise surfaced. **[OPEN]** marks unresolved items.

Legend: each step is `type/role`. Types: planner/builder/critic/manager/gate.
Roles are arbitrary matching labels (`code`, `review`, `code-review`, `ui-tests`,
…). The phase **Manager** drives the consensus loop; a **Gate** ratifies.

---

## Phase 1 — Define (recap)

Non-technical. Detailed in [execution-model.md](./execution-model.md). Produces
`discovery_notes`, `business_requirements` (atomic "When X, then Y"), and
`documentation`. Human in the loop throughout.

---

## Phase 2 — Plan

**Intent:** convert the Define outputs into a technical design + a build plan.
**Inputs:** `business_requirements`, `discovery_notes`, `documentation`.

```
Steps:
  P1 Approach Planner    planner/code    reads: business_requirements, codebase
                                          writes: technical_approach
  B1 Design Writer       builder/code    reads: technical_approach, codebase
                                          writes: technical_design (components, data model, APIs, file-level plan)
  B2 Work Partitioner    planner/code    reads: technical_design
                                          writes: build_task_plan  ← the Build phase's task list, each with a disjoint SCOPE
  B3 Docs Updater        builder/code    reads: technical_design → writes: documentation (technical)
  C1 Coverage Critic     critic/review   every business requirement addressed by the design?
  C2 Feasibility Critic  critic/review   sound & consistent with the existing codebase?
  C3 Scope Critic        critic/review   are build_task_plan scopes truly disjoint & complete?
  G1 Gate                gate            configurable human approval → Phase 3

Loop (Manager): P1→B1→B2→B3→C1→C2→C3; route findings back (coverage→B1, scope→B2), repeat to consensus.
```

**Key output:** `build_task_plan` — the partitioned, scoped task list that Build
consumes. Producing the scopes here (not in Build) is what lets Build fan out
safely (disjoint-ownership rule).

---

## Phase 3 — Build

**Intent:** implement the plan. **Primary output is real code changes in the
repo — not `.pipeliner/` documents.**
**Inputs:** `technical_design`, `build_task_plan` (scopes), `business_requirements`.

```
Steps:
  P1 Build Planner    planner/code   reads: build_task_plan → sequences/parallelizes the tasks
  B* Implementer(s)   builder/code   ONE PER build task; each owns its declared SCOPE;
                                     writes CODE to the repo; parallel (disjoint scopes)
  B9 Integrator       builder/code   fan-in: wire modules, make the whole thing build
  C1 Test Critic      critic/code    runs tests / typecheck / lint on the branch
  C2 UI Test Critic   critic/ui-tests  (conditional) browser-based checks — only if the task touches UI
  C3 Coverage Critic  critic/review  does the code implement each requirement?
  G1 Gate             gate           configurable → Phase 4

Loop (Manager): implementers run in parallel → integrate → critics.
  A failing test routes back to the OWNING implementer (matched by scope), not all of them.
  Repeat to consensus.
```

**Note:** `C2` requires the `ui-tests` role → only a worker configured with a
browser can claim it; if none is connected, the step is flagged **stuck**.

---

## Phase 4 — Review

**Intent:** validate what was built against the Define & Plan outputs.
**Inputs:** everything — `business_requirements` (Define), `technical_design`
(Plan), the **code diff** (Build), test results.

```
Steps:
  P1 Review Planner       planner/review   decides which reviews this change needs
                                            (adds conditional security-review / ui-review)
  C1 Requirements Conform critic/review    does the built code satisfy each business requirement?
  C2 Design Conform       critic/review    does the implementation match technical_design? deviations?
  C3 Code Quality/Sec     critic/code-review  bugs, security, quality on the diff  ← e.g. an OpenAI worker
  C4 Verification         critic/code      adequate tests present & passing?
  B1 Review Report Writer builder/review   compiles findings into a review report / PR description
  G1 Final Gate           gate             human approve → FINALIZE (zip .pipeliner → S3, strip it, PR ready for master)

Loop (Manager): run the critics; if the build doesn't match intent, rework is needed (see Finding 1).
```

**On approval, finalization runs** (see [artifact-schema.md](./artifact-schema.md)
→ Finalization): `.pipeliner/` is zipped to S3 and stripped; the PR is left as
clean code for a human to merge to master.

---

## Findings (what the pressure test surfaced)

### Finding 1 — Inter-phase rework loops **(RESOLVED — now a first-class primitive)**

Added to [execution-model.md](./execution-model.md) → *Inter-phase rework routing*
with **automated** and **human-in-the-loop** modes, a max-rework cap, and a
`rework.json` record. Original write-up below for context.


Our model has (a) the Manager's **intra-phase** consensus loop and (b) **Gates**
between phases. But **Review inherently bounces work back to an earlier phase**:
- a requirement isn't implemented → back to **Build**;
- the design was wrong → back to **Plan**;
- the requirement itself was wrong → back to **Define**.

This is the "loop" from the original vision, at the *phase* level. We need a
first-class **rework routing** primitive: a phase outcome (esp. Review's Gate) can
be `send_back_to: <earlier phase>` **with feedback**, re-opening that phase. The
receiving phase runs again (with its prior artifacts + the new feedback) and flows
forward. Needs: a max-rework cap to prevent infinite Define↔Review cycles, and a
record of why it bounced. **→ propose adding to [execution-model.md].**

### Finding 2 — A step's output can be *code*, not a `.pipeliner/` artifact

Build's Implementers write **source code to the repo**, tracked by the step
branch's git diff — not files under `output/`. The schema assumed every output is
a `.pipeliner/output/*` file. We need an output **kind**: `artifact` (a
`.pipeliner/` file, the default) vs. `code` (a repo diff on the step branch, whose
"version" is the merge commit). **→ propose adding `outputs[].kind` to
[artifact-schema.md].**

### Finding 3 — Cross-phase artifact contracts are real and must be stable

Plan → Build hands off `build_task_plan` (with scopes); Review reads Define's
`business_requirements` and Plan's `technical_design` directly. These cross-phase
reads mean **artifact names/locations are an API between phases**, reinforcing the
stable-path rule. **[OPEN]** should we define a small registry of canonical
artifact names per phase so steps can rely on them?

### Finding 4 — Routing a failure to the right builder relies on scope

In Build, a failing test must route to the **owning** implementer. That works only
because each builder declared a disjoint `scope`; the Manager maps failure →
scope → builder. Confirms scope is load-bearing, not just for merge-safety.

### Finding 5 — Conditional steps + roles compose cleanly

`ui-tests` and `security-review` are conditional steps the Planner includes only
when relevant, *and* they require special roles (`ui-tests` needs a browser
worker). Composition (which steps) and matching (which worker) are independent
axes and both showed up naturally — good sign the model holds.

### Verdict

The four-phase / planner-builder-critic / branch-per-step model **held up well.**
The one genuine structural gap is **Finding 1 (inter-phase rework loops)** — worth
resolving next. Findings 2–3 are schema refinements; 4–5 are confirmations.
