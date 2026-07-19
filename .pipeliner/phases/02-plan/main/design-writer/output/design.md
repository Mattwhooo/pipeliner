# Technical Design — Human-in-the-Loop Pause (Define phase)

Grounded in `.pipeliner/phases/01-define/main/requirements-writer/output/requirements.md`
(R1–R34) and `.pipeliner/phases/01-define/main/codebase-explorer/output/discovery_notes.md`.
Every design element below cites the requirement(s) it satisfies.

## 1. Overview

Today the Define phase only stops for a human at its **settled gate**
(`consensus`/`awaiting_human`, ratified by `Phases::Approve`/`SendBack`/
`AnswerQuestions`). This feature adds a second, independent stopping point: a
human can **pause Define at any point while it's running**, and while paused,
work through a **menu loop** — Explore, Clarifying Questions, Ask Human, Repeat
from the Beginning, Done — as many times as needed before finishing.

The design's central move is to make `paused` a **new `Phase.status`** that the
Manager tick already refuses to act on (`return … unless @phase.running?`), and
to model **every menu action as creating ordinary `StepRun`s** the existing
Worker/Claim/Complete/Merge pipeline already knows how to execute — so almost
nothing about *how work runs* changes; only *when the Manager is allowed to keep
going on its own* changes.

Two small booleans on `Phase` carry the two states that don't fit "instantly
paused or not":

- **`pause_requested`** — pause was asked for while a step was still in flight;
  hold until it settles (R3).
- **`restart_in_progress`** — "Repeat from the Beginning" is cascading through
  several steps over several ticks (discovery notes F2); the phase is
  temporarily `running` again so the *existing* dispatch/route/converge engine
  does the cascading, but its exit is redirected back to `paused` instead of the
  normal gate.

No new state machine is invented for the restart cascade — it reuses
`Phases::ManagerTick` verbatim, which is both the smallest change and the only
way to get correct DAG-ordered re-dispatch (predecessor-must-be-merged, one
`ready` run per step) for free.

## 2. Key decisions

1. **`paused` is a new `Phase.status` value**, not a reuse of `awaiting_human`.
   Reusing `awaiting_human` would make `Approve` work with zero changes (per
   discovery-notes F4), but it would conflate "cap escalation" with "human
   paused on purpose" in the UI and in every place that branches on phase
   status. A distinct status reads clearly (R4) at the cost of two small,
   additive extensions: `Phases::ManagerTick`'s top guard already excludes it
   for free (`unless @phase.running?`); `Phases::Approve` and
   `Phases::AnswerQuestions` each gain `paused` in their allow-list (§4.4, §4.6).

2. **"Resume" is not a control (R5, and iteration-3 discovery F1).** There is no
   code path anywhere today that hands a held phase back to fully-automatic
   running with no attached action, and this design doesn't invent one. The
   *only* two ways out of `paused` are: trigger a menu item (creates a run,
   phase stays `paused`), or **Done** (`Phases::Approve`, extended — see below).

3. **"Done" reuses `Phases::Approve`**, extended to accept `paused` *only when
   the phase is actually settled*, checked **live** at click-time rather than
   trusted from cached status — because a paused phase's `workflows[].status`
   is never refreshed by a background tick (paused phases aren't ticked). A new
   read-only query object, `Phases::Convergence`, is the single source of truth
   for "is this phase settled," shared by `ManagerTick` (which already computes
   this) and `Approve` (which now needs to ask the same question on demand).
   Per `guides/backend-guide.md` "Query objects," it lives in `app/queries/`,
   not `app/services/` — it has no `.call`/`Result` interface because it isn't
   a business action, just a predicate read. This satisfies R20/R21 without
   duplicating the consensus rule.

4. **Explore and Clarifying Questions are identified by the artifact they
   produce (`discovery_notes`, `open_questions`), not by step slug or name.**
   `Pipelines::Create` composes Define from a project's `pipeline_template`
   (`app/services/pipelines/create.rb:94-123`), so step slugs are
   `template.name.parameterize` and are **not guaranteed stable across
   projects** — only the artifact each step is declared to write
   (`Step#outputs`, already a first-class jsonb column) is stable, per
   `docs/artifact-schema.md`. Menu actions resolve their target step by
   scanning `step.outputs` for the artifact name.

5. **"Repeat from the Beginning" reuses `Phases::ManagerTick`'s normal
   dispatch/route/converge cascade** rather than a bespoke "run all these steps
   and wait" primitive (which discovery-notes F2 confirms doesn't exist
   anywhere). The phase flips to `running` for the duration
   (`restart_in_progress: true`), and `ManagerTick` is taught two small branch
   points: land on `paused` (not the gate) when the restart converges, and fall
   back to `paused` (not silently stall) if a restart step fails — see §4.7.

6. **Everything is additive.** No existing status, allow-list entry, or
   behavior is removed; `paused` and its two booleans are *new* values a phase
   can be in, and every existing gate path (`consensus`/`awaiting_human` via
   `Approve`/`SendBack`/`AnswerQuestions`) is untouched for those statuses
   (R32–R34).

