# Pipeliner reference worker

The Node/TypeScript worker from [docs/worker.md](../docs/worker.md): it polls
the control plane, claims one step at a time (role-matched), executes it by
launching **Claude Code** headlessly in a dedicated git worktree on the step's
own branch, streams progress + heartbeats (with cooperative cancel), and
reports completion.

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
| `PIPELINER_CONCURRENCY` | `1` | Advertised concurrency (loop executes one step at a time) |
| `PIPELINER_REPOS_DIR` | `~/.pipeliner-worker/repos` | Clone + worktree location |
| `PIPELINER_POLL_INTERVAL` | `5` | Seconds between claim polls when idle |
| `PIPELINER_CLAUDE_BIN` | `claude` | Claude Code binary |
| `PIPELINER_STEP_TIMEOUT` | `900` | Per-step wall-clock cap (seconds) |

## v0 scope (deliberate simplifications)

- **Subprocess, not container.** The design calls for an ephemeral container
  per step; v0 runs Claude Code directly (with `--dangerously-skip-permissions`,
  confined to the worktree by instruction + branch rules). Container mode is
  the next hardening step.
- **Ambient git credentials.** Short-lived GitHub App tokens arrive with the
  GitHub integration; until then the worker uses whatever git auth it has.
  Pushes are best-effort — a failed push is recorded in the result, not fatal.
- **Worker cuts the pipeline branch if missing** (control-plane branch/PR
  creation isn't built yet).
- One step at a time regardless of advertised concurrency.
