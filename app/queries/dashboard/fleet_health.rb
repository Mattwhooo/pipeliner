module Dashboard
  # Global worker-fleet health (no membership scoping — workers carry no
  # project association). Trusts `worker.status` directly: StepRuns::Sweep
  # already flips stale workers to offline on its own cadence, so this
  # doesn't recompute staleness.
  class FleetHealth
    def call
      workers = Worker.order(:name).to_a
      online = workers.select(&:online?)
      {
        workers: workers,
        online_count: online.size,
        offline_count: workers.size - online.size,
        role_gap: role_coverage_gap(online)
      }
    end

    private

    def role_coverage_gap(online)
      available = online.flat_map(&:supported_roles).uniq
      demanded = StepRun.where(state: %w[ready stuck]).distinct.pluck(:required_role)
      demanded - available
    end
  end
end
