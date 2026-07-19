# Discovery Notes — Add UI for Dashboard

Phase: Define · Step: codebase-explorer · Iteration 1

The ask: *"We need a UI for the Dashboard. Not sure what needs to be here but
it will probably be similar to the current 'Pipelines' view. Make sensible
defaults for what someone would want to see at a glance."*

These are factual discovery notes only — no design decisions or implementation.

---

## 1. Key finding: the "Dashboard" already exists as a placeholder

The application root already routes to a page titled **"Dashboard"**, but it is
an empty placeholder — the ask is really *fill in the Dashboard*, not *create a
new route/nav entry*.

- `config/routes.rb`: `root "home#index"`.
- `app/controllers/home_controller.rb`: `HomeController#index` is empty (no
  data loaded).
- `app/views/home/index.html.erb`: page header `<h1>Dashboard</h1>` + a single
  card reading *"Welcome to Pipeliner / Projects, pipelines, and workers will
  appear here as they are built."*
- Sidebar (`app/helpers/navigation_helper.rb` + `app/views/shared/_sidebar.html.erb`):
  the first nav item is **Dashboard → `root_path`**, already active on `/`.
- Test already asserts the title: `test/controllers/home_controller_test.rb`
  → *"signed-in user sees the dashboard"* asserts `assert_select "h1", "Dashboard"`.

**Implication:** work is additive inside `home#index` + its view (and likely a
data/aggregation object). No new route, nav item, or controller class is needed.

---

## 2. The reference view — "Pipelines" (what the ask points at)

`PipelinesController#index` + `app/views/pipelines/index.html.erb`:

- **Controller** loads a single scoped collection:
  ```ruby
  @pipelines = Pipeline.joins(project: :memberships)
    .where(memberships: { user_id: current_user.id })
    .includes(:project).order(created_at: :desc)
  ```
- **View** is the standard index shape shared by Projects, Workers, Pipelines:
  1. Page header: `flex items-center justify-between` with an `<h1 class="text-2xl
     font-semibold text-gray-900">` (+ optional primary action button on the right).
  2. `mt-8` content: a **card-wrapped table** (`rounded-lg border border-gray-200
     bg-white shadow-sm`) with `min-w-full divide-y divide-gray-100`, header cells
     `text-xs font-semibold text-gray-500`, rows `hover:bg-gray-50`.
  3. **Empty state** branch: card with centered `py-12`, one-line message + a
     primary action (`bg-indigo-600 ... text-white`).
- Columns shown per pipeline: **Title** (linked), **Project**, **Status**
  (`status_badge(pipeline.status)`), **Phase** (`pipeline.current_phase.humanize`),
  **Created** (`time_ago_in_words` + absolute in `title`).

`Projects#index` and `Workers#index` follow the identical header→table→empty-state
pattern — this is the established convention a Dashboard would either reuse or
compose from.

---

## 3. Data the Dashboard can surface (models + enums)

All models are plain ActiveRecord (`app/models/`). Relevant states:

| Model | Key attributes / associations | Enum states |
|-------|-------------------------------|-------------|
| `Project` | `name`, `repo_url`, `project_type`, `has_many :pipelines`, `memberships`/`users` | `env_status`: pending, assessing, ready, needs_setup |
| `Pipeline` | `title`, `belongs_to :project`, `has_many :phases` | `status`: draft, running, awaiting_human, blocked, stuck, completed, aborted · `current_phase`: define/plan/build/review |
| `Phase` | `belongs_to :pipeline`, `has_many :workflows` | `status`: pending, running, consensus, approved, reworking, awaiting_human, failed · `kind`: define/plan/build/review |
| `Step` / `StepRun` | run has `belongs_to :worker` (optional), `iteration`, `attempt`, `progress`, `merged_at`, `verdict` | `StepRun.state`: ready, claimed, running, succeeded, failed, stuck |
| `Worker` | `name`, `public_id`, `backend`, `supported_roles`, `concurrency`, `last_heartbeat_at` | `status`: online, draining, offline |

`StepRun` has helpful scopes: `.leased` (claimed/running) and `.lease_expired`.

**Candidate at-a-glance data** (facts, not a decided design): counts of pipelines
by status; pipelines needing attention (`stuck` / `blocked` / `awaiting_human`);
active/running pipelines and their current phase; recent pipelines (already the
Pipelines table); workers online vs offline / last heartbeat; project count &
env_status distribution.

---

## 4. Helpers / styling primitives already available

- **`status_badge(status, label:)`** (`app/helpers/status_helper.rb`) — semantic
  pill. `STATUS_TONES` already maps every enum value above (running→info/blue,
  succeeded/completed/online→success/green, awaiting_human/reworking/needs_setup→
  attention/amber, stuck/failed/blocked/aborted→danger/red, pending/draft/offline→
  muted/gray). `TONE_CLASSES` holds the Tailwind classes. Reuse this — do not
  invent new status colors.
- `verdict_badge` / `severity_badge` (`app/helpers/phases_helper.rb`) — critic
  verdicts, likely not needed for a top-level dashboard.
