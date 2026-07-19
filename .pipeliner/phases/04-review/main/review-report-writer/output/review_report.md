# Live Pipeline Status Summary — Review Report

**Phase:** Review · **Overall:** ✅ ready to merge — every critic finding is resolved in the merge candidate.
**Tests:** ✅ green (112 runs, 408 assertions, 0 failures / 0 errors / 0 skips) · `bin/rubocop` (rails-omakase) clean across 115 files · worker `tsc --noEmit` exit 0.

> **Verdict note (read first).** Two of the three critics ran against the current tree and both **pass** (`test-critic`, `requirements-conformance-critic`). The third, `guide-alignment-critic`, returned `needs_work` but ran one commit **before** `implementer (iteration 4)`, which fixed every item it raised. All four of its findings were re-checked against the committed code and are **resolved** — see [Findings & resolution](#findings--resolution) for the file/line evidence. The merge candidate carries no open findings.

---

## What was asked

Add a single, real-time, continuously-updating status for each pipeline that
summarizes what is happening **right now** in plain language — prominent on the
pipeline board, live via Turbo Streams, and true on page load. Work must follow
`guides/ui-style-guide.md` and `guides/backend-guide.md`.

Define expanded this into 18 business requirements:

- **Placement (R1–R2):** full summary in the detail-page header above the phase
  columns; a compact summary in each row of the pipeline list; both live, neither stale.
- **Wording (R3–R13):** plain-language sentences for every pipeline state — one step
  working (named, with an iteration suffix only on the 2nd+ attempt), two steps (both
  named), three-or-more (phase + count), awaiting human approval (with location),
  complete, failed (with location), not-started, canceled, and an unconditional
  catch-all so the summary is never blank; everyday language, no codes or jargon.
- **Liveness (R14–R16):** every state-changing event pushes the new summary to all open
  pages within seconds without a refresh; pages are true on load; out-of-order events
  converge on the latest state.
- **Presentation (R17–R18):** status carried by words, not color alone; compact and
  full forms can never disagree.

## What was built

A pure-derivation core plus after-commit broadcasting, wired into the existing board.
Feature components (line counts are `git diff` vs `main`):

- **`app/lib/pipelines/status_summary.rb`** (+237) — a *total* derivation PORO.
  `StatusSummary.for(pipeline)` maps whole-pipeline state to one
  `Summary(text, tone, phase_label)` via a first-match ladder (completed → failed →
  canceled → awaiting-human → one/two/many active steps → not-started) ending in an
  unconditional catch-all, so no state is ever blank or wrong. Every branch sources its
  `tone` from the single `StatusHelper::STATUS_TONES` table, so the summary dot and the
  status badge can never diverge.
- **`app/services/pipelines/broadcast_status.rb`** (+23) — after-commit service that
  reloads, re-derives, and replaces the stable `dom_id(pipeline, :summary)` region on the
  existing pipeline stream (reload-and-re-derive makes it order-independent, R16). Wired
  into `StepRuns::Claim` / `RecordProgress` / `Complete`, `Phases::ManagerTick`, **and**
  the human `Phases::Approve` path.
- **`app/views/pipelines/_status_summary.html.erb`** (+29) — one shared partial serving
  both the full (header) and compact (row) surfaces, so R18 holds by construction.
  `aria-live="polite"`; the tone dot is `aria-hidden` and the sentence carries meaning (R17).
- **`app/models/pipeline.rb`** — `with_board` preload scope for N+1-free load-time truth;
  both `pipelines_controller` and the index row rendering use it (R15).
- **Gate-approval path:** `ApprovalsController` → `Phases::Approve` → `Phases::Advance`
  (+ route), each owning its transaction and broadcasting only after commit.
- **Tests:** `status_summary_test.rb` (+277 unit), `pipeline_live_status_test.rb` (+92
  integration), `broadcast_status_test.rb` (+74), plus `approve` / `advance` /
  `manager_tick` service specs and the approvals controller spec.
- **Docs/guide:** `docs/developer-guide.md`, and a `ui-style-guide.md` tone-table row for
  the `aborted → :muted` retone that keeps the shared tone table authoritative.

## Evidence of conformance

| Area | Verdict | Evidence |
|------|---------|----------|
| **Tests & lint** (`test-critic`) | ✅ pass | Full Rails suite 112 runs / 408 assertions / 0 failures / 0 errors / 0 skips; `bin/rubocop` no offenses across 115 files; worker `tsc --noEmit` exit 0. Ran in `RAILS_ENV=test` only; no dev/prod DB commands. |
| **Requirements** (`requirements-conformance-critic`) | ✅ pass | All 18 requirements satisfied with code evidence and empty findings. Total pure PORO covers all wordings incl. never-blank catch-all (R3–R13); one shared partial in header (R1) and rows (R2) from a single source of truth (R18); words carry status with the dot echoing (R17); `with_board` gives load-time truth (R15); reload-and-re-derive broadcast is order-independent (R16); every enumerated event — start, finish/fail, progress, gate-starts-waiting, **and gate-stops-waiting on human approve** — broadcasts (R14). |
| **Guide alignment** (`guide-alignment-critic`) | ⚠️ `needs_work` — **stale** | Ran on the pre-iteration-4 tree. Confirmed the core is strongly guide-aligned (pure derivation PORO homed in `app/lib` with query-style `.for`; single `STATUS_TONES` table; smallest-DOM-unit broadcasts via stable `dom_id`s; load-time truth with streams as enhancement; `aria-live` region with meaning in the sentence; Tailwind type scale / semantic colors). Its four findings are all fixed in the merge candidate (below). |

## Findings & resolution

`guide-alignment-critic (iteration 3)` merged at commit `5bf5563`; `implementer
(iteration 4)` merged after it at `ac66724` and addressed each finding. Verified against
the current committed tree:

| # | Sev | Finding (guide-alignment) | Status in merge candidate |
|---|-----|---------------------------|---------------------------|
| F1 | major | Human gate-approval path never calls `Pipelines::BroadcastStatus`, so non-approving viewers see a stale "awaiting approval" until reload (ui-style-guide "Live by default"). | ✅ **Resolved.** `app/services/phases/approve.rb:35` calls `Pipelines::BroadcastStatus.call(pipeline)` after commit and returns `Result.success(pipeline)`. `requirements-conformance-critic` independently confirmed this closes R14. |
| F2 | minor | `ApprovalsController` branches on `phase.pipeline.reload.completed?` — business branching + a reload to re-derive an outcome the service already produced (backend-guide "Controllers — light"). | ✅ **Resolved.** `Approve` now returns the pipeline; the controller reads `result.value.completed?` (`approvals_controller.rb:12`) — no reload, no re-derivation. |
| F3 | minor | Stray `tmp_run_tests.rb` scaffold committed at repo root (backend-guide "boring, obvious code"). | ✅ **Resolved.** File is absent from the tree and untracked by git. |
| F4 | minor | Compact summary text used off-palette `text-gray-700` (ui-style-guide "Color"). | ✅ **Resolved.** `_status_summary.html.erb` uses `text-gray-500` (compact, secondary) and `text-gray-900` (full, primary); no `gray-700` remains. |

The two backend-atomicity items flagged in the prior review round (own-transaction in
`Phases::Advance`, after-commit deferral of `BroadcastColumn`) are also in place:
`advance.rb:33–36` wraps its writes in `ApplicationRecord.transaction`, and `advance.rb:51`
defers every column broadcast behind `ActiveRecord.after_all_transactions_commit`.

## On the critic discrepancy

`guide-alignment-critic` and `requirements-conformance-critic` appear to disagree about
F1 (whether the approve path broadcasts). This is a **timing artifact, not a live
conflict**: the guide-alignment step ran against `5bf5563`, before the iteration-4
implementer fix at `ac66724`; the requirements and test critics ran after it. The
committed code (`approve.rb:35`) settles it in favor of the later critics — the broadcast
is present. Re-running guide-alignment against the current tree would be expected to pass.

## Recommendation

**Merge.** All three critics' concerns are satisfied in the merge candidate: the feature
is a clean pure-derivation core with a single shared surface, after-commit broadcasting on
every state-changing event (including human approval), load-time truth, and a green
suite + lints. No rework is required. The only caveat is procedural — the
`guide-alignment-critic` verdict on record is stale; a re-run would refresh it, but its
substance is already closed.

---

### Verdict summary

| Critic | Verdict (on record) | Basis | Open findings in merge candidate |
|--------|--------------------|-------|----------------------------------|
| `test-critic` | ✅ pass | current tree | none |
| `requirements-conformance-critic` | ✅ pass | current tree | none |
| `guide-alignment-critic` | ⚠️ needs_work | pre-iteration-4 tree (`5bf5563`) | none — all 4 findings verified resolved |
| **Overall** | **✅ ready to merge** | | **0 open** |
