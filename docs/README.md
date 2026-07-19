# Pipeliner — Design Docs

Pipeliner manages **agentic pipelines**: agent-driven processes that carry a unit
of development work from an initial ask to a reviewed, merge-ready PR. Work is
done by distributed, model-agnostic Workers and orchestrated through four fixed
phases, all on a dedicated git branch.

## Read in this order

1. **[concepts.md](./concepts.md)** — vocabulary, the Project→Pipeline→Phase→Workflow→Step
   hierarchy, the four fixed phases, and the git binding.
2. **[execution-model.md](./execution-model.md)** — step roles
   (Planner/Builder/Critic/Manager/Gate), the artifact workspace, structured
   critic verdicts, and the Manager-driven consensus loop.
3. **[architecture.md](./architecture.md)** — control plane + distributed Workers,
   pull-based polling/heartbeats, and branch-per-step concurrency.
4. **[artifact-schema.md](./artifact-schema.md)** — the rigid on-disk git contract
   every step reads/writes (normative).
5. **[worker.md](./worker.md)** — the reference Worker (drives Claude Code),
   leases/heartbeat, and clean-restart / crash-safety semantics.
6. **[tech-stack.md](./tech-stack.md)** — Rails 8 + Hotwire + the Solid trio, and
   how it maps onto the architecture.
7. **[phase-playbooks.md](./phase-playbooks.md)** — worked step-sets for all four
   phases + the pressure-test findings.
8. **[data-model.md](./data-model.md)** — the relational schema for the control
   plane (tables, associations, claim/lease/stuck behaviors).
9. **[scenario-pressure-test.md](./scenario-pressure-test.md)** — 21 adversarial
   scenarios + ranked findings (the current worklist).

## Settled decisions

- **Projects** (root; 1:1 with a git repo) own many **Pipelines**. Pipeliner is
  multi-project.
- Four fixed phases: **Define → Plan → Build → Review**; each consumes prior
  phases' artifacts. **Phase artifacts differ by phase** (Build's primary output
  is code changes in the repo, not `.pipeliner/` docs).
- A Step has two axes: **type** (behavior: Planner/Builder/Critic workers +
  Manager/Gate controllers) and **role** (an *arbitrary* worker-matching label).
  One Manager per phase drives consensus.
- **Model-agnostic Workers** poll a control plane, claim one Step, run it (Claude
  agent or other LLM), report heartbeat + incremental progress. **Matching is
  role-based** — a step declares a required role; workers report the arbitrary
  roles they support **on connect and every heartbeat**; a worker claims a step
  iff it supports that role. Roles mean anything (`code`, `review`, `ui-tests`
  needing a browser, `claude` for Claude-only). A ready step whose role no
  connected worker supports is flagged **stuck**.
- **Steps are configurable, not hard-coded.** A **Step Library** of templates is
  editable in the UI; workflows are composed **manually and/or by an agentic
  Planner** that selects which (conditional) steps a task needs.
- **Git is the artifact store**; the control-plane DB holds ephemeral runtime
  state. Stable paths, **latest content only** (no per-iteration snapshots).
- **Branch-per-step**, merging into the pipeline branch; the pipeline branch is
  the PR that merges to repo master at the end.
- **Inter-phase rework routing:** a later phase (esp. Review) can send work back
  to an earlier phase with feedback — **automated** (info was just missed) or
  **human-in-the-loop** (needs more context); capped to avoid infinite cycles.
- **Branch write rules are infra-enforced:** a step worker can push only `step/**`
  branches (scoped GitHub App token + GitHub rulesets, not agent trust); the
  control plane's **pre-merge scope check** rejects out-of-scope diffs; only the
  control plane merges; only a human merges to master.
- **Phase-boundary squashing:** each phase's commits collapse to one phase commit;
  clean ~4-commit history before the final PR.
- **Finalization:** at the end of Review, `.pipeliner/` is **zipped to S3** for
  audit and **stripped from the branch**, so the merged PR is clean code only.
- **Safe parallelism = disjoint ownership** (`.pipeliner/` subtrees automatically;
  source-code scopes assigned by the Planner). Overlap ⇒ serialize.
