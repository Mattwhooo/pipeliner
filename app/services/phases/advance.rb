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
        ApplicationRecord.transaction do
          pipeline.update!(status: "completed")
        end
        broadcast_column(@phase)
        return Result.success(pipeline)
      end

      index = Phase::KINDS_IN_ORDER.index(@phase.kind)
      next_phase = pipeline.phases.find_by!(kind: Phase::KINDS_IN_ORDER[index + 1])

      # Own the transaction so the advance is atomic for every caller. From
      # ManagerTick this nests inside the tick transaction (a savepoint); from
      # Phases::Approve — which calls us after its own commit — it is the sole
      # transaction, so a failed pipeline update can't leave the next phase
      # running while the pipeline still points at the prior phase.
      ApplicationRecord.transaction do
        next_phase.update!(status: "running")
        pipeline.update!(current_phase: next_phase.kind, status: "running")
      end

      broadcast_column(@phase)
      broadcast_column(next_phase)

      Result.success(next_phase)
    end

    private

    # Broadcast only after the write commits (backend-guide: after_commit
    # semantics). Deferred to the outermost transaction so that, when we run
    # inside ManagerTick's tick, a rollback discards the broadcast instead of
    # repainting stale phase state.
    def broadcast_column(phase)
      ActiveRecord.after_all_transactions_commit { BroadcastColumn.call(phase) }
    end
  end
end
