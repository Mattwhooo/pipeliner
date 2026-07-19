# Pipeliner — Git Artifact Schema (the step-to-step contract)

> **Normative spec.** This defines the on-disk layout and file formats that every
> Step reads from and writes to. It is a rigid contract: consistency across steps
> depends on it. Builds on [architecture.md](./architecture.md) and
> [execution-model.md](./execution-model.md). Changes here are versioned via
> `schema_version`. **[OPEN]** marks the few items still to decide.

## Principles

1. **Git = durable artifacts + decisions. DB = ephemeral runtime state.**
   Artifacts, manifests, and verdicts live in git (below). Heartbeats, progress,
   and claim/lease status live in the control-plane DB — never in git.
2. **Stable paths; context lives in files, not commits.** A step always writes to
   the *same* path. No run-number directories. **Squashing is history-only — it
   never touches the working tree**, so every step's full context
   (`step.json`, `prompt.md`, `input.json`, `output/`, `verdict.json`,
   `result.json`) **remains preserved in `.pipeliner/` on the branch after a phase
   is squashed.** What squashing removes is only the granular per-commit timeline.
   The durable record is therefore the files themselves (+ the S3 archive at
   finalization), not commit archaeology. **[OPEN]** if intermediate *re-run*
   snapshots of a single step are ever wanted, that would need file-based
   versioning — today only the latest content of each path is kept.
3. **Ownership is exclusive.** A step MUST write only within its own subtree.
   Parallel steps therefore cannot collide, and fan-in merges are conflict-free
   by construction.
4. **Machine files are JSON with a `schema_version`; content artifacts are
   Markdown.** Every JSON file below carries `"schema_version"`.
5. **Slugs are lowercase-kebab-case.** Phase directories are fixed: `01-define`,
   `02-plan`, `03-build`, `04-review`.

## Directory layout (canonical)

```
.pipeliner/
├── manifest.json                       # pipeline manifest
└── phases/
    ├── 01-define/
    │   ├── manifest.json               # phase manifest
    │   └── <workflow-slug>/
    │       ├── manifest.json           # workflow manifest = the compiled DAG
    │       └── <step-slug>/
    │           ├── step.json           # step definition (role, io, fan-out)
    │           ├── prompt.md           # the step's system prompt (versioned)
    │           ├── input.json          # resolved inputs for the current run
    │           ├── output/             # artifact files this step produces
    │           │   └── *.md | *.json
    │           ├── shards/             # ONLY if step.fan_out is set
    │           │   └── <shard-key>/output/*
    │           ├── verdict.json        # critics only
    │           └── result.json         # durable summary of the latest run
    ├── 02-plan/          …
    ├── 03-build/  …           # NOTE: real code changes live in the repo
    └── 04-review/          …           #       proper, not under .pipeliner/
```

- **Every directory MUST contain its `manifest.json` (or `step.json`) before any
  children.** A reader can always discover structure top-down.
- `03-build` produces code changes in the **actual repo tree**; its
  `.pipeliner/` subtree holds only the reasoning/notes/plan artifacts about that
  code, plus `result.json`.

## File formats

### `manifest.json` — pipeline
```json
{
  "schema_version": "1.0",
  "pipeline_id": "pl_...",
  "title": "Human title of the pipeline",
  "branch": "pipeliner/pl_...",
  "pr": { "number": null, "url": null },
  "current_phase": "01-define",
  "config": { "archive_to_s3": true }
}
```
See *Finalization* below: `.pipeliner/` is **not** merged to master — it is
stripped from the branch at the end of Review and archived to S3.

### `manifest.json` — phase
```json
{
  "schema_version": "1.0",
  "phase": "define",
  "order": 1,
  "status": "pending | running | consensus | approved | failed",
  "workflows": ["<workflow-slug>"],
  "gate": { "type": "human | automated", "required": true }
}
```

### `rework.json` — inter-phase rework record (in the *target* phase dir)

Written when a later phase sends work back to this phase (see
[execution-model.md](./execution-model.md) → *Inter-phase rework routing*).
Append-only list; one entry per bounce.
```json
{
  "schema_version": "1.0",
  "entries": [
    {
      "from_phase": "04-review",
      "reason": "R-7 (export to CSV) is unimplemented.",
      "mode": "automated | human",
      "feedback": [ { "target_artifact": "...", "issue": "...", "severity": "major" } ],
      "iteration": 1
    }
  ]
}
```

### `manager.json` — Manager consensus record (per phase, M5)

The hybrid Manager (control-plane scheduling + LLM judgment) records each round's
reasoning here — why it routed, weighed disagreement, or declared consensus.
```json
{
  "schema_version": "1.0",
  "rounds": [
    { "iteration": 2, "verdicts_seen": ["completeness:pass", "docs_match:needs_work"],
      "decision": "route_to", "route_to": ["docs_updater"],
      "rationale": "Requirements are complete; only the docs lag." },
    { "iteration": 3, "decision": "consensus", "rationale": "All critics pass." }
  ]
}
```

