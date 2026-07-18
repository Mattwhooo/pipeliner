module StepRuns
  # Queues a step for execution: creates a ready run at the next iteration.
  # Until the Manager loop lands, this is how work gets dispatched (from the
  # board UI). Guards: only worker-executed steps, one live run per step.
  class Queue
    def self.call(step:)
      new(step:).call
    end

    def initialize(step:)
      @step = step
    end

    def call
      return Result.failure(:not_worker_executed) unless @step.worker_executed?
      return Result.failure(:already_active) if active_run?

      iteration = (@step.step_runs.maximum(:iteration) || 0) + 1
      run = @step.step_runs.create!(
        state: "ready",
        iteration: iteration,
        required_role: @step.role
      )

      BroadcastCard.call(run)
      Result.success(run)
    rescue ActiveRecord::RecordInvalid => e
      Result.failure(:invalid, record: e.record)
    end

    private

    def active_run?
      @step.step_runs.where(state: %w[ready claimed running]).exists?
    end
  end
end
