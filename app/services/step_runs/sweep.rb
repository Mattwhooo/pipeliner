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

      newly_stuck_scope = StepRun.where(state: "ready", created_at: ...STUCK_GRACE.ago)
        .where.not(required_role: available)
      # update_all returns a row count, not records — capture the affected
      # pipelines before each update so the dashboard can be told afterward.
      newly_stuck_pipeline_ids = pipeline_ids_for(newly_stuck_scope)
      newly_stuck = newly_stuck_scope.update_all(state: "stuck", updated_at: Time.current)

      unstuck_scope = StepRun.where(state: "stuck", required_role: available)
      unstuck_pipeline_ids = pipeline_ids_for(unstuck_scope)
      unstuck = unstuck_scope.update_all(state: "ready", updated_at: Time.current)

      # Both directions need telling — a pipeline that just recovered from
      # stuck would otherwise keep its stale "Stuck" attention state on the
      # dashboard until some unrelated later event happens to broadcast it.
      broadcast_stuck_state_changed(newly_stuck_pipeline_ids | unstuck_pipeline_ids)

      [ newly_stuck, unstuck ]
    end

    def pipeline_ids_for(step_run_scope)
      Pipeline.joins(phases: { workflows: { steps: :step_runs } })
        .where(step_runs: { id: step_run_scope.select(:id) })
        .distinct.pluck(:id)
    end

    def broadcast_stuck_state_changed(pipeline_ids)
      Pipeline.where(id: pipeline_ids).find_each do |pipeline|
        Dashboard::Broadcast.call(pipeline: pipeline, activity: true)
      end
    end

    def available_roles
      Worker.online.pluck(:supported_roles).flatten.uniq
    end
  end
end
