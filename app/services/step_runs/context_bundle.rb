module StepRuns
  # The payload a worker receives when it claims a run: everything needed to
  # execute the step (see docs/worker.md — "Download step context").
  # Git credentials (short-lived GitHub App token) are added with the GitHub
  # integration.
  class ContextBundle
    def self.build(step_run)
      step = step_run.step
      workflow = step.workflow
      phase = workflow.phase
      pipeline = phase.pipeline
      project = pipeline.project

      {
        step_run: {
          id: step_run.id,
          epoch: step_run.epoch,
          iteration: step_run.iteration,
          attempt: step_run.attempt,
          shard_key: step_run.shard_key,
          step_branch: step_run.step_branch,
          lease_expires_at: step_run.lease_expires_at
        },
        step: {
          slug: step.slug,
          type: step.step_type,
          role: step.role,
          system_prompt: step.system_prompt,
          inputs: step.inputs,
          outputs: step.outputs,
          scope: step.scope,
          fan_out: step.fan_out
        },
        workflow: { slug: workflow.slug, shared_paths: workflow.shared_paths },
        phase: { kind: phase.kind, position: phase.position },
        pipeline: {
          public_id: pipeline.public_id,
          branch: pipeline.branch,
          title: pipeline.title,
          initial_prompt: pipeline.initial_prompt
        },
        project: {
          repo_url: project.repo_url,
          default_branch: project.default_branch,
          project_type: project.project_type
        }
      }
    end
  end
end