7. **Scoped to Define, structured to generalize (open question 15 /
   requirements' final assumption).** Nothing in `Phases::Pause`,
   `Phases::RerunMenuStep`, `Phases::RestartDefine`, or `ManagerTick`'s new
   branches references `define_phase?`. The feature is exposed to Define only
   because only `_define_panel.html.erb` renders the pause control and menu.
   Extending to another phase later is a view + routing change, not a service
   rewrite.

8. **`business_requirements` gets the same net-new inline surfacing as
   `discovery_notes` (iteration-3 F1).** R19 requires a completed restart's
   "fresh, replaced results" to be visible before the person picks their next
   action, and a restart regenerates all three Define artifacts, not just the
   two this design previously surfaced. Since `business_requirements` (Define's
   headline deliverable) is rendered nowhere in the UI today, this design adds
   a third `define_*` helper and inline block, identical in shape to the
   existing `open_questions` pattern (§6.2, §6.3) — no new mechanism, just the
   established one applied to the artifact R19 actually depends on.

9. **The "Ask Human" anchor renders even with no open questions (iteration-3
   F2).** `Phases::AnswerQuestions` has never required `open_questions` to
   exist — it just attaches whatever free-text it's given as feedback — so a
   paused Define with no questions yet (e.g. paused right after Explore) can
   already be answered by the service; the gap was purely that the view's
   anchor target only rendered when `questions.present?`. The fix widens that
   one condition to `questions.present? || phase.paused?` (§6.3) with an
   empty-state message and relabeled field, rather than adding a new action or
   service.

## 3. Data model

### 3.1 Migration

New file `db/migrate/<timestamp>_add_pause_support_to_phases.rb` (next
available timestamp after `20260718230011_create_pipeline_templates.rb`):

```ruby
class AddPauseSupportToPhases < ActiveRecord::Migration[8.0]
  def change
    add_column :phases, :pause_requested, :boolean, default: false, null: false
    add_column :phases, :pause_requested_at, :datetime
    add_column :phases, :restart_in_progress, :boolean, default: false, null: false
    add_column :phases, :restart_feedback, :jsonb, default: [], null: false
  end
end
```

`phases.status` stays a plain `string` column (no DB check constraint exists
today — confirmed in `db/schema.rb`), so adding the `"paused"` value is a
**model-only** change, no migration needed for it.

### 3.2 `app/models/phase.rb`

```ruby
enum :status, {
  pending: "pending",
  running: "running",
  paused: "paused",           # NEW — human-requested hold mid-loop (R2–R6)
  consensus: "consensus",
  approved: "approved",
  reworking: "reworking",
  awaiting_human: "awaiting_human",
  failed: "failed"
}
```

Add one small shared predicate, used by `Pause`, `RerunMenuStep`,
`RestartDefine`, and reusable by any future phase (§2.7):

```ruby
# Any worker-executed step of this phase already has a live run (ready/
# claimed/running) — used to gate pause/menu actions so a manual trigger never
# overlaps the Manager's own dispatch or a previous menu action (R29, R30).
def any_step_active?
  workflows.flat_map(&:steps).any?(&:active_run?)
end
```

`AnswerQuestions#define_busy?` (identical logic, pre-existing) is left as-is —
unifying it with `any_step_active?` is a safe follow-up refactor, not required
by this feature, and out of scope to avoid touching tested behavior
incidentally.

## 4. Service layer

### 4.1 `Phases::Convergence` (new — `app/queries/phases/convergence.rb`)

Extracted from `ManagerTick`'s existing `workflow_converged?`/
`consensus_reached?` so the *same* rule is usable both by the tick (which also
needs to mark each workflow `"converged"`) and by `Approve` (which only needs
the boolean, computed fresh, with no side effects). This is a **query object**,
not a service (`guides/backend-guide.md` "Query objects" vs. "Services") — it
is a read-only, noun-named predicate with no `.call`/`Result` interface, so it
lives in `app/queries/`, alongside domain reads like `StepRuns::ClaimableFor`,
rather than being conflated with the verb-first, `Result`-returning business
actions in `app/services/`:

```ruby
module Phases
  # Read-only: is a phase's work settled? Same rule ManagerTick uses to declare
  # consensus (all worker steps succeeded+merged, every critic pass/n_a) — but
  # callable on demand with no side effects, so Approve can ask it live for a
  # phase that isn't being ticked (paused phases aren't) — R20/R21.
  class Convergence
    RESOLVED_VERDICTS = %w[pass not_applicable].freeze

    def self.phase_settled?(phase)
      workflows = phase.workflows.to_a
      workflows.present? && workflows.all? { |w| workflow_converged?(w) }
    end

    def self.workflow_converged?(workflow)
      worker_steps = workflow.steps.select(&:worker_executed?)
      return false if worker_steps.empty?
      return false unless worker_steps.all? { |s| s.latest_run&.succeeded? && s.latest_run.merged? }

      worker_steps.select(&:type_critic?).all? do |critic|
        RESOLVED_VERDICTS.include?(critic.latest_run.verdict_status)
      end
    end
  end
end
```

`ManagerTick#workflow_converged?`/`#consensus_reached?` are deleted; every call
site becomes `Convergence.workflow_converged?(workflow)`. Behavior is
byte-for-byte identical — existing `manager_tick_test.rb` coverage should pass
unchanged.

### 4.2 `Phases::Pause` (new — `app/services/phases/pause.rb`)

```ruby
module Phases
  # A human asks Define to hold (R1–R4). If a step is already in flight, we
  # can't freeze it (60s leases — docs/execution-model.md constraints), so we
  # only flag the request; ManagerTick settles it into `paused` once idle
  # (R3). If nothing is in flight, pause takes effect immediately.
  class Pause
    PAUSABLE_STATUSES = %w[running].freeze

    def self.call(phase:, user:)
      new(phase:, user:).call
    end

    def initialize(phase:, user:)
      @phase = phase
      @user = user
    end

    def call
      return Result.failure(:not_pausable, record: @phase) unless @phase.status.in?(PAUSABLE_STATUSES)
      return Result.success(@phase) if @phase.pause_requested? # idempotent re-click

      if @phase.any_step_active?
        @phase.update!(pause_requested: true, pause_requested_at: Time.current)
      else
        @phase.update!(status: "paused", pause_requested: false, pause_requested_at: nil)
      end

      BroadcastColumn.call(@phase)
      Result.success(@phase)
    end
  end
end
```

`user:` isn't persisted anywhere yet (no `Approval` row — pause isn't a gate
decision); it's accepted for parity with the other Phase services and in case
an audit trail is wanted later.

