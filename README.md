# Pipeliner

A Rails app for managing **agentic development pipelines**: agent-driven
processes that carry a unit of work from an initial ask — through Define, Plan,
Build, and Review phases — to a reviewed, merge-ready PR, executed by
distributed, model-agnostic workers.

## Start here

- **[docs/developer-guide.md](docs/developer-guide.md)** — setup, running the
  app, extending it, debugging. Read this first.
- **[docs/README.md](docs/README.md)** — the design docs index (architecture,
  execution model, data model, worker spec).
- **[guides/](guides/)** — mandatory coding standards (backend + UI). All code
  must follow these.
- **[CLAUDE.md](CLAUDE.md)** — instructions for AI agents working in this repo.

## Quick start

```sh
source .devenv        # selects Homebrew Ruby, neutralizes RVM — required
bundle install
bin/rails db:prepare db:seed
bin/dev               # http://localhost:3000 — dev@pipeliner.local / password123
```
