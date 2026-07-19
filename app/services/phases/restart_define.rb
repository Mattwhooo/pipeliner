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
          iteration: next_iteration,
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

    # The restart must land strictly ahead of EVERY worker step's current
    # iteration, not just the first step's. A menu re-run (RerunMenuStep) or
    # an answered question (AnswerQuestions) can have already bumped a later
    # step's iteration independently, so seeding the first step at merely
    # `its own max + 1` can collide with — or fall behind — a sibling that's
    # already ahead. ManagerTick#dispatch_ready_steps only dispatches a step
    # when `current_iteration(step) < target_iteration`; going one past the
    # highest iteration anywhere in the phase guarantees every dependent step
    # in the cascade re-runs instead of being skipped as "already current".
    def next_iteration
      worker_steps.flat_map(&:step_runs).map(&:iteration).max.to_i + 1
    end

    # Every answer/note the human has given this phase so far (tagged "human"
    # by Phases::AnswerQuestions) — so restarting doesn't discard context
    # already supplied (R18). Attached to the first step's run directly, and
    # to every step ManagerTick dispatches for the rest of the cascade (see
    # ManagerTick#dispatch_ready_steps) via `phase.restart_feedback`. Deduped
    # by content: a prior restart fans the same entries out onto every step it
    # dispatches (ManagerTick#restart_carry_feedback), so re-collecting them on
    # the next "Repeat from the Beginning" would otherwise double the set each
    # time the menu loop runs.
    def carried_feedback
      worker_steps.flat_map(&:step_runs).flat_map { |r| Array(r.feedback) }
        .select { |f| f.is_a?(Hash) && f["from"] == "human" }
        .uniq
    end
  end
end
