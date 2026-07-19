import { hostname } from "node:os";
import { resolve } from "node:path";

/** Worker configuration, entirely from environment (12-factor). */
export interface Config {
  /** Control plane base URL, e.g. http://localhost:5000 */
  baseUrl: string;
  /** Shared secret for self-registration (control plane config.x.worker_registration_key). */
  registrationKey: string;
  /** Stable worker id across restarts (docs/worker.md). */
  workerId: string;
  workerName: string;
  /** Arbitrary role labels this worker supports (role-based matching). */
  roles: string[];
  concurrency: number;
  /** Directory where project repos are cloned and worktrees are created. */
  reposDir: string;
  /** Seconds between claim polls when there is no work. */
  pollIntervalSeconds: number;
  /** `claude` CLI binary. */
  claudeBin: string;
  /** Model passed via --model. Defaults to Opus 4.8; empty string = use the claude CLI's own default. */
  claudeModel: string;
  /** Hard wall-clock cap for one step execution. */
  stepTimeoutSeconds: number;
}

export function loadConfig(): Config {
  const env = process.env;
  return {
    baseUrl: (env.PIPELINER_URL ?? "http://localhost:5000").replace(/\/$/, ""),
    registrationKey: env.PIPELINER_REGISTRATION_KEY ?? "dev-registration-key",
    workerId: env.PIPELINER_WORKER_ID ?? `wk_${hostname().toLowerCase().replace(/[^a-z0-9]/g, "-")}`,
    workerName: env.PIPELINER_WORKER_NAME ?? `Claude Code worker on ${hostname()}`,
    roles: (env.PIPELINER_ROLES ?? "code,requirements,review").split(",").map((r) => r.trim()).filter(Boolean),
    concurrency: Number(env.PIPELINER_CONCURRENCY ?? 1),
    reposDir: resolve(env.PIPELINER_REPOS_DIR ?? `${env.HOME}/.pipeliner-worker/repos`),
    pollIntervalSeconds: Number(env.PIPELINER_POLL_INTERVAL ?? 5),
    claudeBin: env.PIPELINER_CLAUDE_BIN ?? "claude",
    claudeModel: env.PIPELINER_CLAUDE_MODEL ?? "claude-opus-4-8",
    stepTimeoutSeconds: Number(env.PIPELINER_STEP_TIMEOUT ?? 900),
  };
}