### 4.3 `Phases::RerunMenuStep` (new — `app/services/phases/rerun_menu_step.rb`)

Handles both **Explore** (R8, R9) and **Clarifying Questions** (R10, R11) —
same shape, different target artifact:

```ruby
module Phases
  # A single-step re-run triggered from the paused menu. The target step is
  # resolved by the artifact it's declared to write (Step#outputs), not by
  # slug/name — a project's pipeline_template can rename or reorder Define's
  # steps (app/services/pipelines/create.rb), so only artifact identity is a
  # stable contract (docs/artifact-schema.md).
  class RerunMenuStep
    ARTIFACTS = %w[discovery_notes open_questions].freeze

    def self.call(phase:, artifact:)
      new(phase:, artifact:).call
    end

    def initialize(phase:, artifact:)
      @phase = phase
      @artifact = artifact.to_s
    end

    def call
      return Result.failure(:invalid_artifact) unless @artifact.in?(ARTIFACTS)
      return Result.failure(:not_paused, record: @phase) unless @phase.paused?
      return Result.failure(:busy, record: @phase) if @phase.any_step_active?

      step = target_step
      return Result.failure(:no_target, record: @phase) if step.nil?

      run = step.step_runs.create!(
        state: "ready",
        iteration: (step.step_runs.maximum(:iteration) || 0) + 1,
        required_role: step.role
      )

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Result.success(run)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(:invalid, record: e.record)
    end

    private

    def target_step
      @phase.workflows.flat_map(&:steps)
        .find { |s| s.worker_executed? && Array(s.outputs).include?(@artifact) }
    end
  end
end
```

Because `@phase.status` is never touched here, the phase is simply still
`"paused"` for the whole lifetime of this run and after it completes — R22/R23
("return to the paused menu," "phase remains paused") fall out of the design
for free, with no explicit "return to menu" step needed anywhere.

Deliberately **no feedback is attached** to this run: neither R8 nor R10 asks
for it, and neither step's declared `inputs` include human feedback (only
`Requirements Writer` does, which is `Ask Human`'s target — §4.4).

### 4.4 `Phases::AnswerQuestions` — extended (`app/services/phases/answer_questions.rb`)

**Ask Human** (R13, R14) reuses this service exactly as it exists today — it
already does precisely what R13/R14 ask (surface `open_questions`, capture
free-form answers, attach them as `{"from" => "human", ...}` feedback on a
fresh Requirements Writer run). The only change is widening the allow-list by
one value:

```ruby
ANSWERABLE_STATUSES = %w[running consensus awaiting_human paused].freeze
```

`define_busy?` (`steps.any?(&:active_run?)`) already guards against overlap
(R30); `reopen_iteration` only fires `if @phase.consensus?`, so when
`@phase.paused?` it's simply skipped — the phase stays `paused` after
answering with **no other code change**, satisfying R22/R23 for this action
too. R34 ("existing way of answering… at the normal settled gate keeps working
unchanged") holds because `running`/`consensus`/`awaiting_human` behavior is
untouched.

### 4.5 `Phases::RestartDefine` (new — `app/services/phases/restart_define.rb`)

**Repeat from the Beginning** (R15–R19):

```ruby
module Phases
  # Restarts Define from its first worker-executed step (R15). Deliberately
  # reuses ManagerTick's ordinary dispatch/route/converge cascade instead of a
  # bespoke "run N steps and wait" primitive — none exists (see design §2.5) —
  # by flipping the phase back to `running` for the cascade's duration.
  # `restart_in_progress` tells ManagerTick to land back on `paused` instead of
  # the normal gate when it converges (R19), and to bail back to `paused`
  # instead of stalling forever if a restart step fails (R25).
  class RestartDefine
    def self.call(phase:, user:)
      new(phase:, user:).call
    end

    def initialize(phase:, user:)
      @phase = phase
      @user = user
    end

    def call
      return Result.failure(:not_paused, record: @phase) unless @phase.paused?
      return Result.failure(:busy, record: @phase) if @phase.any_step_active?

      first_step = worker_steps.first
      return Result.failure(:no_steps, record: @phase) if first_step.nil?

      feedback = carried_feedback
      run = nil
      ApplicationRecord.transaction do
        @phase.update!(
          status: "running",
          restart_in_progress: true,
          restart_feedback: feedback,
          pause_requested: false,
          pause_requested_at: nil
        )
        run = first_step.step_runs.create!(
          state: "ready",
          iteration: (first_step.step_runs.maximum(:iteration) || 0) + 1,
          required_role: first_step.role,
          feedback: feedback
        )
      end

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Result.success(run)
    end

    private

    def worker_steps
      @phase.workflows.flat_map(&:steps).select(&:worker_executed?).sort_by(&:position)
    end

    # Every answer/note the human has given this phase so far (tagged "human"
    # by Phases::AnswerQuestions) — so restarting doesn't discard context
    # already supplied (R18). Attached to the first step's run directly, and
    # to every step ManagerTick dispatches for the rest of the cascade (see
    # ManagerTick#dispatch_ready_steps, §4.7) via `phase.restart_feedback`.
    def carried_feedback
      worker_steps.flat_map(&:step_runs).flat_map { |r| Array(r.feedback) }
        .select { |f| f.is_a?(Hash) && f["from"] == "human" }
    end
  end
end
```

R17 ("replace earlier results, keep only the latest") needs no extra code:
every builder step overwrites the same artifact path when it re-runs — that's
already the workspace's standing contract (`docs/artifact-schema.md`,
`docs/execution-model.md` "Artifact Workspace").

### 4.6 `Phases::Approve` — extended (`app/services/phases/approve.rb`)

**Done** (R20, R21):

