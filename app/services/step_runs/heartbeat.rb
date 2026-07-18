module StepRuns
  # Renews a lease and refreshes the worker's liveness + advertised roles.
  # The response doubles as the cooperative-cancellation channel (M8): when the
  # lease is no longer valid (reclaimed, canceled, pipeline aborted), the
  # worker is told to stop and clean up.
  class Heartbeat
    LEASE_TTL = Claim::LEASE_TTL

    def self.call(step_run:, worker:, epoch:, roles: nil)
      new(step_run:, worker:, epoch:, roles:).call
    end

    def initialize(step_run:, worker:, epoch:, roles:)
      @step_run = step_run
      @worker = worker
      @epoch = epoch
      @roles = roles
    end

    def call
      refresh_worker!

      return Result.success({ cancel: true }) unless lease_valid?

      @step_run.update!(
        lease_expires_at: LEASE_TTL.from_now,
        last_heartbeat_at: Time.current
      )
      Result.success({ cancel: false, lease_expires_at: @step_run.lease_expires_at })
    end

    private

    def refresh_worker!
      attrs = { last_heartbeat_at: Time.current, status: "online" }
      attrs[:supported_roles] = Array(@roles).map(&:to_s) unless @roles.nil?
      @worker.update!(attrs)
    end

    def lease_valid?
      @step_run.worker_id == @worker.id &&
        @step_run.epoch == @epoch &&
        @step_run.state.in?(%w[claimed running]) &&
        !pipeline_aborted?
    end

    def pipeline_aborted?
      @step_run.step.workflow.phase.pipeline.aborted?
    end
  end
end
