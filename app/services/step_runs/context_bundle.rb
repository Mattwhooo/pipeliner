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

      bundle = {
        step_run: {
          id: step_run.id,
          epoch: step_run.epoch,
          iteration: step_run.iteration,
          attempt: step_run.attempt,
          shard_key: step_run.shard_key,
          step_branch: step_run.step_branch,
          lease_expires_at: step_run.lease_expires_at,
          # Routed critic findings for this re-run. The worker writes these into
          # input.json's `feedback` array alongside `resolved_inputs`
          # (worker/src/executor.ts writeStepContext).
          feedback: step_run.feedback
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

      # Planner steps receive the Step Library so they can compose workflows
      # (which steps this task needs, and in what order).
      if step.type_planner?
        bundle[:library] = StepTemplate.available_to(project).order(:name).map do |t|
          { name: t.name, type: t.step_type, role: t.role,
            requirement: t.requirement, phase: t.phase }
        end
      end

      bundle
    end
  end
end
