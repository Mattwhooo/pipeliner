# Live Pipeline Status Summary — Review Report

**Phase:** Review · **Overall verdict:** `needs_work` (3 major + 1 minor open finding)
**Tests:** ✅ green (112 runs, 408 assertions, 0 failures/errors/skips) · rubocop clean · worker `tsc --noEmit` clean

---

## What was asked

Add a single, real-time, continuously-updating status for each pipeline that
summarizes what is happening right now in plain language — prominent on the
pipeline board, live via Turbo Streams, and true on page load. Work must follow
`guides/ui-style-guide.md` and `guides/backend-guide.md`.

The Define phase expanded this into 18 business requirements:

- **Placement (R1–R2):** full summary in the detail-page header above the step
  cards; a compact form in each row of the pipeline list; both live, neither stale.
- **Wording (R3–R13):** plain-language sentences for every pipeline state — one
  step working (named, with iteration only on 2nd+ attempt), two steps (both
  named), three-or-more (phase + count), awaiting human approval (with location),
  complete, failed (with location), not-started, paused/canceled, and a total
  catch-all so the summary is never blank; everyday language, no codes or jargon.
- **Liveness (R14–R16):** every state-changing event pushes the new summary to all
  open pages within seconds without a refresh; pages are true on load; out-of-order
  events converge on the latest state.
- **Presentation (R17–R18):** status carried by words not color alone; compact and
  full forms can never disagree.

## What was built

A new pure-derivation core plus after-commit broadcasting, wired into the existing
board. Code change set (excluding pipeline artifacts): **35 files, +1318 / −74**.

- **`app/lib/pipelines/status_summary.rb`** — a *total* derivation PORO. `Summary.for`
  maps whole-pipeline state to one `Summary(text, tone, phase_label)` via an ordered
  branch cascade (completed → failed → canceled → awaiting-human → blocked →
  actively-working → not-started) ending in an unconditional catch-all. Every branch
  sources its `tone` from the single `StatusHelper::STATUS_TONES` table, so the
  summary dot and the status badge cannot diverge (drove the `aborted` `:danger→:muted`
  retone, landed with a matching `guides/ui-style-guide.md` row).
- **`app/services/pipelines/broadcast_status.rb`** — after-commit service that replaces
  the stable `dom_id(pipeline, :summary)` region on the existing pipeline stream. Wired
  into `StepRuns::Claim` / `RecordProgress` / `Complete` and `Phases::ManagerTick`.
- **`app/views/pipelines/_status_summary.html.erb`** — shared full + compact partial,
  `aria-live="polite"`, dot-plus-word via a new `summary_dot_class` helper. Rendered in
  the show header and in each index row.
- **`Pipeline.with_board`** preload scope for N+1-free load-time truth; both controllers
  use it, and the index subscribes per row.
- **New gate-approval path:** `ApprovalsController` → `Phases::Approve` → `Phases::Advance`
  (with `Phases::BroadcastColumn`), plus route.
- **Tests:** `status_summary` unit specs (277 lines), integration board specs, broadcast
  specs, approve/manager_tick service specs, approvals controller specs.
- **Docs:** `docs/developer-guide.md` (+123) and the `ui-style-guide.md` tone row.
- **Worker:** `worker/src/git.ts` and `worker.ts` adjustments (push/config plumbing).

## Evidence of conformance

| Area | Verdict | Evidence |
|------|---------|----------|
| **Tests & lint** (`test-critic`) | ✅ pass | Full Rails suite 112 runs / 408 assertions / 0 failures / 0 errors / 0 skips; `bin/rubocop` (rails-omakase) no offenses across 115 files; worker `tsc --noEmit` exit 0. Test-only env; no DB-mutating commands run. |
| **Requirements** (`requirements-conformance-critic`) | ⚠️ needs_work | 17 of 18 requirements satisfied with concrete evidence — total pure PORO covers all wordings incl. never-blank catch-all (R3–R13), single shared partial in header (R1) and index rows (R2) from one source of truth (R18), words carry status with dot echoing (R17), `with_board` gives load-time truth (R15), reload-and-rerender broadcast is order-independent (R16). One gap (R14 on the human-approval event). |
| **Guide alignment** (`guide-alignment-critic`) | ⚠️ needs_work | Strongly guide-aware: `StatusSummary` a pure derivation PORO correctly homed in `app/lib` with query-style `.for`; tone from the single `STATUS_TONES` table; broadcasts target the smallest DOM unit via stable `dom_id`s; both surfaces true on load with streams as enhancement; dot `aria-hidden` with meaning in an `aria-live` region; Tailwind type scale, eyebrow label, Card, semantic colors all match; `aborted→gray` is a coherent same-PR guide update. Two backend deviations + one minor UI drift. |

