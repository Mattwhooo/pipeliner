module Phases
  # A human sends free-form notes to the Define phase from the paused menu,
  # re-opening the clarifying loop for another iteration. Their notes become
  # feedback on the Clarifying Questions step (the loop's entry point, which
  # consumes human context) — so re-running it re-emits open questions and the
  # decision-tree loop continues. Deliberately NOT the Code Explorer: discovery
  # runs once per pipeline and human answers must never re-trigger it.
  #
  # (In the normal running loop the human answers via the first-class Human
  # Feedback step — Phases::SubmitHumanFeedback. This path is the paused-menu
  # "Ask Human" escape hatch.)
  #
  # Valid only for the Define phase while it is still open (running or parked at
  # a human gate). At consensus/awaiting_human, answering re-opens the phase for
  # another iteration rather than approving it.
  class AnswerQuestions
    ANSWERABLE_STATUSES = %w[running consensus awaiting_human paused].freeze

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

      target = clarifying_questions_step
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

    # The Clarifying Questions step, identified by the `open_questions` artifact
    # it declares (stable across template renames/reorders — same convention as
    # Phases::RerunMenuStep). Falls back to the first worker step after Code
    # Explorer so a note is never silently dropped, but never the explorer itself.
    def clarifying_questions_step
      by_artifact = steps.find do |s|
        s.worker_executed? && Array(s.outputs).any? { |o| o["artifact"] == "open_questions" }
      end
      by_artifact || steps.select(&:worker_executed?).reject { |s| explorer?(s) }.min_by(&:position)
    end

    def explorer?(step)
      Array(step.outputs).any? { |o| o["artifact"] == "discovery_notes" }
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
