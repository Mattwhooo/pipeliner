module Phases
  # Moves the pipeline forward past an approved phase: starts the next phase, or
  # kicks off finalization when Review was approved. Shared by the Manager's
  # auto-gate and human approval (Phases::Approve).
  class Advance
    def self.call(phase:)
      new(phase:).call
    end

    def initialize(phase:)
      @phase = phase
    end

    def call
      pipeline = @phase.pipeline

      # Review approval does not mark the pipeline completed here — Pipelines::
      # Finalize sets "completed" only after it archives + strips the .pipeliner
      # workspace and pushes the PR-ready branch (docs/artifact-schema.md
      # "Finalization"). We just enqueue that job after committing nothing but
      # the broadcast.
      if @phase.review_phase?
        Pipelines::FinalizeJob.perform_later(pipeline)
        BroadcastColumn.call(@phase)
        return Result.success(pipeline)
      end

      index = Phase::KINDS_IN_ORDER.index(@phase.kind)
      next_phase = pipeline.phases.find_by!(kind: Phase::KINDS_IN_ORDER[index + 1])

      # Both state writes are one business action — atomic or not done. Broadcasts
      # and jobs run only after the transaction commits (guides/backend-guide.md).
      ApplicationRecord.transaction do
        next_phase.update!(status: "running")
        pipeline.update!(current_phase: next_phase.kind, status: "running")
      end

      BroadcastColumn.call(@phase)
      BroadcastColumn.call(next_phase)

      Result.success(next_phase)
    end
  end
end
