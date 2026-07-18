require "test_helper"

module StepRuns
  class CompleteTest < ActiveSupport::TestCase
    setup do
      @worker = workers(:claude_local)
      @run = step_runs(:requirements_ready)
      @run.update!(state: "running", worker: @worker, epoch: "abc123",
        lease_expires_at: 1.minute.from_now)
    end

    test "records a successful completion" do
      result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
        status: "succeeded", result: { "ok" => true }, commit_sha: "deadbeef")

      assert result.success?
      @run.reload
      assert_equal "succeeded", @run.state
      assert_equal "deadbeef", @run.commit_sha
      assert @run.finished_at.present?
      assert_nil @run.lease_expires_at
    end

    test "rejects a completion with a stale epoch" do
      result = Complete.call(step_run: @run, worker: @worker, epoch: "old-epoch",
        status: "succeeded")

      assert result.failure?
      assert_equal :stale_epoch, result.error
      assert_equal "running", @run.reload.state
    end

    test "rejects a duplicate success for the same (step, iteration) — at-most-one-merge" do
      StepRun.create!(step: @run.step, iteration: @run.iteration, attempt: @run.attempt + 1,
        state: "succeeded", required_role: @run.required_role)

      result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
        status: "succeeded")

      assert result.failure?
      assert_equal :duplicate_completion, result.error
    end

    test "rejects an unknown status" do
      result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
        status: "exploded")
      assert_equal :invalid_status, result.error
    end
  end
end
