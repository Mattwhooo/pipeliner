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

### Requirements source

The business requirements for this task exist at
`.pipeliner/phases/01-define/main/requirements-writer/output/requirements.md`
(**R1–R18**). This step's `input.json` did not wire them in as a
`resolved_input` (`resolved_inputs: []`), but they are the authoritative,
in-repo requirements for this pipeline, so every component below cites them by
their real IDs rather than restating the ask. The mapping used throughout:

| ID | Requirement (abridged) |
|----|------------------------|
| **R1** | Full summary above the per-step cards, in the detail page header — first status on the page. |
| **R2** | Compact summary on each row of the pipeline list; both surfaces live, neither stale/static. |
| **R3** | One step working → name phase, step, and what it's doing ("Define: requirements-writer is drafting requirements"). |
| **R4** | State the attempt number **only on the 2nd+ attempt** ("iteration 3"); **hide it on the first attempt**. |
| **R5** | Two steps working → **name both**. |
| **R6** | Three or more steps working → state **phase + count** ("Build: 4 steps are running"), not each name. |
| **R7** | Waiting on a person to approve/reject → say it's waiting on human approval **and where**. |
| **R8** | All work finished successfully → say the pipeline is complete. |
| **R9** | Stopped by an error, can't continue on its own → say it **failed** and **name the phase/step** where it stopped. |
| **R10** | Exists but no work started → say it hasn't started. |
| **R11** | Deliberately paused/canceled by a person → say so plainly ("Paused" / "Canceled"). |
| **R12** | Any other/uncovered/future state → still a defined, truthful sentence; **never blank, missing, or wrong**. |
| **R13** | Everyday language; no internal codes, IDs, or jargon. |
| **R14** | Any event changing activity pushes the new state to every open page within seconds, without viewer action. |
| **R15** | On load/reload, the summary already reflects true current state even if no event ever arrives. |
| **R16** | Out-of-order / rapid events settle on the actual latest state; a newer state is never overwritten by an older one. |
| **R17** | Status recognizable by its **words**, not color alone. |
| **R18** | Compact form conveys the **same** state as the full form; the two never disagree. |

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
  gate (`approved`/advance), and `escalate` → `awaiting_human`. Its `call`
  finishes with `broadcast_affected` (per-card) + `BroadcastColumn` (per-phase).
- `StatusHelper::STATUS_TONES` / `TONE_CLASSES` already map status strings to the
  guide's semantic colors (info/success/attention/danger/muted) and
  `status_badge` renders the color-plus-word badge.
- `StepRun` has `state`, `iteration`, `attempt`, `progress` (JSONB, worker's
  latest `progress["message"]`), and `worker` (current claimant while leased).
- **Pipeline status enum** (canonical, `app/models/pipeline.rb`): `draft`,
  `running`, `awaiting_human`, `blocked`, `stuck`, `completed`, `aborted`.
  `aborted` is the deliberate cooperative-cancel signal (see
  `StepRuns::Heartbeat#pipeline_aborted?`). **Phase status enum** includes
  `failed` — the schema's representation of an error stop. There is **no
  `paused` status** today (see §3.1 note on R11).

**Missing (the gap this design fills):**

1. No object turns whole-pipeline state into a sentence (R3–R12).
2. Nothing broadcasts a **pipeline-level** summary; only individual step cards
   and phase columns broadcast. Phase/pipeline status transitions in
   `ManagerTick` (consensus, gate wait, escalate) do not refresh any
   pipeline-wide summary — so a gate-wait or escalation would be invisible until
   reload (R14).
3. The board has no prominent single-line status element (R1); the index list
   shows a bare status badge, not what's happening (R2).

---

## 3. Component design

