module Pipelines
  # Thin wrapper (guides/backend-guide.md). Enqueued by Phases::Advance once the
  # Review phase is approved. Idempotent — Finalize's guards make a re-run (or an
  # infra-error retry) safe. Concurrency is capped to one finalize per pipeline.
  class FinalizeJob < ApplicationJob
    queue_as :default

    limits_concurrency to: 1, key: ->(pipeline) { "finalize-pipeline-#{pipeline.id}" }

    def perform(pipeline) = Finalize.call(pipeline: pipeline)
  end
end
