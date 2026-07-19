module Phases
  # Restarts Define from its first worker-executed step (R15). Deliberately
  # reuses ManagerTick's ordinary dispatch/route/converge cascade instead of a
  # bespoke "run N steps and wait" primitive by flipping the phase back to
  # `running` for the cascade's duration. `restart_in_progress` tells
  # ManagerTick to land back on `paused` instead of the normal gate when it
  # converges (R19), and to bail back to `paused` instead of stalling forever
  # if a restart step fails (R25).
  class RestartDefine
    def self.call(phase:, user:)
      new(phase:, user:).call
    end

    def initialize(phase:, user:)
      @phase = phase
      @user = user
    end

    def call
      return Result.failure(:not_paused, record: @phase) unless @phase.paused?
      return Result.failure(:busy, record: @phase) if @phase.any_step_active?

      first_step = worker_steps.first
      return Result.failure(:no_steps, record: @phase) if first_step.nil?

      feedback = carried_feedback
      run = nil
      ApplicationRecord.transaction do
        @phase.update!(
          status: "running",
          restart_in_progress: true,
          restart_feedback: feedback,
          pause_requested: false,
          pause_requested_at: nil
        )
        run = first_step.step_runs.create!(
          state: "ready",
          iteration: (first_step.step_runs.maximum(:iteration) || 0) + 1,
          required_role: first_step.role,
          feedback: feedback
        )
      end

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Result.success(run)
    end

    private

    def worker_steps
      @phase.workflows.flat_map(&:steps).select(&:worker_executed?).sort_by(&:position)
    end

    # Every answer/note the human has given this phase so far (tagged "human"
    # by Phases::AnswerQuestions) — so restarting doesn't discard context
    # already supplied (R18). Attached to the first step's run directly, and
    # to every step ManagerTick dispatches for the rest of the cascade (see
    # ManagerTick#dispatch_ready_steps) via `phase.restart_feedback`.
    def carried_feedback
      worker_steps.flat_map(&:step_runs).flat_map { |r| Array(r.feedback) }
        .select { |f| f.is_a?(Hash) && f["from"] == "human" }
    end
  end
end
