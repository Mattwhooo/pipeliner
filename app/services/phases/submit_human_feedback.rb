module Phases
  # A human executes the Define phase's Human Feedback step in the UI: they
  # answer the open questions Clarifying Questions raised (each in its own field)
  # plus optional free-form notes. This completes the step's awaiting_input run —
  # storing the answers as its `human_answers` artifact in the rigid schema — so
  # the Manager's route_to edge (ManagerTick#route_human_feedback) then re-runs
  # Clarifying Questions with those answers to reassess whether the task is fully
  # defined (docs/execution-model.md — "Human Feedback step").
  #
  # A human step is never claimed by a worker and never pushes a branch, so there
  # is nothing to merge; the run is marked merged so it reads as fully settled.
  class SubmitHumanFeedback
    def self.call(phase:, user:, answers:, notes: nil)
      new(phase:, user:, answers:, notes:).call
    end

    def initialize(phase:, user:, answers:, notes:)
      @phase = phase
      @user = user
      @answers = Array(answers).map { |a| a.to_h.symbolize_keys }
      @notes = notes.to_s.strip
    end

    def call
      return Result.failure(:not_define, record: @phase) unless @phase.define_phase?

      run = pending_run
      return Result.failure(:no_pending_step, record: @phase) if run.nil?
      return Result.failure(:blank_answers, record: @phase) if nothing_submitted?

      ApplicationRecord.transaction do
        run.update!(
          state: "succeeded",
          result: build_result,
          finished_at: Time.current,
          merged_at: Time.current,
          lease_expires_at: nil
        )
      end

      StepRuns::BroadcastCard.call(run)
      BroadcastColumn.call(@phase)
      Pipelines::BroadcastStatus.call(@phase.pipeline)
      Result.success(run)
    end

    private

    # The Human Feedback step's run currently awaiting the human's input. Only one
    # human step is ever in flight in Define, so this is unambiguous.
    def pending_run
      @phase.workflows.flat_map(&:steps).select(&:type_human?)
        .filter_map(&:latest_run)
        .find { |r| r.state == "awaiting_input" }
    end

    def nothing_submitted?
      @notes.blank? && answered_pairs.empty?
    end

    # Only the questions the human actually answered (blank fields fall back to
    # the question's stated default downstream, so we don't record them).
    def answered_pairs
      @answered_pairs ||= @answers.filter_map do |entry|
        question = entry[:question].to_s.strip
        answer = entry[:answer].to_s.strip
        next if question.blank? || answer.blank?

        { "question" => question, "answer" => answer }
      end
    end

    def build_result
      {
        "schema_version" => "1.0",
        "summary" => "Human answered #{answered_pairs.size} question(s)" \
          "#{@notes.present? ? " and added notes" : ""}.",
        "artifacts" => {
          "human_answers" => rendered_markdown,
          "human_answers_structured" => answered_pairs
        }
      }
    end

    def rendered_markdown
      lines = answered_pairs.map { |p| "**Q: #{p["question"]}**\n\nA: #{p["answer"]}" }
      lines << "**Notes**\n\n#{@notes}" if @notes.present?
      lines.join("\n\n")
    end
  end
end
