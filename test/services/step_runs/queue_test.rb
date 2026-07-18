require "test_helper"

module StepRuns
  class QueueTest < ActiveSupport::TestCase
    test "queues the next iteration when the previous run finished" do
      run = step_runs(:requirements_ready)
      run.update!(state: "succeeded")

      result = Queue.call(step: steps(:requirements_writer))

      assert result.success?
      assert_equal 2, result.value.iteration
      assert_equal "ready", result.value.state
      assert_equal "requirements", result.value.required_role
    end

    test "refuses when a run is already active" do
      result = Queue.call(step: steps(:requirements_writer)) # fixture run is ready
      assert result.failure?
      assert_equal :already_active, result.error
    end

    test "refuses non-worker-executed steps" do
      gate = steps(:requirements_writer).workflow.steps.create!(
        slug: "gate", step_type: "gate", position: 99)
      result = Queue.call(step: gate)
      assert_equal :not_worker_executed, result.error
    end
  end
end
