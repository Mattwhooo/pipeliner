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
        broadcast_columns_after_commit(@phase)
        return Result.success(pipeline)
      end

      index = Phase::KINDS_IN_ORDER.index(@phase.kind)
      next_phase = pipeline.phases.find_by!(kind: Phase::KINDS_IN_ORDER[index + 1])
      ApplicationRecord.transaction do
        next_phase.update!(status: "running")
        pipeline.update!(current_phase: next_phase.kind, status: "running")
      end
      broadcast_columns_after_commit(@phase, next_phase)

      Result.success(next_phase)
    end

    private

    # Repaint the affected columns only once the advance is durable. When called
    # standalone (Phases::Approve) this fires after our own transaction; when
    # nested inside ManagerTick's tick it fires after that outer transaction —
    # so a rolled-back advance never leaves a stale column on the board.
    def broadcast_columns_after_commit(*phases)
      ActiveRecord.after_all_transactions_commit do
        phases.each { |phase| BroadcastColumn.call(phase) }
      end
    end
  end
end
