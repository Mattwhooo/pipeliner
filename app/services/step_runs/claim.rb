module StepRuns
  # Atomically claims one ready step run for a worker (pull-based dispatch).
  # SKIP LOCKED lets many workers poll concurrently without contention; the
  # epoch minted here fences all later calls for this lease (M10).
  class Claim
    LEASE_TTL = 60.seconds

    def self.call(worker:)
      new(worker:).call
    end

    def initialize(worker:)
      @worker = worker
    end

    def call
      return Result.failure(:at_capacity) if at_capacity?

      run = nil
      ApplicationRecord.transaction do
        run = ClaimableFor.new(@worker).first_with_lock
        run&.update!(
          state: "claimed",
          worker: @worker,
          epoch: SecureRandom.hex(8),
          lease_expires_at: LEASE_TTL.from_now,
          last_heartbeat_at: Time.current,
          started_at: Time.current
        )
      end

      return Result.failure(:no_work) unless run

      BroadcastCard.call(run)
      Result.success(run)
    end

    private

    def at_capacity?
      @worker.step_runs.leased.count >= @worker.concurrency
    end
  end
end
