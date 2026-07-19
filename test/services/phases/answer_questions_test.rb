require "test_helper"

module Phases
  class AnswerQuestionsTest < ActiveSupport::TestCase
    setup do
      @pipeline = pipelines(:onboarding)
      @define = phases(:onboarding_define)
      @workflow = workflows(:define_main)
      @requirements = steps(:requirements_writer)
      # Clear the in-flight fixture run so the phase isn't "busy" by default.
      step_runs(:requirements_ready).update!(state: "succeeded")
    end

    test "queues a next-iteration requirements run carrying the answers as feedback" do
      @define.update!(status: "running")

      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "1. Use OAuth.")

      assert result.success?
      run = result.value
      assert_equal @requirements, run.step
      assert_equal "ready", run.state
      assert_equal 2, run.iteration
      assert_equal "requirements", run.required_role
      assert_equal({ "from" => "human", "issue" => "1. Use OAuth.", "severity" => "major" },
        run.feedback.first)
    end

    test "re-opens a consensus define for another iteration" do
      @define.update!(status: "consensus")
      @pipeline.update!(status: "awaiting_human")
      @workflow.update!(status: "converged")

      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "answers")

      assert result.success?
      assert_equal "running", @define.reload.status
      assert_equal "running", @pipeline.reload.status
      assert_equal "running", @workflow.reload.status
    end

    test "answers a paused phase and leaves it paused" do
      @define.update!(status: "paused")

      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "1. Use OAuth.")

      assert result.success?
      assert_equal "paused", @define.reload.status
    end

    test "leaves a running phase and pipeline as they are" do
      @define.update!(status: "running")
      @pipeline.update!(status: "running")

      AnswerQuestions.call(phase: @define, user: users(:dev), answers: "answers")

      assert_equal "running", @define.reload.status
      assert_equal "running", @pipeline.reload.status
    end

    test "guards against answering while a run is in flight" do
      @define.update!(status: "running")
      step_runs(:requirements_ready).update!(state: "running")

      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "answers")

      assert result.failure?
      assert_equal :busy, result.error
      assert_equal 1, @requirements.step_runs.count
    end

    test "rejects blank answers" do
      @define.update!(status: "running")
      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "   ")
      assert result.failure?
      assert_equal :blank_answers, result.error
    end

    test "rejects non-define phases" do
      plan = phases(:onboarding_plan)
      plan.update!(status: "running")
      result = AnswerQuestions.call(phase: plan, user: users(:dev), answers: "answers")
      assert result.failure?
      assert_equal :not_answerable, result.error
    end

    test "rejects an approved define" do
      @define.update!(status: "approved")
      result = AnswerQuestions.call(phase: @define, user: users(:dev), answers: "answers")
      assert result.failure?
      assert_equal :not_answerable, result.error
    end
  end
end
