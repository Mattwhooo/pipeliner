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
      @requirements.step_runs.create!(state: "succeeded", iteration: 1, attempt: 2, required_role: "requirements",
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
      @requirements.step_runs.create!(state: "succeeded", iteration: 1, attempt: 2, required_role: "requirements",
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
      @requirements.step_runs.create!(state: "ready", iteration: 1, attempt: 2, required_role: "requirements")
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

    test "seeds the first step strictly ahead of every worker step's iteration, not just its own" do
      critic = steps(:completeness_critic)
      # A menu re-run (RerunMenuStep) or an answered question bumped a later
      # step's iteration independently of the first step's — the restart must
      # still land ahead of it, or ManagerTick's cascade skips that step as
      # "already current" once it reaches it (F1).
      critic.step_runs.create!(state: "succeeded", iteration: 2, required_role: critic.role,
        finished_at: Time.current, merged_at: Time.current)

      result = RestartDefine.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal 3, result.value.iteration
    end

    test "the restart cascade does not skip a step that was already advanced independently" do
      critic = steps(:completeness_critic)
      @workflow.step_edges.create!(from_step: @requirements, to_step: critic, kind: "depends_on")
      critic.step_runs.create!(state: "succeeded", iteration: 2, required_role: critic.role,
        finished_at: Time.current, merged_at: Time.current)

      result = RestartDefine.call(phase: @define, user: users(:dev))
      assert result.success?
      run = result.value
      assert_equal 3, run.iteration

      run.update!(state: "succeeded", finished_at: Time.current, merged_at: Time.current)
      ManagerTick.call(phase: @define.reload)

      critic.reload
      assert_equal 3, critic.latest_run.iteration,
        "the already-advanced critic is re-dispatched by the cascade instead of being skipped"
      assert_equal "ready", critic.latest_run.state
    end

    test "de-duplicates repeatedly carried human feedback across multiple restarts" do
      feedback = { "from" => "human", "issue" => "Use OAuth.", "severity" => "major" }
      @requirements.step_runs.create!(state: "succeeded", iteration: 1, attempt: 2, required_role: "requirements",
        finished_at: Time.current, merged_at: Time.current, feedback: [ feedback ])
      # A prior restart's cascade already stamped the same feedback onto a
      # second step (ManagerTick#restart_carry_feedback) — collecting it again
      # unfiltered would double the set on every "Repeat from the Beginning"
      # loop (F2).
      critic = steps(:completeness_critic)
      critic.step_runs.create!(state: "succeeded", iteration: 1, required_role: critic.role,
        finished_at: Time.current, merged_at: Time.current, feedback: [ feedback ])

      result = RestartDefine.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal [ feedback ], result.value.feedback
      assert_equal [ feedback ], @define.reload.restart_feedback
    end
  end
end
