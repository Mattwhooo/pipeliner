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
end
