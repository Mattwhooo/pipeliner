import { Api, type Bundle } from "./api.js";
import type { Config } from "./config.js";
import { Executor } from "./executor.js";
import { Workspace } from "./git.js";

const log = (msg: string) => console.log(`[worker] ${new Date().toISOString()} ${msg}`);

/**
 * The main loop (docs/worker.md): register, poll for work, execute steps
 * concurrently up to `config.concurrency`, heartbeat with cooperative cancel,
 * report results. Interruption safe: uncommitted work is discarded; the control
 * plane reclaims the lease.
 */
export class WorkerLoop {
  private stopping = false;
  /** Currently executing step promises; size is the live concurrency. */
  private readonly inFlight = new Set<Promise<void>>();
  /** While in the future, don't claim: the backend is limiting/overloaded. */
  private cooldownUntil = 0;

  /** Pause claiming after a transient outage (default 5 minutes). */
  private enterCooldown(reason: string): void {
    const ms = 5 * 60_000;
    this.cooldownUntil = Math.max(this.cooldownUntil, Date.now() + ms);
    log(`transient outage — pausing claims for ${ms / 60_000}m (${reason.slice(0, 120)})`);
  }

  constructor(private readonly config: Config, private readonly api: Api) {}

  async start(): Promise<void> {
    // Retry registration with backoff: under a Procfile the worker often
    // starts before the control plane finishes booting, and a process-manager
    // treats an early fatal as "kill everything".
    for (let attempt = 1; ; attempt++) {
      try {
        await this.api.register();
        break;
      } catch (e) {
        const delay = Math.min(5_000 * attempt, 30_000);
        log(`registration failed (attempt ${attempt}): ${String(e).slice(0, 200)} — retrying in ${delay / 1000}s`);
        await sleep(delay);
      }
    }
    log(`registered as ${this.config.workerId} (roles: ${this.config.roles.join(", ")}, concurrency: ${this.config.concurrency})`);

    process.on("SIGINT", () => this.requestStop());
    process.on("SIGTERM", () => this.requestStop());

    while (!this.stopping) {
      // At capacity, or cooling down after a transient outage: don't claim.
      if (this.inFlight.size >= this.config.concurrency || Date.now() < this.cooldownUntil) {
        await sleep(this.config.pollIntervalSeconds * 1000);
        continue;
      }

      let bundle: Bundle | null;
      try {
        bundle = await this.api.claim();
      } catch (e) {
        log(`claim error: ${String(e)} — backing off`);
        await sleep(10_000);
        continue;
      }

      if (bundle) {
        log(`claimed run ${bundle.step_run.id}: ${bundle.step.slug} (${bundle.step.type}/${bundle.step.role})`);
        this.track(this.executeStep(bundle));
        // Immediately loop to claim again and fill remaining capacity (the
        // control plane also caps us server-side, returning 204 at capacity).
        continue;
      }

      await sleep(this.config.pollIntervalSeconds * 1000); // 204: no work right now
    }

    // Graceful shutdown: claiming has stopped; drain in-flight executions.
    if (this.inFlight.size) log(`draining ${this.inFlight.size} in-flight step(s)`);
    await Promise.allSettled([...this.inFlight]);
    log("stopped");
  }

  /** Tracks a step execution as in-flight until it settles. */
  private track(run: Promise<void>): void {
    this.inFlight.add(run);
    void run.finally(() => this.inFlight.delete(run));
  }

  private requestStop(): void {
    if (this.stopping) process.exit(1);
    this.stopping = true;
    log(`stopping: no new claims, draining ${this.inFlight.size} in-flight step(s) (press again to force)`);
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

      // Infrastructure outage (session/rate limit, API overload): discard the
      // partial work, hand the run back for a backoff retry, and stop claiming
      // for a while — every step would hit the same wall.
      if (!outcome.ok && outcome.transient) {
        await this.api.complete(runId, epoch, {
          status: "transient",
          result: { summary: outcome.summary },
        });
        this.enterCooldown(outcome.summary);
        await workspace.cleanup(true);
        return;
      }

      const status = outcome.ok ? "succeeded" : "failed";
      await executor.writeResult(status, outcome.summary);

      const sha = await workspace.commitAll(
        `Step ${bundle.step.slug} (iteration ${bundle.step_run.iteration}): ${status}`,
      );
      const pushed = sha ? await workspace.push() : false;

      const artifacts = outcome.ok ? await executor.collectArtifacts() : {};
      const accepted = await this.api.complete(runId, epoch, {
        status,
        commit_sha: sha ?? undefined,
        result: {
          summary: outcome.summary,
          pushed,
          step_branch: bundle.step_run.step_branch,
          ...(Object.keys(artifacts).length ? { artifacts } : {}),
        },
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
