require "test_helper"

module Phases
  class SubmitHumanFeedbackTest < ActiveSupport::TestCase
    setup do
      @define = phases(:onboarding_define)
      @define.update!(status: "running")
      @workflow = @define.workflows.first
      @human_step = @workflow.steps.create!(slug: "human-feedback", step_type: "human",
        role: "human", position: 3,
        outputs: [ { "artifact" => "human_answers", "kind" => "artifact", "path" => "output/human_answers.md" } ])
      @run = @human_step.step_runs.create!(state: "awaiting_input", iteration: 1,
        required_role: "human")
    end

    test "completes the pending run and stores the answers as its artifact" do
      result = SubmitHumanFeedback.call(phase: @define, user: users(:dev),
        answers: [ { question: "Scope?", answer: "just the API" },
                   { question: "Empty?", answer: "" } ],
        notes: "keep it small")

      assert result.success?
      @run.reload
      assert_equal "succeeded", @run.state
      assert @run.merged_at.present?, "human run is marked merged (nothing to merge)"

      answers = @run.result.dig("artifacts", "human_answers_structured")
      assert_equal 1, answers.size, "the blank answer is dropped"
      assert_equal "just the API", answers.first["answer"]
      assert_includes @run.result.dig("artifacts", "human_answers"), "keep it small"
    end

    test "a notes-only submission (no question answers) still completes the step" do
      result = SubmitHumanFeedback.call(phase: @define, user: users(:dev),
        answers: [], notes: "some context")

      assert result.success?
      assert_equal "succeeded", @run.reload.state
    end

    test "fails when nothing was submitted" do
      result = SubmitHumanFeedback.call(phase: @define, user: users(:dev),
        answers: [ { question: "Q?", answer: "" } ], notes: "")

      assert result.failure?
      assert_equal :blank_answers, result.error
      assert_equal "awaiting_input", @run.reload.state
    end

    test "fails when no human step is awaiting input" do
      @run.update!(state: "succeeded")

      result = SubmitHumanFeedback.call(phase: @define, user: users(:dev),
        answers: [ { question: "Q?", answer: "A" } ], notes: "")

      assert result.failure?
      assert_equal :no_pending_step, result.error
    end
  end
end
