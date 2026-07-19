# Pipeliner — Developer Guide

> Practical onboarding for a Rails developer new to this codebase. Design docs in
> [`docs/`](./README.md) are the source of truth for *what we're building*; the
> guides in `guides/` are the mandatory standard for *how we write code*. This
> document tells you how to get productive.

---

## 1. What Pipeliner is

Pipeliner is a Rails 8 control plane for **agentic development pipelines**:
structured, agent-driven processes that carry a unit of work from an initial ask
to a reviewed, merge-ready PR. LLM agents do the work; Pipeliner orchestrates,
sequences, and captures the artifacts.

The domain hierarchy is **Project → Pipeline → Phase → Workflow → Step**. A
Project is bound 1:1 to a git repo; each Pipeline is bound 1:1 to a branch + PR
in that repo. Every pipeline flows through **four fixed phases — Define → Plan →
Build → Review** — each of which is a **Manager-driven consensus loop**: planner
steps decide the approach, builder steps produce work, critic steps judge it
with structured verdicts, and a per-phase Manager routes feedback and declares
consensus (with human or automated Gates at phase boundaries, and forward-only
inter-phase rework when a later phase finds a problem rooted in an earlier one).

Execution is distributed: **model-agnostic Workers** (reference implementation:
Node/TypeScript driving Claude Code, one ephemeral container per step) poll the
control plane over HTTPS, claim step runs by **role matching** (`SKIP LOCKED`
claims, 15s heartbeat / 60s lease), and do the work on a **git branch per step**
(`step/**`) pushed directly to GitHub. The control plane merges step branches
back via the GitHub API after a pre-merge scope check. Durable artifacts live in
the **`.pipeliner/` workspace on the pipeline branch** (a rigid schema —
manifests, `step.json`, `verdict.json`, `result.json`); at the end of Review the
whole tree is zipped to S3 and stripped so the final PR is clean code only.

**Read [`docs/README.md`](./README.md)** — it indexes all design docs (concepts,
execution model, architecture, artifact schema, worker spec, tech stack, data
model, phase playbooks) and records every settled decision. When this guide and
a design doc disagree, the design doc wins.

---

## 2. Getting set up

### Prerequisites

- **Homebrew Ruby 4.0.6** (`brew install ruby`; `.ruby-version` pins 4.0.6).
  **This repo does not use RVM** — see the `.devenv` ritual below.
- **PostgreSQL** running locally (any recent version; Homebrew 14/16 both work):
  `brew services start postgresql@16` (or whichever you have).
- Nothing else. No Redis (Solid Queue/Cache/Cable are DB-backed), no Node build
  step (Propshaft + import maps; the Tailwind CLI ships in the gem).

### The `.devenv` ritual (do not skip)

If your machine has RVM installed, it silently exports `GEM_HOME`/`GEM_PATH`
pointing at an old Ruby 3.0 gemset, which breaks everything here. **Every shell
session in this repo must start with:**

```sh
source .devenv
```

That does exactly two things: unsets `GEM_HOME`/`GEM_PATH`, and prepends
`/opt/homebrew/opt/ruby/bin` plus the Homebrew gem bindir
(`/opt/homebrew/lib/ruby/gems/4.0.0/bin`) to `PATH`. Verify with
`ruby -v` → `4.0.6` and `which ruby` → `/opt/homebrew/opt/ruby/bin/ruby`.

### Gems are vendored

`.bundle/config` sets `BUNDLE_PATH: vendor/bundle`, so `bundle install` puts
everything in `vendor/bundle/` inside the repo — never in system or RVM gem
dirs. If `bin/rails` complains about missing gems, you (or a fresh clone) just
need `bundle install`.

### First five minutes

```sh
cd ~/Projects/pipeliner
source .devenv            # ALWAYS first — kills RVM pollution, picks Homebrew Ruby
ruby -v                   # expect ruby 4.0.6
bundle install            # into vendor/bundle (already configured)
bin/rails db:prepare      # creates + migrates pipeliner_development / _test
bin/dev                   # Procfile.dev: rails server (:3000) + tailwind watcher
```