### `manifest.json` — workflow (the compiled DAG)
```json
{
  "schema_version": "1.0",
  "workflow": "<workflow-slug>",
  "max_parallel": 4,
  "max_iterations": 10,
  "shared_paths": ["config/routes.rb", "package.json", "db/migrate/**"],
  "steps": [
    { "slug": "explore",      "type": "builder", "role": "code",   "depends_on": [] },
    { "slug": "requirements", "type": "builder", "role": "requirements", "depends_on": ["explore"] },
    { "slug": "completeness", "type": "critic",  "role": "review", "depends_on": ["requirements"],
      "route_to": ["requirements"] }
  ]
}
```
Compiling a workflow = producing this DAG: `depends_on` defines ordering;
independent nodes MAY fan out (up to `max_parallel`); `route_to` names the steps a
critic may bounce work back to. **`shared_paths` (M4)** are files only the fan-in
**Integrator** step may edit; parallel Builders emit *intents* instead (see
[execution-model.md](./execution-model.md)).

### `step.json` — step definition
```json
{
  "schema_version": "1.0",
  "slug": "requirements",
  "type": "planner | builder | critic | manager | gate",
  "role": "requirements",
  "prompt": "prompt.md",
  "inputs": [
    { "artifact": "discovery_notes", "from": "../explore/output" }
  ],
  "outputs": [
    { "artifact": "business_requirements", "kind": "artifact",
      "path": "output/requirements.md" }
  ],
  "scope": null,
  "fan_out": null
}
```
`outputs[].kind`:
- **`artifact`** (default) — a `.pipeliner/` file at `path`; latest content on a
  stable path.
- **`repo`** (M17 — was `code`) — real **changes to the repo's own files** (Build
  phase): source, docs, wiki pages, config — anything the repo contains. Tracked
  by the step branch's git **diff**; its "version" is the merge commit. No
  `output/` file is written. `path` may be omitted or used as a scope hint.
  Domain-neutral so non-code projects (wiki/docs) fit without special-casing.
Two separate axes (see [execution-model.md](./execution-model.md)):
- **`type`** — behavior in the loop (`planner|builder|critic|manager|gate|human`).
  Only `planner|builder|critic` are pulled by Workers; `manager|gate` are
  controllers; **`human`** is executed by a person in the UI (Define's Human
  Feedback step) — the Manager dispatches it into an `awaiting_input` run no
  worker claims, and `Phases::SubmitHumanFeedback` completes it.
- **`role`** — an **arbitrary** capability label used for **worker matching only**.
  A Worker may claim a step **iff it supports the step's `role`** (see
  [worker.md](./worker.md)). Roles can mean anything: `code`, `review`,
  `ui-tests` (needs a browser-configured worker), `claude` (Claude workers only).
`scope` (required for any Builder that may run in parallel with another Builder):
declares the responsibilities/paths this builder owns so parallel builders don't
collide on real source. Parallel builder scopes MUST be disjoint (set by the
Planner). Example:
```json
"scope": {
  "responsibility": "API endpoints for billing",
  "paths": ["app/controllers/billing/**", "app/services/billing/**"]
}
```
`fan_out` (optional):
```json
"fan_out": { "mode": "static | dynamic", "keys": ["a","b"], "max": 4 }
```
When set, the step writes each parallel unit under `shards/<shard-key>/output/`
and writes NOTHING to `output/`; a downstream fan-in step consumes the shards.
- **`static`** — keys known at compile time (Planner-enumerated).
- **`dynamic` (M6)** — keys **discovered at runtime**: the step returns a
  **fan-out expansion outcome** listing the shard keys, and the **control plane
  then materializes the shard `step_run`s + the fan-in run dynamically** (the
  static DAG can't pre-know them).

### `input.json` — resolved inputs (written by the control plane per run)
```json
{
  "schema_version": "1.0",
  "iteration": 2,
  "resolved_inputs": [
    { "artifact": "discovery_notes", "path": "../explore/output/notes.md",
      "commit": "abc1234" }
  ],
  "feedback": [
    { "from": "completeness", "finding_id": "F3",
      "issue": "R-4 is not atomic; split it.", "severity": "major" }
  ]
}
```
On the first run `feedback` is `[]`. On a revision it carries the routed findings.

### `verdict.json` — critic output (rigid)
```json
{
  "schema_version": "1.0",
  "step": "completeness",
  "verdict": "pass | needs_work | not_applicable",
  "summary": "One-line judgment.",
  "findings": [
    {
      "id": "F1",
      "target_artifact": "business_requirements",
      "issue": "Requirement R-4 is not atomic; split into two.",
      "severity": "blocker | major | minor",
      "route_to": "requirements",
      "suggested_fix": "Split R-4 into R-4a and R-4b."
    }
  ]
}
```
`findings` is `[]` when `verdict` is `pass`.

### `result.json` — durable summary of the latest run
```json
{
  "schema_version": "1.0",
  "step": "requirements",
  "status": "succeeded | failed",
  "iteration": 2,
  "worker": { "id": "wk_...", "backend": "claude | other", "model": "..." },
  "outputs": [ { "artifact": "business_requirements",
                 "path": "output/requirements.md" } ],
  "commit": "def5678"
}
```

## The Step I/O contract (what every worker relies on)

A worker claiming a step is **guaranteed**:
- a dedicated **worktree on its own step branch**, cut from the pipeline branch
  (see [architecture.md](./architecture.md) → branch-per-step),
- its `step.json` (type, role, io), `prompt.md` (system prompt), and `input.json`
  (resolved input paths + feedback).

A worker MUST, on completion:
- write its artifact(s) **only** to the path(s) named in `step.json.outputs`
  (or, if fan-out, to `shards/<key>/output/`),
- write `verdict.json` **iff** its `type` is `critic`,
- write `result.json`,
- commit to its **step branch**. The control plane then **merges the step branch
  back into the pipeline branch** and removes the worktree/branch.

A worker MUST NOT write outside its own step subtree.

## Invariants (enforceable checks)

- Each directory has its manifest/definition file before children exist.
- A step's writes are confined to its own subtree (`output/`, `shards/*`,
  `verdict.json`, `result.json`).