```
Controller (thin: preload + render)                        [R1, R2, R15]
  pipelines#show / #index
      └─ renders _status_summary (on load, true state)
             └─ Pipelines::StatusSummary.for(pipeline)  → Summary value  [R3–R13]

Turbo stream (per pipeline, already subscribed on show)     [R14, R16]
  Pipelines::BroadcastStatus.call(pipeline)
      └─ broadcast_replace_later_to(pipeline, dom_id(pipeline,:summary), _status_summary)
   called after commit from:
      StepRuns::Claim / RecordProgress / Complete   (run transitions)
      Phases::ManagerTick                           (phase/gate/pipeline transitions)
```

### 3.1 `Pipelines::StatusSummary` — domain PORO (R3–R13)

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
    # `text` is a complete plain-language sentence (R13) and is NEVER blank (R12).
    Summary = Data.define(:text, :tone, :phase_label) do
      def to_s = text
    end

    # Tone is NEVER a per-branch literal. Every branch resolves its `tone` by
    # looking the governing status string up in `StatusHelper::STATUS_TONES`
    # (the same table `status_badge` uses), so the summary dot and the
    # pipeline's status badge can never show different colors for the same
    # state (ui-style-guide "one source of truth per component"; "status colors
    # are semantic and reserved"). Status-driven branches key on
    # `pipeline.status`; the failed branch keys on the failed phase's status
    # ("failed"). See the F1 resolution in §8 for the one table change this
    # requires (aborted → :muted): see §3.4 and §8b.

    def self.for(pipeline) = new(pipeline).build

    def initialize(pipeline) = @pipeline = pipeline

    def build
      # returns a Summary; see resolution order below.
      # The final branch is an unconditional catch-all, so `build` always
      # returns a non-blank Summary for any status (R12).
    end
  end
end
```

**Resolution order** (first match wins — most operationally salient first). The
order is defined so that every reachable pipeline/phase/run state resolves to
exactly one branch, and the last branch is an unconditional default (R12).

1. **Completed** — `pipeline.completed?` → `"Completed"` (success). *(R8)*

2. **Failed (error stop)** — an error has stopped the pipeline and it cannot
   continue on its own. Detected by a **`failed` phase** (`phases.any?(&:failed?)`)
   or a run left in `failed`/`stuck` that halts progress. Names where it stopped:
   - Prefer the failed step: `"Failed in <Phase>: <role> could not complete"`.
   - No identifiable step, only a failed phase:
     `"Failed in <Phase>"`.
   - Tone: `STATUS_TONES.fetch("failed", :danger)` → **`:danger`** (keyed on the
     failed phase's status, since the pipeline row may still read `running`/`stuck`).
     This branch **always names the phase (and step when known)** and uses failure
     wording, distinct from the deliberate cancellation below — an error stop stays
     red; a deliberate cancel is muted. *(R9)*

3. **Canceled / Paused (deliberate)** — a person stopped it, not an error.
   - `pipeline.aborted?` → `"Canceled"` (the cooperative-cancel state; see
     `StepRuns::Heartbeat`).
   - If a `paused` state is later added to the enum, it maps here to
     `"Paused"`. *(No `paused` status exists in the schema today; only
     `aborted`→"Canceled" is reachable now. This branch is written state-driven
     so the "Paused" wording activates automatically if/when that state lands,
     and until then R12's default — branch 8 — covers any interim value. Called
     out so the schema gap is explicit, not hidden.)*
   - Tone: `STATUS_TONES.fetch("aborted", :muted)` → **`:muted`**. This requires
     the one-line F1 reconciliation (§3.4, §8b): `StatusHelper::STATUS_TONES` maps
     `"aborted"` to `:danger` today, which would make the summary dot (gray) and
     the pipeline `status_badge` (red) disagree for the *same* aborted pipeline.
     Because a deliberate cancel is a neutral terminal state — not the error stop
     that red is reserved for (R9 / branch 2) — we retone `"aborted" => :muted`
     at the single source and propose the matching guide row, so **both** the
     badge and the summary now read gray. *(R11, and see §8/§5.)*

4. **Awaiting human** — `pipeline.awaiting_human?`:
   - A gate awaiting a person's approval (phase in `consensus`/`approved` with
     `gate_human?` and no recorded `Approval`) →
     `"Waiting on human approval at the <Phase> gate"`. *(R7)*
   - An escalation (phase parked at `awaiting_human` from
     `ManagerTick#escalate`, max iterations reached) →
     `"Paused at <Phase>: needs human guidance"`.
   - Tone `:attention`.

