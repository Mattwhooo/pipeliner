# Dashboard UI — Review Report

## Summary

Adds a signed-in landing dashboard that gives an at-a-glance overview of active
pipelines and their phase/status, recent activity across the user's projects, and
worker-fleet health — plus an in-place modal for answering a pipeline's open
questions when it is waiting on a person. Live updates arrive over Turbo Streams
without a manual reload.

**Review status: approved with follow-ups.** Requirements conformance passes on all
50 requirements; the Build phase's tests and lint are green. The code-quality
critic's `needs_work` verdict was driven purely by performance/consistency findings
(no correctness or security defects) — **all four have since been fixed and were
re-verified against the current code for this report.** What remains open are **six
minor UI/style-guide conformance items** (palette drift, badge-helper reuse, a
helper-vs-PORO placement, empty-state actions, off-scale spacing values, and one
deliberate polling deviation) — none change behavior, none block merge.

---

## What was asked

> Add a dashboard UI that gives an at-a-glance overview: active pipelines and their
> current phase/status, recent activity, worker fleet health.

Define elaborated the ask into **50 business requirements (R1–R50)** across seven
areas: access & landing, overall layout & headline summary, active-pipelines
overview, recent activity, worker-fleet health, freshness/live-updates,
responsiveness/accessibility, and an in-place "answer open questions" modal
(human-in-the-loop).

## What was built

Scoped to the projects the signed-in user belongs to; read-and-navigate except for
the one supported action (answering open questions).

**Backend (POROs + thin controllers, per `guides/backend-guide.md`)**
- `Dashboard::ActivePipelines`, `Dashboard::RecentActivity`, `Dashboard::FleetHealth`
  — three query objects that assemble the panels' data.
- `Dashboard::Broadcast` — a per-user broadcast service wired into post-commit call
  sites (approve, rework, finalize, step completion, manager tick, sweep, card
  broadcast, column broadcast) so panels update live.
- `HomeController` (dashboard root + `fleet_health` polling endpoint) and a
  `PhasesController#answers` Turbo Stream branch driving `Phases::AnswerQuestions`.
- `open_questions_structured` artifact plumbing (seed template, `DefineHelper`,
  artifact-schema docs) so questions render one-per-input.

**Frontend (Tailwind + shared components, per `guides/ui-style-guide.md`)**
- Full `home/` view/partial tree: summary tiles, active-pipelines list with phase
  progress and attention treatments, recent-activity feed, fleet-health panel
  (initial frame + poll fragment), section-error partial, and the answer-questions
  modal.
- Three Stimulus controllers: `dialog`, `answer_questions_form`, `poll_frame`;
  native `<dialog>` overlay for the modal.

**Performance/consistency hardening (in response to the code-quality critic):**
`StepRuns::BroadcastCard.call` gained a `dashboard:` flag so per-worker progress
ticks (`RecordProgress`) skip the full dashboard fan-out;
`Dashboard::RecentActivity`'s four source queries each gained a DB-level
`ORDER … LIMIT`; `Phases::ManagerTick#broadcast_affected` now fires one dashboard
broadcast per tick instead of one per decision; and `StepRuns::Sweep` now broadcasts
both stuck **and** recovered (unstuck) pipelines. All four fixes were confirmed
present in the current code while preparing this report.

---

## Evidence of conformance

### Requirements conformance — **PASS** (`requirements-conformance-critic`)

All **50 requirements (R1–R50) satisfied with concrete evidence.** Highlights:

- **Access/landing (R1–R4):** root → `home#index`, `authenticate_user!` with Devise
  return-to, membership-scoped multi-project view with per-item project name, and a
  no-projects empty state.
- **Layout/summary (R5–R7):** three separated panels; headline tiles for
  active/attention/online counts always rendered, including zeros.
- **Active pipelines (R8–R18):** scoped to `running/awaiting_human/blocked/stuck`
  (excludes draft/completed/aborted); title+project, 4-segment phase progress with
  current-phase label, plain-language status badge that always shows the status word
  (meaning never relies on color alone — R12/R35), amber "Needs your input" vs red
  "Stuck" treatments, relative last-active time, full-row deep link, empty state,
  attention-first then recency sort capped at 10 with a "See all" link.
- **Recent activity (R19–R24):** merges approval/rework/manager/step-completion
  events with description+pipeline+project+time, recency-sorted, deep-linked, empty
  state, capped at 15.
- **Fleet health (R25–R30):** online/offline counts, per-worker
  name/status/last-heartbeat, role-coverage-gap warning, no-workers empty state,
  prominent unhealthy banner.
- **Live updates (R31–R33):** per-user post-commit broadcasts for
  rows/summary/activity plus a 30s fleet poll; per-section rescue keeps one panel's
  failure from 500-ing the page; responsive grid reflow (R34).
