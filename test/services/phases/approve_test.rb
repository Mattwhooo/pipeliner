require "test_helper"

module Phases
  class ApproveTest < ActiveSupport::TestCase
    setup do
      @pipeline = pipelines(:onboarding)
      @define = phases(:onboarding_define)
    end

    test "approves a consensus phase and starts the next one" do
      @define.update!(status: "consensus")
      @pipeline.update!(status: "awaiting_human")

      result = Approve.call(phase: @define, user: users(:dev), note: "LGTM")

      assert result.success?
      assert_equal "approved", @define.reload.status
      assert_equal "running", phases(:onboarding_plan).reload.status
      @pipeline.reload
      assert_equal "plan", @pipeline.current_phase
      assert_equal "running", @pipeline.status
      approval = @define.approvals.sole
      assert_equal users(:dev), approval.user
      assert_equal "LGTM", approval.note
    end

    test "approving an escalated awaiting_human phase works (approve anyway)" do
      @define.update!(status: "awaiting_human")
      result = Approve.call(phase: @define, user: users(:dev))
      assert result.success?
      assert_equal "approved", @define.reload.status
    end

    test "approving review completes the pipeline" do
      review = phases(:onboarding_review)
      review.update!(status: "consensus")
      result = Approve.call(phase: review, user: users(:dev))
      assert result.success?
      assert_equal "completed", @pipeline.reload.status
    end

    test "refuses phases that are not at a gate" do
      @define.update!(status: "running")
      result = Approve.call(phase: @define, user: users(:dev))
      assert result.failure?
      assert_equal :not_approvable, result.error
    end
  end
end
