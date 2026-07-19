# Technical Design — Dashboard UI

Source: `docs/README.md` architecture; `guides/backend-guide.md`;
`guides/ui-style-guide.md`; `output/requirements.md` (R1–R50); Define-phase
`discovery_notes.md`; `open_questions.md` (confirmed defaults + Q11–Q14).

## 0. Framing

The dashboard route, layout, nav entry, and auth already exist as a stub
(`HomeController#index` → `app/views/home/index.html.erb`). This design fills
that stub in. Nothing here touches routing, layout, or navigation except one
new sub-route for fleet-health polling and the existing `answers_phase_path`
route's response format.

Three genuinely new pieces of infrastructure are introduced, because nothing
today does this:

1. **Aggregate read queries** (`app/queries/dashboard/`) — the first
   cross-pipeline, cross-model reads in the app.
2. **A per-user live stream** — existing Turbo Streams are all
   pipeline-scoped; the dashboard spans every pipeline a user can see, so it
   needs its own stream and its own fan-out broadcast.
3. **A structured open-questions artifact** — R39/R40 need one question per
   input box with its default as placeholder text, but the only artifact
   that exists today (`open_questions.md`) is free-form prose written by an
   LLM with no enforced shape. Parsing that reliably at render time is
   fragile, so the artifact contract gains a structured sibling. See §6.

Everything else is composition of what already exists: `status_badge`,
`time_ago_in_words`, the card/table/empty-state classes from
`pipelines/index.html.erb` and `workers/index.html.erb`, and the
`BroadcastCard`/`BroadcastColumn` broadcast pattern.

## 1. Components

```
HomeController#index                          (R1–R35 read path)
  ├─ Dashboard::ActivePipelines  (query) ──▶ home/_active_pipelines, _pipeline_row
  ├─ Dashboard::RecentActivity   (query) ──▶ home/_recent_activity, _activity_item
  └─ Dashboard::FleetHealth      (query) ──▶ home/_fleet_health         [polled, own route]
       (headline counts derived from the three above) ──▶ home/_summary

Dashboard::Broadcast (service)                 (R31, R44 live path)
  called from the existing broadcast choke points + a handful of event-
  creation sites ──▶ per-user Turbo Stream "[user, :dashboard]"

Phases::AnswerQuestions (existing, untouched)  (R36–R50 write path)
  fed by a new structured artifact + a new modal UI;
  PhasesController#answers gains a turbo_stream response branch
```

## 2. Data model

**No new tables, no new columns, no migration.** Every field the three panels
need already exists (`discovery_notes.md` confirms this). The one schema-ish
change is a new *artifact* (a JSON file in the git workspace, not a DB row) —
see §6.

Derivations worth calling out because they aren't already computed anywhere:

- **`Pipeline#status` never actually reaches `"blocked"` or `"stuck"`** — grepped
  across `app/`, no service ever sets either value; they're unused enum
  members. R14 ("stuck or blocked... flagged as needing attention") can't be
  satisfied by trusting `pipeline.status` alone. Instead, `Dashboard::ActivePipelines`
  derives "needs attention" as:
  ```
  pipeline.awaiting_human? || pipeline.blocked? || pipeline.stuck? ||
    pipeline.phases current-phase has any step_run in state "stuck"
  ```
  The last clause reuses `StepRuns::Sweep`'s own stuck detection (the
  system's actual source of truth for "can't make progress"), so the
  dashboard doesn't wait on `pipeline.status` ever being wired up to match.
  This is a deliberate design choice, not an oversight — flagged for the
  Implementer so it isn't "fixed" by trying to set `pipeline.status = "stuck"`
  as a side quest.
- **"Last active" (R15)** — `pipeline.updated_at` alone under-reports (a
  running step's progress ticks don't touch the pipeline row). Compute per
  pipeline as `max(pipeline.updated_at, latest step_run.last_heartbeat_at /
  updated_at across its steps)`.
- **Fleet health "unhealthy" (R27, R30)** — trust `worker.status` directly.
  `StepRuns::Sweep` already flips stale workers to `offline` every 30s
  (`WORKER_OFFLINE_AFTER = 2.minutes`); the dashboard doesn't need to
  recompute staleness, just read the enum.
- **Role-coverage gap (R28)** — `available_roles = Worker.online.flat_map(&:supported_roles).uniq`
  (verbatim from `StepRuns::Sweep#available_roles`) vs. roles demanded by
  `StepRun` rows in state `ready` or `stuck`. A non-empty difference is the
  warning.

## 3. Query objects (`app/queries/dashboard/`)

Per `guides/backend-guide.md`, complex/reporting reads live in query objects,
not inlined in the controller. All three are scoped by `user` where R3/R25
require it (pipelines/activity are membership-scoped; fleet health is
explicitly **global** per the confirmed default in `open_questions.md` —
workers carry no project association).

### `Dashboard::ActivePipelines`

