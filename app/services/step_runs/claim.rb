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
      # A claim poll is an idle worker's liveness signal — without this, workers
      # that poll but hold no lease would be swept offline between steps.
      @worker.update!(last_heartbeat_at: Time.current, status: "online")

      return Result.failure(:at_capacity) if at_capacity?

      run = nil
      ApplicationRecord.transaction do
        run = ClaimableFor.new(@worker).first_with_lock
        if run
          epoch = SecureRandom.hex(8)
          run.update!(
            state: "claimed",
            worker: @worker,
            epoch: epoch,
            step_branch: step_branch_for(run, epoch),
            lease_expires_at: LEASE_TTL.from_now,
            last_heartbeat_at: Time.current,
            started_at: Time.current
          )
        end
      end

      return Result.failure(:no_work) unless run

      BroadcastCard.call(run)
      Result.success(run)
    end

    private

    def at_capacity?
      @worker.step_runs.leased.count >= @worker.concurrency
    end

    # Branch-per-step: the one ref this lease may push (docs/architecture.md).
    def step_branch_for(run, epoch)
      step = run.step
      phase = step.workflow.phase
      "step/#{phase.position.to_s.rjust(2, "0")}-#{phase.kind}/#{step.workflow.slug}/#{step.slug}/#{epoch}"
    end
  end
end
