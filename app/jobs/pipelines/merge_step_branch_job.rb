module Pipelines
  # Thin wrapper (guides/backend-guide.md). Enqueued by StepRuns::Complete after
  # a successful completion. Concurrency is capped to one merge at a time per
  # pipeline so step branches land serially and never race on the branch head.
  class MergeStepBranchJob < ApplicationJob
    queue_as :default

    limits_concurrency to: 1, key: ->(step_run) { "merge-pipeline-#{step_run.step.workflow.phase.pipeline_id}" }

    def perform(step_run) = MergeStepBranch.call(step_run: step_run)
  end
end
