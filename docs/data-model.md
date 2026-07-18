# Pipeliner — Data Model (control plane)

> Working draft. The relational model behind the Rails control plane. Builds on
> [concepts.md](./concepts.md), [execution-model.md](./execution-model.md),
> [architecture.md](./architecture.md), and [artifact-schema.md](./artifact-schema.md).
> **[OPEN]** marks unresolved items.

## What lives where (the boundary)

- **Git (`.pipeliner/` + code):** source of truth for **artifacts, verdicts,
  results, rework records** — the durable content.
- **Database (this doc):** **structure** (projects → … → steps), **ephemeral
  runtime state** (leases, heartbeats, progress, claim status), and **indexes**
  (pointers into git/S3) so the UI is fast and live without shelling out to git.

The DB rows for content (e.g. `result`, `verdict`, `rework`) are **cached mirrors
/ pointers**; git remains authoritative.

## Entity overview

```
User ─< Membership >─ Project ─1:1─ git repo
                         │
                         └─< Pipeline ──1:1── branch + PR
                               ├─ Phase (exactly 4: define, plan, build, review)
                               │    ├─ Workflow (1+)
                               │    │    └─ Step (1+)  ── depends_on / route_to (edges)
                               │    │          └─ StepRun (execution attempts / the work queue)
                               │    └─ Approval (gate decisions)
                               ├─ ReworkEvent (inter-phase send-backs)
                               └─ Archive (S3 finalization pointer)

Worker ──claims──> StepRun          (role-matched, lease-based)
StepRun ─1:1─ StepToken             (short-lived scoped credential)
StepTemplate                        (the Step Library; steps are instantiated from these)
ArtifactRef                         (index of .pipeliner artifacts for the UI)
```

## Tables

### `users` (Devise)
Standard Devise columns. A user authenticates to the app and owns/joins projects.

### `memberships`
| column | type | notes |
|---|---|---|
| user_id | bigint FK | |
| project_id | bigint FK | |
| role | string enum | `owner \| admin \| member` (app-level, unrelated to step roles) |
Unique (user_id, project_id).

### `projects`
| column | type | notes |
|---|---|---|
| name | string | |
| repo_url | string | the single GitHub repo (1:1); workers push `step/**` here (C1) |
| default_branch | string | e.g. `main`/`master` — pipeline branches cut from here |
| project_type | string | template pack: `software` (default) `\| wiki \| …` (M17) |
| github_app_installation_id | string | for minting short-lived scoped push tokens (C1) |
| env_status | string enum | onboarding: `pending \| assessing \| ready \| needs_setup` (C2) |
| settings | jsonb | project-level defaults (gate policy, archive on/off, …) |

### `pipelines`
| column | type | notes |
|---|---|---|
| project_id | bigint FK | |
| title | string | |
| slug / public_id | string | `pl_...` used in branch name & paths |
| branch | string | `pipeliner/<public_id>` — the pipeline trunk / PR branch |
| pr_number, pr_url | int / string | nullable until opened |
| status | string enum | `draft \| running \| awaiting_human \| blocked \| stuck \| completed \| aborted` |
| current_phase | string enum | `define \| plan \| build \| review` |
| config | jsonb | `{ archive_to_s3: true, ... }` |
| initial_prompt | text | the original ask |
Indexes: (project_id, status), unique (project_id, branch).

### `phases`
Exactly four rows per pipeline, seeded at creation.
| column | type | notes |
|---|---|---|
| pipeline_id | bigint FK | |
| kind | string enum | `define \| plan \| build \| review` |
| position | int | 1..4 |
| status | string enum | `pending \| running \| consensus \| approved \| reworking \| failed` |
| gate_mode | string enum | `human \| auto` (configurable per phase) |
| rework_count | int | for the max-rework cap |
Unique (pipeline_id, kind).

### `workflows`
| column | type | notes |
|---|---|---|
| phase_id | bigint FK | |
| slug | string | |
| max_parallel | int | default e.g. 4 |
| max_iterations | int | consensus-loop safety cap |
| status | string enum | `pending \| running \| converged \| failed` |
| compiled_at | datetime | when the DAG was last resolved |

