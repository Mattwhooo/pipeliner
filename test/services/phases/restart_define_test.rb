require "test_helper"

module Phases
  class RestartDefineTest < ActiveSupport::TestCase
    setup do
      @define = phases(:onboarding_define)
      @workflow = workflows(:define_main)
      @requirements = steps(:requirements_writer) # position 1, first worker step
      step_runs(:requirements_ready).update!(state: "succeeded")
      @define.update!(status: "paused")
    end

    test "queues a fresh run on the first worker-executed step" do
      result = RestartDefine.call(phase: @define, user: users(:dev))

      assert result.success?
      run = result.value
      assert_equal @requirements, run.step
      assert_equal "ready", run.state
      assert_equal 2, run.iteration
    end

    test "flips the phase back to running with restart_in_progress set" do
      RestartDefine.call(phase: @define, user: users(:dev))

      @define.reload
      assert @define.running?
      assert @define.restart_in_progress?
      assert_not @define.pause_requested?
    end

    test "carries prior human-tagged feedback onto the seeded run" do
      @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
        finished_at: Time.current, merged_at: Time.current,
        feedback: [ { "from" => "human", "issue" => "Use OAuth.", "severity" => "major" } ])

      result = RestartDefine.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal [ { "from" => "human", "issue" => "Use OAuth.", "severity" => "major" } ],
        result.value.feedback
      assert_equal [ { "from" => "human", "issue" => "Use OAuth.", "severity" => "major" } ],
        @define.reload.restart_feedback
    end

    test "does not carry non-human feedback" do
      @requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
        finished_at: Time.current, merged_at: Time.current,
        feedback: [ { "from" => "critic", "issue" => "Not atomic.", "severity" => "major" } ])

      result = RestartDefine.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_empty result.value.feedback
    end

    test "refuses to restart a phase that isn't paused" do
      @define.update!(status: "running")
      result = RestartDefine.call(phase: @define, user: users(:dev))
      assert result.failure?
      assert_equal :not_paused, result.error
    end

    test "refuses to restart while a step is active" do
      @requirements.step_runs.create!(state: "ready", iteration: 1, required_role: "requirements")
      result = RestartDefine.call(phase: @define, user: users(:dev))
      assert result.failure?
      assert_equal :busy, result.error
    end

    test "no-ops with no_steps when the phase has no worker-executed steps" do
      @workflow.steps.destroy_all
      result = RestartDefine.call(phase: @define, user: users(:dev))
      assert result.failure?
      assert_equal :no_steps, result.error
    end
  end
end
