module Phases
  # Moves the pipeline forward past an approved phase: starts the next phase,
  # or completes the pipeline when Review was approved. Shared by the Manager's
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

      if @phase.review_phase?
        pipeline.update!(status: "completed")
        return Result.success(pipeline)
      end

      index = Phase::KINDS_IN_ORDER.index(@phase.kind)
      next_phase = pipeline.phases.find_by!(kind: Phase::KINDS_IN_ORDER[index + 1])
      next_phase.update!(status: "running")
      pipeline.update!(current_phase: next_phase.kind, status: "running")

      Result.success(next_phase)
    end
  end
end
