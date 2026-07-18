# Pipeliner — Worker Spec (reference implementation)

> Working draft. Specifies the Worker process that claims and executes Steps.
> Builds on [architecture.md](./architecture.md) and
> [artifact-schema.md](./artifact-schema.md). **[OPEN]** marks unresolved items.

## What a Worker is

A **Worker** is a separate process (not necessarily Ruby) that polls the control
plane for ready Steps and executes them. Workers are **model-agnostic**; this doc
specifies the **first reference Worker**, which drives **Claude Code** instances.

- The reference Worker launches **Claude Code agents** to do a step's work.
- Those agents run with **permissions pre-approved so nothing escalates to a
  human** (auto-approve / bypass-permissions mode). Containment comes from
  isolation (dedicated worktree + step branch + scoped credentials), not from
  interactive approval — see *Safety* below.

## Project onboarding assessment (project-level task)

Beyond pipeline steps, Workers also handle **project-level tasks**. The first is
**onboarding assessment**, run when a Project is added (C2):

- A capable worker clones the repo, **builds the repo-native environment**
  (devcontainer/Dockerfile), and verifies it actually runs: deps install, the
  test/lint commands execute, required services/DB come up, and — if the project
  needs it — a browser is present for `ui-tests`.
- It reports **readiness** (or a list of what's missing/misconfigured), which the
  UI surfaces so the user fixes the env **before** any pipeline runs — instead of
  discovering env failures mid-Build.
- This confirms which **capability roles** the project's workers can satisfy.

Onboarding is dispatched and claimed through the same pull/role mechanism as
steps (it just isn't part of a pipeline's four phases).

## Roles & work matching

Matching is **role-based**, and **roles are arbitrary, worker-declared labels** —
*not* the behavioral step type (planner/builder/critic). A role names whatever
capability a step needs. Every Step declares a **required role**; a Worker
declares the **set of roles it supports**; a Worker may claim a Step **iff it
supports that step's role**.

- Workers report their supported roles **on connect and in every heartbeat**, so
  the set is **dynamic** — a worker can gain/lose roles (e.g. a browser becomes
  available) and the system tracks the *currently* available roles.
  ```json
  // heartbeat / connect payload
  {
    "worker_id": "wk_...",
    "roles": ["claude", "code", "ui-tests"],
    "backend": "claude-code",
    "concurrency": 2
  }
  ```
- **Eligibility:** `step.role ∈ worker.roles`. Nothing else is required.
- **Roles are free-form and can mean anything:**
  - identity — a `claude` role only Claude workers advertise (so a step can demand
    a Claude worker specifically);
  - environment/tooling — a `ui-tests` role only advertised by workers configured
    with a browser and all the trappings to run UI tests;
  - domain — `review`, `security-review`, `requirements`, etc.
- **Workers may support multiple roles** simultaneously and are eligible for any
  step whose role they support.

### Stuck detection (no eligible worker)

Because supported roles are known live (via heartbeats), the control plane can
tell when a **ready step requires a role no connected worker currently supports.**
It **flags that step (and its pipeline) as _stuck_** — "no worker with role `X` to
pick up this work" — instead of letting it wait silently. Surfaced in the UI so
the user can spin up / configure a worker with that role. **Grace period: ~90s** —
a ready step with no eligible *online* worker is flagged `stuck` after ~90s (lets
a role-capable worker reconnect first). When a worker advertising the missing role
connects, stuck runs are re-evaluated back to `ready`.

## Responsibilities (lifecycle)

1. **Identity & registration.** The Worker has a **stable worker id** (persisted
   locally) and registers with the app, authenticating to obtain a worker token.
2. **Fetch directions.** Download the current pipeline/worker directions
   (protocol version, endpoints, config).
3. **Poll for work.** Long-poll/poll the app for a **ready Step**. Claiming a step
   returns a **lease** (see *Leases & heartbeat*) plus a **context bundle**.
4. **Download step context.** The bundle contains everything needed to run the
   step, with nothing durable stored on the worker:
   - `step.json` (type, role, inputs, outputs, scope, fan-out),
   - `prompt.md` (the step's system prompt),
   - resolved `input.json` (input artifact refs + any routed feedback),
   - git coordinates: origin, pipeline branch + the **step branch** to create,
   - **dynamic instructions**, including a **short-lived, step-scoped API key**
     (callbacks) and a **short-lived GitHub App token** scoped to push `step/**`.
5. **Prepare an isolated workspace.** Clone origin (or reuse a local cache),
   `git worktree add` a **fresh step branch** off the pipeline branch, and build
   the **repo-native environment** (C2): the container starts from the repo's own
   devcontainer/Dockerfile (validated at project onboarding — see below). A fresh
   checkout every time is what makes restarts clean.
6. **Execute.** Launch a Claude Code agent in the container against the worktree
   with the system prompt + inputs; it writes outputs only to the paths declared
   in `step.json`. Verification critics can actually run tests/lint/etc. because
   the repo-native env is present.
7. **Heartbeat + progress.** Emit **regular heartbeats** (renewing the lease,
   reading back the `cancel` flag) and stream **incremental progress**.
8. **Complete.** Write `result.json` (and `verdict.json` if a critic), commit, and
   **push the step branch to GitHub origin**, then signal `done`. The **control
   plane merges** it into the pipeline branch via the GitHub API (after the
   pre-merge scope check), serialized to avoid races.
9. **Release & loop.** Drop the lease and poll for the next step.

## Leases & heartbeat ("nothing gets forgotten")

- Claiming a step grants a **lease with an expiry**. The Worker's heartbeat
  **renews** the lease.
- If heartbeats stop (worker crash, hang, network loss), the lease **expires** and
  the control plane's sweeper **reclaims the step → marks it ready again** for any
  worker. This is the guarantee that stalled/forgotten work is detected and
  retried. **Heartbeat: 15s. Lease TTL: 60s** (~4 missed beats → reclaim).
- The **heartbeat response is a control channel**: it carries back a `cancel` flag
  (see cooperative cancellation, [architecture.md](./architecture.md)) so the
  outbound-only worker learns when to stop and clean up.
- Heartbeats and lease/claim state live in the **DB**, not git (ephemeral).

## Branch write rules & enforcement

**The rule (stated simply):** a Step may commit **only to its own step branch**,
and may push **only that branch**. It may **never** write to the pipeline branch,
to master, or to any other step's branch. **Merges are performed exclusively by
the control plane** — never by a worker.

Authorization matrix:

| Actor                       | May write to                                            |
|-----------------------------|---------------------------------------------------------|
| Step worker (leased token)  | its **own step branch ref only**                        |
| Control plane (privileged)  | create step branches; **merge** step→pipeline; pipeline branch; open PR |
| Human                       | merge the PR → repo **master**                           |

Because agents run without human escalation, these rules are **enforced by
infrastructure, not by trusting the agent.** Workers push **directly to GitHub
origin** (C1 — no self-hosted git server, so no custom `pre-receive` hook). Layers:

1. **Container + worktree isolation.** The step runs in a fresh container with a
   dedicated worktree on its step branch — the only branch present. Network is
   confined to GitHub origin + the callback API.
2. **GitHub branch rulesets (hard).** The worker identity (scoped GitHub App
   installation) may only **create/push branches matching `step/**`**; `master`
   and the pipeline branch are **protected** (no worker push, no force-push).
   GitHub rejects anything else regardless of what the agent attempts.
3. **Control-plane pre-merge scope check (authoritative for paths).** GitHub can't
   validate per-path scope, so **before merging** a step branch the control plane
   fetches it and **rejects the merge if the diff strays outside the step's
   declared `scope`** (or, for shared files, wasn't produced by the Integrator —
   see [execution-model.md](./execution-model.md)). A bad commit can sit on an
   ephemeral step branch but **can never be merged.**
4. **Merges are control-plane-only, via the GitHub API.** Workers never merge.
5. **Client-side `pre-commit`/`pre-push` hooks.** A fast local guard that fails
   early with a clear message — advisory only (bypassable), never the sole gate.

Net effect: a worker can only ever **create a `step/**` branch**; anything
out-of-scope is caught at the control-plane merge gate; the pipeline branch and
master are only advanced by the control plane and a human, respectively.

## Clean restart / interruption safety (core requirement)

**Invariant: a Step becomes durable only when it commits to its step branch and
reports `result.json`. Before that, it has left no committed trace.**

Consequences:
- **At-most-one-*merge*, not idempotent output (M10).** LLM steps are
  non-deterministic, so two runs of the same step produce *different* content —
  they are **not** idempotent. Safety therefore comes from the **merge gate**, not
  from output equality: the control plane merges **at most one** step branch per
  `(step, iteration)`. Re-runs are fine because only one ever lands.
- **Interrupted step = throw away and redo.** If a Worker (or its agent) dies
  mid-step, the partial, uncommitted worktree is simply discarded. The lease
  expires, the app reclaims the step, and it is re-dispatched from scratch. No
  half-state to reconcile.
- **On Worker restart**, the Worker:
  1. re-registers with its stable id,
  2. asks the app **"what is leased to me?"**,
  3. for each in-flight lease, **abandons** it (releases → app reclaims) and
     **discards the dirty worktree/step branch**, then
  4. resumes normal polling.
- **At-least-once execution, at-most-one merge** is the model — never "resume a
  partially-completed agent."

**Double-completion fencing (M10 — decided):** each claim carries an **epoch /
lease-id**; a completion (push + `done`) is only honored if its epoch matches the
current lease. A worker that completes but crashed before releasing → its branch
is a **duplicate** for an already-merged `(step, iteration)` and is **not merged**
(the merge gate enforces at-most-one). Late/duplicate completions are dropped.

## Security / trust

- Agents run **without human escalation**, so isolation is the safety boundary:
  - **Every step runs in a fresh ephemeral container** (decided) — provisioned by
    the Worker per step, with the worktree mounted and the network confined to the
    GitHub origin + callback API (C1: no self-hosted mirror). Torn down after
    the step.
  - dedicated **worktree + step branch** (blast radius = that step's subtree /
    declared scope),
  - **short-lived, step-scoped API key** (least privilege: only heartbeat/
    progress/result for *this* step; expires with the lease),
  - all work confined to the **pipeline branch**, never repo master.
- **Transport & authn (decided):** worker↔app over **HTTPS** — long-poll to claim,
  POST for heartbeat/progress/result. Authn = a **worker-level bearer token**
  (registration) plus the **per-step token** for run-scoped calls and git push.

## Deliverable

Building this reference Worker is an explicit deliverable, alongside the Rails
control plane. It can live in a separate directory/repo since it is a distinct
process with its own runtime. A Worker **need not be Ruby** — the contract is the
HTTP API + git, so any language works. **Reference Worker: Node/TypeScript**
(decided), since Claude Code is a Node CLI with a TS SDK and hosting the agents
there is the most natural fit. Other-language workers remain first-class via the
same contract.
