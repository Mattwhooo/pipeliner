# Technical Design — Live pipeline status summary

## 1. Summary

Add a single, plain-language, continuously-updating status line for each
pipeline that answers the operator's core question — *"what is happening right
now?"* — without reading the per-step cards (e.g. `Define: requirements-writer
is drafting requirements, iteration 3` or `Waiting on human approval at the Plan
gate`).

The design follows the repo's established seam: **derivation logic lives in a
reusable domain PORO**, controllers stay thin and render it on load (true state
without a socket), and a **service broadcasts it after commit** from the exact
points that already refresh the board. It reuses the existing
`turbo_stream_from @pipeline` stream, the semantic status tones in
`StatusHelper`, and the `broadcast_replace_later_to` pattern already used by
`StepRuns::BroadcastCard`.

No upstream requirements/approach artifact was wired into this step's
`input.json` (`resolved_inputs: []`). Requirement IDs below are therefore
derived directly from the pipeline ask so each component can be cited; they
restate the ask, they do not invent scope.

### Derived requirements

| ID | Requirement (from the ask) |
|----|----------------------------|
| **R1** | One single status per pipeline that summarizes current activity in plain language. |
| **R2** | Prominent on the pipeline board (the `pipelines#show` view). |
| **R3** | Updates live via Turbo Streams as runs progress — no manual refresh. |
| **R4** | Always reflects true current state on page load; streams are enhancement, never required for correctness. |
| **R5** | Expresses the meaningful states: active step + role + iteration, waiting on human at a gate, escalated/parked, stuck, completed, not-started, idle. |
| **R6** | Appearance follows `guides/ui-style-guide.md`; logic placement follows `guides/backend-guide.md`. |

---

## 2. Current state (what exists, what's missing)

**Exists and is reused:**

- `pipelines/show.html.erb` already subscribes with `turbo_stream_from @pipeline`
  and preloads `phases → workflows → steps → step_runs → worker`
  (`PipelinesController#show`).
- `StepRuns::BroadcastCard` broadcasts a single card via
  `Turbo::StreamsChannel.broadcast_replace_later_to(pipeline, target: dom_id(step, :card), …)`.
  It is called from **`StepRuns::Claim`, `StepRuns::RecordProgress`,
  `StepRuns::Complete`** — the three worker-driven run transitions.
- `Phases::ManagerTick` (recurring every 10s via `Phases::TickAll`) is the only
  writer of phase/pipeline **status** transitions: dispatch, route, consensus,
  gate (`approved`/advance), and `escalate` → `awaiting_human`.
- `StatusHelper::STATUS_TONES` / `TONE_CLASSES` already map status strings to the
  guide's semantic colors (info/success/attention/danger/muted) and
  `status_badge` renders the color-plus-word badge.
- `StepRun#progress` is a JSONB column holding the worker's latest incremental
  message (`progress["message"]`); `StepRun#iteration` is the iteration counter.

**Missing (the gap this design fills):**

1. No object turns whole-pipeline state into a sentence (R1, R5).
2. Nothing broadcasts a **pipeline-level** summary; only individual step cards
   broadcast, and phase/pipeline status transitions in `ManagerTick`
   (consensus, gate wait, escalate, advance) broadcast **nothing** — so a
   gate-wait or escalation is invisible until reload (R3).
3. The board has no prominent single-line status element (R2); the index list
   shows a bare status badge, not what's happening (R1).

---

## 3. Component design

```
Controller (thin: preload + render)                     [R2, R4]
  pipelines#show / #index
      └─ renders _status_summary (on load, true state)
             └─ Pipelines::StatusSummary.for(pipeline)  → Summary value  [R1, R5]

Turbo stream (per pipeline, already subscribed on show)  [R3]
  Pipelines::BroadcastStatus.call(pipeline)              [R3]
      └─ broadcast_replace_later_to(pipeline, dom_id(pipeline,:summary), _status_summary)
   called after commit from:
      StepRuns::Claim / RecordProgress / Complete   (run transitions)
      Phases::ManagerTick                           (phase/gate/pipeline transitions)
```

### 3.1 `Pipelines::StatusSummary` — domain PORO (R1, R5, R6)

Location: **`app/lib/pipelines/status_summary.rb`**. This is a pure *derivation
/ state-logic* PORO (backend-guide §"Business logic lives in reusable POROs" —
"Domain POROs (values, states)"). It performs no writes and no HTTP/job
assumptions, so it is callable from the view, the broadcast job, the console,
and tests. It is **not** a `*_verb` service (no business action / no mutation)
and it is not a `Query` object (it returns a value, not an
`ActiveRecord::Relation`), so `app/lib` is the correct home per the guide's
"app/lib for app-specific POROs that aren't services/queries."