```ruby
module Dashboard
  class ActivePipelines
    ACTIVE_STATUSES = %w[running awaiting_human blocked stuck].freeze  # R8
    LIMIT = 10                                                         # R18

    Row = Struct.new(:pipeline, :attention, :attention_reason,
                      :last_active_at, keyword_init: true)

    def initialize(user) = @user = user

    # Attention-first, then most-recently-active, capped. R18.
    def call
      rows = base_scope.map { |p| build_row(p) }
      rows.sort_by { |r| [r.attention ? 0 : 1, -r.last_active_at.to_i] }.first(LIMIT)
    end

    def total_count = base_scope.count            # R6 headline
    def attention_count = base_scope.count { |p| build_row(p).attention }  # R6

    # One row, recomputed — used by Dashboard::Broadcast for a targeted
    # partial replace. Returns nil if the pipeline is no longer active/visible
    # to this user (so the broadcast can remove the row instead of stale-
    # replacing it).
    def row_for(pipeline)
      build_row(pipeline) if base_scope.exists?(pipeline.id)
    end

    private

    def base_scope
      Pipeline.joins(project: :memberships)
        .where(memberships: { user_id: @user.id })
        .where(status: ACTIVE_STATUSES)
        .includes(:project, phases: { workflows: { steps: :step_runs } })
        .distinct
    end

    def build_row(pipeline) = Row.new(
      pipeline:,
      attention: attention?(pipeline),
      attention_reason: attention_reason(pipeline),   # :awaiting_human | :stuck | nil — R13/R14 distinguish
      last_active_at: last_active_at(pipeline)
    )

    # attention?/attention_reason/last_active_at implement the derivations in §2.
  end
end
```

`attention_reason` distinguishes `:awaiting_human` from `:stuck` (not just a
boolean) because R13 and R14 are two different visual treatments — "needs a
human" vs. "blocked/stuck" — that must "stand apart from pipelines that are
progressing normally" (R14) and from each other in plain language (R11/R12).

### `Dashboard::RecentActivity`

```ruby
module Dashboard
  class RecentActivity
    LIMIT = 15   # confirmed default in open_questions.md

    Event = Struct.new(:kind, :pipeline, :project, :description,
                        :occurred_at, keyword_init: true)

    def initialize(user) = @user = user

    def call
      (approval_events + rework_events + manager_events + step_completion_events)
        .sort_by { |e| -e.occurred_at.to_i }
        .first(LIMIT)
    end

    private

    # Approval (decision: approve) on a Review phase reads as "pipeline
    # finished" (R19's 4th example) rather than generic "Review approved" —
    # same source record, narrated by phase kind.
    def approval_events
      Approval.joins(phase: { pipeline: { project: :memberships } })
        .where(memberships: { user_id: @user.id }, decision: "approve")
        .includes(phase: :pipeline).map { |a| describe(a) }
    end

    # ManagerDecision rows with decision "consensus" (auto-gate approved a
    # phase) or "escalate" (parked for a human) — "route_to" entries are
    # per-iteration routing noise, not user-facing events, and excluded.
    def manager_events
      ManagerDecision.where(decision: %w[consensus escalate])
        .joins(phase: { pipeline: { project: :memberships } })
        .where(memberships: { user_id: @user.id })
        .includes(phase: :pipeline).map { |d| describe(d) }
    end

    def rework_events
      ReworkEvent.joins(pipeline: { project: :memberships })
        .where(memberships: { user_id: @user.id })
        .includes(:from_phase, :target_phase, pipeline: :project).map { |r| describe(r) }
    end

    # A run reaching a terminal state (succeeded/failed) — "a piece of work
    # completing" (R19). Claimed/running/ready/stuck transitions are excluded;
    # "stuck" surfaces via the active-pipelines attention flag (R14), not the
    # activity feed, to keep this feed to meaningful completions.
    def step_completion_events
      StepRun.where(state: %w[succeeded failed]).where.not(finished_at: nil)
        .joins(step: { workflow: { phase: { pipeline: { project: :memberships } } } })
        .where(memberships: { user_id: @user.id })
        .includes(step: { workflow: { phase: :pipeline } }).map { |sr| describe(sr) }
    end

    # describe(record) builds one Event per source type: plain-language
    # description (R20), pipeline+project reference, occurred_at.
  end
end
```

No new persisted event/audit table — confirmed default. This does mean four
separate queries merged and sorted in Ruby on every load; at this app's scale
(an internal ops tool, `LIMIT 15` after merge) that's the right tradeoff over
a write-side event log, but flag it: if activity volume grows, the next step
is a real `Activity` table written by `Dashboard::Broadcast`'s call sites
rather than computed on read. Not needed for v1.

### `Dashboard::FleetHealth`

```ruby
module Dashboard
  class FleetHealth
    def call
      workers = Worker.order(:name)
      online = workers.select(&:online?)
      {
        workers:,
        online_count: online.size,
        offline_count: workers.size - online.size,   # includes draining, R25/R26
        role_gap: role_coverage_gap(online)           # R28
      }
    end

    private

    def role_coverage_gap(online)
      available = online.flat_map(&:supported_roles).uniq
      demanded = StepRun.where(state: %w[ready stuck]).distinct.pluck(:required_role)
      demanded - available
    end
  end
end
```

Global (no membership scoping) per the confirmed default.

## 4. Controller

```ruby
class HomeController < ApplicationController
  def index
    @active_pipelines = safely { Dashboard::ActivePipelines.new(current_user) }
    @recent_activity  = safely { Dashboard::RecentActivity.new(current_user).call }
    @fleet            = safely { Dashboard::FleetHealth.new.call }
  end

  # Own action so the fleet panel is independently pollable (see §5) without
  # re-rendering the whole dashboard.
  def fleet_health
    render partial: "home/fleet_health", locals: { fleet: Dashboard::FleetHealth.new.call }
  end

  private

  # R33: a failed section must not fail the page. This is the one sanctioned
  # blind StandardError rescue in the codebase (guides/backend-guide.md says
  # "never rescue StandardError blindly; rescue what you can handle") — it's
  # a presentation-boundary requirement (R33), not business-logic flow
  # control, and it's narrowly scoped to one query call at a time so one
  # panel's failure can't mask another's.
  def safely
    yield
  rescue StandardError => e
    Rails.logger.error("[dashboard] #{e.class}: #{e.message}")
    nil
  end
end
```