Then open <http://localhost:3000> — the Rails welcome page (no root route yet)
— and <http://localhost:3000/up>, which must return 200. To verify the test and
lint toolchain:

```sh
bin/rails test            # Minitest
bin/rails test:system     # Capybara/Selenium system tests
bin/rubocop               # rubocop-rails-omakase
```

`bin/setup` bundles, prepares the DB, clears logs, and starts `bin/dev` in one
shot (idempotent; `--skip-server` to stop before launching).

---

## 3. Repo map

| Path | What it is |
|---|---|
| `docs/` | **Design source of truth.** Start at `docs/README.md`. `artifact-schema.md` and `data-model.md` are the closest to normative specs. |
| `guides/` | **Mandatory coding standards** — `backend-guide.md` (all Ruby/Rails) and `ui-style-guide.md` (all views/styling). Read before writing code. |
| `CLAUDE.md` | Agent/contributor instructions + the guide-enforcement policy. |
| `app/models/` | Persistence only: associations, validations, scopes, string enums, tiny intrinsic helpers. No business callbacks. |
| `app/services/` | **Where business logic lives** — verb-first POROs (`Pipelines::Create`), uniform `.call` → Result. *(Directory appears with the first service.)* |
| `app/queries/` | Query objects for complex reads; `SKIP LOCKED`-style operational SQL lives here or in its owning service, never inline in controllers. *(Also created on first use.)* |
| `app/jobs/` | Solid Queue jobs — thin wrappers that delegate to a service. |
| `app/controllers/` | Thin: auth + params + one service call + respond. Worker-facing endpoints go under `app/controllers/api/` (token auth, JSON only). |
| `app/views/` | ERB + shared components/partials per the UI guide (StatusBadge, Card, buttons — one source of truth each). |
| `app/lib/` | App-specific POROs that aren't services/queries (e.g. a future `GitHub::Client`). Top-level `lib/` only for framework-independent code. |
| `config/` | Standard Rails 8.1 config; PostgreSQL in `database.yml`; Solid Queue/Cache/Cable use dedicated DBs in production. |
| `bin/` | `dev`, `setup`, `rails`, `rubocop`, `brakeman`, `bundler-audit`, `ci`. |
| `.github/workflows/ci.yml` | CI: brakeman, bundler-audit, importmap audit, rubocop, tests + system tests against a Postgres service. |
| `vendor/bundle/` | Vendored gems (git-ignored). Don't touch by hand; `bundle install` manages it. |
| `.devenv` | The env fixer you `source` in every shell. |