### `step_templates` (the Step Library)
Reusable definitions users manage in the UI; steps are instantiated from these.
| column | type | notes |
|---|---|---|
| project_id | bigint FK (nullable) | null = global/shared template |
| name | string | "Requirements Writer", "UI Testing" |
| step_type | string enum | `planner \| builder \| critic \| manager \| gate` |
| role | string | **arbitrary** matching label (`code`, `review`, `ui-tests`, …) |
| system_prompt | text | |
| default_inputs | jsonb | artifact refs it reads |
| default_outputs | jsonb | `[{artifact, kind: artifact\|code, path}]` |
| requirement | string enum | `required \| conditional` |
| default_scope | jsonb | nullable |

### `steps` (instances within a workflow)
Mirror of `step.json` on disk.
| column | type | notes |
|---|---|---|
| workflow_id | bigint FK | |
| step_template_id | bigint FK (nullable) | provenance if instantiated from a template |
| slug | string | unique within workflow |
| step_type | string enum | `planner \| builder \| critic \| manager \| gate` |
| role | string | arbitrary matching label; required for worker-run types |
| system_prompt | text | |
| inputs | jsonb | `[{artifact, from}]` |
| outputs | jsonb | `[{artifact, kind, path}]` |
| scope | jsonb | nullable; disjoint-ownership for parallel builders |
| fan_out | jsonb | nullable |
| position | int | authoring order |

### `step_edges` (the DAG)
| column | type | notes |
|---|---|---|
| workflow_id | bigint FK | |
| from_step_id | bigint FK | |
| to_step_id | bigint FK | |
| kind | string enum | `depends_on` (ordering) \| `route_to` (critic bounce target) |
Unique (from_step_id, to_step_id, kind).

### `step_runs` (execution attempts — **this is the work queue**)
A run is one dispatchable unit for a specific step + iteration. Ready runs are what
workers claim.
| column | type | notes |
|---|---|---|
| step_id | bigint FK | |
| iteration | int | logical revision (feedback-driven re-run) |
| attempt | int | execution retry of the same iteration (after crash/reclaim) |
| shard_key | string (nullable) | set for fan-out shards |
| state | string enum | `ready \| claimed \| running \| succeeded \| failed \| stuck` |
| required_role | string | copied from step for fast matching/indexing |
| worker_id | bigint FK (nullable) | current claimant |
| lease_expires_at | datetime (nullable) | heartbeat renews it |
| last_heartbeat_at | datetime (nullable) | |
| progress | jsonb (nullable) | latest incremental progress (for live UI) |
| result | jsonb (nullable) | mirror of `result.json` |
| verdict | jsonb (nullable) | mirror of `verdict.json` (critic runs) |
| commit_sha | string (nullable) | the step-branch commit merged back |
| step_branch | string | `step/<phase>/<wf>/<slug>/<lease>` |
| epoch | string | lease-id fence — completions honored only if epoch matches (M10) |
| started_at, finished_at | datetime | |
Indexes: **(state, required_role)** for claiming; (step_id, iteration, attempt) unique;
(lease_expires_at) for the reclaim sweeper.
**Idempotency key:** (step_id, iteration) — guards double-completion.

### `workers`
| column | type | notes |
|---|---|---|
| public_id | string | `wk_...`, stable across restarts |
| name | string | |
| status | string enum | `online \| draining \| offline` |
| backend | string | `claude-code \| openai \| ...` (informational) |
| model | string | informational |
| supported_roles | jsonb (string[]) | **refreshed on connect and every heartbeat** |
| concurrency | int | max simultaneous claims |
| last_heartbeat_at | datetime | offline when stale |
| auth_token_digest | string | worker-level auth |
Index: (status), GIN on supported_roles for role-availability queries.

### `step_tokens` (short-lived scoped credentials)
Issued per claimed run; used by the agent to call back and to push its branch.
| column | type | notes |
|---|---|---|
| step_run_id | bigint FK | |
| token_digest | string | |
| allowed_ref | string | the one git ref this token may push (server-enforced) |
| scopes | jsonb | e.g. `[heartbeat, progress, result]` |
| expires_at | datetime | tied to the lease |

### `rework_events` (inter-phase send-backs)
Mirror of `rework.json`, indexed for the UI/timeline.
| column | type | notes |
|---|---|---|
| pipeline_id | bigint FK | |
| from_phase_id | bigint FK | who raised it (usually review) |
| target_phase_id | bigint FK | where it goes back to |
| reason | text | |
| mode | string enum | `automated \| human` |
| feedback | jsonb | structured findings |
| raised_by | string enum | `agent \| human` |
| resolved_at | datetime (nullable) | |