## Open findings

Two `major` findings and one `minor`. All three trace back to the write/broadcast
lifecycle of the **new gate-approval path** (`Approve → Advance`); the actively-working
and gate-*starts*-waiting paths are already correct.

### 🔴 Major — R14 liveness hole on human gate approval
*(requirements-conformance F1 — `app/services/phases/approve.rb`, `app/services/phases/advance.rb`)*

`Pipelines::BroadcastStatus` is wired into the step-run and `ManagerTick` paths but **not**
the human-approval path. `ApprovalsController#create → Phases::Approve → Phases::Advance`
transitions the pipeline out of `awaiting_human` (to running/completed) and broadcasts only
the phase columns via `BroadcastColumn` — it never calls `BroadcastStatus`. So after a human
approves a gate, other viewers' detail summaries and every compact list-row keep showing
"Waiting on human approval at the *&lt;phase&gt;* gate" until a manual reload. The approver's
own page is masked only by the controller's full redirect. Scored major (not blocker) because
load-time truth (R15) still holds, so a reload corrects it.
**Fix:** call `Pipelines::BroadcastStatus.call(pipeline)` after commit on the approval/advance
path, mirroring `ManagerTick`'s tail call.

### 🔴 Major — `Phases::Advance` writes are not atomic
*(guide-alignment F1 — `app/services/phases/advance.rb`)*

`Advance` performs two writes on the advance path (`next_phase.update!(status: "running")`
then `pipeline.update!(current_phase:, status:)`) with **no** `ApplicationRecord.transaction`
wrapper. backend-guide: "Services own transactions — a business action is atomic or it isn't
done." From `ManagerTick` these run inside the outer tick transaction, but `Phases::Approve`
calls `Advance` *after* its own transaction commits — so a failure of the second update from
the human path leaves the next phase running while the pipeline still points at the prior
phase (a partially-advanced board state).
**Fix:** wrap `Advance`'s writes in its own transaction so it is atomic for every caller.

### 🔴 Major — Broadcasts fire inside `ManagerTick`'s open transaction
*(guide-alignment F2 — `app/services/phases/manager_tick.rb`, `broadcast_column.rb`)*

`BroadcastColumn.call` is invoked while `ManagerTick`'s `ApplicationRecord.transaction` is still
open (escalate ~L122; gate human branch ~L179; and `Advance`'s broadcasts via
`settle_convergence → reach_consensus → advance_pipeline → Advance.call`, all inside the L41–49
block). backend-guide: "Broadcasts/jobs happen only after the write commits (after_commit
semantics)." `broadcast_replace_later_to` enqueues a Solid Queue job in a separate DB that can
run before — or despite a rollback of — the tick transaction, repainting stale phase state (the
exact "invisible until reload" failure this feature fixes). Notably the tick's own
`broadcast_affected` and `Pipelines::BroadcastStatus` are already correctly placed *after* the
block, so this is an internal inconsistency.
**Fix:** move the in-transaction `BroadcastColumn` calls (and `Advance`'s broadcasts) to after
commit.

### 🟡 Minor — Gate approve button/input styled ad hoc
*(guide-alignment F3 — `app/views/pipelines/_phase_column.html.erb`)*

The gate approve button and note input use inline Tailwind (`px-2 py-1.5 text-xs`,
`ring-amber-600/30`) rather than the guide's shared button/form specs
(`bg-indigo-600 … px-3 py-2 text-sm font-semibold`; input `ring-1 ring-gray-300
focus:ring-2 focus:ring-indigo-600`), violating "one source of truth per component."
**Fix:** build these from the shared button/input component (or an explicitly-approved
compact variant added to the guide).

## Recommendation

Address the three items above before merge. The two `major` findings share a root
cause — the new approval/advance path does not follow the after-commit + owned-transaction
+ broadcast-status pattern the rest of the code already uses — so a single focused pass on
`Phases::Approve` / `Phases::Advance` (own transaction, after-commit broadcasts, add the
`BroadcastStatus` call) closes both R14 liveness and both backend-atomicity deviations. The
minor UI drift is a quick component swap. The core derivation, presentation, load-time truth,
and the tests are solid and require no rework.

---

### Verdict summary

| Critic | Verdict | Findings |
|--------|---------|----------|
| `test-critic` | ✅ pass | none |
| `requirements-conformance-critic` | ⚠️ needs_work | 1 major |
| `guide-alignment-critic` | ⚠️ needs_work | 2 major, 1 minor |
| **Overall** | **needs_work** | **3 major** (all on the approval/advance broadcast + atomicity path), **1 minor** (UI component) |