**One distinction worth being explicit about:** the `.pipeliner/` directory
described throughout the design docs is the artifact workspace that lives **in
the target repos that pipelines operate on** (on each pipeline's branch). There
is no `.pipeliner/` directory in *this* repo — this repo is the control plane
that reads/writes that schema remotely.

---

## 4. The rules (non-negotiable)

From `guides/backend-guide.md`:

- **All business logic in reusable POROs** — services, domain objects, value
  objects. Not in controllers, not in jobs, not in model callbacks.
- **Services**: one class = one business action, verb-first, namespaced by
  domain (`app/services/pipelines/create.rb`). `call` is the only public
  method; keyword args; returns a **Result** (`success?` / `value` / `error`) —
  domain failures are data, not exceptions.
- **Services own transactions and side-effect ordering**: persist → enqueue →
  broadcast, with jobs/broadcasts only after commit.
- **Controllers are thin** (target ≤ ~10 lines/action): authenticate,
  authorize, strong params, one service call, branch only on `result.success?`.
  Worker API controllers under `api/`, token auth, JSON only.
- **Models are persistence-only**; enums stored as **strings**; state
  transitions with rules get a service, not scattered `update!` calls.
- **Jobs are thin wrappers** around a service; idempotent by design.
- **Broadcasts come from services after commit**, never model callbacks.
- **Minitest**; services are the primary test unit; every bugfix lands with a
  regression test.
- **DB constraints mirror critical validations** (null/unique/FK).

From `guides/ui-style-guide.md`:

- **Tailwind only, on the defined scale**: spacing steps 2/4/6/8/12, the six
  type styles, neutrals + one indigo accent.
- **Status colors are semantic and reserved** (blue=running, green=success,
  amber=needs attention, red=stuck/failed, gray=pending) — and status is
  **never conveyed by color alone**.
- **Shared components** (StatusBadge, Card, buttons) have one source of truth —
  don't re-style ad hoc.
- **Turbo Streams target the smallest DOM unit** (a badge, a card, keyed by
  `dom_id`), and **every page renders correct state without the socket** —
  streams are enhancement, never correctness.

The enforcement policy (from `CLAUDE.md`): **consult the guides before and
while writing any code. A PR that deviates from a guide is wrong — unless the
guide itself is explicitly updated in the same PR.** If a guide is silent,
follow its principles and propose a guide addition alongside your change.

---

## 5. How to extend

### Adding a model + migration

Follow `docs/data-model.md` — it specifies every table, column, and index the
control plane needs; don't invent schema that contradicts it. House style:
string enums, DB constraints mirroring validations, reversible migrations, no
data + schema changes in one migration.

```ruby
# db/migrate/XXXX_create_pipelines.rb
class CreatePipelines < ActiveRecord::Migration[8.1]
  def change
    create_table :pipelines do |t|
      t.references :project, null: false, foreign_key: true
      t.string :title, null: false
      t.string :branch, null: false
      t.string :status, null: false, default: "draft"
      t.string :current_phase, null: false, default: "define"
      t.jsonb :config, null: false, default: {}
      t.timestamps
    end
    add_index :pipelines, [ :project_id, :status ]
    add_index :pipelines, [ :project_id, :branch ], unique: true
  end
end

# app/models/pipeline.rb — persistence only
class Pipeline < ApplicationRecord
  belongs_to :project
  has_many :phases, dependent: :destroy

  enum :status, { draft: "draft", running: "running", awaiting_human: "awaiting_human",
                  blocked: "blocked", stuck: "stuck", completed: "completed",
                  aborted: "aborted" }

  validates :title, :branch, presence: true
end
```

No callbacks that trigger business logic — seeding the four phases, cutting the
branch, opening the PR all belong in the creation *service*, not `after_create`.

### Adding a service

```ruby
# app/services/pipelines/create.rb
module Pipelines
  class Create
    Result = Struct.new(:success?, :value, :error, keyword_init: true)

    def self.call(project:, title:, initial_prompt:)
      new(project:, title:, initial_prompt:).call
    end

    def initialize(project:, title:, initial_prompt:)
      @project = project
      @title = title
      @initial_prompt = initial_prompt
    end

    def call
      pipeline = nil
      ApplicationRecord.transaction do
        pipeline = @project.pipelines.create!(title: @title, initial_prompt: @initial_prompt, ...)
        seed_phases(pipeline)
      end
      # Side effects only after the transaction commits:
      Pipelines::OpenPrJob.perform_later(pipeline)
      broadcast_created(pipeline)
      Result.new(success?: true, value: pipeline)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(success?: false, error: e.record.errors)
    end
    # ...
  end
end
```

Conventions: verb-first name, domain namespace, keyword args, `call` as the
only public entry, Result out (never raise for flow control), transaction owned
by the service, jobs/broadcasts after the transaction block (or via
`ActiveRecord.after_all_transactions_commit`). Once a shared Result object
exists (e.g. `app/lib/result.rb` or `ApplicationService`), use it instead of
per-service structs — one source of truth.

### Adding a controller + route + view

```ruby
# config/routes.rb
resources :projects do
  resources :pipelines, only: %i[index show new create]
end

# app/controllers/pipelines_controller.rb
class PipelinesController < ApplicationController
  def create
    project = current_user.projects.find(params[:project_id])
    result = Pipelines::Create.call(project:, **pipeline_params.to_h.symbolize_keys)
    if result.success?
      redirect_to project_pipeline_path(project, result.value)
    else
      @errors = result.error
      render :new, status: :unprocessable_entity
    end
  end

  private

  def pipeline_params
    params.expect(pipeline: [ :title, :initial_prompt ])
  end
end
```

Views follow the UI guide: page header with one primary action top-right,
`max-w-3xl` forms / `max-w-7xl` boards, shared StatusBadge/Card partials or
ViewComponents, `dom_id`-keyed elements for anything Turbo Streams will update.

### Adding a background / recurring job

```ruby
# app/jobs/leases/sweep_expired_job.rb — a thin wrapper, nothing more
class Leases::SweepExpiredJob < ApplicationJob
  queue_as :default
  def perform = Leases::SweepExpired.call
end
```

Recurring work (lease sweeper, stuck detection) goes in Solid Queue's recurring
tasks (`config/recurring.yml`), each entry pointing at a thin job that delegates
to a service. Jobs must be idempotent — the reclaim model depends on it.

### Adding a worker API endpoint

Worker-facing endpoints live under `app/controllers/api/`, authenticate with a
bearer token, and speak JSON only:

```ruby
# app/controllers/api/base_controller.rb
module Api
  class BaseController < ActionController::API
    before_action :authenticate_worker!

    private

    def authenticate_worker!
      token = request.headers["Authorization"]&.delete_prefix("Bearer ")
      @current_worker = Workers::Authenticate.call(token:).value
      head :unauthorized unless @current_worker
    end
  end
end

# app/controllers/api/claims_controller.rb
module Api
  class ClaimsController < BaseController
    def create
      result = StepRuns::Claim.call(worker: @current_worker, roles: params[:roles])
      if result.success?
        render json: result.value        # lease + context bundle
      else
        head :no_content                 # nothing claimable
      end
    end
  end
end
```

Route under a namespace: `namespace :api { resources :claims, only: :create }`.
The claim service owns the `FOR UPDATE SKIP LOCKED` query (see
`docs/data-model.md` → "Key behaviors"); the controller never touches SQL.
Protocol details (heartbeat 15s / lease 60s, cancel flag in the heartbeat
response, epoch fencing) are specified in `docs/worker.md`.

### Adding a derived, live-broadcast status view

The **pipeline status summary** is the reference example of a piece of UI that
is *derived* (computed from current state, never stored) and *live* (rebroadcast
whenever that state changes). The board carries a single, prominent, plain-
language line per pipeline — *"Define: requirements-writer is drafting
requirements, iteration 3"*, *"Waiting on human approval at the Plan gate"*,
*"Build: 4 steps are running"*, *"Failed in Build: code-writer could not
complete"* — that always reflects the true current state. Copy this shape for any future summarize-the-whole-thing view
(a project rollup, a phase health line, etc.).

Three pieces, each landing where the guides put it:

- **The read is a domain value PORO** — `app/lib/pipelines/status_summary.rb`,
  a pure derivation object with no side effects. It lives in `app/lib`, **not**
  `app/queries`: a query object returns an `ActiveRecord::Relation`, but this
  returns an in-memory value, so it belongs with "app/lib for app-specific POROs
  that aren't services/queries" (`guides/backend-guide.md`). Its entry point is
  `Pipelines::StatusSummary.for(pipeline)` — `.for`, **not** `.call`, because the
  guide reserves `.call` for verb-first services that perform a business action;
  a pure read reads more honestly as `.for` and won't be mistaken for a mutation.
  It returns a `Summary` value carrying the finished sentence (`text`, never
  blank) plus a **semantic tone** (`:info` / `:success` / `:attention` /
  `:danger` / `:muted`) drawn from the same `StatusHelper` `STATUS_TONES` /
  `TONE_CLASSES` vocabulary the badges use, so the summary and the badge can
  never disagree.

  `build` is a **total function**: an ordered list of first-match branches,
  most operationally salient first, ending in an **unconditional catch-all** so
  every current or future pipeline state yields a non-blank, truthful sentence.
  The order is completed → failed (names the phase, and the step when known) →
  canceled (`aborted`) → awaiting-human (gate wait vs. escalation) →
  blocked/stuck → running → not-started → default. For a `running` pipeline it
  looks at the current phase's **active runs** (state `running` or `claimed` — a
  worker is actually leased): **one** active step names the phase, role, and
  what it's doing (its latest `progress["message"]`, the same field the step
  card shows, or a type verb like `planning`/`building`/`reviewing`), appending
  `, iteration N` **only on the 2nd+ pass** (hidden on the first attempt);
  **two** active steps name **both**; **three or more** collapse to
  *"&lt;Phase&gt;: N steps are running"* rather than naming each. Keep every
  branch of the wording in this one object so there is a single source of truth
  for how state reads in English — distinct from `ManagerDecision#rationale`,
  which is the *persisted* per-decision log, not the live board line.

  ```ruby
  # app/lib/pipelines/status_summary.rb
  module Pipelines
    class StatusSummary
      Summary = Data.define(:text, :tone, :phase_label) do
        def to_s = text
      end

      def self.for(pipeline) = new(pipeline).build
      def initialize(pipeline) = @pipeline = pipeline
      def build = ...  # -> Summary; pure, reads current associations only
    end
  end
  ```

