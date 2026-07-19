# Discovery Notes — Human-in-the-Loop Pause (Define phase)

*Iteration 2 — re-explored to ground the requirements-completeness critic's
feedback (F1–F5) in concrete code facts. Iteration-1 findings below were
re-verified against the current code and stand; a new section adds the facts
needed to resolve F1–F4. (F5 is a requirements-drafting atomicity issue, not a
new code fact — no additional exploration was needed for it.)*

## The ask (restated)

> It should be possible to pause anytime during the Define phase for human
> feedback, especially at the clarifying-questions step. There should be a menu
> loop there of "Explore, Clarifying questions, ask human, repeat from the
> beginning" until done.

Two distinct capabilities are implied:
1. **Pause on demand, mid-flight** — stop the Define phase at an arbitrary point
   (not only at the settled gate) and hand control to a human.
2. **A menu loop of human-driven actions** — while paused, let the human choose
   among {re-run Explore, re-run Clarifying Questions, ask/answer a human, repeat
   from the beginning} and keep looping until they declare Define done.

---

## What exists today

### The Define phase and its steps
- Pipeline creation composes Define directly (`Pipelines::Create`,
  `app/services/pipelines/create.rb`). Default fallback step order
  (`CORE_DEFINE_NAMES`, and `db/seeds.rb` / `Projects::Create` template pack):
  1. **Codebase Explorer** (`builder`, role `code`) → `discovery_notes` — "Explore"
  2. **Requirements Writer** (`builder`) → `business_requirements`
  3. **Clarifying Questions Writer** (`builder`, role `requirements`, *conditional*)
     → `open_questions` artifact — "Clarifying questions"
  4. **Requirements Completeness Critic** (`critic`) → routes `needs_work` back to
     Requirements Writer
- Steps are linear (`depends_on` edges wired by `Steps::AddToWorkflow`); the
  critic's `route_to` points at the first builder.
- Define starts `running` immediately on pipeline creation (`Pipelines::Create#start`)
  — it is the interactive "pre-phase". `gate_mode: human` (`Pipelines::Create::GATE_MODES`).
- **Initial dispatch of the whole phase is nothing more than `phase.update!(status:
  "running")`.** There is no synchronous "run every step now" call anywhere in the
  codebase. Step 1 (Codebase Explorer) becomes a `ready` run on the *next* Manager
  tick (`dispatch_ready_steps`); step 2 becomes ready only once step 1's run has
  **succeeded and merged**, on a *later* tick; and so on. The whole phase walks its
  DAG one tick (~10s, `config/recurring.yml`) at a time, entirely driven by
  `@phase.running?` staying true. This is the only existing precedent for
  "(re)start a multi-step workflow from the beginning" — see F2 facts below.

### The Manager loop (the engine that would need to "pause")
- `Phases::ManagerTick` (`app/services/phases/manager_tick.rb`) is the
  deterministic core. **It only acts when `@phase.running?`** — first line:
  `return Result.failure(:not_running) unless @phase.running?`.
- `Phases::TickAll` ticks every `running` phase; scheduled every 10s via
  `config/recurring.yml` (`Phases::ManagerTickJob`). Also `StepRuns::SweepJob`
  every 30s.
- Tick does: **dispatch** ready runs along `depends_on`; **route** critic
  `needs_work` feedback to a re-run; **converge** → `consensus` → gate
  (`apply_gate`: auto → advance, human → pipeline `awaiting_human`); **escalate**
  on `max_iterations` → phase+pipeline `awaiting_human`.

### State machines
- **`Phase.status`**: `pending, running, consensus, approved, reworking,`
  **`awaiting_human`** `, failed`. No `paused` state.
- **`Pipeline.status`**: `draft, running, awaiting_human, blocked, stuck,`
  `completed, aborted`. No `paused` state.
- **`StepRun.state`**: `ready, claimed, running, succeeded, failed, stuck`. Runs
  carry `iteration`, `attempt`, `feedback` (array of `{from, issue, severity}`),
  and `result`/`verdict` JSON. No pause/hold state.

### Human-in-the-loop machinery that already exists (gate-based)
- **`Phases::AnswerQuestions`** (`answer_questions.rb`) — human answers the
  `open_questions` artifact. Creates a fresh run of the **Requirements Writer**
  (the first worker-executed step) with the answers as `human`/`major` feedback;
  re-opens the loop. Guards: `ANSWERABLE_STATUSES = running, consensus,`
  `awaiting_human`; **rejects when `define_busy?`** (`steps.any?(&:active_run?)`,
  i.e. any step with a `ready`/`claimed`/`running` run) → `Result.failure(:busy)`.
  Always targets Requirements Writer, not a chosen step.
