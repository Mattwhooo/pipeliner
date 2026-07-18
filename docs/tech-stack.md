# Pipeliner — Technology Stack

> Working draft. Records the platform decisions and how they map onto the
> architecture. Builds on [architecture.md](./architecture.md).
> **[OPEN]** marks unresolved items. Exact versions to be pinned at scaffold time.

## Directives (from the product owner)

- **Ruby on Rails**, latest-and-greatest Ruby and Rails.
- UI must be **simple, elegant, and real-time.**
- Use **as much built-in Rails technology as possible** — minimize external deps.

## Core platform

| Concern            | Choice                                        | Notes                                              |
|--------------------|-----------------------------------------------|----------------------------------------------------|
| Language           | **Ruby** (latest stable; confirm at scaffold) | e.g. 3.4+/3.5 — pin the newest stable at `rails new`|
| Framework          | **Rails 8.x** (latest stable)                 | Lean on the modern default stack below             |
| Database           | **PostgreSQL**                                | Chosen over SQLite for concurrent workers/queue    |
| Real-time UI       | **Hotwire — Turbo + Stimulus**                | Built-in; no SPA framework                          |
| Live updates       | **Turbo Streams broadcast** over **Solid Cable** | DB-backed Action Cable, no Redis                 |
| Background jobs    | **Solid Queue** (Active Job)                  | DB-backed; Rails 8 default                          |
| Cache              | **Solid Cache**                               | DB-backed; Rails 8 default                          |
| Assets / JS        | **Propshaft + import maps**                   | No Node build step; built-in                        |
| Auth               | **Devise**                                    | Standard, well-worn Rails auth                      |
| Object storage     | **S3** (via `aws-sdk-s3`)                     | Zipped `.pipeliner/` archives at end of Review      |
| Deployment         | **Local-first now**; **Kamal** to cloud later | Run control plane locally while iterating; host TBD |
| Styling            | **Tailwind CSS** (`tailwindcss-rails`)        | Fast path to a clean, consistent, elegant UI        |
| Step isolation     | **Ephemeral container per step**              | Provisioned by the Worker; strongest blast-radius control |

> The "Solid trio" (Queue + Cache + Cable) means **Postgres is the only backing
> service** — no Redis. That is a deliberate simplicity win.

## Why this maps cleanly onto our architecture

The runtime we designed in [architecture.md](./architecture.md) lines up almost
one-to-one with built-in Rails 8 tech:

- **Real-time worker progress & heartbeats** → **Turbo Streams broadcasts**. When
  a step advances, the control plane broadcasts a partial; the UI updates live
  with no custom JS. This directly delivers "simple, elegant, real-time."
- **Internal orchestration** (Manager loops, heartbeat-timeout sweeps, reclaiming
  dead steps, scheduling) → **Solid Queue** jobs. Deterministic, DB-backed,
  observable.
- **The versioned artifact workspace** → Active Record models with versioning.
- **Git branch + PR per pipeline** → a service layer shelling out to git / the
  GitHub API from jobs.

## Two distinct "queues" — do not conflate

This is the one subtlety. There are **two** queue-like things:

1. **Solid Queue (internal).** Rails' own background jobs — the control plane's
   async work (run a Manager tick, sweep heartbeats, open a PR). Pure Ruby, in
   the app.
2. **The Step work queue (external).** The pool of **ready Steps** that external
   **Worker processes** poll and claim. Workers are **model-agnostic and may not
   be Ruby** (a Claude agent, a Python process, another LLM), so they cannot be
   Solid Queue consumers. They claim work over an **HTTP/JSON API** backed by a
   `steps` table (state machine: ready → claimed → running → done/failed).

So: **Solid Queue runs the app's own async work; a thin HTTP API exposes the Step
queue to outside workers.** Keeping these separate is important to the design.

## UI principles

- **Hotwire-first, JS-minimal.** Reach for Turbo Streams before Stimulus, and
  Stimulus before any bespoke JavaScript. No React/Vue/SPA.
- **Server-rendered, live-updated.** The pipeline board, phase loops, and worker
  heartbeats update in place via broadcasts.
- **Elegant = restrained.** Clean typography, calm layout, clear state at a
  glance (which phase, which steps running, consensus status).
- **Step configuration is a first-class UI surface.** Users manage the **Step
  Library** (CRUD on Step Templates: role, system prompt, inputs/outputs,
  required/conditional) and **compose workflows** (add/order steps, wire
  dependencies) — standard Rails CRUD + Hotwire, no SPA. Agentic composition (a
  Planner selecting steps) coexists with manual editing.

## Decided since first draft

- **Ship a reference Worker** (drives Claude Code, leaning Node/TS) as a distinct
  deliverable — see [worker.md](./worker.md). App is *not* control-plane-only.
- **Worker auth:** short-lived, **step-scoped API key** delivered in the context
  bundle (least privilege, expires with the lease).

## Open questions

- **[OPEN]** Exact Ruby & Rails versions — pin the newest stable at scaffold.
- **[OPEN]** Cloud host / Kamal deployment target — deferred (local-first for now).
- **[OPEN]** Per-step container base image + workspace provisioning (deps/DB/
  services/browser) — see pressure-test finding C2.
