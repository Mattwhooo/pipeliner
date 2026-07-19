# Discovery Notes — Add UI for Dashboard

Step: codebase-explorer (Define phase). Factual survey of what exists today,
what the ask touches, open questions, and constraints. No decisions made here.

## The ask (restated)

Add a dashboard UI giving an at-a-glance overview of three things:

1. **Active pipelines** and their current phase/status.
2. **Recent activity** across the system.
3. **Worker fleet health.**

## What exists today

### The dashboard route already exists (as a stub)

- `root "home#index"` → `HomeController#index` (empty action) →
  `app/views/home/index.html.erb`.
- The view is a placeholder: an `<h1>Dashboard</h1>` header and a single "Welcome
  to Pipeliner" empty card. No data is loaded or displayed.
- The sidebar (`app/helpers/navigation_helper.rb`) already labels this route
  **"Dashboard"** and marks it active on `root_path`. So the ask is to fill in an
  existing, already-navigable page — not to add a new route or nav entry.

### App shell / layout (ready to reuse)

- `app/views/layouts/application.html.erb` — fixed left sidebar + scrollable
  `<main>` with `max-w-7xl px-6 py-8` content wrapper. Dashboard renders inside
  this automatically.
- `app/views/shared/_sidebar.html.erb` + `NavigationHelper#nav_items` — nav is
  Dashboard / Projects / Pipelines / Workers / Step Library.
- Auth: `ApplicationController` has `before_action :authenticate_user!` (Devise).
  `current_user` is available in all controllers/views.

### Data models the three panels draw on

**Pipelines** (`app/models/pipeline.rb`, table `pipelines`):
- `belongs_to :project`; `has_many :phases` (ordered by position).
- `status` enum: `draft, running, awaiting_human, blocked, stuck, completed,
  aborted`.
- `current_phase` enum: `define, plan, build, review` (prefix `:in`, e.g.
  `in_define?`).
- Fields: `title`, `public_id`, `branch`, `initial_prompt`, `pr_number`,
  `pr_url`, timestamps. Index on `[project_id, status]`.

**Phases** (`app/models/phase.rb`, table `phases`):
- `belongs_to :pipeline`; `KINDS_IN_ORDER = %w[define plan build review]`.
- `status` enum: `pending, running, consensus, approved, reworking,
  awaiting_human, failed`. `position` 1..4.

**Workers** (`app/models/worker.rb`, table `workers`):
- `status` enum: `online, draining, offline`. Indexed on `status`.
- Fields: `public_id`, `name`, `backend`, `model`, `concurrency`,
  `supported_roles` (jsonb array, GIN-indexed), `last_heartbeat_at`.
- `has_many :step_runs`.

**StepRuns** (`app/models/step_run.rb`, table `step_runs`) — the unit of live
work, and the richest source of "activity":
- `state` enum: `ready, claimed, running, succeeded, failed, stuck`.
- `belongs_to :worker, optional: true` (current claimant while leased).
- Timestamps that read as activity: `started_at`, `finished_at`, `merged_at`,
  `last_heartbeat_at`, `created_at`, `updated_at`.
- Scopes: `leased` (claimed+running), `lease_expired`. `merged?`, `verdict_status`.

**Other activity-bearing records** (exist, not yet surfaced anywhere in UI):
- `ManagerDecision` (`belongs_to :phase`; decision: route_to/consensus/escalate).
- `Approval` (`belongs_to :phase, :user`; approve/send_back/abort).
- `ReworkEvent` (`belongs_to :pipeline`; `unresolved` scope; `reason`, `mode`,
  `raised_by`). There is **no** generic `Activity`/`Event` model — "recent
  activity" would be composed from these record types + step_run transitions.

### Worker fleet health — the source of truth already computed

`app/services/step_runs/sweep.rb` (recurring Solid Queue job, every 30s per
`config/recurring.yml`) already defines fleet-health semantics:
- `WORKER_OFFLINE_AFTER = 2.minutes` — workers with stale `last_heartbeat_at`
  are flipped to `offline`.
- Heartbeat cadence is **15s**, lease TTL **60s** (docs/worker.md).
- Stuck detection: `ready` runs whose `required_role` no `online` worker
  supports become `stuck` (90s grace); the inverse un-sticks them.
- `available_roles = Worker.online.pluck(:supported_roles).flatten.uniq` — the
  set of roles the fleet can currently serve. A "role coverage gap" (a needed
  role no online worker supports) is a natural fleet-health signal.

So fleet health = online/draining/offline counts + stale-heartbeat detection +
role coverage vs. queued demand. Most of this is already derivable.

### Existing UI patterns to reuse (mandated by guides + already in code)

- **Status badges:** `StatusHelper#status_badge(status)` maps every enum value
  above to a semantic tone (info/success/attention/danger/muted) with soft
  Tailwind classes. Covers pipeline, phase, worker, and step_run statuses. Also
  `PhasesHelper` has `verdict_badge` / `severity_badge`.
- **Existing list views to mirror** (same visual grammar the dashboard should
  match):
  - `app/views/pipelines/index.html.erb` — table: Title / Project / Status /
    Phase / Created, with `status_badge` and relative timestamps.
  - `app/views/workers/index.html.erb` — table: Worker / Status / Backend /
    Roles / Concurrency / Last heartbeat.
- **Cards:** `rounded-lg border border-gray-200 bg-white p-6 shadow-sm`.
- **Empty states:** icon + one sentence + primary action (never a bare table).
- Relative timestamps via `time_ago_in_words(...) + " ago"` with absolute in
  `title`.

