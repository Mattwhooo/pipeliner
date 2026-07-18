module StepRuns
  # Stores the latest incremental progress (latest-only by design) and moves a
  # freshly-claimed run to running. UI broadcasts hang off this service.
  class RecordProgress
    def self.call(step_run:, worker:, epoch:, progress:)
      new(step_run:, worker:, epoch:, progress:).call
    end

    def initialize(step_run:, worker:, epoch:, progress:)
      @step_run = step_run
      @worker = worker
      @epoch = epoch
      @progress = progress
    end

    def call
      return Result.failure(:stale_epoch) unless current_lease?

      @step_run.update!(
        state: "running",
        progress: @progress,
        last_heartbeat_at: Time.current
      )
      Result.success(@step_run)
    end

    private

    def current_lease?
      @step_run.worker_id == @worker.id &&
        @step_run.epoch == @epoch &&
        @step_run.state.in?(%w[claimed running])
    end
  end
end