**Interface:**

```ruby
module Pipelines
  class StatusSummary
    # Immutable value the view renders. `tone` is a StatusHelper tone symbol
    # (:info/:success/:attention/:danger/:muted) so color stays semantic and
    # centralized (ui-style-guide "Status colors are semantic and reserved").
    Summary = Data.define(:text, :tone, :phase_label, :as_of) do
      def to_s = text
    end

    def self.for(pipeline) = new(pipeline).build

    def initialize(pipeline) = @pipeline = pipeline

    def build
      # returns a Summary; see resolution order below
    end
  end
end
```

**Resolution order** (first match wins — most operationally salient first) (R5):

1. **Terminal pipeline** — `completed` → `"Completed"` (success);
   `aborted` → `"Aborted"` (danger).
2. **Awaiting human** (`pipeline.awaiting_human?`):
   - A phase in `consensus`/`approved` with `gate_human?` and no `Approval`
     yet → `"Waiting on human approval at the <Phase> gate"` (attention).
   - A phase in `awaiting_human` (escalation from `ManagerTick#escalate`) →
     `"Paused at <Phase>: needs human guidance (reached max iterations)"`
     (attention).
3. **Stuck / blocked** (`pipeline.stuck?`/`blocked?`, or any latest run
   `stuck`) → `"Blocked at <Phase>: <role> has no available worker"` (danger).
4. **Running** — locate the current phase (`pipeline.current_phase`), pick the
   **most salient active run** in it (priority `running > claimed > ready`, tie
   broken by most-recent `updated_at`) and phrase it:
   - `running` with `progress["message"]`:
     `"<Phase>: <role> is <message>, iteration <n>"` →
     *"Define: requirements-writer is drafting requirements, iteration 3"*.
   - `running` without a message: fall back to a type verb
     (`planner→planning`, `builder→building`, `critic→reviewing`):
     `"<Phase>: <role> is <verb>, iteration <n>"`.
   - `claimed` (leased, not yet reporting):
     `"<Phase>: <role> starting on <worker>"`.
   - `ready`/queued only: `"<Phase>: waiting for <role> to start"`.
   - When >1 run is active, append `" (+N more running)"` so the line stays
     single-sentence but honest (never silently hides concurrency).
   - Tone `:info` (blue) throughout.
5. **Idle/not-started** — `draft`/`pending`, no runs → `"Not started"` (muted).

`role` uses `step.role` (the worker-matching label, e.g. `requirements-writer`);
`<Phase>` uses `phase.kind.humanize`. All branches read only preloaded
associations, so on `show` (which preloads the full tree) it adds **zero**
queries.

`as_of` is `Time.current` at build time, surfaced as a relative timestamp in the
partial (ui-style-guide "Timestamps: relative with absolute on hover").

### 3.2 `Pipelines::BroadcastStatus` — service (R3, R6)

