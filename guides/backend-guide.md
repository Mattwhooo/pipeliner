# Pipeliner — Backend Development Guide

> Persistent guide. Conventions for all Ruby/Rails code in this repo. When a PR
> deviates from this guide, the PR is wrong or the guide needs an explicit update
> — never silent drift.

## Architecture at a glance

```
Controller (thin: auth + params + delegate + respond)
    └─> Service PORO (one business action, composable)
          ├─> Models (persistence, associations, validations, scopes)
          ├─> Query objects (complex reads)
          └─> Domain POROs (values, results, state logic)
Jobs (thin: retry/queue config + delegate to a service)
Broadcasts (after business action succeeds, from the service layer)
```

## Business logic lives in reusable POROs

- **All business logic goes in plain Ruby objects** — services, domain objects,
  value objects. Not in controllers, not in jobs, not in callbacks, and models
  only own what is intrinsically theirs (validity, associations, simple
  derivations).
- POROs must be **reusable and composable**: callable from controllers, jobs,
  the console, tests, and other services with no HTTP/job context assumed.
- No `ActiveSupport::Concern` grab-bags for business behavior. Concerns are for
  genuinely shared *model* behavior (e.g. `Sluggable`), not to hide fat logic.

## Services

- One class = **one business action**, named verb-first:
  `Pipelines::Create`, `StepRuns::Claim`, `Phases::AdvanceGate`,
  `Workers::RecordHeartbeat`.
- Location: `app/services/`, namespaced by domain
  (`app/services/pipelines/create.rb`).
- **Uniform interface:** `Result = ServiceName.call(...)` with keyword args.
  `call` is the only public method.
- **Return a Result, don't raise for flow control:**
  ```ruby
  result = StepRuns::Claim.call(worker:, roles:)
  result.success? # => true/false
  result.value    # the claimed run (on success)
  result.error    # symbol/message (on failure)
  ```
  Raise only for programmer errors and truly exceptional states.
- Services own **transactions** (`ApplicationRecord.transaction`) — a business
  action is atomic or it isn't done.
- Services own **side-effect ordering**: persist → enqueue jobs → broadcast.
  Broadcasts/jobs happen only after the write commits (`after_commit` semantics —
  use `ActiveRecord.after_all_transactions_commit` or enqueue inside the service
  after the transaction block).

## Controllers — light, always

- Responsibilities: **authenticate, authorize, parse params, call one service,
  respond.** Nothing else. Target ≤ ~10 lines per action.
- No business branching in controllers — a controller may branch only on
  `result.success?` to pick a response.
- Strong params always; never pass raw `params` into services.
- Respond with Turbo Streams / HTML / JSON as the request asks; API (worker)
  controllers live under `app/controllers/api/` with token auth and JSON only.
- No instance-variable soup: one primary ivar per action where possible.

## Models

- Persistence concerns only: associations, validations, scopes, enums, small
  intrinsic helpers (`stuck?`, `display_name`).
- **No callbacks that trigger business logic** (no `after_save :open_pr!`).
  Callbacks are for data hygiene (normalization, defaults) at most.
- Enums as strings in the DB (readable, migration-safe):
  `enum :state, { ready: "ready", claimed: "claimed", ... }`.
- State transitions that carry rules get a service (`StepRuns::Transition`),
  not ad-hoc `update!` calls scattered around.

## Query objects

- Complex/reporting reads: `app/queries/`, e.g. `StepRuns::ClaimableFor.new(worker).relation`.
- Return `ActiveRecord::Relation` where composability matters.
- Keep `SKIP LOCKED`-style operational SQL in one place (the query/service that
  owns it), never inline in controllers.

## Jobs (Solid Queue)

- Jobs are **thin wrappers**: queue/retry config + a single service call.
  ```ruby
  class Leases::SweepExpiredJob < ApplicationJob
    def perform = Leases::SweepExpired.call
  end
  ```
- Idempotent by design — safe to run twice (the sweeper/reclaim model depends on
  this).
- Recurring work (sweeps, stuck detection) via Solid Queue recurring tasks, each
  delegating to a service.

## Errors & results

- Domain failures are **data** (Result objects), not exceptions.
- Define a small error taxonomy per domain when needed
  (`Pipelines::Error < StandardError`) for the genuinely exceptional.
- Never rescue `StandardError` blindly; rescue what you can handle.
- **Presentation-boundary rescue (sanctioned exception):** a multi-panel
  aggregate view (e.g. the dashboard) may wrap each independent panel's
  single read in a narrow `rescue StandardError`, logged and converted to
  `nil`, so one panel's infrastructure failure doesn't 500 the whole page.
  Scope it to exactly one call per rescue (never a block of business logic),
  and only for read-only query objects — a service with side effects must
  still return a `Result`, never rely on this.

## Real-time (Turbo) conventions

- Broadcasts happen from **services** (after commit), not model callbacks.
- Target the smallest partial (badge/card), keyed by `dom_id`.
- Every page must render correct state without the socket (streams are
  enhancement — see UI guide).

## Testing

- **Minitest** (Rails default). Test services as the primary unit: given inputs →
  Result + state changes + enqueued jobs/broadcasts.
- Controller tests are thin (auth, status codes, delegation); system tests cover
  the critical flows (pipeline board, gate approval, worker claim API).
- Fixtures or plain factories — keep test data explicit and small.
- Every bugfix lands with a regression test.

## General Rails practice

- Latest stable Ruby/Rails; run `rubocop-rails-omakase` (Rails 8 default linting)
  — don't fight it.
- Migrations: reversible, no data + schema in one migration; heavy backfills as
  jobs.
- DB constraints mirror critical validations (null, unique, FK) — the DB is the
  last line of defense (uniqueness of claims, etc.).
- Credentials via Rails credentials/env — never committed. GitHub App keys, S3
  keys, worker tokens all via config.
- `app/lib` for app-specific POROs that aren't services/queries (e.g.
  `GitHub::Client` wrapper); top-level `lib/` only for genuinely
  framework-independent code.
- Prefer boring, obvious code over clever metaprogramming. Optimize for the next
  reader — which here may be an agent.
