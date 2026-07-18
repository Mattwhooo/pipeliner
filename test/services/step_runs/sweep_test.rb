require "test_helper"

module StepRuns
  class SweepTest < ActiveSupport::TestCase
    setup do
      @worker = workers(:claude_local)
      @run = step_runs(:requirements_ready)
    end

    test "reclaims expired leases back to ready with a new attempt" do
      @run.update!(state: "running", worker: @worker, epoch: "gone",
        lease_expires_at: 1.minute.ago, attempt: 1)

      Sweep.call
      @run.reload

      assert_equal "ready", @run.state
      assert_equal 2, @run.attempt
      assert_nil @run.worker_id
      assert_nil @run.epoch
    end

    test "marks workers with stale heartbeats offline" do
      @worker.update!(status: "online", last_heartbeat_at: 5.minutes.ago)
      Sweep.call
      assert_equal "offline", @worker.reload.status
    end

    test "flags aged ready runs with no capable online worker as stuck" do
      @run.update!(required_role: "ui-tests", created_at: 2.minutes.ago)
      Sweep.call
      assert_equal "stuck", @run.reload.state
    end

    test "recovers stuck runs when a capable worker is online" do
      @run.update!(state: "stuck", required_role: "ui-tests")
      @worker.update!(status: "online", last_heartbeat_at: Time.current,
        supported_roles: [ "ui-tests" ])

      Sweep.call
      assert_equal "ready", @run.reload.state
    end

    test "respects the stuck grace period for fresh runs" do
      @run.update!(required_role: "ui-tests", created_at: 10.seconds.ago)
      Sweep.call
      assert_equal "ready", @run.reload.state
    end
  end
end
