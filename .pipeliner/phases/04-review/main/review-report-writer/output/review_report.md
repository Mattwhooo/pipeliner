# Review Report — Human-in-the-Loop Pause (Define phase)

_Compiled from the Review-phase critic verdicts: `requirements-conformance-critic`
(**pass**) and `code-quality-critic` (**needs_work** → reworked → resolved).
Suitable for use as the PR description._

## Summary

| | |
|---|---|
| **Feature** | Pause the Define phase mid-run and drive it through a human-in-the-loop menu |
| **Phase** | Review (04) |
| **Requirements conformance** | ✅ **Pass** — all 34 requirements (R1–R34) traced to evidence, no deviations |
| **Code quality** | ⚠️ **Needs_work** at review — 1 major + 2 minor findings, **all three reworked and resolved** in Build iteration 3 |
| **Tests** | ✅ 238 runs / 786 assertions, 0 failures / 0 errors / 0 skips |
| **Lint** | ✅ rubocop-rails-omakase — 151 files, no offenses |
| **Net change** | ~1,135 lines across 28 app/test files (11 new files, 17 modified) |

The feature is functionally complete and conformant. The review surfaced one
correctness bug and two hardening gaps; all three were sent back to Build,
fixed, and re-verified by the test-critic on the current branch. **No open
blocking findings remain.**

---

## What was asked

> It should be possible to pause anytime during the Define phase for human
> feedback, especially the clarifying-questions step. There should be a menu loop
> there of "Explore, Clarifying questions, ask human, repeat from the beginning"
> until done.

The Define phase previously only stopped for a human at its **settled gate**.
This work adds a **second, independent stopping point**: a human can pause Define
at any time while it is running and then work a **menu loop** — Explore,
Clarifying Questions, Ask Human, Repeat from the Beginning, Done — as many times
as they want before finishing.

---

## What was built

The central design move is to make `paused` a **new `Phase.status`** that the
Manager tick already refuses to advance (`return … unless @phase.running?`), and
to model **every menu action as an ordinary `StepRun`** the existing
Worker/Claim/Complete/Merge pipeline already knows how to execute. Almost nothing
about *how work runs* changes; only *when the Manager may keep going on its own*
changes. The change set is strictly additive — no existing status, allow-list
entry, or gate path was removed.

### New files

- `db/migrate/20260718230012_add_pause_support_to_phases.rb` — adds
  `pause_requested`, `pause_requested_at`, `restart_in_progress`,
  `restart_feedback` to `phases`.
- `app/queries/phases/convergence.rb` — read-only "is this phase settled?"
  predicate, extracted from `ManagerTick` so both the tick and `Approve` share
  one source of truth (query object per the backend guide, not a service).
- `app/services/phases/pause.rb` — flags a pause; holds until the in-flight step
  settles, then transitions to `paused`.
- `app/services/phases/rerun_menu_step.rb` — single-step re-run for **Explore**
  (`discovery_notes`) and **Clarifying Questions** (`open_questions`), resolving
  the target step by the **artifact it writes**, not by slug (slugs aren't stable
  across project templates).
- `app/services/phases/restart_define.rb` — **Repeat from the Beginning**;
  reuses `ManagerTick`'s dispatch/route/converge cascade by flipping the phase
  back to `running` for the cascade's duration.
- Test files: `convergence_test.rb`, `pause_test.rb`, `rerun_menu_step_test.rb`,
  `restart_define_test.rb`.

### Modified files

- `app/models/phase.rb` — new `paused` status enum value + shared
  `any_step_active?` overlap guard.
- `app/services/phases/manager_tick.rb` — pause settling, restart cascade
  landing back on `paused`, restart-failure abort, and delegation to
  `Convergence`.
- `app/services/phases/approve.rb` — **Done**: accepts `paused` only when
  `Convergence.phase_settled?` is true (checked live at click-time), else
  `:not_settled`.
- `app/services/phases/answer_questions.rb` — **Ask Human**: allow-list widened
  by one value (`paused`); reuses the existing answer/feedback path unchanged.
- `app/controllers/phases_controller.rb` — `pause` / `rerun_step` / `restart`
  actions (thin: auth + one service call + redirect).
- `app/controllers/approvals_controller.rb` — plain-language `:not_settled`
  message for R21.
- `config/routes.rb` — three new member routes.
- `app/helpers/status_helper.rb` — `paused` tone in the shared status map.
- `app/helpers/define_helper.rb` — inline artifact surfacing for
  `discovery_notes` / `business_requirements` and a menu-failure helper.
- `app/views/pipelines/_define_panel.html.erb` — pause control, the five-item
  paused menu, in-progress and failure states, and inline fresh-result blocks.
- `db/schema.rb` + corresponding test files.

---

## Evidence of conformance

**`requirements-conformance-critic` — verdict: PASS, 0 findings.** All 34
business requirements were traced to concrete evidence in the diff. Highlights:

- **Pausing (R1–R6):** a Pause control shows while running; pause flags a request
  and `ManagerTick#settle_pause` holds only after the in-flight step finishes
  (R2/R3); a paused phase makes `ManagerTick` early-return so the auto loop can't
  advance (R5/R27); paused state is shown with a status badge **and** an explicit
  "Define is paused" label — not color alone (R4).
