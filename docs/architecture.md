# Pipeliner — Architecture

> Working draft. Defines the runtime shape: control plane, workers, and how work
> flows between them. Builds on [concepts.md](./concepts.md) and
> [execution-model.md](./execution-model.md). **[OPEN]** marks unresolved items.

## Shape: control plane + distributed workers

Pipeliner is split into a **control plane** (the app) and a fleet of **Workers**
(separate processes that execute steps).

```
        ┌──────────────────────────────────────────────┐
        │                CONTROL PLANE (app)            │
        │  • Projects, Pipelines, Phases, Workflows,    │
        │    Steps                                      │
        │  • Artifact Workspace (versioned)             │
        │  • Phase Managers (consensus loop)            │
        │  • Work queue  ← ready Steps enqueued here    │
        │  • Heartbeat / progress tracking              │
        │  • Git: branch + PR per pipeline              │
        └──────────────┬───────────────────────────────┘
                       │  poll for work / report back
        ┌──────────────┴───────────────────────────────┐
        │                    WORKERS                    │
        │  Separate processes. Each one:                │
        │   1. Polls the app for available work         │
        │   2. Claims one Step's worth of work          │
        │   3. Executes it (as a Claude agent OR        │
        │      another LLM — model-agnostic)            │
        │   4. Emits heartbeats + incremental progress  │
        │   5. Reports result / writes artifact back    │
        └───────────────────────────────────────────────┘
```

## The unit of work: one Step

- Workers pull **individual Steps** — a Step is the atomic dispatchable unit.
- A work item handed to a worker carries everything needed to run the step: the
  step's **system prompt**, its **type** (planner/builder/critic) and **role**
  (matching label), the **input artifacts** (or refs) it reads, the target branch,
  and its allowed toolset.
- The worker executes the step and reports back: **new artifact version(s)** or a
  **structured verdict**, plus completion status.

## Workers are model-agnostic

- A Worker may run as a **Claude agent** (e.g. via the Claude Agent SDK) **or a
  different LLM.** The step contract (inputs → outputs/verdict) is the same
  regardless of backend.
- Implication: the app must not assume a specific model/provider. **Matching is
  role-based** (decided): every step has a role; a worker declares the set of
  roles it fulfills and may claim a step iff it fulfills that step's role — e.g.
  grant Claude workers `builder`/`planner` and an OpenAI worker `critic` so review
  routes to OpenAI. See [worker.md](./worker.md) → *Roles & work matching*.

## Git topology (C1 — decided)

Workers are outbound-only and Projects bind to an **external GitHub repo**, so:

- **Workers push step branches directly to GitHub origin** (no self-hosted git
  mirror). They clone origin and build worktrees locally.