```ruby
APPROVABLE_STATUSES = %w[consensus awaiting_human paused].freeze

def call
  unless @phase.status.in?(APPROVABLE_STATUSES)
    return Result.failure(:not_approvable, record: @phase)
  end
  if @phase.paused? && !Convergence.phase_settled?(@phase)
    return Result.failure(:not_settled, record: @phase)
  end

  ApplicationRecord.transaction do
    @phase.approvals.create!(user: @user, decision: "approve", note: @note)
    @phase.update!(status: "approved")
  end
  # ...unchanged from here (advance, seed_next_phase)
end
```

The extra `Convergence.phase_settled?` check only runs for `paused` — the
`consensus`/`awaiting_human` paths are untouched, so R32 ("existing approve at
the normal gate keeps working unchanged") holds exactly. `:not_settled` is a
new distinct error symbol so the controller can give R21's specific wording
instead of the generic "not awaiting approval."

### 4.7 `Phases::ManagerTick` — extended (`app/services/phases/manager_tick.rb`)

Three additions, all inside the existing `#call`/private-method structure; no
existing line is semantically changed except the `workflow_converged?`
extraction (§4.1):

```ruby
def call
  return Result.failure(:not_running) unless @phase.running?

  # A restart step failed/got stuck — don't leave the phase stalled at
  # "running" forever; hand it back to the paused menu with the failure
  # visible (R25, R26).
  if @phase.restart_in_progress? && restart_step_failed?
    abort_restart
    broadcast_affected
    return Result.success(@phase)
  end

  # Pause was requested while a step was in flight — wait for it to finish,
  # dispatch nothing new in the meantime (R2, R3, R27).
  if @phase.pause_requested? && !@phase.restart_in_progress?
    settle_pause
    broadcast_affected
    return Result.success(@phase)
  end

  ApplicationRecord.transaction do
    catch(:halt) do
      @phase.workflows.each do |workflow|
        dispatch_ready_steps(workflow)
        route_critic_feedback(workflow)
      end
      settle_convergence
    end
  end

  perform_pending_rework
  broadcast_affected
  Result.success(@phase)
end

private

def restart_step_failed?
  @phase.workflows.flat_map(&:steps)
    .any? { |s| s.latest_run&.state&.in?(%w[failed stuck]) }
end

def abort_restart
  @phase.update!(status: "paused", restart_in_progress: false, restart_feedback: [])
  @affected_phases << @phase
end

def settle_pause
  return if @phase.any_step_active?
  @phase.update!(status: "paused", pause_requested: false, pause_requested_at: nil)
  @affected_phases << @phase
end
```

`dispatch_ready_steps` gains one line — carry the restart's feedback onto
every step it dispatches during the cascade (R18), not just the first (which
`RestartDefine` already seeded directly):

```ruby
def dispatch_ready_steps(workflow)
  workflow.steps.each do |step|
    next unless step.worker_executed?
    next if step.active_run?

    predecessors = step.worker_predecessors
    next unless predecessors.all? { |p| p.latest_run&.succeeded? && p.latest_run.merged? }

    target_iteration = predecessors.filter_map { |p| p.latest_run.iteration }.max || 1
    next unless current_iteration(step) < target_iteration

    create_run(step, iteration: target_iteration, feedback: restart_carry_feedback)
  end
end

def restart_carry_feedback
  @phase.restart_in_progress? ? @phase.restart_feedback : []
end
```

`settle_convergence` branches on `restart_in_progress?` instead of always
reaching the gate:

```ruby
def settle_convergence
  @phase.workflows.each do |workflow|
    workflow.update!(status: "converged") if Convergence.workflow_converged?(workflow)
  end
  return unless @phase.workflows.all? { |w| w.status == "converged" }

  @phase.restart_in_progress? ? settle_restart : reach_consensus
end

def settle_restart
  @phase.update!(status: "paused", restart_in_progress: false, restart_feedback: [])
  record_decision(
    decision: "restart_complete",
    iteration: phase_iteration,
    rationale: "Repeat-from-the-Beginning converged; returned to the paused menu with fresh results."
  )
  @affected_phases << @phase
end
```

And `escalate` (the existing max-iterations path) additionally clears
`restart_in_progress`, so a restart that genuinely can't converge and hits the
existing cap doesn't leave a stale flag behind — it legitimately falls through
to the pre-existing `awaiting_human` escalation (out of scope to redesign;
this is the same safety net every other loop already has):

```ruby
def escalate(workflow, critic, critic_run, attempted_iteration)
  @phase.update!(status: "awaiting_human", restart_in_progress: false)
  # ...unchanged
end
```

**Why detection lives entirely in `ManagerTick` and not in
`StepRuns::Complete`/`Sweep`:** during a restart, `@phase.status == "running"`,
so `Phases::TickAll` (`Phase.where(status: "running")`) keeps ticking this
phase every ~10s exactly as it would any other running phase — no new
scheduling hook needed, and all restart-lifecycle logic (start, cascade,
converge, fail) stays in the one file that already owns "what a running phase
does next," per `guides/backend-guide.md`'s "business logic in reusable
POROs," not scattered across the completion/sweep paths.

## 5. Controllers & routes

### 5.1 `config/routes.rb`

```ruby
resources :phases, only: [ :show ] do
  resources :steps, only: [ :new, :create ]
  resource :approval, only: [ :create ]
  member do
    post :send_back
    post :answers
    post :pause
    post :rerun_step
    post :restart
  end
end
```

### 5.2 `app/controllers/phases_controller.rb` — three new actions

Same auth pattern as the existing `send_back`/`answers` actions
(`membership_scoped_phase`, already private in this controller):

```ruby
def pause
  phase = membership_scoped_phase
  result = Phases::Pause.call(phase: phase, user: current_user)

  if result.success?
    redirect_to pipeline_path(phase.pipeline), notice: pause_notice(phase.reload)
  else
    redirect_to pipeline_path(phase.pipeline), alert: "Define can't be paused right now."
  end
end

def rerun_step
  phase = membership_scoped_phase
  result = Phases::RerunMenuStep.call(phase: phase, artifact: params[:artifact])

  if result.success?
    redirect_to pipeline_path(phase.pipeline),
      notice: "Re-running — you'll see fresh results here shortly."
  else
    redirect_to pipeline_path(phase.pipeline), alert: menu_alert(result.error)
  end
end

def restart
  phase = membership_scoped_phase
  result = Phases::RestartDefine.call(phase: phase, user: current_user)

  if result.success?
    redirect_to pipeline_path(phase.pipeline), notice: "Restarting Define from the beginning…"
  else
    redirect_to pipeline_path(phase.pipeline), alert: menu_alert(result.error)
  end
end

private

def pause_notice(phase)
  phase.paused? ? "Define is paused." : "Pausing — finishing the current step first."
end

def menu_alert(error)
  case error
  when :busy       then "Define is still finishing something — wait for it to settle."
  when :not_paused then "Define isn't paused."
  else "Could not start that."
  end
end
```

### 5.3 `app/controllers/approvals_controller.rb` — R21's message

```ruby
def create
  phase = Phase.joins(pipeline: { project: :memberships })
    .where(memberships: { user_id: current_user.id })
    .find(params[:phase_id])

  result = Phases::Approve.call(phase: phase, user: current_user,
    note: params[:note].presence, context: params[:context].presence)

  if result.success?
    redirect_to pipeline_path(phase.pipeline),
      notice: "#{phase.kind.humanize} approved#{phase.pipeline.reload.completed? ? " — pipeline complete" : ""}."
  else
    redirect_to pipeline_path(phase.pipeline), alert: approval_alert(result.error)
  end
end

private

def approval_alert(error)
  case error
  when :not_settled then "Define isn't ready to finish yet — keep using the menu until it settles."
  else "This phase is not awaiting approval."
  end
end
```

## 6. Views

### 6.1 `app/helpers/status_helper.rb`

Add the new status to the shared tone map (one source of truth per
`guides/ui-style-guide.md`; label is always rendered alongside, never color
alone — R4, R26):

```ruby
STATUS_TONES = {
  "running" => :info, "assessing" => :info, "claimed" => :info,
  "ready" => :success, "approved" => :success, "completed" => :success,
  "converged" => :success, "succeeded" => :success, "passed" => :success,
  "online" => :success, "consensus" => :success,
  "awaiting_human" => :attention, "needs_setup" => :attention,
  "reworking" => :attention, "draining" => :attention,
  "paused" => :attention,                                   # NEW
  "stuck" => :danger, "failed" => :danger, "blocked" => :danger,
  "aborted" => :danger,
  "pending" => :muted, "draft" => :muted, "offline" => :muted
}.freeze
```

### 6.2 `app/helpers/define_helper.rb` — generalized artifact surfacing (R9, R11, R19, R26)

Generalizes the existing `define_open_questions` pattern (which already pulls
the latest succeeded run's named artifact) to `discovery_notes` **and
`business_requirements`**. The third one is not optional polish: a completed
**Repeat from the Beginning** regenerates all three of Define's artifacts
(discovery notes, business requirements, open questions —
`docs/artifact-schema.md`'s Define step order), and R19 requires the person to
see the restart's "fresh, replaced results" before choosing their next action.
`business_requirements` is Define's headline deliverable (produced by
Requirements Writer) but — per discovery-notes iteration-1 F1 — it is surfaced
**nowhere in the UI today**; the existing `define_open_questions` pattern is
the only reusable precedent, so this design applies it a second time rather
than leaving the restart's main output invisible:

```ruby
module DefineHelper
  def define_open_questions(phase)
    define_artifact(phase, "open_questions")
  end

  def define_discovery_notes(phase)
    define_artifact(phase, "discovery_notes")
  end

  # NEW (iteration 3, F1) — Requirements Writer's output. Nothing renders this
  # today (discovery-notes F1); without it, a completed restart has no inline
  # evidence of its regenerated headline deliverable, and R19 is unmet.
  def define_business_requirements(phase)
    define_artifact(phase, "business_requirements")
  end

  # The most recent failed/stuck run across Define's steps — while paused, the
  # only steps that ever run are ones the human just triggered from the menu,
  # so this is always "my re-run failed," never Manager-triggered noise (R26).
  def define_menu_failure(phase)
    run = phase.workflows.flat_map(&:steps).filter_map(&:latest_run)
      .select { |r| r.state.in?(%w[failed stuck]) }
      .max_by { |r| [ r.iteration, r.attempt, r.id ] }
    run && run.result.is_a?(Hash) ? run.result["summary"].presence : nil
  end

  private

  def define_artifact(phase, name)
    run = latest_artifact_run(phase, name)
    run && artifact_value(run, name)
  end

  def latest_artifact_run(phase, name)
    phase.workflows.flat_map(&:steps).flat_map(&:step_runs)
      .select { |run| run.succeeded? && artifact_value(run, name).present? }
      .max_by { |run| [ run.iteration, run.attempt, run.id ] }
  end

  def artifact_value(run, name)
    return nil unless run.result.is_a?(Hash)
    artifacts = run.result["artifacts"]
    artifacts.is_a?(Hash) ? artifacts[name].presence : nil
  end
end
```

`define_open_questions`'s name and behavior are unchanged (R34).

### 6.3 `app/views/pipelines/_define_panel.html.erb` — the paused panel + menu

Same root wrapper (`dom_id(phase, :column)` — unchanged, so
`Phases::BroadcastColumn` keeps working), same `approved?` and `at_gate`
branches (**untouched**, R32–R34), with new branches inserted between the
header and the step-card grid:

```erb
<div id="<%= dom_id(phase, :column) %>">
  <% if phase.approved? %>
    <%# ...unchanged... %>
  <% else %>
    <% at_gate = phase.status.in?(%w[consensus awaiting_human]) && phase.gate_human? %>
    <% questions = define_open_questions(phase) %>
    <% discovery = define_discovery_notes(phase) %>
    <% requirements = define_business_requirements(phase) %>
    <% steps = phase.workflows.flat_map(&:steps) %>
    <% menu_busy = phase.paused? && phase.any_step_active? %>
    <div class="rounded-lg border bg-white p-6 shadow-sm
                <%= at_gate ? "border-amber-300 ring-1 ring-amber-100"
                    : (phase.paused? ? "border-amber-300 ring-1 ring-amber-100"
                    : (phase.kind == current_phase_kind ? "border-indigo-300 ring-1 ring-indigo-100" : "border-gray-200")) %>">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-xs uppercase tracking-wide text-gray-400">Pre-phase</span>
          <h2 class="text-lg font-semibold text-gray-900">Definition</h2>
        </div>
        <div class="flex items-center gap-3">
          <%= status_badge(phase.status) %>
          <% if phase.running? && !phase.restart_in_progress? && !phase.pause_requested? %>
            <%= button_to "Pause", pause_phase_path(phase),
                  class: "text-xs font-medium text-gray-500 underline hover:text-gray-900" %>
          <% end %>
        </div>
      </div>

      <% if phase.running? && phase.pause_requested? && !phase.restart_in_progress? %>
        <p class="mt-3 text-xs text-gray-500" aria-live="polite">
          Pausing — finishing the current step, then Define will hold for you.
        </p>
      <% end %>

      <% if phase.running? && phase.restart_in_progress? %>
        <div class="mt-4 rounded-md bg-blue-50 p-4 ring-1 ring-inset ring-blue-600/20">
          <p class="text-sm font-medium text-blue-800" aria-live="polite">
            Restarting Define from the beginning — this runs every step again.
            You'll land back on the paused menu with fresh results when it's done.
          </p>
        </div>
      <% elsif phase.paused? && menu_busy %>
        <div class="mt-4 rounded-md bg-blue-50 p-4 ring-1 ring-inset ring-blue-600/20">
          <p class="text-sm font-medium text-blue-800" aria-live="polite">
            Re-running — the menu will come back once this finishes.
          </p>
        </div>
      <% elsif phase.paused? %>
        <div class="mt-4 rounded-md bg-amber-50 p-4 ring-1 ring-inset ring-amber-600/20">
          <p class="text-sm font-medium text-amber-800">Define is paused — choose what to do next.</p>
          <% if (failure = define_menu_failure(phase)) %>
            <div class="mt-2 flex items-start gap-2 text-sm text-red-700">
              <%= status_badge("failed", label: "Re-run failed") %>
              <span><%= failure %></span>
            </div>
          <% end %>
          <div class="mt-3 flex flex-wrap gap-2">
            <% if steps.any? { |s| Array(s.outputs).include?("discovery_notes") } %>
              <%= button_to "Explore", rerun_step_phase_path(phase, artifact: "discovery_notes"),
                    class: "rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50",
                    data: { turbo_submits_with: "Starting…" } %>
            <% end %>
            <% if steps.any? { |s| Array(s.outputs).include?("open_questions") } %>
              <%= button_to "Clarifying Questions", rerun_step_phase_path(phase, artifact: "open_questions"),
                    class: "rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50",
                    data: { turbo_submits_with: "Starting…" } %>
            <% end %>
            <a href="#define-ask-human"
               class="rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50">Ask Human</a>
            <%= button_to "Repeat from the Beginning", restart_phase_path(phase),
                  class: "rounded-md bg-white px-3 py-2 text-sm font-semibold text-gray-900 ring-1 ring-inset ring-gray-300 hover:bg-gray-50",
                  data: { turbo_confirm: "Restart Define from the first step? This replaces the current discovery notes and requirements with fresh output.",
                          turbo_submits_with: "Restarting…" } %>
            <%= form_with url: phase_approval_path(phase), class: "inline" do |f| %>
              <%= f.submit "Done", class: "rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white hover:bg-indigo-700 cursor-pointer",
                    data: { turbo_submits_with: "Finishing…" } %>
            <% end %>
          </div>
        </div>
      <% end %>

      <% if at_gate %>
        <%# ...unchanged gate banner (R32, R33)... %>
      <% end %>

      <div class="mt-4">
        <h3 class="text-xs font-semibold uppercase tracking-wide text-gray-400">Steps</h3>
        <%# ...unchanged step-card grid... %>
      </div>

      <% if discovery.present? %>
        <div class="mt-6 border-t border-gray-100 pt-6">
          <h3 class="text-sm font-semibold text-gray-900">Discovery notes</h3>
          <div class="mt-2 space-y-1 text-sm text-gray-700"><%= simple_format(discovery) %></div>
        </div>
      <% end %>

      <%# NEW (iteration 3, F1) — Requirements Writer's output. Not gated on
          phase.paused? at all, same as the discovery/questions blocks: it
          renders whenever the artifact exists, so a restart's regenerated
          business_requirements is on the page — before the paused menu, in
          DOM order — the moment ManagerTick#settle_restart lands back on
          `paused` and re-renders this partial (R19). %>
      <% if requirements.present? %>
        <div class="mt-6 border-t border-gray-100 pt-6">
          <h3 class="text-sm font-semibold text-gray-900">Requirements</h3>
          <div class="mt-2 space-y-1 text-sm text-gray-700"><%= simple_format(requirements) %></div>
        </div>
      <% end %>

      <%# CHANGED (iteration 3, F2) — was `questions.present?` only, which left
          Ask Human's button targeting a non-existent anchor whenever Define is
          paused before Clarifying Questions has ever produced open_questions
          (e.g. paused right after Explore). AnswerQuestions itself has never
          required questions to exist — it just attaches whatever free-text
          `answers` string it's given as feedback (app/services/phases/
          answer_questions.rb:21, no presence check) — so the fix is a view-only
          empty state, not a service change. Outside `paused`, behavior is
          byte-for-byte unchanged (R34): this block still only appears when
          questions are present, exactly as it does today. %>
      <% if questions.present? || phase.paused? %>
        <div id="define-ask-human" class="mt-6 border-t border-gray-100 pt-6">
          <h3 class="text-sm font-semibold text-gray-900">Open questions</h3>
          <% if questions.present? %>
            <div class="mt-2 space-y-1 text-sm text-gray-700"><%= simple_format(questions) %></div>
          <% else %>
            <p class="mt-2 text-sm text-gray-500">
              No open questions right now — you can still send notes for the agent to take into account.
            </p>
          <% end %>
          <%= form_with url: answers_phase_path(phase), class: "mt-4 space-y-3" do |f| %>
            <div>
              <%= f.label :answers, questions.present? ? "Your answers" : "Notes for the agent",
                    class: "block text-sm font-medium text-gray-900" %>
              <%= f.text_area :answers, rows: 4, required: true,
                    placeholder: questions.present? ? "Answer by number — unanswered questions use their stated defaults" : "Anything you want the agent to take into account",
                    class: "mt-1 block w-full rounded-md border-0 px-3 py-2 text-sm text-gray-900 ring-1 ring-inset ring-gray-300 focus:ring-2 focus:ring-indigo-600 bg-white" %>
              <p class="mt-1 text-xs text-gray-500">Sending re-opens the requirements loop for another pass.</p>
            </div>
            <%= f.submit "Send answers",
                  class: "rounded-md bg-indigo-600 px-3 py-2 text-sm font-semibold text-white hover:bg-indigo-700 cursor-pointer",
                  data: { turbo_submits_with: "Sending…" } %>
          <% end %>
        </div>
      <% end %>
    </div>
  <% end %>
</div>
```

Notes on this view:

- **R12's generalization.** R12's text names Explore/Clarifying Questions
  specifically, but its own rationale ("every in-flight re-run … shown to the
  person consistently") applies equally to Ask Human's Requirements-Writer
  re-run. `menu_busy` is computed from `phase.any_step_active?`, not from a
  per-action flag, so *any* menu-triggered run (Explore, Clarifying Questions,
  or Ask Human's answer submission) hides the whole menu the same way,
  matching the precedent `_step_card.html.erb:25-29` already sets for a single
  step ("Re-run" link absent for the run's entire `ready/claimed/running`
  lifetime).
- **Ask Human is a same-page anchor**, not a new server round-trip — R13's
  "show them the questions and let them submit answers" is already close to
  what the existing `questions.present?` block below does today (it isn't
  gated to `at_gate`); the button just scrolls to it. This avoids inventing a
  redundant reveal/hide action for content that's already rendered when
  present. The block's condition is widened to `questions.present? ||
  phase.paused?` (§6.3, iteration-3 F2) specifically so the anchor always has
  something to scroll *to* while paused, even before Clarifying Questions has
  ever run — otherwise Ask Human's button would target a `<div>` that doesn't
  exist yet and R14 would have no submission path in that state.
- The **Explore/Clarifying Questions buttons are conditionally rendered** on
  whether a step declaring that output actually exists in this phase's
  workflow — defensive against a project template that composed Define
  without one of them (§2.4); Repeat from the Beginning and Done are not
  step-specific and always render.

## 7. Requirements traceability

| Req. | Design element |
|---|---|
| R1 | Pause button in `_define_panel.html.erb`, visible whenever `phase.running?` |
| R2 | `ManagerTick`'s existing `unless @phase.running?` guard once `status` flips to `paused`; `settle_pause`/`pause_requested` suppress new dispatch even before that |
| R3 | `Phases::Pause` sets `pause_requested` instead of forcing status when a step is active; `ManagerTick#settle_pause` only transitions once `any_step_active?` is false |
| R4 | `status_badge("paused")`, new `STATUS_TONES` entry (label + tone, never color alone) |
| R5 | No "resume" control exists (§2.2); only Done (`Approve`) or a menu action ends `paused` |
| R6 | Same `membership_scoped_phase` auth as every other phase action — any project member |
| R7 | Five-button menu in the `phase.paused?` branch of `_define_panel.html.erb` |
| R8 | `Phases::RerunMenuStep` targeting `discovery_notes` |
| R9 | `define_discovery_notes` helper + inline "Discovery notes" block |
| R10 | `Phases::RerunMenuStep` targeting `open_questions` |
| R11 | Existing `define_open_questions` + inline block (unchanged) |
| R12 | `menu_busy` (`phase.paused? && any_step_active?`) hides the menu, shows a live `aria-live` message — generalized to any menu-triggered run, matching Repeat-from-Beginning's own treatment |
| R13 | `Phases::AnswerQuestions`, extended allow-list; existing open-questions/answer UI, reachable while paused; anchor block widened to `questions.present? \|\| phase.paused?` (§6.3, F2) so it's reachable even with no open questions yet |
| R14 | `AnswerQuestions`'s existing `{"from" => "human", ...}` feedback attach, unchanged |
| R15 | `Phases::RestartDefine` — new run on the first worker-executed step |
| R16 | `phase.restart_in_progress?` branch replaces the menu with a "restart in progress" banner |
| R17 | No new code — artifacts overwrite the same path on re-run (existing workspace contract) |
| R18 | `RestartDefine#carried_feedback` + `ManagerTick#restart_carry_feedback` propagate prior human-tagged feedback through the whole cascade |
| R19 | `ManagerTick#settle_restart` — converged restart lands on `paused`, not the gate; fresh output shown via R9/R11's inline blocks for `discovery_notes`/`open_questions` **plus the new `define_business_requirements` helper + "Requirements" block (§6.2/§6.3, F1)** for the restart's regenerated `business_requirements` |
| R20 | `Phases::Approve` accepts `paused` when `Convergence.phase_settled?` is true |
| R21 | `Approve` returns `:not_settled` when not; `ApprovalsController#approval_alert` gives the plain-language message |
| R22 | Menu actions never change `phase.status`; the panel always re-renders the paused menu once idle |
| R23 | Same — `RerunMenuStep`/`AnswerQuestions` leave `status: "paused"` untouched |
| R24 | Structural — nothing bounds how many times the loop in R22/R23 can repeat |
| R25 | `RerunMenuStep`/`AnswerQuestions` never retry on failure (fire-and-forget, same as today); `ManagerTick#abort_restart` returns a failed restart to `paused` rather than stalling at `running` |
| R26 | `define_menu_failure` helper + failure banner (`status_badge("failed", label: "Re-run failed")` — label, not color alone) |
| R27 | `ManagerTick`'s `pause_requested`/`paused` branches run before, and instead of, `route_critic_feedback`/`escalate` |
| R28 | `RerunMenuStep`/`RestartDefine` create runs directly — they never go through `route_to_target`'s `max_iterations` check |
| R29 | `any_step_active?` guard in every menu service; DB unique index `index_step_runs_unique_without_shard` on `(step_id, iteration, attempt)` backstops the race exactly like existing `Approve#create_seeded_run`'s `RecordNotUnique` rescue |
| R30 | Same `any_step_active?` guard, checked at the top of `Pause`, `RerunMenuStep`, `RestartDefine`, and `AnswerQuestions`'s existing `define_busy?` |
| R31 | All new copy ("Define is paused — choose what to do next," etc.) is plain language, no internal terms |
| R32 | `Approve`'s `consensus`/`awaiting_human` path is byte-for-byte unchanged |
| R33 | `SendBack` is untouched entirely |
| R34 | `AnswerQuestions`'s `running`/`consensus`/`awaiting_human` behavior is unchanged; `define_open_questions` unchanged |

Assumption (generalize later, final bullet of the open-questions doc): satisfied by §2.7 — no service hardcodes `define_phase?`.

## 8. File-level plan

**New files**

- `db/migrate/<timestamp>_add_pause_support_to_phases.rb` — §3.1
- `app/queries/phases/convergence.rb` — §4.1
- `app/services/phases/pause.rb` — §4.2
- `app/services/phases/rerun_menu_step.rb` — §4.3
- `app/services/phases/restart_define.rb` — §4.5
- `test/queries/phases/convergence_test.rb`
- `test/services/phases/pause_test.rb`
- `test/services/phases/rerun_menu_step_test.rb`
- `test/services/phases/restart_define_test.rb`

**Modified files**

- `app/models/phase.rb` — `paused` status value, `any_step_active?` (§3.2)
- `app/services/phases/manager_tick.rb` — pause/restart branches, `Convergence` delegation (§4.7)
- `app/services/phases/approve.rb` — `paused` + settled check (§4.6)
- `app/services/phases/answer_questions.rb` — allow-list widened (§4.4)
- `app/controllers/phases_controller.rb` — `pause`/`rerun_step`/`restart` actions (§5.2)
- `app/controllers/approvals_controller.rb` — `:not_settled` message (§5.3)
- `config/routes.rb` — three new member routes (§5.1)
- `app/helpers/status_helper.rb` — `"paused"` tone (§6.1)
- `app/helpers/define_helper.rb` — generalized artifact + failure helpers (§6.2)
- `app/views/pipelines/_define_panel.html.erb` — pause control, paused menu, in-progress states, discovery-notes block (§6.3)
- `test/models/phase_test.rb` — `any_step_active?`, new status value
- `test/services/phases/manager_tick_test.rb` — pause/restart branches, `Convergence` extraction
- `test/services/phases/approve_test.rb` — `paused`+settled, `paused`+unsettled
- `test/services/phases/answer_questions_test.rb` — answerable from `paused`
- `test/controllers/phases_controller_test.rb` — three new actions
- `test/controllers/approvals_controller_test.rb` — `:not_settled` alert
- `test/helpers/define_helper_test.rb` (new, if it doesn't exist) or extended

**Unchanged (verified, not just assumed)**

- `app/services/phases/send_back.rb`, `app/services/step_runs/{queue,complete,claim,sweep}.rb`, `app/services/phases/{tick_all,advance,broadcast_column}.rb`, `app/services/step_runs/broadcast_card.rb`, `app/views/pipelines/_step_card.html.erb` — none of these need to know about `paused`; the tick's own `running?` guard and the new phase-status branches are the entire seam.

## 9. Edge cases and follow-ups (documented, not built)

- **Pre-existing note (not this feature's bug):** `AnswerQuestions#requirements_step`
  picks "the first worker-executed step by position," which is only Requirements
  Writer when no Explore step precedes it. When a project's `pipeline_template`
  pins an Explore step first (as this repository's own pipeline_template does —
  see `.pipeliner/phases/01-define/main/codebase-explorer/`), `Ask Human`
  inherits whatever `AnswerQuestions` already does today, correct or not; R34
  requires this to be unchanged, so fixing it is out of this feature's scope.
- **Restart hitting the iteration cap** falls through to the existing
  `awaiting_human` escalation (`ManagerTick#escalate`) rather than back to
  `paused` — this is the same safety net every other consensus loop already
  has, not a new state, and isn't one of R25's named failure modes (which
  covers "fails or times out," not "needs more iterations than the cap
  allows").
- **Multiple workflows in one phase:** `Phases::Convergence.phase_settled?`
  and `ManagerTick`'s existing loop already iterate `phase.workflows` plural,
  so nothing here assumes Define has exactly one workflow, even though
  today's default composition does.