- Card / table / empty-state / button class recipes are codified in
  `guides/ui-style-guide.md` §"Core components" (Card = `rounded-lg border
  border-gray-200 bg-white p-6 shadow-sm`; empty state = "icon + one sentence +
  primary action"; timestamps relative with absolute on hover).
- Layout (`app/views/layouts/application.html.erb`): sidebar + `main` with content
  wrapped in `mx-auto max-w-7xl px-6 py-8`. Guide says `max-w-7xl` for
  boards/tables.

**Note:** there is **no shared "stat tile" / metric-card component today.** The
ui-style-guide's Core-components list does not define one (it covers badge, card,
buttons, table, forms, empty state). A KPI/metric row is the most obvious "at a
glance" element and has no existing source of truth — see Open Questions.

---

## 5. Constraints (from guides + existing code)

- **Backend guide (`guides/backend-guide.md`, mandatory):** business logic lives
  in reusable POROs — services with a uniform `.call → Result` interface;
  controllers stay thin (auth + params + one call + respond); no business logic
  in callbacks/jobs. Aggregating dashboard metrics is business logic, so the
  established pattern points to a query/service object (e.g. under
  `app/services/`, mirroring `Pipelines::Create`, `Projects::Create`) rather than
  fat-controller queries. Existing service tests: `test/services/**`.
- **Authorization / scoping:** every controller inherits `authenticate_user!`
  (`ApplicationController`). User-facing data is scoped per user via memberships:
  `current_user.projects` (Projects) and the `joins(project: :memberships)
  .where(memberships: { user_id: current_user.id })` pattern (Pipelines). A
  Dashboard must apply the same scoping — a user should only see their own
  projects'/pipelines' aggregates.
- **Exception — Workers are global:** `WorkersController#index` uses
  `Worker.order(:public_id)` with **no per-user scoping** (workers are shared
  infrastructure, not owned by a membership). If the Dashboard shows worker
  stats, decide whether that section is global (matching Workers page) vs scoped.
- **UI guide (`guides/ui-style-guide.md`, mandatory):** operations UI — "what is
  happening right now?" is the core question; state changes should update in
  place via **Turbo Streams**, targeting the smallest DOM unit (badge/card), with
  stable DOM ids; status is **never conveyed by color alone** (always paired with
  the word); use the defined type scale / spacing / semantic colors; shared
  components are one source of truth. If the guide is silent on a component (e.g.
  stat tiles), CLAUDE.md requires following its principles **and proposing a guide
  addition in the same PR**.
- **Testing:** Minitest. Fixtures exist for `projects`, `pipelines`, `workers`
  (`test/fixtures/`). Controller tests sign in via `users(:dev)`. Per repo memory,
  `bin/rails test` needs a special local runner (Homebrew ruby@4.0 +
  cable-preload) — relevant when the implement step runs tests.

---

## 6. What the ask touches (change surface)

Likely-touched (to be confirmed by planning), all additive:

- `app/controllers/home_controller.rb` — load dashboard data (thin; delegate to a
  service/query object).
- `app/views/home/index.html.erb` — replace the placeholder card with real content
  (metric row + section(s), reusing table pattern for recent pipelines / attention).
- **New** aggregation PORO under `app/services/` (e.g. `Dashboards::Summary`) with
  a `.call → Result`, per backend guide.
- Possibly a **new shared metric/stat-tile partial or ViewComponent** (+ a
  guide addition), since none exists.
- `test/controllers/home_controller_test.rb` (extend) + a new service test.
- Possibly Turbo Stream wiring if live-updating tiles are in scope (broadcasts are
  emitted from services after commit per the guides).

Not touched: routing, sidebar/nav (Dashboard entry already present), auth,
existing Pipelines/Projects/Workers pages.

---

## 7. Open questions (for Define/Plan to resolve)

1. **Which metrics count as "at a glance"?** The ask explicitly defers to
   "sensible defaults." Candidate set to confirm: pipelines-by-status counts,
   attention list (stuck/blocked/awaiting_human), active/running pipelines with
   phase, recent pipelines, worker online/offline. How many, and their priority.
2. **Reuse vs. compose:** Is the Dashboard mostly the Pipelines table again (the
   ask's comparison), or a summary/metrics view that *links to* the full pages?
   ("Similar to Pipelines view" is ambiguous — same table vs. same visual style.)
3. **Stat-tile component:** no shared metric-tile component exists. Introduce one
   (+ guide addition) or lay out tiles inline with existing Card classes?
4. **Worker section scope:** global (matches Workers page) or scoped to the
   current user's context? Workers are currently un-scoped infrastructure.
5. **Live updates in scope?** Guide favors Turbo Streams for state; is real-time
   updating of dashboard counts required now, or is load-time-correct enough with
   streams as a later enhancement?
6. **Empty state:** what shows for a brand-new user with zero projects/pipelines
   (the current placeholder's job)? Guide requires "icon + one sentence + primary
   action."
7. **Time window:** should "recent" / activity be bounded (e.g. last N, or last 7
   days)? No existing convention for a time-scoped list.