- **Enforcement of branch write rules** is **GitHub-native** (there is no custom
  server-side `pre-receive` hook available on GitHub):
  - **Branch rulesets:** the worker identity (a scoped bot/GitHub App) may only
    **create/push branches matching `step/**`**; `master` and the pipeline branch
    are **protected** (no direct worker pushes; no force-push).
  - **Path/scope enforcement moves to the control plane's pre-merge check**
    (GitHub can't validate per-path scope). Before merging a step branch, the
    control plane fetches it and **rejects the merge if the diff strays outside
    the step's declared `scope`.** A bad commit can land on an ephemeral step
    branch but can never be *merged*.
- **Merges are done by the control plane via the GitHub API** (step→pipeline; and
  the final pipeline→master is a human-reviewed PR).
- **update-from-base (M9 — implemented):** `Pipelines::UpdateFromBase` merges the
  project's default branch into the pipeline branch on demand (the "Update from
  main" action on a finalized pipeline), reusing the per-project clone + flock.
  A clean merge is pushed; a conflict aborts cleanly and surfaces a message for a
  human to resolve. Keeps the branch current; forward-only (merge commit, no
  rewrite). Automatic pre-Review invocation + a dedicated resolution step remain
  future work.
- **Worker git credentials (resolves earlier [OPEN]):** a **short-lived GitHub App
  installation token**, scoped to the project repo, delivered in the step context
  bundle and expiring with the lease.

### Local hub mode (keep intermediary commits off the real remote)

A project's `repo_url` can be a **local bare repo** ("hub") instead of the real
remote. All pipeline traffic — step branches, per-step merges, iteration churn —
stays on the hub; the real remote (GitHub/GitLab) sees nothing until a human
deliberately pushes a finished pipeline branch from the hub and opens the PR/MR.

```
real remote (GitHub/GitLab)          # pristine — final branches only, pushed manually
        ▲  (manual push of finished branch)
local hub  ~/.pipeliner-hubs/<name>.git   # project.repo_url — all pipeline traffic
        ▲  workers push step/**; control plane merges pipeline branches
```

Setup: `git clone --bare <working-repo-or-remote> ~/.pipeliner-hubs/<name>.git`,
register the hub path as the project's `repo_url`. Caveats: refresh the hub from
the real remote before new pipelines (`git fetch <remote-url> <branch>:<branch>`
— the future update-from-base op should own this), and hub mode is inherently
**local-first** (remote workers would need the hub served over SSH/HTTP — the
original C1 mirror topology, worth supporting as a mode when workers leave the
machine).

## Deployment topology

- **Local-first for now** — the control plane runs **locally** while iterating
  (single source of truth: DB, queue, Managers, git coordination, UI). Cloud host
  via Kamal is the eventual path, deferred.
- **Workers run anywhere** — on the user's **local machines**, or on **VMs /
  containers spun up on demand**. They are **heterogeneous and ephemeral**:
  spin up more to add throughput, tear down when idle.
- **Only outbound connections.** Workers make outbound HTTPS to the cloud app and
  outbound git to the remote; the cloud never needs to reach into a worker. This
  is why the protocol is **pull-based** — it works behind NAT/firewalls and for
  short-lived VMs with no stable address.
- **Scaling = worker count.** Because claiming is pull-based and steps are
  idempotent (see [worker.md](./worker.md)), horizontal scale is just "run more
  workers"; they self-register and start polling.
- Workers need repo access — they **clone the pipeline branch** from the git
  remote. **[OPEN]** how workers get git credentials (short-lived token in the
  context bundle, like the app API key?).
- Control-plane deploy via **Kamal** to a cloud host (see
  [tech-stack.md](./tech-stack.md)). **[OPEN]** specific host.

## Communication protocol (pull-based)

- **Polling / claim:** Workers poll the control plane and claim ready work. Pull
  model → the app doesn't need to know worker addresses; workers can scale
  horizontally and come/go freely.
- **Heartbeat:** an in-progress step emits periodic heartbeats. Missing
  heartbeats → the app can reclaim/reassign the step (crash tolerance).
  **[OPEN]** heartbeat interval & reclaim timeout.
- **Incremental progress:** workers stream partial progress so the app (and user)
  can see a step advancing, not just start/finish. **[OPEN]** progress payload
  shape (log lines? % complete? token counts?).

## Concurrency & isolation — branch-per-step

**Resolved.** Every Step runs on its **own git branch**, cut from the pipeline
branch, and **merges back** into the pipeline branch when done. Branch topology:

```
main (repo)
 └── pipeliner/<pipeline-id>              # the pipeline branch = the PR branch
      ├── step/01-define/<wf>/explore  # a step branch, off the pipeline branch
      │     work → commit → merge back → delete
      ├── step/01-define/<wf>/requirements
      └── …
```

Mechanics (revised per C1 — workers are outbound-only, so the control plane can
**not** hand a worktree to a worker): the **worker itself** clones the repo and
creates its step branch + worktree **locally** (via `git worktree add`), off the
pipeline branch. It commits locally and **pushes the step branch directly to
GitHub origin**. The **control plane then merges** the step branch into the
pipeline branch **via the GitHub API** and deletes it. See *Git topology* below.

**Phase-boundary squashing.** A phase merges many step branches, so the pipeline
branch accumulates lots of commits. When a phase completes (advances past its
gate), the control plane **squashes that phase's commits on the pipeline branch
into a single phase commit** (e.g. `Phase 2 — Plan: <summary>`). Result: a clean
~4-commit history (one per phase) before the final PR, on top of which
finalization strips `.pipeliner/`. If inter-phase rework re-opens a phase, it is
re-squashed on completion.

Tradeoff: squashing **collapses intra-phase step/iteration commits**, so
fine-grained git history is not the record of *how* a phase iterated — the
`.pipeliner/` artifacts (current state, `result.json`, `rework.json`) are, and the
full trail is archived to S3 at finalization. See the adjusted version-history
principle in [artifact-schema.md](./artifact-schema.md).

Why this works:
- **Isolation** — each step has its own branch + worktree; parallel steps never
  share an index/HEAD.
- **Conflict-free merges for artifacts** — combined with the exclusive-subtree
  ownership rule (see [artifact-schema.md](./artifact-schema.md)), steps write
  disjoint paths under `.pipeliner/`, so merges back have no conflicts.
- **Configurable parallel vs. series** falls out of the workflow DAG: independent
  steps fan out onto parallel branches; dependent steps serialize.

**Phase 3 (Build)** parallel steps may edit the *same source files* (not
disjoint like artifacts), so their branch merges *can* conflict. **Handling
(decided):** parallel Builders must declare **disjoint scopes** (the Planner
partitions the work); Builders with overlapping or unclear scope **run in
series**, or a fan-in **combine** step reconciles them. See the *Parallel Builder
rule* in [execution-model.md](./execution-model.md) and `step.json.scope` in
[artifact-schema.md](./artifact-schema.md). **[OPEN]** only the residual case:
auto-resolve strategy if a scope-partition proves imperfect and a merge conflicts
anyway.

## Where does the Manager run?

**Decided (M5): hybrid.** The control plane does the **deterministic scheduling**
(dispatch steps, collect verdicts, enforce caps) and makes a **direct Manager LLM
call** for the *judgment* parts (weigh critic disagreement, declare consensus,
choose re-runs). No worker round-trip for control decisions. The Manager's
rationale each round is recorded in `manager.json` (and a `manager_decisions`
row). It is **not** a worker-claimed step.

## Open questions

- **[OPEN]** Residual merge-conflict auto-resolve when a scope partition proves
  imperfect (see branch-per-step section).
- **[OPEN]** Progress payload shape (log lines? % complete? token counts?).

*Resolved since first draft:* work matching → role-based ([worker.md](./worker.md));
same-pipeline concurrency → branch-per-step (above); implementation conflicts →
disjoint Planner-assigned scopes + Integrator ([execution-model.md](./execution-model.md));
Manager placement → hybrid (M5, above); transport → HTTPS long-poll + POST
([worker.md](./worker.md)); worker trust → per-step containers + rulesets +
pre-merge scope check (*Git topology* above, [worker.md](./worker.md)); git
credentials → short-lived GitHub App token in the context bundle (*Git topology*
above).