- **The five-item menu (R7–R19):** Explore / Clarifying Questions re-run the step
  that declares the artifact and surface fresh output inline (R8–R11), with an
  in-progress indicator replacing the menu while any re-run runs (R12); Ask Human
  reuses `AnswerQuestions` to show open questions and fold answers/notes in as
  human-tagged feedback (R13/R14); Repeat from the Beginning restarts from the
  first worker step, shows a "restart in progress" state, overwrites with fresh
  output, carries human feedback forward, and lands back on the paused menu on
  convergence (R15–R19); Done maps to `Approve`, gated live by
  `Convergence.phase_settled?` (R20/R21).
- **Stepping & failure (R22–R26):** each menu action returns to the paused menu;
  a failed re-run keeps the phase paused and surfaces a labeled "Re-run failed"
  badge + message.
- **Safeguards (R27–R30):** `any_step_active?` guards on every menu service plus
  the unique `(step_id, iteration, attempt)` index prevent overlap and
  menu/auto conflicts; manual re-runs bypass `route_to_target`'s max-iterations
  cap so a human action is never itself refused (R28).
- **Existing behavior (R31–R34):** gate approval, send-back rework, and
  clarifying-question answering are left intact and only additively widened.

**Tests & lint (from the Build test-critic, verdict PASS):** `bin/rails test`
runs 238 tests / 786 assertions with 0 failures, 0 errors, 0 skips, including
the new pause/restart coverage; `bin/rubocop` reports no offenses across 151
files; the migration applies cleanly against the isolated test database.

---

## Review findings and their resolution

The `code-quality-critic` returned **needs_work** with three findings. All three
were sent back to Build (implementer iteration 3) and fixed; the test-critic
re-ran green on the resulting branch. Each is documented below with its
resolution on the current HEAD.

### F1 — "Repeat from the Beginning" could skip steps _(major — RESOLVED)_

`app/services/phases/restart_define.rb`

- **Finding:** `RestartDefine` seeded only the first worker step at that step's
  own `iteration max + 1` and delegated the rest to
  `ManagerTick#dispatch_ready_steps`, which dispatches a step only when
  `current_iteration(step) < target_iteration`. Because `RerunMenuStep` and
  `AnswerQuestions` each advance a **single** step's iteration independently, a
  prior menu re-run could leave a later step already at the restart's seed
  iteration — so the cascade would skip it and the restart would regenerate only
  a subset of Define's artifacts, contradicting the feature's promise.
- **Resolution:** `next_iteration` now seeds one past the **highest iteration of
  any worker step in the phase**
  (`worker_steps.flat_map(&:step_runs).map(&:iteration).max + 1`), guaranteeing
  every dependent step in the cascade re-runs rather than being skipped as
  "already current."

### F2 — Human feedback duplicated geometrically across restarts _(minor — RESOLVED)_

`app/services/phases/restart_define.rb`

- **Finding:** `carried_feedback` collected every `from == "human"` feedback
  entry with no de-duplication and re-fanned it onto every dispatched step, so
  repeated "Repeat from the Beginning" loops grew the human-feedback set
  geometrically.
- **Resolution:** `carried_feedback` now applies `.uniq`, bounding the set across
  repeated restarts.

### F3 — `Pause` lacked a Define-phase guard _(minor — RESOLVED)_

`app/services/phases/pause.rb`

- **Finding:** `PAUSABLE_STATUSES` was just `%w[running]` with no
  `define_phase?` guard, so a crafted POST to `/phases/:id/pause` on any running
  non-Define phase would set it to `paused` — a state `Phases::TickAll` skips and
  the board has no UI to resume from, stranding the phase.
- **Resolution:** `pausable?` now requires `@phase.define_phase?` in addition to
  the runnable status, matching the scope of the other menu services
  (`AnswerQuestions#answerable?`).

---

## Accepted trade-offs (documented, not defects)

Called out by the conformance critic and accepted by design:

- **R28 / iteration cap nuance:** manual re-runs share the per-step iteration
  counter the automatic cap reads. This only interacts during a subsequent
  Repeat-from-the-Beginning restart (the auto loop and manual re-runs never run
  in the same phase state otherwise), and the restart-vs-cap fall-through to
  `awaiting_human` is an explicitly documented, accepted design decision. R28's
  core intent — a human menu action is never itself refused or capped — holds.
- **Restart hitting the iteration cap** falls through to the existing
  `awaiting_human` escalation rather than back to `paused`. This is the same
  safety net every other consensus loop already has, and is not one of R25's
  named failure modes ("fails or times out").
- **Scoped to Define, structured to generalize:** no service hardcodes
  `define_phase?` in its cascade logic (the `Pause` guard above is a scope check,
  not cascade logic); extending the pause/menu idea to another phase later is a
  view + routing change, not a service rewrite.

---

## Verdict

- **Requirements conformance:** ✅ Pass — full R1–R34 traceability, no deviations.
- **Code quality:** ⚠️ Needs_work at review (1 major, 2 minor) → **all resolved**
  in Build rework, re-verified by the test-critic.
- **Current branch state:** tests and lint green; all review findings addressed.

**Recommendation: ready to merge.**