- **Answer-questions modal (R36–R50):** offered only on answerable `awaiting_human`
  Define phases with structured questions; native `<dialog>` titled with
  pipeline+project; one labeled input per question with the default as placeholder;
  untouched inputs contribute their default, typed inputs override; single
  submission that closes on success and re-opens the Define loop; all-defaults submit
  blocked with approve-instead guidance; cancel/Escape/backdrop leave the pipeline
  untouched; a busy loop returns `:busy` and re-renders the error while preserving
  typed input; focus-trap/Escape/focus-return via native dialog; shared
  Tailwind styling.

### Tests & lint — **PASS** (Build phase `test-critic`)

- Full non-system suite green: **213 tests / 738 assertions, 0 failures/errors**
  (`bin/rails test`, `PARALLEL_WORKERS=1` — the fork-based parallel runner crashes on
  this host's Ruby build, unrelated to app code); covers the new dashboard queries,
  the broadcast service, controllers, and view partials.
- `bin/rubocop` clean (rubocop-rails-omakase) across 152 files, no offenses.
- System tests (`dashboard_test.rb`, `answer_questions_modal_test.rb`) could not be
  executed due to a **local chromedriver v122 / Chrome v150 mismatch** (Selenium
  `SessionNotCreatedError` — an unrelated tooling issue, not an app defect).
  *Follow-up: confirm the system tests run in CI.*

### Guide alignment — **NEEDS_WORK** (`guide-alignment-critic`)

The dashboard is strongly aligned with both guides: business logic lives in query
objects and a `Dashboard::Broadcast` service; controllers stay thin; broadcasts fire
from services after commit and target the smallest DOM unit; the shared
`status_badge` helper carries semantic tones with the status word always shown;
Minitest covers queries/service/controller/system flows; and the two genuinely new
patterns (presentation-boundary rescue, per-user cross-pipeline stream) were added
to the guides in the same PR as CLAUDE.md requires. The `needs_work` verdict rests
entirely on six **minor** conformance items (see Open findings) — no blockers or
majors.

### Code quality & security — **NEEDS_WORK on record; all findings verified RESOLVED** (`code-quality-critic`)

No correctness-breaking or security defects were found. Verified by the critic: all
dashboard queries are correctly membership-scoped, `PhasesController#answers` stays
authorized via `membership_scoped_phase`, the fleet `html_safe` output is
pre-escaped via `content_tag`, all referenced model enums/methods exist, and the
sweep's capture-ids-before-`update_all` ordering is sound. The `needs_work` verdict
was driven entirely by four performance/consistency findings.

**Note on freshness:** this critic ran at **iteration 1**, i.e. *before* the four
fixes landed, so its recorded verdict predates them. All four are present in the
current code and were each re-confirmed while writing this report (see Resolved
findings below) — which is why they are reported here as resolved rather than open.

---

## Resolved findings (code-quality critic — verified fixed in current code)

| ID | Severity | Location | Finding | How it was resolved (verified) |
|----|----------|----------|---------|---------------------|
| **CQ-1** | major | `app/services/step_runs/broadcast_card.rb` | Write-amplification: `Dashboard::Broadcast` ran on every card update, including `RecordProgress` progress ticks, recomputing the full active-pipeline tree + fleet health per project member. | `BroadcastCard.call` now takes `dashboard:` (default true); progress-tick callers (`record_progress.rb:28`, `complete.rb:54,93`) pass `dashboard: false`, so ticks no longer trigger the dashboard fan-out (`broadcast_card.rb:11,21`). |
| **CQ-2** | major | `app/queries/dashboard/recent_activity.rb` | Unbounded reads: the four event sources queried with no DB `LIMIT`/window, materialized every row, merged, then kept `first(15)` — working set grew with total history. | Each source query now carries `.order(<ts> :desc).limit(LIMIT)` at the DB before the Ruby merge; the global top-N can never need more than `LIMIT` rows from any single source (`recent_activity.rb:38,49,57,67`). |
| **CQ-3** | minor | `app/services/step_runs/sweep.rb` | Asymmetric broadcasting: newly-stuck pipelines were broadcast, but pipelines flipped stuck→ready via `unstuck` were not, so a recovered pipeline kept a stale "Stuck" row until an unrelated event. | Sweep now captures `unstuck_pipeline_ids` before its `update_all` and broadcasts the union of stuck + unstuck ids (`sweep.rb:57–64`). |
| **CQ-4** | minor | `app/services/phases/manager_tick.rb` | Redundant fan-out: `@affected_decisions.each { Dashboard::Broadcast.call(...) }` fired the identical per-member broadcast once per decision. | Replaced with a single `Dashboard::Broadcast.call(...) if @affected_decisions.any?` (`manager_tick.rb:282`). |

---

## Open findings (UI/style-guide conformance — all minor, non-blocking)

These are the six conformance items raised by `guide-alignment-critic` against
`guides/ui-style-guide.md` / `guides/backend-guide.md`. All are **minor**, none
affect behavior, and all were re-confirmed still present in the current build.

| ID | Severity | Location | Issue | Suggested fix |
|----|----------|----------|-------|---------------|
| **UI-1** | minor | `app/views/home/_pipeline_row.html.erb:10,29` | Palette drift from the reserved status scale: the attention border uses `border-red-500` and completed-phase progress segments use `bg-green-500`, but the guide's status table mandates `red-600` (stuck/failed) and `green-600` (success/converged). The sibling `border-amber-500` / `bg-indigo-600` are correct. | Use `border-red-600` and `bg-green-600` for the semantic status fills. |
| **UI-2** | minor | `app/views/home/_pipeline_row.html.erb:18–19` | The "Needs your input" / "Stuck" attention pill hand-rolls the full soft-badge class string instead of the shared `status_badge` helper — "one source of truth per component." `status_badge("awaiting_human", label: "Needs your input")` and `status_badge("stuck")` produce the same pill (the only extras are `gap-1` + a decorative ● dot; the inline copy also omits the helper's `ring-inset`). | Render via `status_badge`, extending the helper if the dot/gap is desired, so the two can't drift. |
| **UI-3** | minor | `app/helpers/define_helper.rb:14,40` | Business logic in a view helper: `define_open_questions_structured` / `latest_structured_questions_run` select the authoritative `StepRun` across phases/workflows (`flat_map` + `max_by` on iteration/attempt/id) and JSON-parse the payload — and duplicate the near-identical run-selection in `latest_open_questions_run`. Per backend-guide, this belongs in a reusable PORO callable from controllers/jobs/console/tests. | Extract the run-selection + parse into a query/domain object; have both helpers delegate to it. |
| **UI-4** | minor | `_active_pipelines.html.erb:16`, `_recent_activity.html.erb:13`, `_fleet_health_content.html.erb:9` | Empty states omit the icon and primary action the guide requires ("icon + one sentence + primary action; never a bare empty table"). "No projects yet" in `index.html.erb` includes an action, but "No active pipelines", "No recent activity", and "No workers connected" are text-only — an inconsistency within the same PR. | Add an icon + primary action (or an intentional, guide-consistent rationale) to each of the three bare empty states. |
| **UI-5** | minor | `app/views/home/_fleet_health.html.erb:1`, `app/javascript/controllers/poll_frame_controller.js` | The worker-fleet panel stays current via fixed-interval client polling (`turbo_frame_tag src:` + `poll_frame_controller.js`, 30s) rather than Turbo Stream broadcasts, a departure from the stream-first "Live by default" principle. **Deliberate, documented deviation:** worker heartbeats don't broadcast to the dashboard and per-heartbeat fan-out would storm; it still avoids a manual refresh. Unlike the two sanctioned new patterns, neither guide was amended to allow the poll fallback. | Borderline — a **manager decision** on whether to keep the documented polling or move worker-state to stream-driven updates, with a one-line guide note either way. |
| **UI-6** | minor | `_pipeline_row.html.erb:25,29,46`, `_activity_item.html.erb:4`, `_fleet_health_content.html.erb:36` | Off-scale spacing values. The guide's Layout rule is "stick to Tailwind steps 2, 4, 6, 8, 12 … avoid one-off values." The dashboard partials use sub-scale steps outside that set: `mt-0.5` (`pipeline_row:25`, `activity_item:4`, `fleet_health_content:36`) and `py-1.5`/`h-1.5` (`pipeline_row:29,46`). The badge `py-0.5` is separately sanctioned by the StatusBadge spec, but these are not; the small button at `pipeline_row:46` also uses `py-1.5` where the guide's button spec is `px-3 py-2`. | Move the flagged values onto the sanctioned scale (e.g. `mt-1`, `h-2`, button `px-3 py-2`), or, where the density is deliberate, propose the sub-scale steps as an explicit guide addition. |

---

## Recommendation

**Merge the feature.** It satisfies all 50 requirements, the Build phase's unit
suite and lint are green, and the four performance/consistency findings that drove
the code-quality `needs_work` verdict have been fixed and independently re-verified
in the current code (no correctness or security defects at any point).

The six remaining items are all **minor UI/style-guide conformance** cleanups that
don't affect behavior. UI-1 (palette), UI-2 (badge helper), and UI-6 (off-scale
spacing) are quick, low-risk edits worth folding in; UI-3 (helper→PORO) is a small
refactor; UI-4 (empty-state icon + action) is a consistency pass across three
partials; **UI-5 (fleet polling vs streams) needs a manager decision** — it is a
deliberate, documented deviation, not an oversight. Confirm the two system tests
execute in CI (the local chromedriver/Chrome mismatch was environmental).