- **Reference Worker drives Claude Code** in **Node/TypeScript**, running **each
  step in a fresh ephemeral container** (no human escalation). Heartbeat **15s** /
  lease **60s**; steps restart cleanly (at-least-once). Transport: HTTPS
  long-poll + POST, outbound-only.
- **Deployment: local-first** (run the control plane locally while iterating);
  cloud host via Kamal deferred.
- **Loop caps:** default **max-iterations = 10**; on non-convergence, **pause &
  escalate to a human** (not silent failure). Stuck-role grace **~90s**.
- Stack: **Rails 8**, PostgreSQL, Hotwire (Turbo + Stimulus), Solid
  Queue/Cache/Cable, Propshaft + import maps, **Tailwind**, Devise, S3, Kamal.

## Open items — from the scenario pressure test

The 21-scenario adversarial review is in
[scenario-pressure-test.md](./scenario-pressure-test.md). **All Critical/Major
findings are now resolved** — decisions below are recorded in the normative docs.

**Critical — resolved**
| # | Finding | Decision |
|---|---------|----------|
| C1 | Git topology impossible (control plane can't hand a worktree to an outbound-only worker) | **Workers clone locally + push `step/**` directly to GitHub origin.** Enforcement = GitHub **rulesets** (protect master/pipeline) + **control-plane pre-merge scope check** (no self-hosted hook). Control plane merges via GitHub API. Git creds = short-lived GitHub App token. |
| C2 | Worker execution environment unspecified | **Repo-native env** (repo's devcontainer/Dockerfile builds the per-step container) + a **project onboarding assessment** worker task that verifies runnability when a project is added. |
| C3 | Rework after merge leaves bad code | **Forward-only** corrective commits (no history rewrite); rework Builder's `scope` expands to cover reverts; coverage critics guard completeness. |

**Major — resolved**
| # | Finding | Decision |
|---|---------|----------|
| M4 | Shared/integration files break disjoint scopes | **Integrator owns declared `shared_paths`**; parallel Builders emit *intents*; pre-merge check enforces it. |
| M5 | Manager executor undecided | **Hybrid** — control-plane scheduling + Manager LLM judgment; `manager.json` / `manager_decisions`. |
| M6 | Dynamic fan-out breaks static DAG | **Fan-out expansion outcome** returns keys at runtime; control plane mints shard + fan-in runs. |
| M7 | Stuck runs not recovered | Re-evaluate `stuck → ready` when a capable worker connects. |
| M8 | No cancellation channel | **`cancel` flag in the heartbeat response**; merges fenced for canceled runs. |
| M9 | Branch drift from base | **update-from-base** merge (on-demand "Update from main"; `Pipelines::UpdateFromBase`) — implemented; auto pre-Review + conflict-resolution step still future. |
| M10 | LLM steps aren't idempotent | **At-least-once execution, at-most-one merge**; `epoch`/lease-id fences duplicate/late completions. |
| M11 | History contradiction | Reconciled to **latest-only**. |

**Minor / adopted**
| # | Finding | Decision |
|---|---------|----------|
| M12 | Four-phase overkill for trivial work | **Scale down within the 4 phases** (auto-gates + minimal auto-composed workflows); no phase skipped. |
| M17 | Code-biased naming | **`kind: repo`** (was `code`) + **per-project-type template packs** (`software` default). |
| M18 | No graceful-degrade critic | Critics may return **`not_applicable`**. |

**Wiki verdict:** Pipeliner **generalizes to non-code git repos** — structure,
roles, branch-per-step, scope, rework, finalization all held; only naming/defaults
were code-biased (fixed via M17/M18).

**Still genuinely open (small):** routing latitude
(config vs. Manager discretion); per-artifact content schemas; container base-image
specifics; S3/hosting (deferred, local-first).

## Status

**Implementation underway** (since 2026-07-18): Rails 8.1.3 / Ruby 4.0.6 app
scaffolded at the repo root with Devise auth and the app shell. See
[developer-guide.md](./developer-guide.md) for setup and day-to-day development,
and `guides/` for the mandatory coding standards. Docs remain living drafts;
`[OPEN]` markers flag unresolved points.
