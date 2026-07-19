# Dashboard UI — Review Report

## Summary

Adds a signed-in landing dashboard that gives an at-a-glance overview of active
pipelines and their phase/status, recent activity across the user's projects, and
worker-fleet health — plus an in-place modal for answering a pipeline's open
questions when it is waiting on a person. Live updates arrive over Turbo Streams
without a manual reload.

**Review status: approved with follow-ups.** Two of three review critics passed
outright; the code-quality critic returned `needs_work` on performance/quality
grounds only — it found **no correctness or security defects**. The findings are
scalability and consistency issues on the broadcast/activity paths and are captured
below as open follow-ups; none block the feature's behavior.

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
- `Dashboard::Broadcast` — a per-user broadcast service wired into 8 post-commit
  call sites (approve, rework, finalize, step completion, manager tick, sweep, card
  broadcast, column broadcast) so panels update live.
- `HomeController` (dashboard root + `fleet_health` polling endpoint) and a
  `PhasesController#answers` Turbo Stream branch driving `Phases::AnswerQuestions`.
- `open_questions_structured` artifact plumbing (seed template, `DefineHelper`,
  artifact-schema docs) so questions render one-per-input.

**Frontend (Tailwind + shared components, per `guides/ui-style-guide.md`)**
- Full `home/` view/partial tree: summary tiles, active-pipelines list with phase
  progress and attention treatments, recent-activity feed, fleet-health panel
  (initial frame + `src`-less poll fragment), section-error partial, and the
  answer-questions modal.
- Three Stimulus controllers: `dialog`, `answer_questions_form`, `poll_frame`;
  native `<dialog>` overlay for the modal.

**Size:** app/config/db **+703 / −29** (33 files); tests **+552 / −5** (11 files);
docs/guides **+22 / −1** (2 guide additions appended as CLAUDE.md requires:
presentation-boundary rescue, per-user-stream pattern).

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

### Tests & lint — **PASS** (Build `test-critic`)

- Full non-system suite green: **213 tests / 738 assertions, 0 failures/errors**
  (implementer reported 217/754 after its fixes); covers the new dashboard queries,
  the broadcast service, controllers, and view partials.
- `bin/rubocop` clean (rubocop-rails-omakase), no offenses.
- System tests (`dashboard_test.rb`, `answer_questions_modal_test.rb`) were green in
  the implementer's environment against real headless Chrome; the Build test-critic
  could not re-run them due to a **local chromedriver v122 / Chrome v150 mismatch**
  (unrelated tooling issue, not an app defect). *Follow-up: confirm the system tests
  run in CI.*

### Code quality & security — **NEEDS_WORK** (`code-quality-critic`)

No correctness-breaking or security defects. Verified: all dashboard queries are
correctly membership-scoped, `PhasesController#answers` stays authorized via
`membership_scoped_phase`, the fleet `html_safe` output is pre-escaped via
`content_tag`, all referenced model enums/methods exist, and the sweep's
capture-ids-before-`update_all` ordering is sound. The verdict is driven entirely by
the performance/consistency findings below.

---

## Open findings

These are follow-ups, not blockers — the feature behaves as specified. Two majors
concern scalability under load; two minors concern broadcast consistency/redundancy.

| ID | Severity | Location | Issue | Suggested fix |
|----|----------|----------|-------|---------------|
| **F1** | major | `app/services/step_runs/broadcast_card.rb:17` | Write-amplification on a hot path: `Dashboard::Broadcast` runs on every card update — including `RecordProgress` progress ticks — recomputing the full active-pipeline tree (eager-loading phases→workflows→steps→step_runs) plus fleet health **for each project member**. Frequent progress with several members re-runs the whole aggregation many times per second. | Debounce/throttle dashboard broadcasts, gate them to state-changing transitions rather than progress ticks, or move the recompute off the request path. |
| **F2** | major | `app/queries/dashboard/recent_activity.rb:35` | Unbounded reads: the four event sources query with no DB `LIMIT`/time window, materialize every matching row, concatenate, sort in Ruby, then keep `first(15)`. `step_completion_events` grows with every completed run for the lifetime of every project — memory/CPU per load grows without bound, recomputed per member on each activity broadcast. | Bound each source query at the DB (`ORDER BY ts DESC LIMIT 15`, or a `created_at` window) before merging. |
| **F3** | minor | `app/services/step_runs/sweep.rb:65` | Asymmetric broadcasting: `refresh_stuck_state` broadcasts newly-**stuck** pipelines but not those it just flipped stuck→ready via `unstuck` `update_all`. A recovered-but-unclaimed pipeline keeps its red "Stuck" row/count until the next event (usually a Claim) triggers a broadcast. | Capture and broadcast the unstuck pipeline ids the same way as the stuck ones. |
| **F4** | minor | `app/services/phases/manager_tick.rb:282` | Redundant fan-out: `@affected_decisions.each { Dashboard::Broadcast.call(...) }` ignores the loop variable and fires the identical full per-member fan-out once per decision, multiplying F1's cost for no added information. | Fire once: `Dashboard::Broadcast.call(...) if @affected_decisions.any?`. |

**Also noted (non-blocking):** the "Workers online" summary tile refreshes on
pipeline-scoped broadcasts rather than on every isolated worker status flip; the
fleet panel itself stays current via its 30s poll, so R31's intent is met.

---

## Recommendation

Merge the feature. It satisfies all 50 requirements with tests and lint green.
Track **F1** and **F2** as fast-follow performance work before the dashboard is
exercised under production-scale history and broadcast volume; **F3** and **F4** are
small consistency cleanups suitable for the same follow-up. Confirm the two system
tests execute in CI (the local chromedriver/Chrome mismatch was environmental).