### Real-time infrastructure (the "live by default" requirement)

- Views subscribe with `<%= turbo_stream_from @pipeline %>` (see
  `pipelines/show.html.erb`).
- Broadcasts come from **services after commit**, targeting the smallest DOM
  unit by `dom_id`: `StepRuns::BroadcastCard`, `Phases::BroadcastColumn` use
  `Turbo::StreamsChannel.broadcast_replace_later_to(pipeline, target:, partial:)`.
- Stack: Solid Cable/Queue/Cache, Hotwire (Turbo + Stimulus), import maps.
- Existing broadcasts are **scoped per-pipeline** (stream name = the pipeline
  record). There is currently **no** global/system-wide stream that a dashboard
  aggregating all pipelines could subscribe to.

## What the ask touches

- **`HomeController#index`** — must load dashboard data (currently empty).
- **`app/views/home/index.html.erb`** — must render the three panels (currently
  a stub).
- **New read/query logic** — per backend guide, complex/reporting reads belong in
  `app/queries/` (e.g. a `Dashboard::*` query or several), returning relations;
  aggregation logic must not be inlined in the controller. `app/queries/` today
  holds only `StepRuns::ClaimableFor`.
- **New view partials** — likely `home/_*.html.erb` (or shared components) for
  the three panels; guides prefer one source of truth per component.
- **Possibly new broadcast plumbing** — to satisfy "live by default" for a
  cross-pipeline view (a global stream + broadcasts on the relevant state
  changes). This is the largest net-new area.
- **Authorization scoping** — `PipelinesController#index` scopes pipelines to
  `memberships.user_id = current_user.id`. The dashboard must decide the same
  scoping question (see open questions).

## Constraints (from CLAUDE.md + guides)

- **Backend guide (mandatory):** business logic in reusable POROs; controllers
  thin (auth + params + one call + respond); complex reads in query objects;
  broadcasts from services after commit, never model callbacks; services return
  `Result`, don't raise for flow control. Minitest tests (services are the
  primary unit; controller tests thin; system tests for critical flows).
- **UI style guide (mandatory):** calm ops UI, "what is happening right now?"
  legible at a glance. Fixed type scale (page title `text-2xl font-semibold`,
  section `text-lg font-semibold`, meta `text-xs text-gray-500`). Spacing steps
  2/4/6/8/12. Neutrals + single indigo accent; **status colors are semantic and
  reserved**, and **status is never conveyed by color alone** (a11y — always pair
  with the word). Cards/badges/tables have prescribed classes. Empty states
  required. Timestamps relative with absolute on hover. Live by default via Turbo
  Streams targeting the smallest DOM unit; every page must render correct state
  on load without the socket (streams are enhancement).
- **Stack:** Rails 8, PostgreSQL, Hotwire, Solid Queue/Cache/Cable, Tailwind,
  Devise, Propshaft + import maps. No ViewComponent gem is installed today
  (guides mention it as an option; current code uses plain partials + helpers).
- **Local-first**, no cloud deploy. Tests: `bin/rails test`; lint
  `bin/rubocop` (rubocop-rails-omakase). (Note: memory records that plain
  `bin/rails test` needs a special local runner in this environment.)

## Open questions

1. **Scope of "active pipelines":** which statuses count as active —
   `running` + `awaiting_human` + `blocked` + `stuck`, excluding
   `draft/completed/aborted`? And should the dashboard be scoped to the current
   user's memberships (like `PipelinesController#index`) or show all pipelines
   (like `WorkersController#index`, which is unscoped)?
2. **"Recent activity" definition:** there is no `Activity`/event log model.
   Should activity be a merged, time-ordered feed synthesized from
   step_run transitions + `ManagerDecision` + `Approval` + `ReworkEvent`? Over
   what window / item cap? Do we need a new persisted event model, or compute
   on read?
3. **Fleet-health depth:** just online/draining/offline counts + stale
   heartbeats, or also role-coverage gaps (roles demanded by queued/stuck
   step_runs that no online worker supports), queue depth, and reclaimed-lease
   counts? How is "healthy vs degraded" summarized at a glance?
4. **Real-time expectations:** must the dashboard live-update (guide says "live
   by default"), or is on-load-correct with periodic refresh acceptable for v1?
   Live cross-pipeline updates require a new global Turbo stream + broadcasts
   from the relevant services — a non-trivial addition. Alternatively a
   Stimulus poll / `turbo_frame` auto-refresh.
5. **Empty / first-run state:** what shows when there are no pipelines / no
   workers yet (matches existing empty-state pattern)?
6. **Navigation intent:** are the panels' items links into existing detail views
   (pipeline board, workers index, phase pages)? Assumed yes, but confirm the
   primary drill-down targets.
7. **Time/count thresholds:** exact "recent" window, active-pipeline definition,
   and worker-stale threshold — reuse `Sweep::WORKER_OFFLINE_AFTER` (2 min) for
   consistency, or a display-specific threshold?

## Notable facts / gotchas

- The dashboard page, route, and nav entry **already exist** — this is a
  fill-in, not a greenfield screen.
- `status_badge` already covers every status enum in play, so panels can be
  visually consistent with zero new color logic.
- All fleet-health thresholds already have a home in `StepRuns::Sweep`; reusing
  its constants keeps the dashboard consistent with actual reclaim behavior.
- Existing broadcasts are per-pipeline only; a genuinely live dashboard is the
  one area needing net-new real-time plumbing.
- No aggregate/reporting query objects exist yet; the dashboard will introduce
  the first ones under `app/queries/`.
