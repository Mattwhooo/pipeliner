import type { Config } from "./config.js";

/** Context bundle returned by a successful claim (mirrors StepRuns::ContextBundle). */
export interface Bundle {
  step_run: {
    id: number;
    epoch: string;
    iteration: number;
    attempt: number;
    shard_key: string | null;
    step_branch: string;
    lease_expires_at: string;
    /** Routed critic findings when this run is a feedback-driven re-run. */
    feedback: Array<Record<string, unknown>> | null;
  };
  step: {
    slug: string;
    type: "planner" | "builder" | "critic";
    role: string;
    system_prompt: string | null;
    inputs: Array<Record<string, string>>;
    outputs: Array<Record<string, string>>;
    scope: Record<string, unknown> | null;
    fan_out: Record<string, unknown> | null;
  };
  workflow: { slug: string; shared_paths: string[] };
  /** Step Library summary, present for planner steps (workflow composition). */
  library?: Array<{ name: string; type: string; role: string | null; requirement: string }>;
  phase: { kind: string; position: number };
  pipeline: { public_id: string; branch: string; title: string; initial_prompt: string | null };
  project: { repo_url: string; default_branch: string; project_type: string };
}

export interface CompletePayload {
  status: "succeeded" | "failed" | "transient";
  commit_sha?: string;
  result?: Record<string, unknown>;
  verdict?: Record<string, unknown>;
}

/** Thin client for the control plane's worker API. */
export class Api {
  private token = "";
  heartbeatInterval = 15;

  constructor(private readonly config: Config) {}

  async register(): Promise<void> {
    const res = await this.request("/api/v1/workers/register", {
      headers: { "X-Registration-Key": this.config.registrationKey },
      body: {
        worker: {
          public_id: this.config.workerId,
          name: this.config.workerName,
          backend: "claude-code",
          model: this.config.claudeModel || "claude-cli-default",
          roles: this.config.roles,
          concurrency: this.config.concurrency,
        },
      },
    });
    if (res.status !== 201) throw new Error(`registration failed: HTTP ${res.status} ${await res.text()}`);
    const body = (await res.json()) as { token: string; heartbeat_interval?: number };
    this.token = body.token;
    if (body.heartbeat_interval) this.heartbeatInterval = body.heartbeat_interval;
  }

  /** Returns a bundle, or null when there is no work (204). */
  async claim(): Promise<Bundle | null> {
    const res = await this.authed("/api/v1/claims", {});
    if (res.status === 204) return null;
    if (res.status !== 200) throw new Error(`claim failed: HTTP ${res.status}`);
    return (await res.json()) as Bundle;
  }

  /** Renews the lease; returns true when the control plane asks us to cancel. */
  async heartbeat(runId: number, epoch: string): Promise<boolean> {
    const res = await this.authed(`/api/v1/step_runs/${runId}/heartbeat`, {
      epoch,
      roles: this.config.roles,
    });
    if (res.status !== 200) return true; // treat auth/network oddities as cancel-and-resync
    const body = (await res.json()) as { cancel: boolean };
    return body.cancel;
  }

  async progress(runId: number, epoch: string, message: string): Promise<void> {
    await this.authed(`/api/v1/step_runs/${runId}/progress`, {
      epoch,
      progress: { message: message.slice(0, 500) },
    });
  }

  async complete(runId: number, epoch: string, payload: CompletePayload): Promise<boolean> {
    const res = await this.authed(`/api/v1/step_runs/${runId}/complete`, { epoch, ...payload });
    return res.status === 200;
  }

  private authed(path: string, body: unknown): Promise<Response> {
    return this.request(path, { headers: { Authorization: `Bearer ${this.token}` }, body });
  }

  private request(path: string, opts: { headers?: Record<string, string>; body?: unknown }): Promise<Response> {
    return fetch(`${this.config.baseUrl}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...opts.headers },
      body: JSON.stringify(opts.body ?? {}),
    });
  }
}
