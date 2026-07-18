module StepRuns
  # Periodic maintenance for the work queue ("nothing gets forgotten"):
  #   1. Reclaim expired leases → back to ready with a new attempt (the dead
  #      worker's local worktree is simply discarded; at-least-once execution).
  #   2. Mark workers with stale heartbeats offline.
  #   3. Stuck detection (~90s grace): ready runs whose required_role no online
  #      worker supports → stuck; stuck runs whose role became available → ready.
  class Sweep
    WORKER_OFFLINE_AFTER = 2.minutes
    STUCK_GRACE = 90.seconds

    def self.call
      new.call
    end

    def call
      reclaimed = reclaim_expired_leases
      offlined = mark_stale_workers_offline
      stuck, unstuck = refresh_stuck_state

      Result.success({ reclaimed:, offlined:, stuck:, unstuck: })
    end

    private

    def reclaim_expired_leases
      StepRun.lease_expired.find_each.count do |run|
        run.update!(
          state: "ready",
          attempt: run.attempt + 1,
          worker: nil,
          epoch: nil,
          lease_expires_at: nil,
          started_at: nil,
          progress: nil
        )
        true
      end
    end

    def mark_stale_workers_offline
      Worker.where(status: %w[online draining])
        .where(last_heartbeat_at: ...WORKER_OFFLINE_AFTER.ago)
        .update_all(status: "offline", updated_at: Time.current)
    end

    def refresh_stuck_state
      available = available_roles

      newly_stuck = StepRun.where(state: "ready", created_at: ...STUCK_GRACE.ago)
        .where.not(required_role: available)
        .update_all(state: "stuck", updated_at: Time.current)

      unstuck = StepRun.where(state: "stuck", required_role: available)
        .update_all(state: "ready", updated_at: Time.current)

      [ newly_stuck, unstuck ]
    end

    def available_roles
      Worker.online.pluck(:supported_roles).flatten.uniq
    end
  end
end
