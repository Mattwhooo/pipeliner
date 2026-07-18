import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";
import type { Bundle } from "./api.js";
import type { Config } from "./config.js";

const exec = promisify(execFile);

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
    return exec("git", args, { cwd: cwd ?? this.repoDir, timeout: 120_000 });
  }

  async prepare(): Promise<void> {
    const { repo_url, default_branch } = this.bundle.project;
    const pipelineBranch = this.bundle.pipeline.branch;
    const stepBranch = this.bundle.step_run.step_branch;

    await mkdir(this.config.reposDir, { recursive: true });

    if (!existsSync(this.repoDir)) {
      await exec("git", ["clone", repo_url, this.repoDir], { timeout: 300_000 });
    } else {
      await this.git(["fetch", "origin", "--prune"]);
    }

    // Ensure the pipeline branch exists (v0: worker cuts it if missing).
    const hasPipelineBranch =
      (await this.git(["branch", "--list", pipelineBranch])).stdout.trim() !== "" ||
      (await this.git(["ls-remote", "--heads", "origin", pipelineBranch])).stdout.trim() !== "";
    if (!hasPipelineBranch) {
      await this.git(["branch", pipelineBranch, `origin/${default_branch}`]);
    } else if ((await this.git(["branch", "--list", pipelineBranch])).stdout.trim() === "") {
      await this.git(["branch", pipelineBranch, `origin/${pipelineBranch}`]);
    }

    // Fresh worktree on the step branch, cut from the pipeline branch.
    await mkdir(join(this.config.reposDir, ".worktrees"), { recursive: true });
    await this.git(["worktree", "add", "-b", stepBranch, this.worktreeDir, pipelineBranch]);
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
    try {
      await this.git(["worktree", "remove", "--force", this.worktreeDir]);
    } catch {
      await rm(this.worktreeDir, { recursive: true, force: true }).catch(() => {});
      await this.git(["worktree", "prune"]).catch(() => {});
    }
    if (dropBranch) {
      await this.git(["branch", "-D", this.bundle.step_run.step_branch]).catch(() => {});
    }
  }
}