- **The render is the smallest DOM unit.** A `pipelines/_status_summary`
  partial renders inside a container keyed `dom_id(pipeline, :summary)`, wrapped
  in an `aria-live="polite"` region so screen readers announce changes — status
  is carried by a status dot + the sentence, **never color alone** (UI guide).
  One partial, two variants selected by a `compact:` local, both calling the
  same `StatusSummary.for` so the surfaces can never disagree: the **full**
  variant sits high on `pipelines/show` (a Card, above the phase columns), the
  **compact** variant is a single truncated line per row on `pipelines/index`.
  `pipelines/show` already establishes the stream with
  `turbo_stream_from @pipeline`; the summary reuses it — and `pipelines/index`
  gains its **first** subscription, a per-row `turbo_stream_from pipeline`, so
  the list updates live too. Because the partial is rendered on load from the
  same value PORO, a dropped broadcast is cosmetic, never a correctness bug. The
  tone → dot-color mapping goes through a one-line `PipelinesHelper`
  (`summary_dot_class(tone)`) that reuses `StatusHelper::TONE_CLASSES`, so no new
  color literal is introduced. To keep both controllers free of N+1, a
  `Pipeline.with_board` scope
  (`includes(phases: { workflows: { steps: { step_runs: :worker } } })`)
  preloads the whole tree the summary reads; `#show` and `#index` both use it.

