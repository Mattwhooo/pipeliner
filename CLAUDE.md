# Pipeliner

Rails 8 app for managing agentic development pipelines. Design docs live in
`docs/` (start with `docs/README.md`); coding standards live in `guides/`.

## Design guides — mandatory

**Consult the guides before and while writing any code.** They are the standard;
PRs that deviate are wrong unless the guide itself is explicitly updated.

- `guides/backend-guide.md` — ALL Ruby/Rails code. Core rules: business logic in
  reusable POROs (services with a uniform `.call` → Result interface); controllers
  are thin (auth + params + one service call + respond); no business logic in
  callbacks or jobs; broadcasts from services after commit; Minitest.
- `guides/ui-style-guide.md` — ALL views/components/styling. Core rules: Tailwind
  with the defined type scale, spacing steps, and semantic status colors; shared
  components (StatusBadge, Card, buttons) — one source of truth; Turbo Streams
  target the smallest DOM unit; status never conveyed by color alone.

When making a UI decision (colors, spacing, component shape) or a backend
structural decision (where logic lives, service naming, error handling), check
the relevant guide first rather than improvising. If the guide is silent, follow
its principles, then propose a guide addition in the same PR.

## Architecture (summary — details in docs/)

- Hierarchy: Project (1:1 git repo) → Pipeline (1:1 branch+PR) → 4 fixed Phases
  (Define→Plan→Build→Review) → Workflows → Steps.
- Steps have `type` (planner/builder/critic/manager/gate) + arbitrary `role`
  (worker matching). Phases run Manager-driven consensus loops; inter-phase
  rework is forward-only.
- Distributed workers (Node/TS reference, one container per step) poll via HTTP,
  claim step_runs (SKIP LOCKED), heartbeat 15s / lease 60s, push `step/**`
  branches directly to GitHub; control plane merges via API after a pre-merge
  scope check.
- `.pipeliner/` on the pipeline branch is the artifact workspace (rigid schema in
  `docs/artifact-schema.md`); zipped to S3 + stripped at end of Review.

## Conventions

- Stack: Rails 8 (latest stable), PostgreSQL, Hotwire, Solid Queue/Cache/Cable,
  Tailwind, Devise, Propshaft + import maps. Local-first (no cloud deploy yet).
- Tests: Minitest. Run with `bin/rails test` (+ `test:system` for system tests).
- Lint: rubocop-rails-omakase (`bin/rubocop`).
