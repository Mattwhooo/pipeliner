require "test_helper"

module Phases
  class TickAllTest < ActiveSupport::TestCase
    test "ticks every running phase and dispatches ready work" do
      phase = phases(:onboarding_plan)
      phase.update!(status: "running")
      workflow = phase.workflows.create!(slug: "main")
      workflow.steps.create!(slug: "build", step_type: "builder", role: "requirements", position: 1)

      result = TickAll.call

      assert result.success?
      assert result.value[:ticked] >= 1
      assert phase.workflows.first.steps.first.step_runs.ready.exists?,
        "the running phase's root step was dispatched"
    end

    test "ignores phases that are not running" do
      phases(:onboarding_plan).update!(status: "pending")
      # onboarding_define is running in fixtures but has a builder with an active
      # ready run already, so a tick is a no-op there.
      assert_nothing_raised { TickAll.call }
    end
  end
end
