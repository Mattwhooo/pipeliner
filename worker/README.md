# Pipeliner reference worker

The Node/TypeScript worker from [docs/worker.md](../docs/worker.md): it polls
the control plane, claims steps (role-matched, up to its configured
concurrency), and executes each by launching **Claude Code** headlessly in a
dedicated git worktree on the step's own branch, streaming progress +
heartbeats (with cooperative cancel) and reporting completion.

## Run

```sh
cd worker
npm install
PIPELINER_URL=http://localhost:5000 npm start
```

Requires: Node 20+, `git`, and an authenticated `claude` CLI on PATH.

## Configuration (env)

| Variable | Default | Purpose |
|---|---|---|
| `PIPELINER_URL` | `http://localhost:5000` | Control plane |
| `PIPELINER_REGISTRATION_KEY` | `dev-registration-key` | Must match the app's `config.x.worker_registration_key` |
| `PIPELINER_WORKER_ID` | `wk_<hostname>` | Stable id across restarts |
| `PIPELINER_ROLES` | `code,requirements,review` | Arbitrary role labels this worker supports |
| `PIPELINER_CONCURRENCY` | `1` | Max steps executed in parallel (loop claims to fill this cap) |
| `PIPELINER_REPOS_DIR` | `~/.pipeliner-worker/repos` | Clone + worktree location |
| `PIPELINER_POLL_INTERVAL` | `5` | Seconds between claim polls when idle |
| `PIPELINER_CLAUDE_BIN` | `claude` | Claude Code binary |
| `PIPELINER_CLAUDE_MODEL` | `claude-opus-4-8` | Model for step execution (passed as `--model`; set empty to use the CLI default) |
| `PIPELINER_STEP_TIMEOUT` | `900` | Base per-step wall-clock cap (seconds). Timeouts auto-retry after ~1 minute with an escalated cap (base × attempt, max 3×) |

## v0 scope (deliberate simplifications)

- **Subprocess, not container.** The design calls for an ephemeral container
  per step; v0 runs Claude Code directly (with `--dangerously-skip-permissions`,
  confined to the worktree by instruction + branch rules). Container mode is
  the next hardening step.
- **Ambient git credentials.** Short-lived GitHub App tokens arrive with the
  GitHub integration; until then the worker uses whatever git auth it has.
  Pushes are best-effort — a failed push is recorded in the result, not fatal.
- **Worker cuts the pipeline branch if missing** (control-plane branch/PR
  creation isn't built yet). When origin has the pipeline branch (the control
  plane merges step branches into it), worktrees are cut from `origin/<pipeline>`
  so they never build on a stale local ref.
- **Concurrency is honored** up to `PIPELINER_CONCURRENCY`: the loop keeps
  claiming to fill the cap and runs those steps in parallel. Git workspace
  preparation and cleanup for the *same* project's cached clone are serialized by
  an in-process per-repo mutex (concurrent `fetch`/`worktree` on one clone would
  corrupt shared git state); Claude execution itself never holds the lock, and
  distinct projects prepare fully in parallel.