5. **Blocked / stuck (recoverable, no worker)** — `pipeline.blocked?` /
   `pipeline.stuck?`, or a current run in `stuck` while the pipeline is otherwise
   live → `"Blocked at <Phase>: <role> has no available worker"` (danger). This
   is distinct from R9: it is a recoverable wait for capacity, not an error the
   pipeline failed on; it is a real state given a truthful sentence per R12. *(R12)*

6. **Running — actively working steps.** When `pipeline.running?`, compute the
   **active set** = runs in the current phase whose `state` is `running` or
   `claimed` (leased = a worker is actually on it). Let `active` be that set,
   ordered by salience (`running` before `claimed`, tie broken by most-recent
   `updated_at`). Branch on `active.size`:

   - **1 active** → `"<Phase>: <role> is <doing>[, iteration <n>]"` *(R3, R4)*.
     - `<doing>` = the run's `progress["message"]` when present; otherwise a
       type verb (`planner→planning`, `builder→building`, `critic→reviewing`,
       `manager→coordinating`, `gate→awaiting review`).
     - **`, iteration <n>` is appended only when `run.iteration > 1`.** On the
       first attempt (`iteration == 1`) no number is shown, keeping the common
       first pass short (R4). Example first pass: *"Define: requirements-writer
       is drafting requirements"*; second pass: *"…, iteration 2"*.

   - **2 active** → **name both** *(R5)*:
     `"<Phase>: <roleA> is <doingA>[, iteration <nA>] and <roleB> is <doingB>[, iteration <nB>]"`.
     Each clause uses the same `<doing>` rule and the same `n > 1` iteration
     suffix as the 1-active branch (R4 applies per step). Both `roleA` and
     `roleB` are named; neither is hidden behind a count.

   - **≥3 active** → **phase + count only** *(R6)*:
     `"<Phase>: <N> steps are running"` (e.g. *"Build: 4 steps are running"*).
     No individual step is named at this threshold.

   - Tone `:info` (blue) for all three sub-branches.

   - **`pipeline.running?` but the active set is empty** (a momentary lull
     between transitions) → fall through to branch 8 so a truthful sentence is
     still produced (never blank). See R12 note there.

7. **Not started** — `pipeline.draft?` (or a `pending` phase) with no runs →
   `"Not started"` (muted). *(R10)*

8. **Default catch-all (R12) — unconditional.** For any status not matched above
   (including a `running` pipeline with a momentarily empty active set, and any
   status added to the enum in the future), return a truthful generic sentence
   built from the real state, never blank:
   `"<Pipeline status, humanized>"` scoped to the current phase when known —
   e.g. `"Working in <Phase>"` for a running-but-idle moment, or
   `"<status.humanize>"` as the final fallback (tone from
   `StatusHelper::STATUS_TONES.fetch(status, :muted)`). Because this branch has
   no guard, `build` is **total**: every pipeline resolves to a non-blank
   `Summary.text`. *(R12)*

**Wording / plain language (R13):** `<Phase>` is `phase.kind.humanize`
("Define"/"Plan"/"Build"/"Review"); `<role>` is `step.role` (the human-readable
worker-matching label, e.g. `requirements-writer`, as used in the ask's own
examples). No raw enum codes, IDs, or `dom_id`s appear in `text`.

**Displayed attempt number (R4):** the number shown is `step_run.iteration` (the
consensus-loop counter, matching the ask's "iteration 3" example and the
existing card), rendered only when `iteration > 1`.

