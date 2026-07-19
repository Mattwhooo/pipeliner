require "test_helper"

module Phases
  class PauseTest < ActiveSupport::TestCase
    setup do
      @define = phases(:onboarding_define)
      @define.update!(status: "running")
    end

    test "pauses immediately when nothing is in flight" do
      step_runs(:requirements_ready).update!(state: "succeeded")

      result = Pause.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal "paused", @define.reload.status
      assert_not @define.pause_requested?
    end

    test "flags pause_requested and stays running while a step is in flight" do
      # requirements_ready fixture is in state ready → the loop is busy.
      result = Pause.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal "running", @define.reload.status
      assert @define.pause_requested?
      assert @define.pause_requested_at.present?
    end

    test "re-clicking pause while a request is already pending is idempotent" do
      Pause.call(phase: @define, user: users(:dev))
      requested_at = @define.reload.pause_requested_at

      result = Pause.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal "running", @define.reload.status
      assert_equal requested_at, @define.pause_requested_at
    end

    test "refuses to pause a phase that isn't running" do
      @define.update!(status: "consensus")

      result = Pause.call(phase: @define, user: users(:dev))

      assert result.failure?
      assert_equal :not_pausable, result.error
    end

    test "refuses to pause a non-Define phase" do
      plan = phases(:onboarding_plan)
      plan.update!(status: "running")

      result = Pause.call(phase: plan, user: users(:dev))

      assert result.failure?
      assert_equal :not_pausable, result.error
      assert_equal "running", plan.reload.status
    end
  end
end