Three ivars instead of the usual one — the dashboard is inherently a
three-panel aggregate view, called out as an explicit, narrow exception to
"one primary ivar per action" (the guide's own qualifier is "where
possible").

`@active_pipelines` holds the query object (not `.call`'s result) so the view
can call `.call`, `.total_count`, and `.attention_count` without three
separate controller round-trips through `safely`.

Route addition (`config/routes.rb`):
```ruby
get "fleet_health", to: "home#fleet_health", as: :dashboard_fleet_health
```

R1/R2 (land on dashboard, sign-in redirect) need no code — `root "home#index"`
plus Devise's existing `authenticate_user!` + `stored_location_for` already
does this.

## 5. Views

```
app/views/home/
  index.html.erb           — page shell, headline summary, 3-column responsive grid
  _summary.html.erb         — headline counts (R6/R7), id="dashboard-summary"
  _active_pipelines.html.erb — panel wrapper, empty state (R17), "see all" link (R18)
  _pipeline_row.html.erb    — one pipeline; id=dom_id(pipeline, :dashboard_row)
  _recent_activity.html.erb — panel wrapper, empty state (R23), id="recent-activity"
  _activity_item.html.erb   — one event
  _fleet_health.html.erb    — panel wrapper, empty state (R29), turbo-frame body
  _answer_questions_modal.html.erb — the R36–R50 modal, rendered once per
                                      flagged pipeline row
  _section_error.html.erb   — shared "couldn't load this section" partial (R33)
```

### `index.html.erb`

```erb
<%= turbo_stream_from current_user, :dashboard %>

<h1 class="text-2xl font-semibold text-gray-900">Dashboard</h1>

<% if current_user.projects.none? %>
  <%# R4: no-projects empty state, page-level %>
<% else %>
  <div id="dashboard-summary" class="mt-6 ...">
    <%= @active_pipelines ? render("home/summary", active: @active_pipelines, fleet: @fleet) : render("home/section_error") %>
  </div>

  <div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-3">  <%# R34 %>
    <div class="lg:col-span-2">
      <%= @active_pipelines ? render("home/active_pipelines", active: @active_pipelines) : render("home/section_error", title: "Active pipelines") %>
    </div>
    <div>
      <%= @fleet ? render("home/fleet_health", fleet: @fleet) : render("home/section_error", title: "Worker fleet") %>
    </div>
  </div>

  <div class="mt-6">
    <%= @recent_activity ? render("home/recent_activity", events: @recent_activity) : render("home/section_error", title: "Recent activity") %>
  </div>
<% end %>
```

Layout choice: active pipelines is the primary, denser panel (2/3 width on
large screens per the ui guide's "density where it earns it"); fleet health
is a compact side panel; recent activity is a full-width list below (mirrors
the existing pipeline-board full-width-then-columns pattern from
`pipelines/show.html.erb`). Collapses to a single column below `lg` (R34).

### `_pipeline_row.html.erb`

One row per active pipeline (R9–R16), styled as a card row like
`pipelines/index.html.erb`'s table rows but denser, since attention state
needs more visual room than a plain table cell:

- Title + project name (R9), linking to `pipeline_path` (R16).
- Phase progress: 4-dot/segment indicator over `Phase::KINDS_IN_ORDER`,
  current phase filled/emphasized, matching the existing board's "current
  phase emphasized, future muted" convention (ui guide §"pipeline board")
  — satisfies R10 ("make clear how far along... it is") more legibly than
  text alone.
- `status_badge(pipeline.status)` (R11) — reused as-is, already
  R12/R35-compliant (word + color, never color alone).
- Attention treatment (R13/R14): when `row.attention`, an amber left-border
  + amber dot for `:awaiting_human`, a red left-border + red dot for
  `:stuck`/`:blocked` — plus the word ("Needs your input" / "Stuck"), not
  color alone.
- Relative "last active" via `time_ago_in_words(row.last_active_at) + " ago"`
  with absolute in `title` (R15, R32) — same convention as
  `workers/index.html.erb`.
- Whole row clickable to `pipeline_path(pipeline)` (R16), per the ui guide's
  table convention.
- **Answer-questions affordance (R36)**: rendered only when
  `row.attention_reason == :awaiting_human && define_open_questions_structured(define_phase).present?`
  (R50 — no dead actions). A button on the row that opens the paired
  `<dialog>` from `_answer_questions_modal.html.erb` (dom_id `dom_id(phase, :answer_modal)`).

`id="<%= dom_id(pipeline, :dashboard_row) %>"` — this is the target
`Dashboard::Broadcast` replaces.

### `_recent_activity.html.erb` / `_activity_item.html.erb`

List of `Dashboard::RecentActivity::Event`, newest first (R21), each showing
plain-language description + pipeline/project + relative time (R20), each
row a link to the relevant pipeline/detail screen (R22) — `phase_path` for
phase-scoped events, `pipeline_path` otherwise. Empty state per R23.

### `_fleet_health.html.erb`

Wrapped in a `<turbo-frame id="fleet-health-frame" src="<%= dashboard_fleet_health_path %>">`
so it's independently reloadable (§ live updates below). Shows
online/offline counts (R25), a compact list of workers with name + status +
last-heard-from (R26), an unhealthy-worker flag reusing `status_badge` (R27),
a role-coverage-gap warning banner when `fleet[:role_gap].any?` (R28), made
prominent — top of the panel, not buried — when the fleet itself is
unhealthy overall (R30, e.g. `online_count.zero? && role_gap present`).
Empty state when `workers.empty?` (R29).

### Answer-questions modal — `_answer_questions_modal.html.erb`

Full flow detailed in §7; referenced here for the view tree.

## 6. The `open_questions_structured` artifact

**Problem:** R39 needs each question rendered as its own labeled input; R40
needs the assumed default to appear as that input's placeholder text. The
only existing artifact, `open_questions` (`output/open_questions.md`), is
free-form markdown produced by an LLM step whose system prompt only says
"Number them... note your assumed default for each" (`db/seeds.rb:17-19`,
and the pipeline's own `.pipeliner/.../open_questions.md` for this very run
demonstrates the variance — it mixes a non-question "Confirmed" preamble
section with numbered `**Q11. ...**` / `*Assumed default:* ...` entries).
Regex-parsing that reliably, across every pipeline this step ever runs for,
is not a sound foundation for a form UI.

**Decision:** extend the artifact contract with a structured sibling,
following the precedent already established by critics (`verdict.json`,
structured findings) — this codebase already trusts LLM steps to emit
well-formed JSON when asked to.

- `db/seeds.rb` — the "Clarifying Questions Writer" template entry
  (`SOFTWARE_PACK`, ~line 17) gains a second declared output and an
  instruction to also emit it:
  ```ruby
  { name: "Clarifying Questions Writer", phase: "define", step_type: "builder",
    role: "requirements", requirement: "conditional",
    system_prompt: "From the ask and the draft requirements, write the open " \
      "questions where human context would materially change the outcome: " \
      "ambiguities, unstated preferences, tradeoffs only the requester can " \
      "decide. Number them, keep each answerable in a sentence or two, and " \
      "note your assumed default for each. These are presented to a human " \
      "at the phase gate. Also emit the same questions as structured JSON: " \
      "an array of { \"question\", \"default\" } objects (question text " \
      "only, no numbering) — the product UI renders one input per entry.",
    default_outputs: [
      { "artifact" => "open_questions", "kind" => "artifact", "path" => "output/open_questions.md" },
      { "artifact" => "open_questions_structured", "kind" => "artifact", "path" => "output/open_questions.json" }
    ] }
  ```
- `docs/artifact-schema.md`, "Canonical artifacts (per phase)" — register
  `open_questions_structured` alongside `open_questions` (guide-addition
  proposal per CLAUDE.md: "If the guide is silent, follow its principles,
  then propose a guide addition in the same PR").
- `app/helpers/define_helper.rb` — new method:
  ```ruby
  # Structured [{ "question" => ..., "default" => ... }, ...] for the answer
  # modal. Returns [] (never raises) when the artifact is missing or
  # malformed — e.g. a phase whose run predates this artifact — so the modal
  # simply doesn't offer the action (R50), rather than the page erroring.
  def define_open_questions_structured(phase)
    run = latest_structured_questions_run(phase)
    return [] unless run

    data = run.result.dig("artifacts", "open_questions_structured")
    parsed = data.is_a?(String) ? JSON.parse(data) : data
    Array(parsed).select { |q| q.is_a?(Hash) && q["question"].present? }
  rescue JSON::ParserError
    []
  end
  ```
  (mirrors `latest_open_questions_run`'s existing selection logic, filtered
  to runs whose result carries this artifact key instead.)

**Backward compatibility:** old/in-flight phases whose `open_questions`
predates this change simply have no `open_questions_structured` artifact —
`define_open_questions_structured` returns `[]`, the modal doesn't render
(R50), and the plain-markdown display in `_define_panel.html.erb` (kept,
see §7) is unaffected. No backfill, no migration.

## 7. Answering open questions from the dashboard (R36–R50)

Grounds Q11–Q14 from `open_questions.md` in a concrete design, taking each
assumed default as the design decision (each is re-derived below, not just
cited, since the "why" matters for the file-level plan):

- **Q11 (targeting)** — reuse `Phases::AnswerQuestions`'s existing
  "first worker-executed step by position" targeting unchanged. No
  step-picker in the modal. *Design consequence:* zero changes to
  `AnswerQuestions`'s targeting logic.
- **Q12 (submission shape)** — compose the modal's per-question answers into
  one formatted text block client-side, submit through the *existing*
  `answers_phase_path` / `Phases::AnswerQuestions` unchanged. *Design
  consequence:* `PhasesController#answers` and `Phases::AnswerQuestions`
  need no param-shape changes — only a response-format branch (below).
  Format: `"Q1: <question>\nA1: <answer>\n\nQ2: ..."`, matching the
  step's existing free-text expectation.
- **Q13 (phase scope)** — Define-only for v1; R50 already hides the action
  everywhere else, so this needs no extra guard beyond "only render when
  `phase.define_phase?`."
- **Q14 (dual UI)** — remove the inline free-text `<textarea name="answers">`
  form from `_define_panel.html.erb:73-84`. The read-only "Open questions"
  markdown display above it (lines ~63-72, using `define_open_questions`)
  **stays** — it's context, not the duplicated action; only the answer form
  is removed.

### 7.1 Trigger and modal shell

`<dialog>` (native HTML), not a hand-rolled overlay: `<dialog>.showModal()`
gives a native top-layer overlay + backdrop, native `Escape`-to-close (R46),
and — in evergreen Chromium/Firefox/Safari, which `allow_browser versions:
:modern` already requires — native return-focus-to-invoker on close (R48).
This is "semantic HTML first" (ui guide's a11y baseline) doing most of R48's
work for free, versus a Stimulus-managed div overlay reimplementing focus
trapping from scratch.

`app/javascript/controllers/dialog_controller.js` (new, small, generic —
reusable beyond this feature):
```js
export default class extends Controller {
  open()  { this.element.showModal() }        // data-action="click->dialog#open" on the trigger button
  close() { this.element.close() }             // backdrop click / cancel button
}
```
Native `cancel` event (fired on Escape) already closes a `<dialog>` without
JS; nothing extra needed for R46's keyboard-dismiss.

`_answer_questions_modal.html.erb`, rendered inline per flagged row:
```erb
<dialog id="<%= dom_id(phase, :answer_modal) %>"
        data-controller="dialog answer-questions-form"
        data-answer-questions-form-url-value="<%= answers_phase_path(phase) %>"
        class="rounded-lg border border-gray-200 bg-white p-6 shadow-sm backdrop:bg-gray-900/40">
  <h2 class="text-lg font-semibold text-gray-900">
    Answer open questions — <%= phase.pipeline.title %>            <%# R38 %>
    <span class="text-xs text-gray-500"><%= phase.pipeline.project.name %></span>
  </h2>

  <div data-answer-questions-form-target="error" class="hidden mt-3 rounded-md bg-amber-50 p-3 text-sm text-amber-800"></div>  <%# R45/R47 %>

  <%= form_with url: answers_phase_path(phase), data: { answer_questions_form_target: "form", turbo_stream: true } do |f| %>
    <div class="mt-4 space-y-4">
      <% define_open_questions_structured(phase).each_with_index do |q, i| %>
        <div>
          <label class="block text-sm font-medium text-gray-900"><%= q["question"] %></label>  <%# R39 %>
          <input type="text" data-answer-questions-form-target="answer" data-question="<%= q["question"] %>"
                 placeholder="<%= q["default"] %>"                                              <%# R40 %>
                 class="mt-1 block w-full rounded-md ring-1 ring-gray-300 focus:ring-2 focus:ring-indigo-600 ...">
        </div>
      <% end %>
    </div>
    <%= f.hidden_field :answers, data: { answer_questions_form_target: "composed" } %>
    <div class="mt-6 flex justify-end gap-2">
      <button type="button" data-action="dialog#close" class="... secondary button ...">Cancel</button>
      <%= f.submit "Send answers", data: { turbo_submits_with: "Sending…" }, class: "... primary button ..." %>
    </div>
  <% end %>
</dialog>
```

Card styling, type scale, button classes — all reused verbatim from the ui
guide (R49). `backdrop:bg-gray-900/40` is the one bit of new CSS (a Tailwind
arbitrary-variant on `::backdrop`, no separate stylesheet needed).

### 7.2 Client-side compose + validate (`answer_questions_form_controller.js`, new)

```js
export default class extends Controller {
  static targets = ["form", "answer", "composed", "error"]

  submit(event) {
    const answered = this.answerTargets.filter(i => i.value.trim() !== "")
    if (answered.length === 0) {                                    // R45
      event.preventDefault()
      this.errorTarget.textContent =
        "Add at least one answer, or approve the pipeline to accept every default as-is."
      this.errorTarget.classList.remove("hidden")
      return
    }
    this.composedTarget.value = this.answerTargets.map((input, i) =>
      `Q${i + 1}: ${input.dataset.question}\nA${i + 1}: ${input.value.trim() || input.placeholder}`  // R41/R42/R43
    ).join("\n\n")
  }

  // Turbo fires turbo:submit-end after the fetch resolves; close on success
  // only, leaving the (still-populated) form open on failure — R47.
  closeOnSuccess(event) {
    if (event.detail.success) this.element.close()
  }
}
```
Bound via `data-action="submit->answer-questions-form#submit turbo:submit-end->answer-questions-form#closeOnSuccess"`
on the `<dialog>` element (Turbo's `turbo:submit-end` bubbles from the form
inside it).

This satisfies R41–R43 exactly: untouched inputs contribute their
`placeholder` (the default) to the composed string; typed inputs contribute
their own value; the whole thing submits as one `answers` string in one
request.

### 7.3 Server-side: `PhasesController#answers`

Needs exactly one addition — a `turbo_stream` response branch — to satisfy
R47 ("tell the user, preserve what they typed") without a full-page redirect
away from the dashboard. This is still "branch only on `result.success?` to
pick a response," which the backend guide explicitly permits:

```ruby
def answers
  phase = membership_scoped_phase
  result = Phases::AnswerQuestions.call(phase:, user: current_user, answers: params[:answers].to_s.strip)

  respond_to do |format|
    format.html do
      if result.success?
        redirect_to pipeline_path(phase.pipeline), notice: "Answers sent — Define is iterating on the requirements."
      else
        redirect_to pipeline_path(phase.pipeline), alert: answers_alert(result.error)
      end
    end
    format.turbo_stream do
      if result.success?
        head :ok   # dashboard row/summary refresh arrives via Dashboard::Broadcast (R44); nothing to render inline
      else
        render turbo_stream: turbo_stream.replace(
          "#{dom_id(phase, :answer_modal)}_error",
          partial: "home/answer_error", locals: { message: answers_alert(result.error) }
        ), status: :unprocessable_entity
      end
    end
  end
end
```

The existing `answers_alert` private method (already handles `:blank_answers`
and `:busy` — R47's "busy" case is `Phases::AnswerQuestions`'s existing
`Result.failure(:busy, ...)`, already defined behavior, just newly surfaced
here) needs no changes. `format.html` behavior for the existing
`/phases/:id` gate screen is untouched.

### 7.4 Live reflection (R44)

`Phases::AnswerQuestions#call` already calls `StepRuns::BroadcastCard.call(run)`
and `BroadcastColumn.call(@phase)` — both gain the dashboard fan-out in §8,
so the moment answers are accepted, every project member's dashboard row for
that pipeline updates via the existing per-user stream, with zero
answer-modal-specific broadcast code.

## 8. Real-time / live updates (R31, R44)

Existing broadcasts are all pipeline-scoped (`turbo_stream_from @pipeline`).
The dashboard spans every pipeline a user can see, so it needs its own
per-user stream: `<%= turbo_stream_from current_user, :dashboard %>` in
`index.html.erb`.

**New service — `app/services/dashboard/broadcast.rb`:**

```ruby
module Dashboard
  # Fans a pipeline-scoped state change out to every user who can see it (its
  # project's members) on their personal dashboard stream. The dashboard has
  # no stream of its own to broadcast to — this is the one place a
  # pipeline-scoped event becomes N per-user pushes.
  class Broadcast
    def self.call(pipeline:, activity: false) = new(pipeline:, activity:).call

    def initialize(pipeline:, activity:)
      @pipeline = pipeline
      @activity = activity
    end

    def call
      members.each do |user|
        broadcast_pipeline_row(user)
        broadcast_summary(user)
        broadcast_activity(user) if @activity
      end
    end

    private

    def members
      User.joins(:memberships).where(memberships: { project_id: @pipeline.project_id }).distinct
    end

    def broadcast_pipeline_row(user)
      target = ActionView::RecordIdentifier.dom_id(@pipeline, :dashboard_row)
      row = Dashboard::ActivePipelines.new(user).row_for(@pipeline)
      if row
        Turbo::StreamsChannel.broadcast_replace_later_to([ user, :dashboard ], target:,
          partial: "home/pipeline_row", locals: { row: })
      else
        Turbo::StreamsChannel.broadcast_remove_to([ user, :dashboard ], target:)
      end
    end

    def broadcast_summary(user)
      Turbo::StreamsChannel.broadcast_replace_later_to([ user, :dashboard ], target: "dashboard-summary",
        partial: "home/summary", locals: { active: Dashboard::ActivePipelines.new(user), fleet: Dashboard::FleetHealth.new.call })
    end

    def broadcast_activity(user)
      Turbo::StreamsChannel.broadcast_replace_later_to([ user, :dashboard ], target: "recent-activity",
        partial: "home/recent_activity", locals: { events: Dashboard::RecentActivity.new(user).call })
    end
  end
end
```

Whole-panel replace for the recent-activity feed is a deliberate exception to
"target the smallest DOM unit": that feed is a synthesized read model across
4 record types with no single stable identity of its own (unlike a pipeline
row or a step card), and it's capped at 15 items — replacing the whole panel
is cheap and correct, versus reimplementing prepend-with-trim for a feed with
no persisted backing record.

### Call sites — centralized, not scattered

Rather than adding a call at every one of the ~15 places that mutate a
pipeline/phase/step_run (`Advance`, `ManagerTick`, `SendBack`,
`ReworkToPhase`, `MaterializePlan`, `Claim`, `RecordProgress`, `Complete`,
`Queue`, `MergeStepBranch`, ...), hook the two broadcast primitives every one
of those already funnels through:

1. **`app/services/phases/broadcast_column.rb`** — append
   `Dashboard::Broadcast.call(pipeline: phase.pipeline)`. Covers every
   phase-status-driven dashboard-row refresh (Advance, ManagerTick escalate,
   SendBack, AnswerQuestions, ReworkToPhase, MaterializePlan, Finalize) with
   **one file edit**.
2. **`app/services/step_runs/broadcast_card.rb`** — append
   `Dashboard::Broadcast.call(pipeline: step.workflow.phase.pipeline)`. Keeps
   R15's "last active" timestamp live on every step touch (claim, progress,
   completion), not just phase transitions — **one file edit**.

Both above pass `activity: false` (the default) — they're state/freshness
refreshes, not new feed entries.

Plus five precise, `activity: true` call sites for R19's actual event
types (each a single added line, right after the record that *is* the
event is created/persisted):

3. `app/services/phases/approve.rb` — after `@phase.approvals.create!(...)`
   → "phase approved."
4. `app/services/phases/manager_tick.rb#record_decision` — after
   `@phase.manager_decisions.create!`, only when `decision.in?(%w[consensus escalate])`
   → auto-gate approvals and escalations (`"route_to"` excluded — see
   `Dashboard::RecentActivity` above).
5. `app/services/phases/rework_to_phase.rb#record_rework_event` — after
   `@pipeline.rework_events.create!` → "sent back for rework."
6. `app/services/step_runs/complete.rb` — after the `succeeded`/`failed`
   `@step_run.update!` (both the normal-completion branch and the
   transient-retries-exhausted branch in `requeue_transient`) → "piece of
   work completing."
7. `app/services/pipelines/finalize.rb#persist_finalization` — after
   `@pipeline.update!(status: "completed", ...)` → "pipeline finishing"
   (the literal status transition, distinct from #3's "Review phase
   approved," which happens earlier and asynchronously triggers this).

And one more for R14's stuck-flagging to update live, not just on next load:

8. `app/services/step_runs/sweep.rb#refresh_stuck_state` — capture the
   distinct pipeline ids behind `newly_stuck` *before* the `update_all`
   (which returns a row count, not records), then broadcast
   `activity: true` for each afterward.

Eight edits total, each one line plus a lookup for the pipeline — no new
broadcast call sites invented beyond what the existing pattern already
funnels through.

### Worker fleet — polling, not push (confirmed default)

Per the confirmed default ("worker-fleet health refreshes on a light
periodic cadence rather than streaming every heartbeat"), no broadcast is
added for worker status changes. Instead, `_fleet_health.html.erb`'s
`<turbo-frame src="...">` (§5) is reloaded periodically by a small Stimulus
controller:

`app/javascript/controllers/poll_frame_controller.js` (new, generic):
```js
export default class extends Controller {
  static values = { interval: { type: Number, default: 30000 } }  // matches StepRuns::Sweep's cadence
  connect()    { this.timer = setInterval(() => this.element.reload(), this.intervalValue) }
  disconnect() { clearInterval(this.timer) }
}
```
`<turbo-frame id="fleet-health-frame" data-controller="poll-frame" src="<%= dashboard_fleet_health_path %>">`.
`.reload()` is a native Turbo 8 `<turbo-frame>` method — no manual `fetch`
needed. Every page still renders true state on load without this (ui guide's
"streams are enhancement"): the frame's initial content is server-rendered
inline on first paint; the `src` only matters for reload.

### Guide addition (proposed)

`guides/ui-style-guide.md`'s "Real-time behavior" section only documents
per-pipeline streams. Propose appending: *"Cross-pipeline aggregate views
(e.g. the dashboard) use a per-user stream (`turbo_stream_from current_user, :scope`)
fanned out from a small `Dashboard::Broadcast`-style service, since no single
record owns the view."* — this is the first view of this shape; future ones
should follow the same pattern rather than re-deriving it.

## 9. File-level plan

**New files**
```
app/queries/dashboard/active_pipelines.rb
app/queries/dashboard/recent_activity.rb
app/queries/dashboard/fleet_health.rb
app/services/dashboard/broadcast.rb
app/views/home/_summary.html.erb
app/views/home/_active_pipelines.html.erb
app/views/home/_pipeline_row.html.erb
app/views/home/_recent_activity.html.erb
app/views/home/_activity_item.html.erb
app/views/home/_fleet_health.html.erb
app/views/home/_answer_questions_modal.html.erb
app/views/home/_answer_error.html.erb
app/views/home/_section_error.html.erb
app/javascript/controllers/dialog_controller.js
app/javascript/controllers/answer_questions_form_controller.js
app/javascript/controllers/poll_frame_controller.js
test/queries/dashboard/active_pipelines_test.rb
test/queries/dashboard/recent_activity_test.rb
test/queries/dashboard/fleet_health_test.rb
test/services/dashboard/broadcast_test.rb
test/controllers/home_controller_test.rb (exists as a stub test today — extend, don't recreate)
test/system/dashboard_test.rb
test/system/answer_questions_modal_test.rb
```

**Modified files**
```
app/controllers/home_controller.rb        — real #index + new #fleet_health (§4)
app/controllers/phases_controller.rb      — #answers gains turbo_stream branch (§7.3)
app/views/home/index.html.erb             — full rewrite of the stub (§5)
app/views/pipelines/_define_panel.html.erb — remove the free-text answers form (Q14, §7)
app/helpers/define_helper.rb              — + define_open_questions_structured (§6)
app/services/phases/broadcast_column.rb   — + Dashboard::Broadcast.call (§8.1)
app/services/step_runs/broadcast_card.rb  — + Dashboard::Broadcast.call (§8.1)
app/services/phases/approve.rb            — + activity broadcast (§8.3)
app/services/phases/manager_tick.rb       — + activity broadcast in record_decision (§8.4)
app/services/phases/rework_to_phase.rb    — + activity broadcast in record_rework_event (§8.5)
app/services/step_runs/complete.rb        — + activity broadcast (§8.6)
app/services/pipelines/finalize.rb        — + activity broadcast (§8.7)
app/services/step_runs/sweep.rb           — + activity broadcast for newly-stuck pipelines (§8.8)
config/routes.rb                          — + get "fleet_health", to: "home#fleet_health"
db/seeds.rb                               — Clarifying Questions Writer template: + open_questions_structured (§6)
docs/artifact-schema.md                   — register open_questions_structured (§6, guide addition)
guides/ui-style-guide.md                  — document the per-user-stream aggregate-view pattern (§8, guide addition)
```

**Untouched, load-bearing:** `StatusHelper`, `NavigationHelper`, `Pipeline`,
`Phase`, `Worker`, `StepRun`, `Approval`, `ManagerDecision`, `ReworkEvent`
models; `Phases::AnswerQuestions`; `app/views/layouts/application.html.erb`;
`config/routes.rb`'s existing `root "home#index"`.

## 10. Testing plan

Per `guides/backend-guide.md`: services are the primary unit; controller
tests thin; system tests for critical flows.

- **Query object tests** (`test/queries/dashboard/`): membership scoping
  (a pipeline in another user's project never appears), the active-status
  filter (R8), attention-first sort with the stuck-step-run derivation
  (R14), the 10/15-item caps (R18, confirmed default), and each empty-input
  case (no pipelines/workers/activity → `[]`/zero counts, not an exception).
- **`Dashboard::Broadcast` test**: given a pipeline, asserts one
  `broadcast_replace_later_to` per project member on `[user, :dashboard]`
  with the right target ids; `activity: false` doesn't touch
  `"recent-activity"`; a pipeline that drops out of `ActivePipelines` (e.g.
  just completed) gets a `broadcast_remove_to` instead of a stale replace.
- **`HomeController` test**: extend the existing stub — signed-out redirect
  (R2), empty-projects state (R4), zero-counts-shown-not-hidden (R7), each
  panel renders its empty state independently, and a forced query failure
  (stub one query object to raise) still renders the other two panels
  (R33) — a regression test for the `safely` boundary specifically.
- **`Phases::AnswerQuestions` — no changes needed**, its existing test
  (`test/services/phases/answer_questions_test.rb`) already covers the
  targeting/busy/blank behavior this design relies on unchanged.
- **`PhasesController#answers` turbo_stream branch**: new controller test —
  success returns `200` with no redirect; `:busy` and `:blank_answers`
  return `422` + a turbo_stream replacing the error partial (not a
  redirect, so the dashboard doesn't navigate away — R47).
- **System tests** (critical flows per the guide):
  - `dashboard_test.rb`: signs in, sees active pipelines / recent activity /
    fleet health populated from fixtures; a status change to a fixture
    pipeline (simulated via a service call, e.g. `Phases::Advance.call`)
    reflects in the open dashboard tab without a manual reload (R31/R44) —
    the one true end-to-end proof the new stream plumbing works.
  - `answer_questions_modal_test.rb`: opens the modal from a flagged row,
    submits with one answer changed and one left default, asserts the
    submitted string composes both correctly (R41–R43), asserts Escape
    closes with no answers sent (R46), asserts submitting all-defaults is
    rejected with the R45 message.
  - Requires `test/application_system_test_case.rb` to exist — not present
    today; the Implementer should generate Rails 8's default Capybara/Selenium
    system-test scaffold if it isn't already part of this branch.

## 11. Requirements traceability

| Requirements | Satisfied by |
|---|---|
| R1, R2 | Existing `root "home#index"` + Devise `authenticate_user!` — no change |
| R3 | `Dashboard::ActivePipelines`/`RecentActivity` membership scoping; `_pipeline_row` shows project name |
| R4 | `index.html.erb` page-level empty state on `current_user.projects.none?` |
| R5, R6, R7 | `index.html.erb` 3-panel layout; `_summary.html.erb` headline counts, zero shown not hidden |
| R8–R18 | `Dashboard::ActivePipelines`, `_active_pipelines.html.erb`, `_pipeline_row.html.erb` |
| R19–R24 | `Dashboard::RecentActivity`, `_recent_activity.html.erb`, `_activity_item.html.erb` |
| R25–R30 | `Dashboard::FleetHealth`, `_fleet_health.html.erb` |
| R31 | `Dashboard::Broadcast` + 8 call sites (§8); fleet polling (§8) |
| R32 | `time_ago_in_words` + `title=` absolute, reused convention |
| R33 | `HomeController#safely` + per-panel `_section_error.html.erb` |
| R34 | `index.html.erb` `grid-cols-1 lg:grid-cols-3` |
| R35 | `status_badge` reuse (already word+color) |
| R36–R50 | §7 in full: structured artifact (§6), `_answer_questions_modal.html.erb`, `dialog_controller.js`, `answer_questions_form_controller.js`, `PhasesController#answers` turbo_stream branch |

## 12. Open risks / follow-ups (not blocking, flagged for Build/Review)

- **`open_questions_structured` depends on LLM output discipline.** If a
  worker emits malformed JSON, `define_open_questions_structured` degrades
  to `[]` (modal silently doesn't offer — R50-compliant) rather than
  erroring, which is the safe failure mode but means a malformed emission is
  invisible rather than flagged. Acceptable for v1; worth a completeness
  critic finding if it recurs in practice.
- **`Dashboard::RecentActivity` is 4 merged Ruby-side queries**, not one SQL
  query — fine at current scale, flagged in §3 as the thing to revisit
  (a real event table) if activity volume grows.
- **`pipeline.status` "blocked"/"stuck" are dead enum values** (§2) —
  out of scope to actually wire up here; the dashboard works around it by
  deriving stuck-ness from step_run state instead. If a future change makes
  something set these statuses for real, `Dashboard::ActivePipelines`'s
  `attention?` already accounts for them (`pipeline.blocked? || pipeline.stuck?`
  is already in the `||` chain), so no rework needed there.