All branches read only preloaded associations, so on `show` (which preloads the
full tree via `.with_board`, §3.5) the derivation adds **zero** queries.

### 3.2 `Pipelines::BroadcastStatus` — service (R14, R16)

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
pipeline by GlobalID — so the broadcast always paints freshly-derived state from
the database at render time. Two consequences:

- A lost or racing broadcast is cosmetic, never wrong: the page also renders
  true state on load (R15).
- Because each broadcast re-derives from current DB state (not from a snapshot
  captured when the event fired), a late-arriving broadcast still renders the
  *actual latest* state, so a newer state is not overwritten by an older event
  (R16). Turbo replaces the whole `dom_id(pipeline,:summary)` node each time, so
  the last render to land shows current truth.

The re-render is for a single pipeline, so the summarizer's lazy association
loads are a few queries in the broadcast path — acceptable; the partial does not
need eager loading there.

**Call sites** (each fires **once per committed business action**, after the
write, per backend-guide side-effect ordering — R14):

| Seam (existing file) | Why | Edit |
|---|---|---|
| `StepRuns::Claim#call` | run `ready→claimed` (a step starts) | one line after `BroadcastCard.call(run)` |
| `StepRuns::RecordProgress#call` | new `progress`/iteration (the high-frequency "…drafting, iteration 3" update) | one line after `BroadcastCard.call` |
| `StepRuns::Complete#call` | run `succeeded/failed` | one line after `BroadcastCard.call` |
| `Phases::ManagerTick#call` | phase/gate/pipeline transitions: consensus, gate-wait, escalate→`awaiting_human`, advance/`completed` — none of which touch a run's card | one line at end of `call`, after `broadcast_affected` (post-commit) |

The `ManagerTick` seam is essential: gate-wait and escalation change **only**
phase/pipeline status, so without it "Waiting on human approval at the Plan
gate" would never appear live (R7, R14). `BroadcastCard` is intentionally left
single-purpose (one card); the summary is a separate DOM unit with its own
service, so a tick that touches N cards still refreshes the summary exactly once
rather than N times.

> Note (not in scope, called out): `StepRuns::Sweep` uses bulk `update_all` and
> broadcasts nothing today, so a `ready→stuck` flip surfaces on the next
> `ManagerTick` (≤10s) or reload rather than instantly. Acceptable; adding a
> sweep-side broadcast is a follow-up, noted so it isn't mistaken for covered.

### 3.3 Views (R1, R2, R15, R17, R18)

**`app/views/pipelines/_status_summary.html.erb`** — one source of truth for the
element, in two variants via a `compact:` local. Both variants call the **same**
`Pipelines::StatusSummary.for(pipeline)`, so the full and compact surfaces can
never disagree about the state (R18).

- Root: `<div id="<%= dom_id(pipeline, :summary) %>" aria-live="polite">` — the
  stable stream target and the accessibility live region
  (ui-style-guide "Live regions: progress updates in `aria-live=\"polite\"`").
- Computes `summary = Pipelines::StatusSummary.for(pipeline)`.
- **Full variant (show):** a `Card` surface
  (`rounded-lg border border-gray-200 bg-white p-6 shadow-sm`) with a small
  status dot (semantic tone) **always paired with the summary sentence and an
  eyebrow phase label — status is conveyed by the words, never color alone**
  (R17); the sentence in `text-sm`; the eyebrow phase label in
  `text-xs uppercase tracking-wide text-gray-400`. Type scale, spacing steps
  (`p-6`, `gap-4`), and neutrals are all from the guide.
- **Compact variant (index cell):** single line — dot + `summary.text` truncated
  (`truncate text-sm text-gray-700`). The dot repeats the tone but the word
  carries the meaning (R17).
- Tone → dot color via a tiny helper (see 3.4) reusing `TONE_CLASSES`, so no new
  color literals are introduced.

