module Phases
  # A human answers the Define phase's clarifying questions (the open_questions
  # artifact) in-UI, re-opening the requirements loop for another iteration.
  # Their answers become feedback on the requirements writer — the phase's first
  # worker-executed step — so the Manager's existing DAG dispatch re-runs the
  # questions step and its critic afterwards.
  #
  # Valid only for the Define phase while it is still open (running or parked at
  # a human gate). At consensus/awaiting_human, answering re-opens the phase for
  # another iteration rather than approving it.
  class AnswerQuestions
    ANSWERABLE_STATUSES = %w[running consensus awaiting_human].freeze

    def self.call(phase:, user:, answers:)
      new(phase:, user:, answers:).call
    end

    def initialize(phase:, user:, answers:)
      @phase = phase
      @user = user
      @answers = answers.to_s.strip
    end

    def call
      return Result.failure(:not_answerable, record: @phase) unless answerable?
      return Result.failure(:blank_answers, record: @phase) if @answers.blank?
      return Result.failure(:busy, record: @phase) if define_busy?

      target = requirements_step
      return Result.failure(:no_target, record: @phase) if target.nil?

      run = nil
      ApplicationRecord.transaction do
        run = target.step_runs.create!(
          state: "ready",
          iteration: (target.step_runs.maximum(:iteration) || 0) + 1,
          required_role: target.role,
          feedback: [ { "from" => "human", "issue" => @answers, "severity" => "major" } ]
        )
        reopen_iteration if @phase.consensus?
      end

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Result.success(run)
    end

    private

    def answerable?
      @phase.define_phase? && @phase.status.in?(ANSWERABLE_STATUSES)
    end

    # Any live run means the loop is mid-flight — answering now would race the
    # Manager, so wait for the current pass to settle.
    def define_busy?
      steps.any?(&:active_run?)
    end

    # The requirements writer: the first worker-executed step by position.
    def requirements_step
      steps.select(&:worker_executed?).min_by(&:position)
    end

    def steps
      @steps ||= @phase.workflows.flat_map(&:steps)
    end

    # Consensus was already reached — answering pulls the phase and pipeline back
    # into the running loop and un-converges the define workflow.
    def reopen_iteration
      @phase.update!(status: "running")
      @phase.pipeline.update!(status: "running")
      @phase.workflows.where(status: "converged").update_all(status: "running")
    end
  end
end
