import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { Bundle } from "./api.js";
import type { Config } from "./config.js";

const exec = promisify(execFile);

/**
 * Per-repo async mutex. Concurrent steps of the same project share one cached
 * clone; their `git fetch` / `git worktree add` / branch mutations touch shared
 * git state and must not interleave. This is a tiny promise-chain lock keyed by
 * repoDir: each acquire runs after the previous holder for the same key settles,
 * while different repos proceed in parallel. The stored tail swallows errors so a
 * failed critical section never wedges the chain; `fn`'s own result/rejection is
 * returned to its caller unchanged. The map holds at most one entry per repoDir.
 */
const repoLocks = new Map<string, Promise<unknown>>();

function withRepoLock<T>(repoDir: string, fn: () => Promise<T>): Promise<T> {
  const prev = repoLocks.get(repoDir) ?? Promise.resolve();
  const run = prev.then(fn, fn);
  repoLocks.set(repoDir, run.then(() => {}, () => {}));
  return run;
}

/**
 * Workspace management: one cached clone per project, one fresh worktree per
 * step on its own step branch (branch-per-step, docs/architecture.md).
 *
 * v0 notes (local-first):
 *  - Uses ambient git credentials; short-lived GitHub App tokens arrive with
 *    the GitHub integration.
 *  - Ensures the pipeline branch exists (cut from the default branch) because
 *    the control plane's branch/PR creation isn't built yet.
 *  - Pushes are best-effort: failure to push leaves the commit local and is
 *    reported in the result rather than failing the step.
 */
export class Workspace {
  readonly repoDir: string;
  readonly worktreeDir: string;

  constructor(private readonly config: Config, private readonly bundle: Bundle) {
    const repoSlug = bundle.project.repo_url.replace(/\W+/g, "_").slice(-80);
    this.repoDir = join(config.reposDir, repoSlug);
    this.worktreeDir = join(config.reposDir, ".worktrees", `run-${bundle.step_run.id}-${bundle.step_run.epoch}`);
  }

  private git(args: string[], cwd?: string) {
    return exec("git", args, { cwd: cwd ?? this.repoDir, timeout: 120_000, maxBuffer: 64 * 1024 * 1024 });
  }

  async prepare(): Promise<void> {
    const { repo_url, default_branch } = this.bundle.project;
    const pipelineBranch = this.bundle.pipeline.branch;
    const stepBranch = this.bundle.step_run.step_branch;

    // Serialize the whole clone/fetch/branch/worktree body against other steps
    // sharing this cached clone; distinct repos still prepare in parallel.
    await withRepoLock(this.repoDir, async () => {
      await mkdir(this.config.reposDir, { recursive: true });

      if (!existsSync(this.repoDir)) {
        await exec("git", ["clone", repo_url, this.repoDir], { timeout: 300_000, maxBuffer: 64 * 1024 * 1024 });
      } else {
        await this.git(["fetch", "origin", "--prune"]);
      }

      // Decide the base ref for the step worktree. Prefer origin's pipeline
      // branch when it exists: the control plane merges step branches into the
      // pipeline branch on origin, so a local pipeline ref would go stale.
      const originHasPipeline =
        (await this.git(["ls-remote", "--heads", "origin", pipelineBranch])).stdout.trim() !== "";
      const localHasPipeline =
        (await this.git(["branch", "--list", pipelineBranch])).stdout.trim() !== "";

      let base: string;
      if (originHasPipeline) {
        // Always cut the worktree from origin's ref so it reflects merged state.
        base = `origin/${pipelineBranch}`;
        // Keep the local ref in sync for readers, best-effort. Safe because the
        // cached clone never checks out pipeline branches (worktrees sit on step
        // branches); if it somehow is checked out, git refuses and we ignore it —
        // the worktree base above (origin/<pipelineBranch>) doesn't need it.
        if (localHasPipeline) {
          await this.git(["branch", "-f", pipelineBranch, `origin/${pipelineBranch}`]).catch(() => {});
        }
      } else if (localHasPipeline) {
        // Origin doesn't have it yet but a previous step cut it locally — reuse it.
        base = pipelineBranch;
      } else {
        // v0: neither exists (control-plane branch creation isn't built) — cut the
        // pipeline branch from the default branch and base the worktree on it.
        await this.git(["branch", pipelineBranch, `origin/${default_branch}`]);
        base = pipelineBranch;
      }

      // Fresh worktree on the step branch, cut from the resolved base.
      await mkdir(join(this.config.reposDir, ".worktrees"), { recursive: true });
      await this.git(["worktree", "add", "-b", stepBranch, this.worktreeDir, base]);
    });
  }

  /** Commits everything in the worktree. Returns the commit sha, or null if nothing changed. */
  async commitAll(message: string): Promise<string | null> {
    await this.git(["add", "-A"], this.worktreeDir);
    const status = (await this.git(["status", "--porcelain"], this.worktreeDir)).stdout.trim();
    if (status === "") return null;

    await this.git(["-c", "user.name=Pipeliner Worker", "-c", "user.email=worker@pipeliner.local",
      "commit", "-m", message], this.worktreeDir);
    return (await this.git(["rev-parse", "HEAD"], this.worktreeDir)).stdout.trim();
  }

  /** Best-effort push of the step branch. Returns true on success. */
  async push(): Promise<boolean> {
    try {
      await this.git(["push", "origin", this.bundle.step_run.step_branch], this.worktreeDir);
      return true;
    } catch {
      return false;
    }
  }

  /** Removes the worktree (and its branch if the run is being abandoned). */
  async cleanup(dropBranch: boolean): Promise<void> {
    // Worktree remove/prune mutate the shared clone's worktree metadata, so hold
    // the per-repo lock while doing it (kept brief — no Claude execution here).
    await withRepoLock(this.repoDir, async () => {
      try {
        await this.git(["worktree", "remove", "--force", this.worktreeDir]);
      } catch {
        await rm(this.worktreeDir, { recursive: true, force: true }).catch(() => {});
        await this.git(["worktree", "prune"]).catch(() => {});
      }
      if (dropBranch) {
        await this.git(["branch", "-D", this.bundle.step_run.step_branch]).catch(() => {});
      }
    });
  }
}