- `verdict.json` exists **iff** `type` == `critic`.
- Every machine JSON file has a matching `schema_version`.
- Content artifacts referenced by a manifest exist at the declared path.
- Fan-out steps write shards and no top-level `output/`; fan-in steps declare all
  shard producers in `depends_on`.

## Canonical artifacts (per phase)

Because later phases read earlier phases' outputs by name, artifact names are an
**inter-phase contract**. These canonical names are stable and steps may rely on
them (custom steps may add more):

| Phase       | Canonical artifacts                                             | Kind     |
|-------------|----------------------------------------------------------------|----------|
| `01-define` | `discovery_notes`, `open_questions`, `open_questions_structured`, `human_answers`, `business_requirements`, `workflow_plan`, `define_summary`, `documentation` | artifact |
| `02-plan`   | `technical_approach`, `technical_design`, `build_task_plan`, `documentation` | artifact |
| `03-build`  | repo changes (git diff); optional `build_notes`                | repo / artifact |
| `04-review` | `review_report`                                                | artifact |

`build_task_plan` (Plan → Build) carries the scoped, disjoint task partition Build
fans out over. **[OPEN]** formalize each canonical artifact's own schema.

`open_questions_structured` (Define, `output/open_questions.json`) is a
machine-readable sibling of `open_questions`: an array of
`{ "question", "default" }` objects, question text only (no numbering). It
exists so a product UI can render one labeled input per question with the
assumed default as placeholder text, without parsing free-form markdown. A
step whose run predates this artifact simply has none — callers must degrade
gracefully (empty list), never error, since `open_questions` (the prose form)
remains the source of truth presented at the phase gate.

`human_answers` (Define, `output/human_answers.md`) is the Human Feedback step's
output: the human's answers to the open questions plus optional notes. Its run
also carries `human_answers_structured` in `result.json` (an array of
`{ "question", "answer" }`). The answers live in the DB (the step pushes no
branch), so the Manager delivers them to the re-running Clarifying Questions step
as `feedback` (input.json), not as an on-branch artifact.

`define_summary` (Define, `output/define_summary.md`) is the Define Review step's
output and the last artifact produced in Define: a plain-language record of what
was decided (from the Q&A) plus the full numbered requirements. The human
approves the Define gate off this summary.

`workflow_plan` (Define, `output/workflow_plan.json`) is the Workflow Planner's
output: the composed DAG for the Plan, Build and Review phases (top-level `plan`,
`build`, `review` arrays of `{ "template", "route_to" }`). It moved to Define — a
single planner now composes all three downstream phases (see
[execution-model.md](./execution-model.md) → "Define decision tree").

## Finalization (end of Review)

`.pipeliner/` is **working scaffolding, not shipped code.** When the Review phase
completes, the control plane:

1. **Zips the entire `.pipeliner/` tree** (all four phases' artifacts, verdicts,
   manifests, results — the full reasoning trail).
2. **Uploads the zip to S3**, keyed by pipeline id, for later review/audit.
3. **Removes `.pipeliner/` from the pipeline branch** (a finalization commit) so
   the PR that merges to the repo's real master contains **only real code
   changes** — no metadata pollution.

So the durable audit trail lives in **S3** (and the PR history), while master
stays clean. **Key convention:** `pipelines/<project_slug>/<pipeline_id>.zip`;
**retention:** keep by default (configurable); the DB `archives` table is the
index (pipeline → S3 object). (Moot until hosted — see local-first.)

## Open questions

- **Shard keys (decided):** support both — default **planner-enumerated up
  front**; **dynamic runtime fan-out** supported via a fan-out expansion outcome
  (see pressure-test finding M6).
- **File naming (decided):** **constrained** — one canonical filename per declared
  artifact, so downstream steps can rely on the path.
- **Re-run history (decided):** **latest-only** — a step's stable path holds only
  its most recent content; no intermediate iteration snapshots. (Reconciles the
  M11 contradiction — see principle 2.)
- **[OPEN]** formalize each canonical artifact's own content schema.
- **[OPEN]** Where do phase Manager decisions get recorded — leaning a
  `manager.json` per phase (see pressure-test finding M5).
