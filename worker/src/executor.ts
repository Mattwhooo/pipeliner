import { spawn } from "node:child_process";
import { mkdir, writeFile, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { createInterface } from "node:readline";
import type { Bundle } from "./api.js";
import type { Config } from "./config.js";

export interface ExecutionResult {
  ok: boolean;
  summary: string;
  verdict?: Record<string, unknown>;
  /** Infrastructure outage (session/rate limit, API overload) — not the step's fault. */
  transient?: boolean;
}

/** Signatures of temporary infrastructure problems worth retrying with backoff. */
const TRANSIENT_PATTERNS =
  /session limit|usage limit|rate limit|too many requests|overloaded|capacity constraint|temporarily unavailable|quota|resets at|\b(429|503|529)\b|ETIMEDOUT|ECONNRESET|ECONNREFUSED|fetch failed|network error/i;

/**
 * Runs one step by launching a Claude Code instance headlessly in the step's
 * worktree (docs/worker.md: agents run with permissions pre-approved; the
 * blast radius is the worktree). v0 executes as a local subprocess; the
 * per-step container mode lands when Docker is part of the loop.
 */
export class Executor {
  constructor(
    private readonly config: Config,
    private readonly bundle: Bundle,
    private readonly worktreeDir: string,
    private readonly onProgress: (message: string) => void,
  ) {}

  /** `.pipeliner` subtree for this step (artifact-schema.md). */
  private get stepDir(): string {
    const phase = `${String(this.bundle.phase.position).padStart(2, "0")}-${this.bundle.phase.kind}`;
    return join(".pipeliner", "phases", phase, this.bundle.workflow.slug, this.bundle.step.slug);
  }

  /** Materializes step.json / prompt.md / input.json per the artifact schema. */
  async writeStepContext(): Promise<void> {
    const abs = join(this.worktreeDir, this.stepDir);
    await mkdir(join(abs, "output"), { recursive: true });

    const { step, step_run } = this.bundle;
    await writeFile(join(abs, "step.json"), JSON.stringify({
      schema_version: "1.0",
      slug: step.slug,
      type: step.type,
      role: step.role,
      prompt: "prompt.md",
      inputs: step.inputs,
      outputs: step.outputs,
      scope: step.scope,
      fan_out: step.fan_out,
    }, null, 2));
    await writeFile(join(abs, "prompt.md"), step.system_prompt ?? "");
    await writeFile(join(abs, "input.json"), JSON.stringify({
      schema_version: "1.0",
      iteration: step_run.iteration,
      resolved_inputs: step.inputs,
      feedback: step_run.feedback ?? [],
    }, null, 2));
  }

  private buildPrompt(): string {
    const { step, pipeline, phase } = this.bundle;
    const outputs = step.outputs.map((o) => `- ${o.artifact} (kind: ${o.kind ?? "artifact"})` +
      (o.path ? ` -> ${this.stepDir}/${o.path}` : " -> changes to repo files")).join("\n");

    return [
      `You are executing one step of an agentic development pipeline.`,
      ``,
      `## Step: ${step.slug} (type: ${step.type})`,
      step.system_prompt ?? "",
      ``,
      `## Pipeline context`,
      `Task: ${pipeline.title}`,
      `Phase: ${phase.kind}`,
      pipeline.initial_prompt ? `The ask:\n${pipeline.initial_prompt}` : "",
      this.bundle.step_run.feedback?.length
        ? `\n## Feedback to address (from a critic's review of the previous iteration)\n` +
          JSON.stringify(this.bundle.step_run.feedback, null, 2)
        : "",
      ``,
      `## Your working rules`,
      `- Work only inside the current directory (a dedicated git worktree).`,
      `- Read any inputs referenced in ${this.stepDir}/input.json.`,
      `- Write your declared outputs:`,
      outputs || "- (no declared file outputs)",
      step.type === "critic"
        ? `- As a critic you MUST write ${this.stepDir}/verdict.json with shape ` +
          `{"schema_version":"1.0","step":"${step.slug}","verdict":"pass|needs_work|not_applicable",` +
          `"summary":"...","findings":[{"id":"F1","target_artifact":"...","issue":"...","severity":"blocker|major|minor"}]} ` +
          `(findings empty when verdict is pass).`
        : `- Do NOT edit files outside your declared outputs${step.scope ? " and scope" : ""}.`,
      `- When finished, print a one-paragraph summary of what you did.`,
    ].filter(Boolean).join("\n");
  }

  /** Runs Claude Code; streams progress lines back; returns the outcome. */
  async run(signal: AbortSignal): Promise<ExecutionResult> {
    const args = [
      "-p", this.buildPrompt(),
      "--output-format", "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
    ];
    if (this.config.claudeModel) args.push("--model", this.config.claudeModel);

    const child = spawn(this.config.claudeBin, args, {
      cwd: this.worktreeDir,
      // PIPELINER_AGENT marks every process the agent spawns; repos under
      // pipeline development (like Pipeliner itself) use it to redirect
      // dangerous defaults (e.g. the dev database) to scratch equivalents.
      env: { ...process.env, CLAUDE_CODE_ENTRYPOINT: "pipeliner-worker", PIPELINER_AGENT: "1" },
      stdio: ["ignore", "pipe", "pipe"],
      signal,
      timeout: this.config.stepTimeoutSeconds * 1000,
    });

    let lastText = "";
    let resultText = "";
    let stderrTail = "";

    const rl = createInterface({ input: child.stdout });
    rl.on("line", (line) => {
      try {
        const event = JSON.parse(line);
        if (event.type === "assistant") {
          const texts = (event.message?.content ?? [])
            .filter((c: { type: string }) => c.type === "text")
            .map((c: { text: string }) => c.text);
          if (texts.length) {
            lastText = texts.join(" ").trim();
            if (lastText) this.onProgress(lastText);
          }
        } else if (event.type === "result") {
          resultText = event.result ?? "";
        }
      } catch {
        /* non-JSON line — ignore */
      }
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderrTail = (stderrTail + chunk.toString()).slice(-2000);
    });

    const exitCode: number = await new Promise((resolveExit) => {
      child.on("close", (code) => resolveExit(code ?? 1));
      child.on("error", () => resolveExit(1));
    });

    if (exitCode !== 0) {
      const evidence = `${stderrTail} ${resultText} ${lastText}`;
      return {
        ok: false,
        transient: TRANSIENT_PATTERNS.test(evidence),
        summary: `claude exited ${exitCode}: ${stderrTail.slice(-500) || lastText}`,
      };
    }

    const summary = (resultText || lastText).slice(0, 2000);

    // Critics must produce a structured verdict (execution-model.md).
    if (this.bundle.step.type === "critic") {
      const verdictPath = join(this.worktreeDir, this.stepDir, "verdict.json");
      if (!existsSync(verdictPath)) {
        return { ok: false, summary: `critic finished without writing verdict.json. ${summary}` };
      }
      try {
        const verdict = JSON.parse(await readFile(verdictPath, "utf8"));
        return { ok: true, summary, verdict };
      } catch (e) {
        return { ok: false, summary: `verdict.json is not valid JSON: ${String(e)}` };
      }
    }

    return { ok: true, summary };
  }

  /** Writes result.json into the step subtree before the final commit. */
  async writeResult(status: "succeeded" | "failed", summary: string): Promise<void> {
    const abs = join(this.worktreeDir, this.stepDir, "result.json");
    await mkdir(dirname(abs), { recursive: true });
    await writeFile(abs, JSON.stringify({
      schema_version: "1.0",
      step: this.bundle.step.slug,
      status,
      iteration: this.bundle.step_run.iteration,
      worker: { id: this.config.workerId, backend: "claude-code" },
      summary,
    }, null, 2));
  }
}
