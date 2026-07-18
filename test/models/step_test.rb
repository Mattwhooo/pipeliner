require "test_helper"

class StepTest < ActiveSupport::TestCase
  test "worker-executed step types require a role" do
    step = Step.new(workflow: workflows(:define_main), slug: "x", step_type: "builder")
    assert_not step.valid?
    assert step.errors[:role].any?
  end

  test "controller step types do not require a role" do
    step = Step.new(workflow: workflows(:define_main), slug: "g", step_type: "gate")
    assert step.valid?
  end

  test "slug is unique within a workflow" do
    step = Step.new(workflow: workflows(:define_main), slug: "requirements",
      step_type: "builder", role: "code")
    assert_not step.valid?
    assert step.errors[:slug].any?
  end
end
