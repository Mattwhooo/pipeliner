module Phases
  # A human rejects a phase gate and re-opens the phase for more work
  # (docs/execution-model.md — the Gate may "send-back"). Valid from the same
  # gate statuses as Approve:
  #   - consensus       — the normal human gate
  #   - awaiting_human  — the max-iterations escalation
  #
  # Records a send_back approval (target_phase = the phase itself, it re-opens),
  # queues a fresh run for the chosen worker-executed step carrying the human's
  # feedback, and drops the phase + pipeline back to running so the Manager
  # resumes the consensus loop.
  class SendBack
    SENDABLE_STATUSES = %w[consensus awaiting_human].freeze

    def self.call(phase:, user:, feedback:, target_step_id: nil)
      new(phase:, user:, feedback:, target_step_id:).call
    end

    def initialize(phase:, user:, feedback:, target_step_id:)
      @phase = phase
      @user = user
      @feedback = feedback
      @target_step_id = target_step_id
    end

    def call
      unless @phase.status.in?(SENDABLE_STATUSES)
        return Result.failure(:not_sendable, record: @phase)
      end
      return Result.failure(:blank_feedback, record: @phase) if @feedback.blank?

      target = resolve_target
      return Result.failure(:no_target, record: @phase) if target.nil?

      run = nil
      ApplicationRecord.transaction do
        @phase.approvals.create!(user: @user, decision: "send_back",
          target_phase: @phase, note: @feedback)
        run = target.step_runs.create!(
          state: "ready",
          iteration: (target.step_runs.maximum(:iteration) || 0) + 1,
          required_role: target.role,
          feedback: [ { "from" => "human-gate", "issue" => @feedback, "severity" => "major" } ]
        )
        @phase.update!(status: "running")
        @phase.pipeline.update!(status: "running")
      end

      BroadcastColumn.call(@phase)
      StepRuns::BroadcastCard.call(run)
      Result.success(run)
    end

    private

    # Worker-executed steps of this phase, ordered by position. A caller-supplied
    # target must be one of them; otherwise default to the first.
    def resolve_target
      steps = worker_steps
      if @target_step_id.present?
        steps.find { |s| s.id == @target_step_id.to_i }
      else
        steps.first
      end
    end

    def worker_steps
      @phase.workflows.flat_map(&:steps).select(&:worker_executed?).sort_by(&:position)
    end
  end
end