- **`Phases::Approve`** (`approve.rb`) — ratifies the gate. **`APPROVABLE_STATUSES
  = %w[consensus awaiting_human]`** — this is a hard precondition, not a
  convention; calling it from any other status (e.g. `running`) returns
  `Result.failure(:not_approvable)`. Optional `context` seeds the next phase's
  entry steps as feedback.
- **`Phases::SendBack`** (`send_back.rb`) — rejects the gate from
  `consensus`/`awaiting_human` (`SENDABLE_STATUSES`), re-queues a run for a
  **caller-chosen `target_step_id`** (any worker-executed step of the phase,
  defaults to the first) with feedback, drops phase+pipeline back to `running`.
  This is the closest existing primitive to "re-run a specific step with
  feedback attached", but it is gate-only.
- **A second, older single-step re-run primitive already exists, independent of
  gate status**: the step card's **"Queue run" / "Re-run" link**
  (`app/views/pipelines/_step_card.html.erb`) → `POST queue_run_step_path` →
  `StepsController#queue_run` → **`StepRuns::Queue`** (`app/services/step_runs/queue.rb`).
  It creates a `ready` run at `step.step_runs.maximum(:iteration) + 1` for *any*
  worker-executed step, guarded only by "no run already `ready/claimed/running`
  for that step" (`active_run?`) — **no phase-status check, no feedback
  attached**. Comment: "Until the Manager loop lands, this is how work gets
  dispatched." Visible on a step card whenever `run.nil?` or
  `run.state.in?(%w[succeeded failed stuck])`.
- **`PhasesController`** exposes `#answers` and `#send_back`; `ApprovalsController`
  handles approve. Routes: `phases/:id` + member `send_back`, `answers`, and
  nested `approval`; `steps/:id` member `queue_run` (`config/routes.rb`).
- **UI**: `app/views/pipelines/_define_panel.html.erb` — full-width panel showing
  status badge, step cards, and (only `at_gate`, i.e. `consensus`/`awaiting_human`
  + human gate) an approve form and an "Open questions" answer form.

