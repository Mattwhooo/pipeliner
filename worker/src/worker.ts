import { Api, type Bundle } from "./api.js";
import type { Config } from "./config.js";
import { Executor } from "./executor.js";
import { Workspace } from "./git.js";

const log = (msg: string) => console.log(`[worker] ${new Date().toISOString()} ${msg}`);

/**
 * The main loop (docs/worker.md): register, poll for work, execute one step
 * at a time, heartbeat with cooperative cancel, report results. Interruption
 * safe: uncommitted work is discarded; the control plane reclaims the lease.
 */
export class WorkerLoop {
  private stopping = false;

  constructor(private readonly config: Config, private readonly api: Api) {}

  async start(): Promise<void> {
    await this.api.register();
    log(`registered as ${this.config.workerId} (roles: ${this.config.roles.join(", ")})`);

    process.on("SIGINT", () => this.requestStop());
    process.on("SIGTERM", () => this.requestStop());

    while (!this.stopping) {
      try {
        const bundle = await this.api.claim();
        if (bundle) {
          log(`claimed run ${bundle.step_run.id}: ${bundle.step.slug} (${bundle.step.type}/${bundle.step.role})`);
          await this.executeStep(bundle);
        } else {
          await sleep(this.config.pollIntervalSeconds * 1000);
        }
      } catch (e) {
        log(`loop error: ${String(e)} — backing off`);
        await sleep(10_000);
      }
    }
    log("stopped");
  }

  private requestStop(): void {
    if (this.stopping) process.exit(1);
    this.stopping = true;
    log("stopping after current step (press again to force)");
  }

  private async executeStep(bundle: Bundle): Promise<void> {
    const { id: runId, epoch } = bundle.step_run;
    const workspace = new Workspace(this.config, bundle);
    const abort = new AbortController();

    // Heartbeat until the step finishes; cancel cooperatively if told to (M8).
    const heartbeatTimer = setInterval(async () => {
      try {
        const cancel = await this.api.heartbeat(runId, epoch);
        if (cancel) {
          log(`run ${runId}: control plane requested cancel`);
          abort.abort();
        }
      } catch {
        /* transient network issues — lease expiry is the backstop */
      }
    }, this.api.heartbeatInterval * 1000);

    try {
      await this.api.progress(runId, epoch, "Preparing workspace");
      await workspace.prepare();

      const executor = new Executor(this.config, bundle, workspace.worktreeDir, (message) => {
        void this.api.progress(runId, epoch, message);
      });
      await executor.writeStepContext();

      await this.api.progress(runId, epoch, "Running Claude Code");
      const outcome = await executor.run(abort.signal);

      const status = outcome.ok ? "succeeded" : "failed";
      await executor.writeResult(status, outcome.summary);

      const sha = await workspace.commitAll(
        `Step ${bundle.step.slug} (iteration ${bundle.step_run.iteration}): ${status}`,
      );
      const pushed = sha ? await workspace.push() : false;

      const accepted = await this.api.complete(runId, epoch, {
        status,
        commit_sha: sha ?? undefined,
        result: { summary: outcome.summary, pushed, step_branch: bundle.step_run.step_branch },
        verdict: outcome.verdict,
      });

      log(`run ${runId}: ${status}${sha ? ` @ ${sha.slice(0, 7)}` : " (no changes)"}${pushed ? " pushed" : ""}${accepted ? "" : " — completion REJECTED (stale/duplicate)"}`);
      await workspace.cleanup(!accepted);
    } catch (e) {
      log(`run ${runId}: execution error: ${String(e)}`);
      await this.api.complete(runId, epoch, {
        status: "failed",
        result: { summary: `worker error: ${String(e)}`.slice(0, 1000) },
      }).catch(() => {});
      await workspace.cleanup(true).catch(() => {});
    } finally {
      clearInterval(heartbeatTimer);
    }
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