- **The broadcast is a one-line service fired from the services that already
  mutate state** — never a model callback. Mirror `StepRuns::BroadcastCard`
  with a `Pipelines::BroadcastStatus.call(pipeline)` that
  `broadcast_replace_later_to(pipeline, target: dom_id(pipeline, :summary),
  partial: "pipelines/status_summary")`. Because `_later_to` re-renders the
  partial **in a job that reloads the pipeline from the DB**, every broadcast
  paints freshly-derived current state — so a late or racing broadcast still
  lands on the *actual latest* state, and an older event can never repaint a
  stale summary over a newer one. Add that one call, after commit, wherever
  pipeline-visible state turns over: `StepRuns::Claim`, `StepRuns::RecordProgress`
  and `StepRuns::Complete` (run started / progressed / finished — one line right
  after the existing `BroadcastCard.call`), and `Phases::ManagerTick` (once at
  the end of `call`, after `broadcast_affected`). The `ManagerTick` seam is the
  essential one: a gate-wait or an escalation to `awaiting_human` changes **only**
  phase/pipeline status and touches no step card, so without it *"Waiting on
  human approval at the Plan gate"* would never appear live. Keep `BroadcastStatus`
  separate from `BroadcastCard` (don't fold it in): a tick that touches N cards
  should refresh the one summary **once**, not N times. *(Designed but out of
  scope, noted so it isn't mistaken for covered: broadcasting from
  `StepRuns::Sweep` for instant `stuck` flips, first paint from `Pipelines::Create`,
  and a real `paused` pipeline status to make "Paused" wording reachable — today
  only `aborted` → "Canceled" is.)*

This is the first **pipeline-level** broadcast in the app; until now only step
cards (`dom_id(step, :card)`) streamed. The precedent to keep: derived reads are
pure value POROs, live rebroadcast is a thin service called by state-changing
services after commit, and the on-load render is always authoritative.

---

## 6. How to debug

- **Console:** `source .devenv` first, then `bin/rails console`. Services are
  plain objects — exercise them directly:
  `Pipelines::Create.call(project: Project.first, title: "test", ...)`.
- **Logs:** `tail -f log/development.log`. Turbo Stream broadcasts, SQL, and
  job activity all show up here.
- **Solid Queue:** jobs run in-process in development (`bin/dev`). Inspect from
  the console: `SolidQueue::Job.order(created_at: :desc).limit(10)`,
  `SolidQueue::FailedExecution.all`, `SolidQueue::ReadyExecution.count`. If we
  add `mission_control-jobs` later, you'll get a UI at `/jobs`; until then the
  console is the tool.
- **Breakpoints:** the `debug` gem is loaded — drop `debugger` anywhere.
  `bin/dev` exports `RUBY_DEBUG_OPEN=true` / `RUBY_DEBUG_LAZY=true`, so when a
  breakpoint fires under foreman you can attach with `rdbg -A`.
- **Turbo Streams:** if the UI isn't updating live — (1) check
  `log/development.log` for the `broadcast` line (no broadcast = the service
  never sent it, likely a rollback or a broadcast placed inside the
  transaction); (2) check that the partial's DOM id matches the broadcast
  target (`dom_id(record)` / `dom_id(record, :progress)` on both sides);
  (3) remember the rule: **every page must render true state without the
  socket** — hard-refresh; if the state is wrong *after* a refresh the bug is
  in the render path, not the broadcast.
- **Common gotchas:**
  - *Forgot `source .devenv`* → wrong Ruby (RVM's 3.0), gems resolving from an
    old gemset, native-extension errors (bcrypt/pg) that look like corruption.
    Fix: new shell, `source .devenv`, retry.
  - *Postgres not running* → `connection refused` on any db task.
    `brew services start postgresql@16` (or `@14`).
  - *`vendor/bundle` missing or stale* → `bundler: command not found` /
    `Bundler::GemNotFound`. Run `bundle install` (path is already configured).
  - *Foreman interleaving output* — run `bin/rails server` and
    `bin/rails tailwindcss:watch` in separate terminals when you need clean
    logs or a usable `debugger` prompt.

---

## 7. Current state & roadmap

Honesty check: **the app is a fresh Rails 8.1.3 scaffold — the design is
complete, the domain code is not.** Everything in `docs/` describes the target
system; almost none of it exists in `app/` yet. Build order:

1. **Data model** — migrations + models per [`data-model.md`](./data-model.md).
2. **Devise + app shell** — auth, sidebar layout per the UI guide.
   *(Devise, and later `aws-sdk-s3`, are decided in
   [`tech-stack.md`](./tech-stack.md) but not yet in the Gemfile — add them
   when their task starts.)*
3. **Projects / Pipelines CRUD** — first real services + thin controllers.
4. **Worker API** (PLANNED) — claim/heartbeat/progress/result endpoints per
   [`worker.md`](./worker.md) and [`architecture.md`](./architecture.md).
5. **Pipeline board** (PLANNED) — the signature live view per
   [`ui-style-guide.md`](../guides/ui-style-guide.md) → "The pipeline board".

Also PLANNED, design settled but no code: **GitHub integration** (App tokens,
branch rulesets, control-plane merges — [`architecture.md`](./architecture.md)
→ Git topology), **S3 archival/finalization**
([`artifact-schema.md`](./artifact-schema.md) → Finalization), the **Manager
LLM loop** ([`execution-model.md`](./execution-model.md)), and the **reference
Node/TS Worker** ([`worker.md`](./worker.md) — a separate deliverable, likely a
separate repo). If you're reading this after some of those have landed, trust
the code + design docs over this list, and fix the list.

---

## 8. Keeping this guide current

Any PR that makes a substantive structural change — new top-level directory,
new subsystem, changed setup steps, changed conventions — **updates this guide
in the same PR.** Same policy as the guides: no silent drift.
