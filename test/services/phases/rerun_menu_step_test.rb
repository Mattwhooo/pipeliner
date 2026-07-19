require "test_helper"

module Phases
  class RerunMenuStepTest < ActiveSupport::TestCase
    setup do
      @define = phases(:onboarding_define)
      @workflow = workflows(:define_main)
      @requirements = steps(:requirements_writer)
      # Clear the in-flight fixture run so the phase isn't "busy" by default.
      step_runs(:requirements_ready).update!(state: "succeeded")

      @explorer = @workflow.steps.create!(slug: "explore", step_type: "builder",
        role: "code", position: 0,
        outputs: [ { "artifact" => "discovery_notes", "kind" => "artifact",
                     "path" => "output/discovery_notes.md" } ])
      @questions = @workflow.steps.create!(slug: "clarifying-questions", step_type: "builder",
        role: "requirements", position: 3,
        outputs: [ { "artifact" => "open_questions", "kind" => "artifact",
                     "path" => "output/open_questions.md" } ])

      @define.update!(status: "paused")
    end

    test "queues a fresh run on the step that declares the target artifact" do
      result = RerunMenuStep.call(phase: @define, artifact: "discovery_notes")

      assert result.success?
      run = result.value
      assert_equal @explorer, run.step
      assert_equal "ready", run.state
      assert_equal 1, run.iteration
      assert_equal "code", run.required_role
    end

    test "resolves Clarifying Questions by its open_questions output" do
      result = RerunMenuStep.call(phase: @define, artifact: "open_questions")

      assert result.success?
      assert_equal @questions, result.value.step
    end

    test "increments the iteration on a re-run" do
      RerunMenuStep.call(phase: @define, artifact: "discovery_notes")
      @explorer.step_runs.last.update!(state: "succeeded")

      result = RerunMenuStep.call(phase: @define, artifact: "discovery_notes")

      assert result.success?
      assert_equal 2, result.value.iteration
    end

    test "the phase remains paused after queuing a menu re-run" do
      RerunMenuStep.call(phase: @define, artifact: "discovery_notes")
      assert @define.reload.paused?
    end

    test "rejects an artifact that isn't a menu action" do
      result = RerunMenuStep.call(phase: @define, artifact: "business_requirements")
      assert result.failure?
      assert_equal :invalid_artifact, result.error
    end

    test "refuses to run when the phase isn't paused" do
      @define.update!(status: "running")
      result = RerunMenuStep.call(phase: @define, artifact: "discovery_notes")
      assert result.failure?
      assert_equal :not_paused, result.error
    end

    test "refuses to run when another step is already active" do
      @explorer.step_runs.create!(state: "ready", iteration: 1, required_role: "code")

      result = RerunMenuStep.call(phase: @define, artifact: "discovery_notes")

      assert result.failure?
      assert_equal :busy, result.error
    end

    test "no-ops with no_target when the phase has no step for that artifact" do
      @explorer.destroy!
      result = RerunMenuStep.call(phase: @define, artifact: "discovery_notes")
      assert result.failure?
      assert_equal :no_target, result.error
    end
  end
end