### `approvals` (gate decisions)
| column | type | notes |
|---|---|---|
| phase_id | bigint FK | the gate being ratified |
| user_id | bigint FK | who decided |
| decision | string enum | `approve \| send_back \| abort` |
| target_phase_id | bigint FK (nullable) | for `send_back` |
| note | text | |

### `artifact_refs` (index of git artifacts for the UI)
Cache/pointer; git is authoritative.
| column | type | notes |
|---|---|---|
| pipeline_id | bigint FK | |
| phase_kind, workflow_slug, step_slug | string | locate the producer |
| name | string | canonical artifact name |
| kind | string enum | `artifact \| code` |
| path | string | `.pipeliner/...` (null for pure code) |
| commit_sha | string | version pointer |
| updated_at | datetime | |

### `archives` (S3 finalization pointer)
| column | type | notes |
|---|---|---|
| pipeline_id | bigint FK | |
| s3_bucket, s3_key | string | the zipped `.pipeliner/` |
| bytes | bigint | |
| created_at | datetime | |

### `manager_decisions` (M5)
Per-round record of the hybrid Manager's judgment (mirrors `manager.json`).
| column | type | notes |
|---|---|---|
| phase_id | bigint FK | |
| iteration | int | |
| decision | string enum | `route_to \| consensus \| escalate` |
| route_to | jsonb | step slugs, when routing |
| rationale | text | why |

### `project_assessments` (C2)
Onboarding env checks run by a worker when a project is added.
| column | type | notes |
|---|---|---|
| project_id | bigint FK | |
| status | string enum | `passed \| failed` |
| findings | jsonb | what's missing/misconfigured |
| ran_by_worker_id | bigint FK | |

## Key behaviors the schema supports

- **Claiming (pull, race-safe):** a worker asks for work; the app runs
  `SELECT ... FROM step_runs WHERE state='ready' AND required_role = ANY(worker.supported_roles)
   ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1`, flips it to `claimed`,
  sets `worker_id` + `lease_expires_at`, and issues a `step_token`. `SKIP LOCKED`
  lets many workers claim concurrently without contention.
- **Heartbeat / reclaim:** heartbeat bumps `lease_expires_at` + `last_heartbeat_at`
  and returns a `cancel` flag (M8). A Solid Queue sweeper resets runs whose lease
  expired back to `ready` (new `attempt` + new `epoch`), discarding the dead
  worktree. Model = **at-least-once execution, at-most-one merge**: a completion is
  honored only if its `epoch` matches, so a duplicate branch from a
  crashed-after-push worker is never merged (M10).
- **Stuck detection:** a `ready` run whose `required_role` is not in *any*
  `online` worker's `supported_roles` → mark `stuck` and surface it. The GIN index
  on `supported_roles` makes this cheap.
- **Consensus loop:** the Manager reads `step_runs.verdict` for a workflow;
  `needs_work` spawns a new `step_run` (iteration+1) for the routed step
  (`step_edges.kind='route_to'`). Loop until converged or `max_iterations`.
- **Inter-phase rework:** an `approval`/critic creates a `rework_event`, sets the
  target `phase.status='reworking'`, increments `phase.rework_count` (cap check),
  and re-opens that phase.
- **Finalization:** on review approval, zip `.pipeliner/` → S3, create an
  `archive` row, commit the strip, mark pipeline `completed`.

## Decisions

- **DAG:** `step_edges` join table (chosen for queryability).
- **`step_runs` history:** **keep** full per iteration/attempt — it's the runtime
  timeline.
- **Multi-tenancy:** `memberships` now; orgs deferred.
- **Progress:** **latest-only** on `step_runs.progress` (Turbo-fed); no
  append-only events table.
- **Manager decisions:** record a `manager_decisions` row + `manager.json`
  (consensus rationale) — see pressure-test finding M5.

## Open questions

- **[OPEN]** Epoch/lease-id fencing for at-most-one-merge (double-completion,
  finding M10) — column(s) on `step_runs`.
- **[OPEN]** Modeling the control-plane git **mirror** per project (finding C1)
  and **base-branch re-sync** state (finding M9).