### Worker dispatch (pull-based)
- `StepRuns::Claim` — workers poll and atomically claim one `ready` run
  (SKIP LOCKED), mint an `epoch`, set a 60s lease. **There is no gate on claiming
  by phase/pipeline status** — any `ready` run is claimable. So "pausing" cannot
  be achieved by phase status alone unless dispatch stops *creating* ready runs
  (Manager already won't tick a non-`running` phase) or claim/queue is taught to
  respect a pause flag.

---

## Facts sharpening the iteration-2 critic feedback

### F1 — Is a step's fresh output actually shown to a human today?
Two very different answers exist for the two artifact types the ask names:
- **`open_questions` IS surfaced today.** `DefineHelper#define_open_questions`
  (`app/helpers/define_helper.rb`) finds the **latest succeeded run** across all
  of the phase's steps whose `result["artifacts"]["open_questions"]` is present,
  and `_define_panel.html.erb` renders that markdown inline via `simple_format`,
  directly above the "Send answers" form. This only runs when `questions.present?`
  — there's no placeholder/empty state.
- **`discovery_notes` (and every other artifact) is NOT surfaced anywhere in the
  UI today.** The step card (`_step_card.html.erb`) shows only: step slug, a
  status badge, step type, role, iteration badge, a live `progress["message"]`
  while running, the claiming worker's name, and (for `succeeded/failed/stuck`)
  a "Re-run" link. It never reads `run.result["artifacts"]`. There is no step
  detail/show page found (`PhasesController`/`ApprovalsController`/`StepsController`
  have no `show` action rendering artifact content; `phase_path(phase)` linked
  from the panel was not found to render artifact bodies either — it points at
  the same board/phase view).
- So: the existing `open_questions` rendering pattern (helper pulls latest
  succeeded run's named artifact from `result["artifacts"]`, template renders it
  inline) is a **reusable precedent** for surfacing `discovery_notes` and any
  "repeat from the beginning" output, but that surfacing does not exist yet for
  anything other than `open_questions` and would need to be built.

### F2 — Can "Repeat from the Beginning" be a single atomic action?
No — restarting the phase's DAG is inherently **multi-tick, not a single
synchronous operation**, by the same mechanism that starts Define in the first
place (`Pipelines::Create#start`, see above). Concretely:
- `dispatch_ready_steps` only creates a `ready` run for a step once **all of its
  worker predecessors have succeeded *and* merged** (`p.latest_run.merged?`) —
  merging happens asynchronously via `Pipelines::MergeStepBranchJob` after a
  worker pushes. So even "re-run just the first step and let the DAG cascade"
  necessarily spans: worker claims → executes → pushes → `Complete` records
  `succeeded` → `MergeStepBranchJob` merges → **next** Manager tick (up to ~10s
  later) notices the merge and dispatches step 2 → repeat for step 3, step 4.
- This cascade only progresses while `@phase.running?` is true (the tick's first
  guard). A "paused" status, if it is a status the Manager tick doesn't recognize
  as running, would **stop the cascade after the first re-dispatched step** unless
  something explicitly flips the phase back to `running` for the duration of the
  restart and back to paused afterward — which is exactly the ambiguity the critic
  flagged. There is no existing "run this whole workflow and block until it
  converges" primitive to model "repeat from the beginning" on; the closest
  analogue (initial phase start) is fire-and-forget across many ticks, not a
  bounded synchronous action.

### F3 — What happens today when a re-run fails, and is the actor told?
- **Ordinary failure**: `StepRuns::Complete` sets `state: "failed"` with whatever
  `result` the worker reported (often `result["summary"]`). Surfaced only via the
  step card's `status_badge(run.state)` → red "Failed" pill
  (`STATUS_TONES["failed"] => :danger`, `app/helpers/status_helper.rb` — tone is
  always paired with the text label, per the guide's "not color alone" rule).
  No toast, banner, or panel-level notification fires; a viewer has to notice the
  badge changed.
- **Transient failure (retryable infra outage)**: `StepRuns::Complete#requeue_transient`
  re-queues the run (`state: "ready"`) with exponential backoff
  (`TRANSIENT_BACKOFF_STEP`/`_CAP`, up to `MAX_TRANSIENT_ATTEMPTS = 8`), storing a
  human-readable reason in `result["summary"]`. Only after all 8 attempts does it
  become a true `failed` state. During backoff the step just looks `ready`/idle
  again on the badge — nothing distinguishes "waiting to retry after an outage"
  from "queued, not yet claimed."
- **Merge-time failure** (scope violation / merge conflict, discovered *after* the
  worker reported success): `Pipelines::MergeStepBranch#fail_run` flips a
  `succeeded` run to `state: "failed"` and records `merge_error` (not surfaced in
  any view found — no template reads `merge_error`).
- **Lease expiry / stuck**: `StepRuns::Sweep` (every 30s) reclaims runs whose
  lease expired back to `ready` with `attempt + 1` (silent retry, same badge
  behavior as transient), and separately flags `ready` runs whose `required_role`
  has no online worker as `stuck` (red badge) after a 90s grace period.
- **No existing action treats "the re-run failed" as a distinct branch.** Every
  current human-triggered re-run path (`StepRuns::Queue`, `SendBack`,
  `AnswerQuestions`) fires-and-forgets a new `ready` run and returns immediately
  on success of *creating* the run — none of them wait for or react to that run's
  eventual `succeeded`/`failed` outcome. Whatever ends up watching a menu-triggered
  re-run to decide "show fresh output" vs. "show a failure and return to the menu"
  (per F1/F3) would be new: either a broadcast-driven UI update keyed off the
  run's state, or a poll.

### F4 — Is "Done" (Approve) reachable from a mid-loop pause?
Confirmed precondition: `Phases::Approve::APPROVABLE_STATUSES = %w[consensus
awaiting_human]` is enforced in code (`unless @phase.status.in?(APPROVABLE_STATUSES)
→ Result.failure(:not_approvable)`), not just documented as a convention. Only
those two phase statuses are valid.
- If a "paused mid-loop" state is implemented as a **new status** (e.g. `paused`)
  distinct from `consensus`/`awaiting_human`, then **Approve as it exists today
  would reject "Done" from that state** — R14 as currently written ("Done ...
  treat that as the existing approval") would need either (a) `Approve` extended
  to accept the new paused status too, or (b) Done from an un-converged pause to
  be defined as a *different* action than the existing gate approval (e.g. "force
  a convergence check first" or "approve un-converged work" with different
  semantics/warnings than approving a settled consensus).
  Note related risk: `Approve#seed_next_phase` seeds the *next* phase's entry
  steps as if this phase's output is final — approving un-converged Define work
  would carry forward whatever the latest (possibly still-being-revised)
  artifacts are, with no distinct warning path today.
- If pause instead **reuses `awaiting_human`** (already one of the two approvable
  statuses), Done/Approve "just works" via the existing code path with zero
  changes — but conflates two meanings of `awaiting_human` (cap-escalation vs.
  voluntary human pause), which is exactly the ambiguity flagged as an open
  question in iteration 1 (see below).

### F5 — atomicity of R13/R23 (no new code facts)
This is purely a requirements-drafting concern (splitting compound "when X,
Y-and-Z" statements into independently testable requirements); it does not
depend on additional system behavior beyond what's already documented above for
R12/R13 (F2) and R14/R23 (F4, plus the existing, still-accurate `Approve`/
`SendBack`/`AnswerQuestions` behavior described above).

---

## What the ask touches

- **New "pause" concept** — no `paused` status exists on Phase or Pipeline, and
  no field/flag to represent "held for human input mid-loop". A pause that stops
  the Manager can lean on the existing `unless @phase.running?` guard (park the
  phase in a non-running status), but that status must be **resumable** back to
  `running` (like `SendBack` does) and must be reachable **on demand**, not only
  at consensus/cap. See F4 above for the concrete conflict this creates with
  `Approve`'s hard-coded `APPROVABLE_STATUSES`.
- **On-demand trigger** — today humans can only act at the *settled* gate
  (`consensus`/`awaiting_human`). Nothing lets a human interrupt while the loop is
  `running`/mid-iteration. `AnswerQuestions` actively refuses when `define_busy?`.
- **The menu loop** — no notion of a repeatable human choice among sub-actions.
  The four menu items map onto existing pieces but none is exposed as a menu:
  - *Explore* → re-run **Codebase Explorer** step. Two existing partial
    precedents: `StepRuns::Queue` (any status, no feedback) and `SendBack`
    (gate-only, but threads feedback and a chosen `target_step_id`). Neither
    fully fits "re-run this specific step, with feedback, while paused mid-loop."
  - *Clarifying questions* → re-run **Clarifying Questions Writer** (same gap).
  - *Ask human* → surface `open_questions` + collect answers (like
    `AnswerQuestions`, but that only re-runs Requirements Writer, and its
    `define_busy?` guard would need to be compatible with "paused").
  - *Repeat from the beginning* → re-dispatch Define from the first step; see F2
    — this is inherently multi-tick, not a single primitive.
  - *Done* → the existing `Approve` path — see F4 for its status precondition.
- **Surfacing fresh output** — see F1: `discovery_notes` (and any artifact besides
  `open_questions`) has no existing rendering path in the UI; would need new
  helper + template work modeled on `DefineHelper#define_open_questions`.
- **Failure/timeout visibility during a menu-triggered re-run** — see F3: today,
  failure is a badge-only signal with no dedicated "did my re-run work" flow;
  every existing re-run action is fire-and-forget.
- **Controller/routes/UI** — `PhasesController`, `config/routes.rb`, and
  `_define_panel.html.erb` would gain pause/resume + menu affordances. The panel
  currently only renders the answer/approve forms `at_gate`.
- **Concurrency with the Manager** — any pause action races the 10s tick. Existing
  code handles this with `define_busy?` guards, `active_run?` checks, and
  `ActiveRecord::RecordNotUnique` rescues; a pause must interoperate with these.

---

## Constraints

- **Guides are mandatory** (`CLAUDE.md`, `guides/`):
  - Business logic in POROs with uniform `.call` → `Result` (see
    `app/services/result.rb`); controllers thin (auth + params + one service +
    respond); **no business logic in callbacks/jobs**; broadcasts from services
    **after commit**; Minitest.
  - UI: Tailwind with the defined type/spacing scale + semantic status colors;
    shared components (StatusBadge etc.); Turbo Streams target the **smallest DOM
    unit**; **status never by color alone** (verified in `status_helper.rb` —
    label text is always rendered alongside the tone).
- **Define stays non-technical** (`execution-model.md`) — enforced by step system
  prompts; a pause/menu shouldn't introduce technical leakage.
- **Fixed-four-phase invariant** — Define is never skipped; a pause changes *how*
  Define runs, not the phase set.
- **At-least-once execution / at-most-one merge** (M10) — runs are fenced by
  `epoch`/lease; a paused-then-resumed step must not double-merge. Re-runs create
  new runs at a higher `iteration` (the established pattern).
- **60s leases** — an already-`claimed`/`running` step can't be truly frozen; a
  "pause" realistically means "stop dispatching / creating new ready runs and wait
  for a human", not interrupting an in-flight worker mid-execution. In-flight work
  finishes or leases expire and get swept (`StepRuns::Sweep`).
- **Existing gate semantics must not regress** — `Approve`/`SendBack`/
  `AnswerQuestions` and their `consensus`/`awaiting_human` triggers should keep
  working; a new pause path is additive.

---

## Open questions (for Requirements/Design)

1. **Scope of "anytime"** — is pause a single "hold at the next safe point" (after
   the current run settles, since leases can't be frozen), or must it also cover a
   pipeline that is `pending`/`draft`? Does "pause" freeze *dispatch only*, or also
   block worker *claims* of already-`ready` runs?
2. **Where does pause live** — a new `Phase.status` (e.g. `paused`), a boolean
   flag on Phase/Pipeline, or reuse of `awaiting_human`? Reusing `awaiting_human`
   conflates "cap hit" with "human paused on purpose" and (per F4) happens to make
   `Approve` work for free; a distinct state reads clearer in the UI but requires
   extending `Approve`'s `APPROVABLE_STATUSES` (and possibly `SendBack`'s
   `SENDABLE_STATUSES`) to include it.
3. **The menu's exact items & their effects** — confirm the mapping: Explore =
   re-run Codebase Explorer; Clarifying = re-run Clarifying Questions Writer; Ask
   human = surface questions + capture answers as feedback; Repeat from beginning =
   re-dispatch from the first step. Given F2, does "Repeat from the Beginning"
   mean "kick off step 1 and let it cascade over several ticks while the person
   waits/watches," and does the phase stay paused (blocking the cascade after
   step 1) or does it need to go briefly `running` again for the whole restart?
4. **"Ask human" direction** — does the human *pose* questions to be answered
   later, *answer* the agent's `open_questions`, or both? Today only the latter
   exists (`AnswerQuestions`).
5. **Targeted re-run primitive** — should re-running a specific step generalize
   `SendBack`'s `target_step_id` (gate-only today) or `StepRuns::Queue` (any
   status, but no feedback threading), to work while paused with feedback
   attached?
6. **"Until done" exit** — is "done" exactly the existing `Approve` (ratify the
   human gate — only valid from `consensus`/`awaiting_human` per F4), or a
   separate "end Define" action for a still-un-converged pause?
7. **Interaction with the tick** — when paused, should `TickAll` skip the phase
   (natural if paused ⇒ not `running`), and how do we prevent a resume from racing
   the next scheduled tick? What happens to a run that is mid-flight when pause is
   requested — let it finish (recommended, given leases) or mark it for discard?
8. **Auto-vs-manual coexistence** — does pause suspend the automatic consensus
   loop entirely until resumed, or can the human step through iterations manually
   from the menu while auto-ticking is off?
9. **Surfacing fresh output (F1)** — for each menu action that produces new
   content (Explore's `discovery_notes`, Clarifying Questions' `open_questions`,
   Repeat-from-Beginning's replaced artifacts), is the person shown the content
   inline in the paused panel (extending the `define_open_questions` pattern), or
   linked to a separate view? Should stale/prior content stay visible while a
   re-run is in flight, or be cleared/marked-stale immediately?
10. **Failure visibility for menu re-runs (F3)** — when a menu-triggered re-run
    ends in `failed`/`stuck`, or is mid-retry (transient backoff), what does the
    paused view show, and does the person automatically land back on the menu, or
    do they have to notice the badge and act? Should the phase remain paused
    (rather than silently retrying) whenever a menu-triggered run fails?

---

## Relevant files (map for downstream steps)

- Manager/loop: `app/services/phases/manager_tick.rb`, `tick_all.rb`,
  `advance.rb`, `config/recurring.yml`
- Existing HITL: `app/services/phases/answer_questions.rb`, `approve.rb`,
  `send_back.rb`; `app/controllers/phases_controller.rb`,
  `app/controllers/approvals_controller.rb`; `config/routes.rb`
- Existing single-step re-run (non-gate): `app/services/step_runs/queue.rb`,
  `app/controllers/steps_controller.rb#queue_run`
- Run completion / failure paths: `app/services/step_runs/complete.rb`,
  `app/services/step_runs/sweep.rb`, `app/services/pipelines/merge_step_branch.rb`
- Composition/steps: `app/services/pipelines/create.rb`,
  `app/services/steps/add_to_workflow.rb`, `db/seeds.rb`,
  `app/services/projects/create.rb`
- Models/state: `app/models/phase.rb`, `pipeline.rb`, `step_run.rb`, `step.rb`
- Dispatch: `app/services/step_runs/claim.rb`, `queue.rb`, `sweep.rb`
- UI: `app/views/pipelines/_define_panel.html.erb`, `_phase_column.html.erb`,
  `_step_card.html.erb`, `pipelines/show.html.erb`;
  `app/helpers/define_helper.rb`, `app/helpers/status_helper.rb`;
  `app/services/phases/broadcast_column.rb`
- Design docs: `docs/execution-model.md` (Gates & HITL, Convergence caps),
  `docs/phase-playbooks.md` (Phase 1 worked example), `docs/README.md`