Location: **`app/services/pipelines/broadcast_status.rb`**. Mirrors
`StepRuns::BroadcastCard`: a thin broadcast service (backend-guide "Broadcasts
happen from services, after commit; target the smallest partial, keyed by
`dom_id`").

```ruby
module Pipelines
  class BroadcastStatus
    def self.call(pipeline)
      Turbo::StreamsChannel.broadcast_replace_later_to(
        pipeline,
        target: ActionView::RecordIdentifier.dom_id(pipeline, :summary),
        partial: "pipelines/status_summary",
        locals: { pipeline: pipeline }
      )
    end
  end
end
```

`broadcast_replace_later_to` renders the partial **in a job**, reloading the
pipeline by GlobalID — so the broadcast always paints freshly-derived state and
a lost/racing broadcast is cosmetic, never wrong (R4). The re-render is for a
single pipeline, so the summarizer's lazy association loads are a few queries —
acceptable; the partial does not need eager loading in the broadcast path.

**Call sites** (each fires **once per committed business action**, after the
write, per backend-guide side-effect ordering — R3):

| Seam (existing file) | Why | Edit |
|---|---|---|
| `StepRuns::Claim#call` | run `ready→claimed` (a step starts) | one line after `BroadcastCard.call(run)` |
| `StepRuns::RecordProgress#call` | new `progress`/iteration (the high-frequency "…drafting, iteration 3" update) | one line after `BroadcastCard.call` |
| `StepRuns::Complete#call` | run `succeeded/failed` | one line after `BroadcastCard.call` |
| `Phases::ManagerTick#call` | phase/gate/pipeline transitions: consensus, gate-wait, escalate→`awaiting_human`, advance/`completed` — none of which touch a run's card | one line at end of `call` (after the transaction commits, alongside `broadcast_affected`) |

The `ManagerTick` seam is essential: gate-wait and escalation change **only**
phase/pipeline status, so without it "Waiting on human approval at the Plan
gate" would never appear live (R5). `BroadcastCard` is intentionally left
single-purpose (one card); the summary is a separate DOM unit with its own
service, so a tick that touches N cards still refreshes the summary exactly once
rather than N times.

> Note (not in scope, called out): `StepRuns::Sweep` uses bulk `update_all` and
> broadcasts nothing today, so a `ready→stuck` flip surfaces on the next
> `ManagerTick` (≤10s) or reload rather than instantly. Acceptable; adding a
> sweep-side broadcast is a follow-up, noted so it isn't mistaken for covered.

### 3.3 Views (R2, R4, R6)

**`app/views/pipelines/_status_summary.html.erb`** — one source of truth for the
element, in two variants via a `compact:` local.

- Root: `<div id="<%= dom_id(pipeline, :summary) %>" aria-live="polite">` — the
  stable stream target and the accessibility live region
  (ui-style-guide "Live regions: progress updates in `aria-live=\"polite\"`").
- Computes `summary = Pipelines::StatusSummary.for(pipeline)`.
- **Full variant (show):** a `Card` surface
  (`rounded-lg border border-gray-200 bg-white p-6 shadow-sm`) with a small
  status dot (semantic tone, paired with the phase word — never color alone,
  a11y), the sentence in `text-sm`, an eyebrow phase label
  (`text-xs uppercase tracking-wide text-gray-400`), and the relative `as_of`
  timestamp (`text-xs text-gray-500`). Type scale, spacing steps
  (`p-6`, `gap-4`), and neutrals are all from the guide.
- **Compact variant (index cell):** single line — dot + `summary.text` truncated
  (`truncate text-sm text-gray-700`).
- Tone → dot color via a tiny helper (see 3.4) reusing `TONE_CLASSES`, so no new
  color literals are introduced.

**`app/views/pipelines/show.html.erb`** — render the full summary **prominently
at the top of the board**, directly under the header block and above the phase
grid (and above/near "The ask"). Keeps the existing `turbo_stream_from
@pipeline`. (R2)

```erb
<%= render "pipelines/status_summary", pipeline: @pipeline, compact: false %>
```

**`app/views/pipelines/index.html.erb`** — replace the plain "Status" badge cell
(or add a cell) with the compact summary so each row says what's happening, and
add a per-row `<%= turbo_stream_from pipeline %>` so the list updates live too
(the index has no subscription today). (R1, R3)

### 3.4 Helper (R6)

Add **`app/helpers/pipelines_helper.rb`** (file exists, empty) with
`summary_dot_class(tone)` returning the dot's Tailwind classes derived from
`StatusHelper::TONE_CLASSES` — keeps semantic color in one place. No change to
`StatusHelper` itself.

### 3.5 Model (R4)

Add a preloading scope to **`app/models/pipeline.rb`** so both controllers avoid
N+1 without duplicating the include tree (a persistence concern — allowed in the
model per backend-guide "Models: associations, scopes"):

```ruby
scope :with_board, -> {
  includes(phases: { workflows: { steps: { step_runs: :worker } } })
}
```

### 3.6 Controllers (R2, R4)

- `PipelinesController#show`: swap the ad-hoc `includes(...)` for `.with_board`
  (behavior-preserving); no other change — the summary renders inline on load.
- `PipelinesController#index`: add `.with_board` to the query so the compact
  summary derives without N+1.

Both stay ≤10 lines, one primary ivar, no business branching (backend-guide
"Controllers — light").

---

## 4. Data model

**No migration.** The summary is a *derivation* of existing columns; adding a
denormalized column would create a second source of truth that could drift from
the run/phase state the guide treats as canonical. Inputs consumed, all
existing:

- `pipelines.status`, `pipelines.current_phase`
- `phases.kind`, `phases.status`, `phases.gate_mode`, and `approvals` (gate wait
  vs. approved)
- `steps.role`, `steps.step_type`
- `step_runs.state`, `step_runs.iteration`, `step_runs.progress` (JSONB
  `message`), `step_runs.worker_id`, `step_runs.updated_at`

The `Summary` `Data` value is the only new "type," and it is in-memory only.

---

## 5. File-level change plan

**New**

| File | Purpose | Reqs |
|---|---|---|
| `app/lib/pipelines/status_summary.rb` | Derive the plain-language `Summary` value from pipeline state. | R1, R5 |
| `app/services/pipelines/broadcast_status.rb` | After-commit Turbo broadcast of the summary partial to the pipeline stream. | R3 |
| `app/views/pipelines/_status_summary.html.erb` | Summary element (full + compact), `dom_id(pipeline,:summary)`, `aria-live`. | R2, R4, R6 |

**Edited**

| File | Change | Reqs |
|---|---|---|
| `app/models/pipeline.rb` | Add `scope :with_board`. | R4 |
| `app/controllers/pipelines_controller.rb` | `#show`/`#index` use `.with_board`. | R2, R4 |
| `app/views/pipelines/show.html.erb` | Render full summary prominently atop the board. | R2 |
| `app/views/pipelines/index.html.erb` | Render compact summary per row + `turbo_stream_from pipeline`. | R1, R3 |
| `app/helpers/pipelines_helper.rb` | `summary_dot_class(tone)` reusing `TONE_CLASSES`. | R6 |
| `app/services/step_runs/claim.rb` | `Pipelines::BroadcastStatus.call(pipeline)` after card broadcast. | R3 |
| `app/services/step_runs/record_progress.rb` | Same, after card broadcast. | R3 |
| `app/services/step_runs/complete.rb` | Same, after card broadcast. | R3 |
| `app/services/phases/manager_tick.rb` | `Pipelines::BroadcastStatus.call(@phase.pipeline)` at end of `call`. | R3, R5 |

**Tests** (Minitest; backend-guide "Test services as the primary unit… system
tests cover the critical flows… the pipeline board")

| File | Coverage | Reqs |
|---|---|---|
| `test/lib/pipelines/status_summary_test.rb` | State table → expected `text`/`tone`: running+progress+iteration, running-no-message fallback, claimed, ready/queued, human gate-wait, escalation, stuck, completed/aborted, not-started, `+N more running`. | R1, R5 |
| `test/services/pipelines/broadcast_status_test.rb` | Asserts one `turbo_stream` replace enqueued to the pipeline targeting `dom_id(pipeline,:summary)`. | R3 |
| `test/services/phases/manager_tick_test.rb` (extend) | A gate-wait / escalate tick broadcasts the summary. | R3, R5 |
| `test/services/step_runs/{claim,record_progress,complete}_test.rb` (extend) | Each transition also broadcasts the summary. | R3 |
| `test/system/pipeline_status_summary_test.rb` | Board shows the summary on load (R4) and it updates in place after a run/gate transition (R3). | R2, R3, R4 |

---

## 6. Interfaces (signatures)

```ruby
Pipelines::StatusSummary.for(pipeline) # => Summary(text:, tone:, phase_label:, as_of:)
Pipelines::BroadcastStatus.call(pipeline)              # => broadcast enqueued
Pipeline.with_board                                    # => preloaded relation
# helper
summary_dot_class(tone)                                # => Tailwind classes (String)
# partial
render "pipelines/status_summary", pipeline:, compact: # boolean
```

`StatusSummary.for` uses `.for` (not `.call`) deliberately: `.call` is reserved
by the guide for verb-first *services that perform a business action*; a pure
query-by reads more honestly and won't be mistaken for a mutation.

---

## 7. Design decisions & alternatives

- **Derivation PORO, not a DB column (R4).** A stored summary would be a second
  source of truth that drifts from run/phase state and needs its own backfill +
  invalidation. Deriving on render/broadcast is always correct and cheap on a
  preloaded tree.
- **Separate `BroadcastStatus` service rather than folding into
  `BroadcastCard`.** Gate-wait and escalation change no card, so a card-only
  hook would miss them (R5); and a tick touching N cards should refresh the
  summary once, not N times. Distinct DOM unit → distinct broadcast service,
  matching the guide's "smallest DOM unit" rule for both.
- **Reuse the existing `@pipeline` stream + `StatusHelper` tones.** No new
  channel, no new color vocabulary — the summary is an enhancement layered on
  established plumbing (R3, R6).
- **Priority-ordered resolution** keeps the output a single, unambiguous
  sentence (R1) while still exposing concurrency honestly via `+N more running`
  (never a silent cap).
- **Known follow-ups (explicitly out of scope):** broadcasting from
  `StepRuns::Sweep` for instant stuck flips; live-refreshing the pipeline header
  badge and phase-column badges (today static-on-load — the summary now covers
  the "what's happening" need those didn't).