**`app/views/pipelines/show.html.erb`** — render the full summary **prominently
in the header area, above the per-step cards / phase grid** so it is the first
status on the page (R1). Keeps the existing `turbo_stream_from @pipeline`.

```erb
<%= render "pipelines/status_summary", pipeline: @pipeline, compact: false %>
```

**`app/views/pipelines/index.html.erb`** — replace the plain "Status" badge cell
(or add a cell) with the compact summary so each row says what's happening, and
add a per-row `<%= turbo_stream_from pipeline %>` so the list updates live too
(the index has no subscription today) (R2, R14).

### 3.4 Helper + tone reconciliation (R17, F1)

Add **`app/helpers/pipelines_helper.rb`** (file exists, empty) with
`summary_dot_class(tone)` returning the dot's Tailwind classes derived from
`StatusHelper::TONE_CLASSES` — keeps semantic color in one place.

**`app/helpers/status_helper.rb` — one-line retone (F1).** Change
`STATUS_TONES["aborted"]` from `:danger` to `:muted`. This is the single fix
that makes the aborted state consistent everywhere: the summary dot sources its
tone from `STATUS_TONES` (§3.1), and so does the pipeline `status_badge`
(`status_badge(@pipeline.status)` in `show.html.erb`/`index.html.erb`) — so
retoning at this one table is sufficient for both to read gray. It also encodes
the design's own R9-vs-R11 distinction in the shared table: red (`:danger`)
stays reserved for `stuck`/`failed`/`blocked` (error stops needing
intervention), while a deliberate `aborted` cancel becomes `:muted` (a neutral
terminal state, like `draft`/`pending`). Because the ui-style-guide color table
has no "deliberately canceled" row today, we **propose that guide addition in the
same PR** per CLAUDE.md ("if the guide is silent, follow its principles, then
propose a guide addition") — see §5.

### 3.5 Model (R15)

Add a preloading scope to **`app/models/pipeline.rb`** so both controllers avoid
N+1 without duplicating the include tree (a persistence concern — allowed in the
model per backend-guide "Models: associations, scopes"):

```ruby
scope :with_board, -> {
  includes(phases: { workflows: { steps: { step_runs: :worker } } })
}
```

### 3.6 Controllers (R1, R2, R15)

- `PipelinesController#show`: swap the ad-hoc `includes(...)` for `.with_board`
  (behavior-preserving); no other change — the summary renders inline on load
  (R15).
- `PipelinesController#index`: add `.with_board` to the query so the compact
  summary derives without N+1.

Both stay ≤10 lines, one primary ivar, no business branching (backend-guide
"Controllers — light").

---

## 4. Data model

**No migration.** The summary is a *derivation* of existing columns; adding a
denormalized column would create a second source of truth that could drift from
the run/phase state the guide treats as canonical (and would risk R12's "never
describe a state the pipeline is not actually in"). Inputs consumed, all
existing:

- `pipelines.status`, `pipelines.current_phase`
- `phases.kind`, `phases.status` (incl. `failed`, `awaiting_human`),
  `phases.gate_mode`, and `approvals` (gate wait vs. approved)
- `steps.role`, `steps.step_type`
- `step_runs.state`, `step_runs.iteration`, `step_runs.progress` (JSONB
  `message`), `step_runs.worker_id`, `step_runs.updated_at`

The `Summary` `Data` value is the only new "type," and it is in-memory only.

**Note on R11 / schema gap:** distinguishing a deliberate stop (R11) from an
error stop (R9) currently rests on `aborted` (cancel) vs. a `failed` phase
(error). This distinction is now also reflected in **color**: the F1 retone
(§3.4) moves `aborted` from `:danger` to `:muted` in the shared
`STATUS_TONES` table, so a deliberate cancel reads gray (neutral terminal state)
while error stops keep the reserved red — and the summary dot and pipeline badge
agree because both read that one table. There is no `paused` pipeline status, so
"Paused" wording is designed but not yet reachable (§3.1 branch 3). If product
wants a real pause, a `paused` enum value + the branch's existing mapping is the
follow-up; until then R12 guarantees any interim value still renders truthfully.
This is a conscious, called-out limitation, not silent under-coverage.

---

## 5. File-level change plan

**New**

| File | Purpose | Reqs |
|---|---|---|
| `app/lib/pipelines/status_summary.rb` | Derive the plain-language `Summary` value from pipeline state (total function; catch-all default). | R3–R13 |
| `app/services/pipelines/broadcast_status.rb` | After-commit Turbo broadcast of the summary partial to the pipeline stream. | R14, R16 |
| `app/views/pipelines/_status_summary.html.erb` | Summary element (full + compact), `dom_id(pipeline,:summary)`, `aria-live`, dot+word. | R1, R2, R15, R17, R18 |

**Edited**

| File | Change | Reqs |
|---|---|---|
| `app/models/pipeline.rb` | Add `scope :with_board`. | R15 |
| `app/controllers/pipelines_controller.rb` | `#show`/`#index` use `.with_board`. | R1, R2, R15 |
| `app/views/pipelines/show.html.erb` | Render full summary prominently in the header, above the cards. | R1 |
| `app/views/pipelines/index.html.erb` | Render compact summary per row + `turbo_stream_from pipeline`. | R2, R14 |
| `app/helpers/pipelines_helper.rb` | `summary_dot_class(tone)` reusing `TONE_CLASSES`. | R17 |
| `app/helpers/status_helper.rb` | Retone `STATUS_TONES["aborted"]` `:danger`→`:muted` so the summary dot and the pipeline `status_badge` agree on the aborted state (single source of truth). | R17, F1 |
| `guides/ui-style-guide.md` | Add a "deliberately canceled / aborted → gray (muted)" row to the Color status table, distinguishing a deliberate cancel from the red-reserved `stuck`/`failed`/`blocked` error stops (guide addition in the same PR, per CLAUDE.md). | R17, F1 |
| `app/services/step_runs/claim.rb` | `Pipelines::BroadcastStatus.call(pipeline)` after card broadcast. | R14 |
| `app/services/step_runs/record_progress.rb` | Same, after card broadcast. | R14 |
| `app/services/step_runs/complete.rb` | Same, after card broadcast. | R14 |
| `app/services/phases/manager_tick.rb` | `Pipelines::BroadcastStatus.call(@phase.pipeline)` at end of `call`. | R14, R7 |

**Tests** (Minitest; backend-guide "Test services as the primary unit… system
tests cover the critical flows… the pipeline board")

| File | Coverage | Reqs |
|---|---|---|
| `test/lib/pipelines/status_summary_test.rb` | State table → expected `text`/`tone`: one step working (**iteration hidden when 1, shown when >1** — R4); two steps → **both named** (R5); three+ steps → **"<Phase>: N steps are running"** (R6); gate human-wait (R7); escalation; completed (R8); **failed → names phase/step + failure wording, tone `:danger`** (R9); not started (R10); **aborted → "Canceled", tone `:muted`** (R11); running-but-idle and an unknown/synthetic status → **non-blank default** (R12); plain-language/no-codes assertion (R13). **Tone-source consistency (F1):** for each state assert `summary.tone == StatusHelper::STATUS_TONES.fetch(<governing status>)`, and specifically that an aborted pipeline's `summary.tone` equals the tone `status_badge` would use for `pipeline.status` — both `:muted`, never one gray and one red. | R3–R13, F1 |
| `test/services/pipelines/broadcast_status_test.rb` | Asserts one `turbo_stream` replace enqueued to the pipeline targeting `dom_id(pipeline,:summary)`; re-render reflects current DB state (R16). | R14, R16 |
| `test/services/phases/manager_tick_test.rb` (extend) | A gate-wait / escalate tick broadcasts the summary. | R14, R7 |
| `test/services/step_runs/{claim,record_progress,complete}_test.rb` (extend) | Each transition also broadcasts the summary. | R14 |
| `test/integration/pipeline_live_status_test.rb` (`ActionDispatch::IntegrationTest`) | Board renders one `dom_id(pipeline,:summary)` region with true current state on load (R15), names phase/step/iteration (R3–R4), the region is `aria-live="polite"` (R17), a `turbo-cable-stream-source` subscription is present (R14 wiring), gate-wait wording appears (R7), and the index row carries the same compact summary (R2, R18). | R1, R2, R7, R14, R15, R17, R18 |

**Testing-strategy note (F2 — explicit deviation).** backend-guide "Testing" names
*system tests* for the critical board flow, but **the repo has no system-test base
class** (`test/system/` and `application_system_test_case.rb` do not exist; there is
no Capybara/driver setup). The board's live-summary flow is therefore covered by the
full-stack **request spec** `test/integration/pipeline_live_status_test.rb` (the
spec-writer's output), which does exercise the load-time true state (R15), the
`aria-live` region (R17), the stream-source subscription, and the compact/full
agreement (R18) — everything except the in-browser *in-place* repaint after a live
broadcast, which a request spec cannot drive. This is a **pragmatic substitution,
not a coverage gap**, and it is called out so the deviation from the named
expectation is visible. **Follow-up for Build (out of scope here):** add an
`ApplicationSystemTestCase` base class + `test/system/pipeline_status_summary_test.rb`
to verify the end-to-end in-place live update in a real browser; the request spec
stands in until then.

---

## 6. Interfaces (signatures)

```ruby
Pipelines::StatusSummary.for(pipeline) # => Summary(text:, tone:, phase_label:)
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

- **Derivation PORO, not a DB column (R15, R12).** A stored summary would be a
  second source of truth that drifts from run/phase state and needs its own
  backfill + invalidation. Deriving on render/broadcast is always correct and
  cheap on a preloaded tree.
- **Total function with an unconditional catch-all (R12).** The resolution
  order's final branch has no guard, so `build` returns a non-blank sentence for
  every current or future status — the summary can never be blank or describe a
  state the pipeline isn't in.
- **Threshold-based collapse for concurrency (R3/R5/R6).** 1 → full sentence;
  2 → both steps named; 3+ → phase + count. The count form replaces (does not
  append to) a named step, matching R6's "rather than naming each."
- **Failure vs. cancellation are separate branches (R9 vs. R11).** Error stops
  are detected via a `failed` phase / failed run and always name where they
  stopped with failure wording; deliberate stops map from `aborted`→"Canceled"
  (and a future `paused`→"Paused"). They are never conflated.
- **One tone source, not per-branch literals (F1).** Every branch resolves its
  `tone` from `StatusHelper::STATUS_TONES`, the same table `status_badge` reads,
  so the summary dot and the pipeline badge can never disagree for a state.
  Reconciling required exactly one table change — `aborted` `:danger`→`:muted`
  — which also encodes the R9/R11 semantic in color (red reserved for error
  stops, gray for a deliberate cancel) and is proposed as a ui-style-guide row
  in the same PR.
- **Separate `BroadcastStatus` service rather than folding into
  `BroadcastCard`.** Gate-wait and escalation change no card, so a card-only
  hook would miss them (R7/R14); and a tick touching N cards should refresh the
  summary once, not N times. Distinct DOM unit → distinct broadcast service,
  matching the guide's "smallest DOM unit" rule for both.
- **Broadcast re-derives from fresh DB state (R16).** `broadcast_replace_later_to`
  reloads the pipeline in a job before rendering, so the last render to land
  reflects the actual latest state; older events cannot repaint a stale summary.
- **Reuse the existing `@pipeline` stream + `StatusHelper` tones.** No new
  channel, no new color vocabulary — the summary is an enhancement layered on
  established plumbing (R14, R17).
- **No relative timestamp on the summary (F7 / scope).** An earlier iteration
  carried an `as_of` "updated N seconds ago" field on the Summary value. No
  requirement (R1–R18) asks for it, so it has been **removed** to keep the design
  to the stated scope; the live-update requirement (R14) is satisfied by the
  broadcast itself, not by a rendered timestamp. Recorded here as a conscious
  decision rather than a silent change.
- **Known follow-ups (explicitly out of scope):** broadcasting from
  `StepRuns::Sweep` for instant stuck flips; a real `paused` pipeline status to
  make R11's "Paused" wording reachable; live-refreshing the pipeline header
  badge and phase-column badges (today static-on-load — the summary now covers
  the "what's happening" need those didn't); and adding an
  `ApplicationSystemTestCase` base class + a browser system test for the board's
  in-place live repaint (F2 — the request spec covers everything a non-browser
  test can until then).

---

## 8. Feedback resolution (iteration 1 → 2)

| ID | Fix |
|----|-----|
| **F1 (R4)** | §3.1 branch 6: the `, iteration <n>` suffix is appended **only when `iteration > 1`**, in both the 1-active and 2-active branches; first attempt shows no number. |
| **F2 (R5)** | §3.1 branch 6, "2 active": the summary **names both steps** ("<roleA> is … and <roleB> is …"); the `+N more` count form is gone. |
| **F3 (R6)** | §3.1 branch 6, "≥3 active": collapses to **"<Phase>: N steps are running"**, naming no individual step — replacing the old appended-count phrasing. |
| **F4 (R9)** | New §3.1 branch 2 "Failed (error stop)": failure wording **and** the phase (plus step when known), detected via a `failed` phase / failed run; no longer a bare "Aborted". |
| **F5 (R11)** | New §3.1 branch 3 "Canceled / Paused": `aborted`→"Canceled" (deliberate), `paused`→"Paused" when that state exists; distinct from failure. Schema gap called out (§4). |
| **F6 (R12)** | §3.1 branch 8 is an **unconditional catch-all**, making `build` total — every status (incl. running-but-idle and future states) yields a non-blank truthful sentence. |
| **F7 (scope)** | The `as_of` timestamp is **removed** and the decision is recorded in §7; the Summary value no longer carries it. |

## 8b. Feedback resolution (iteration 2 → 3)

| ID | Fix |
|----|-----|
| **F1 (tone source)** | Tone is no longer a per-branch literal: every branch reads `StatusHelper::STATUS_TONES` (§3.1 comment; branches 2, 3, 8), the same table `status_badge` uses. Reconciling the one real conflict — a gray summary dot vs. a red badge for the *same* aborted pipeline — takes a single table change, `STATUS_TONES["aborted"]` `:danger`→`:muted` (§3.4), which also encodes R9-vs-R11 in color (red = error stop; gray = deliberate cancel). The matching ui-style-guide color-table row is **proposed in the same PR** (§5), per CLAUDE.md. `status_summary_test.rb` now asserts `summary.tone` matches `STATUS_TONES` for each state and specifically that aborted's summary tone equals its badge tone (§5 tests). |
| **F2 (test strategy)** | The board flow is covered by the full-stack request spec `test/integration/pipeline_live_status_test.rb` rather than a system test, because **the repo has no system-test base class** (verified: no `test/system/`, no `ApplicationSystemTestCase`). The design's test plan now names that integration spec directly and adds an explicit **testing-strategy note** (§5) marking this as a pragmatic substitution — the request spec exercises load-time true state (R15), the `aria-live` region (R17), the stream subscription, and full/compact agreement (R18); only the in-browser in-place repaint is out of its reach. Adding a system-test base class + browser test is recorded as a Build follow-up (§5, §7). |
