require "test_helper"

module StepRuns
  class ClaimTest < ActiveSupport::TestCase
    setup do
      @worker = workers(:claude_local)
      @run = step_runs(:requirements_ready)
    end

    test "claims the oldest eligible ready run and leases it" do
      result = Claim.call(worker: @worker)

      assert result.success?
      run = result.value
      assert_equal @run, run
      assert_equal "claimed", run.state
      assert_equal @worker, run.worker
      assert run.epoch.present?
      assert run.lease_expires_at > 50.seconds.from_now
    end

    test "returns :no_work when no ready run matches the worker's roles" do
      @run.update!(required_role: "ui-tests")
      result = Claim.call(worker: @worker)

      assert result.failure?
      assert_equal :no_work, result.error
    end

    test "returns :at_capacity when the worker is at its concurrency limit" do
      @worker.update!(concurrency: 1)
      @run.update!(state: "running", worker: @worker,
        lease_expires_at: 1.minute.from_now)

      result = Claim.call(worker: @worker)
      assert result.failure?
      assert_equal :at_capacity, result.error
    end

    test "a claimed run is not claimable again" do
      assert Claim.call(worker: @worker).success?
      other = Worker.create!(public_id: "wk_other", auth_token_digest: "x",
        status: "online", supported_roles: [ "requirements" ], concurrency: 2)

      result = Claim.call(worker: other)
      assert_equal :no_work, result.error
    end
  end
end
