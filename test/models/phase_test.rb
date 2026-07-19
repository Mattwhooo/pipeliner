require "test_helper"

class PhaseTest < ActiveSupport::TestCase
  test "a pipeline cannot have two phases of the same kind" do
    dup = Phase.new(pipeline: pipelines(:onboarding), kind: "define", position: 5)
    assert_not dup.valid?
    assert dup.errors[:kind].any?
  end

  test "phases are ordered by position on the pipeline" do
    assert_equal %w[define plan build review], pipelines(:onboarding).phases.map(&:kind)
  end

  test "paused is a valid status" do
    define = phases(:onboarding_define)
    define.update!(status: "paused")
    assert define.reload.paused?
  end

  test "any_step_active? is true when a step has a ready/claimed/running run" do
    define = phases(:onboarding_define)
    step_runs(:requirements_ready).update!(state: "ready")
    assert define.any_step_active?
  end

  test "any_step_active? is false once every run has settled" do
    define = phases(:onboarding_define)
    step_runs(:requirements_ready).update!(state: "succeeded")
    assert_not define.any_step_active?
  end
end
