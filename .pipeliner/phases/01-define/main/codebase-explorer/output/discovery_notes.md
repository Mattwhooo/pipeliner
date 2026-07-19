# Discovery Notes — Human-in-the-Loop Pause (Define phase)

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
  (`define_specs`, and `db/seeds.rb` / `Projects::Create` template pack):
  1. **Codebase Explorer** (`builder`, role `code`) → `discovery_notes` — "Explore"
  2. **Requirements Writer** (`builder`) → `business_requirements`
  3. **Clarifying Questions Writer** (`builder`, role `requirements`, *conditional*)
     → `open_questions` artifact — "Clarifying questions"
  4. **Requirements Completeness Critic** (`critic`) → routes `needs_work` back to
     Requirements Writer
- Steps are linear (`depends_on` edges wired by `Steps::AddToWorkflow`); the
  critic's `route_to` points at the first builder.
- Define starts `running` immediately on pipeline creation (`start`,
  `Pipelines::Create`) — it is the interactive "pre-phase". `gate_mode: human`
  (`GATE_MODES`).

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
  `awaiting_human`; **rejects when `define_busy?`** (any active run) → error
  `:busy`. Always targets Requirements Writer, not a chosen step.
- **`Phases::Approve`** — ratifies the gate from `consensus`/`awaiting_human`;
  optional `context` seeds the next phase's entry steps as feedback.
- **`Phases::SendBack`** — rejects the gate from `consensus`/`awaiting_human`,
  re-queues a run for a **caller-chosen `target_step_id`** (any worker-executed
  step of the phase) with feedback, drops phase+pipeline back to `running`. This
  is the closest existing primitive to "re-run a specific step".
- **`PhasesController`** exposes `#answers` and `#send_back`; `ApprovalsController`
  handles approve. Routes: `phases/:id` + member `send_back`, `answers`, and
  nested `approval` (`config/routes.rb`).
- **UI**: `app/views/pipelines/_define_panel.html.erb` — full-width panel showing
  status badge, step cards, and (only `at_gate`, i.e. `consensus`/`awaiting_human`
  + human gate) an approve form and an "Open questions" answer form. Questions are
  surfaced by `DefineHelper#define_open_questions` from the latest succeeded run's
  `open_questions` artifact. Broadcast target: `dom_id(phase, :column)` via
  `Phases::BroadcastColumn`.

### Worker dispatch (pull-based)
- `StepRuns::Claim` — workers poll and atomically claim one `ready` run
  (SKIP LOCKED), mint an `epoch`, set a 60s lease. **There is no gate on claiming
  by phase/pipeline status** — any `ready` run is claimable. So "pausing" cannot
  be achieved by phase status alone unless dispatch stops *creating* ready runs
  (Manager already won't tick a non-`running` phase) or claim/queue is taught to
  respect a pause flag.

---

## What the ask touches

- **New "pause" concept** — no `paused` status exists on Phase or Pipeline, and
  no field/flag to represent "held for human input mid-loop". A pause that stops
  the Manager can lean on the existing `unless @phase.running?` guard (park the
  phase in a non-running status), but that status must be **resumable** back to
  `running` (like `SendBack` does) and must be reachable **on demand**, not only
  at consensus/cap.
- **On-demand trigger** — today humans can only act at the *settled* gate
  (`consensus`/`awaiting_human`). Nothing lets a human interrupt while the loop is
  `running`/mid-iteration. `AnswerQuestions` actively refuses when `define_busy?`.
- **The menu loop** — no notion of a repeatable human choice among sub-actions.
  The four menu items map onto existing pieces but none is exposed as a menu:
  - *Explore* → re-run **Codebase Explorer** step (no targeted re-run exists;
    `SendBack` can target an arbitrary step but only from a gate status).
  - *Clarifying questions* → re-run **Clarifying Questions Writer** (same gap).
  - *Ask human* → surface `open_questions` + collect answers (like
    `AnswerQuestions`, but that only re-runs Requirements Writer).
  - *Repeat from the beginning* → re-dispatch Define from the first step; no
    "restart workflow" primitive today.
  - *Done* → the existing `Approve` path (ratify the human gate).
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
    unit**; **status never by color alone**.
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
   conflates "cap hit" with "human paused on purpose"; a distinct state reads
   clearer in the UI (status-not-by-color rule) but is more surface area.
3. **The menu's exact items & their effects** — confirm the mapping: Explore =
   re-run Codebase Explorer; Clarifying = re-run Clarifying Questions Writer; Ask
   human = surface questions + capture answers as feedback; Repeat from beginning =
   re-dispatch from the first step. Is "Repeat from the beginning" a fresh
   iteration of the whole Define workflow, and does it discard or layer on prior
   artifacts (docs say **latest-content-only**, no per-iteration snapshots)?
4. **"Ask human" direction** — does the human *pose* questions to be answered
   later, *answer* the agent's `open_questions`, or both? Today only the latter
   exists (`AnswerQuestions`).
5. **Targeted re-run primitive** — should re-running a specific step generalize
   `SendBack`'s `target_step_id` (which is gate-only today) to work while paused,
   rather than always hitting the Requirements Writer like `AnswerQuestions`?
6. **"Until done" exit** — is "done" exactly the existing `Approve` (ratify the
   human gate), or a separate "end Define" action distinct from convergence?
7. **Interaction with the tick** — when paused, should `TickAll` skip the phase
   (natural if paused ⇒ not `running`), and how do we prevent a resume from racing
   the next scheduled tick? What happens to a run that is mid-flight when pause is
   requested — let it finish (recommended, given leases) or mark it for discard?
8. **Auto-vs-manual coexistence** — does pause suspend the automatic consensus
   loop entirely until resumed, or can the human step through iterations manually
   from the menu while auto-ticking is off?

---

## Relevant files (map for downstream steps)

- Manager/loop: `app/services/phases/manager_tick.rb`, `tick_all.rb`,
  `advance.rb`, `config/recurring.yml`
- Existing HITL: `app/services/phases/answer_questions.rb`, `approve.rb`,
  `send_back.rb`; `app/controllers/phases_controller.rb`,
  `app/controllers/approvals_controller.rb`; `config/routes.rb`
- Composition/steps: `app/services/pipelines/create.rb`,
  `app/services/steps/add_to_workflow.rb`, `db/seeds.rb`,
  `app/services/projects/create.rb`
- Models/state: `app/models/phase.rb`, `pipeline.rb`, `step_run.rb`, `step.rb`
- Dispatch: `app/services/step_runs/claim.rb`, `queue.rb`, `sweep.rb`
- UI: `app/views/pipelines/_define_panel.html.erb`, `_phase_column.html.erb`,
  `_step_card.html.erb`, `pipelines/show.html.erb`;
  `app/helpers/define_helper.rb`; `app/services/phases/broadcast_column.rb`
- Design docs: `docs/execution-model.md` (Gates & HITL, Convergence caps),
  `docs/phase-playbooks.md` (Phase 1 worked example), `docs/README.md`
