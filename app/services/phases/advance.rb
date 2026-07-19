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

      # A single business action (advance the board) — atomic or not done.
      # When called from ManagerTick this nests as a savepoint inside the tick
      # transaction; the after-commit broadcasts still wait for the outermost
      # commit (guide: broadcasts only after the write commits).
      ApplicationRecord.transaction do
        if @phase.review_phase?
          pipeline.update!(status: "completed")
          broadcast_after_commit(@phase)
          next Result.success(pipeline)
        end

        index = Phase::KINDS_IN_ORDER.index(@phase.kind)
        next_phase = pipeline.phases.find_by!(kind: Phase::KINDS_IN_ORDER[index + 1])
        next_phase.update!(status: "running")
        pipeline.update!(current_phase: next_phase.kind, status: "running")
        broadcast_after_commit(@phase)
        broadcast_after_commit(next_phase)

        Result.success(next_phase)
      end
    end

    private

    def broadcast_after_commit(phase)
      ActiveRecord.after_all_transactions_commit { BroadcastColumn.call(phase) }
    end
  end
end
