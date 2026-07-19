require "test_helper"

module StepRuns
  class CompleteTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @worker = workers(:claude_local)
      @run = step_runs(:requirements_ready)
      @run.update!(state: "running", worker: @worker, epoch: "abc123",
        lease_expires_at: 1.minute.from_now)
    end

    test "records a successful completion and enqueues the branch merge" do
      result = nil
      assert_enqueued_with(job: Pipelines::MergeStepBranchJob, args: [ @run ]) do
        result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
          status: "succeeded", result: { "ok" => true }, commit_sha: "deadbeef")
      end

      assert result.success?
      @run.reload
      assert_equal "succeeded", @run.state
      assert_equal "deadbeef", @run.commit_sha
      assert @run.finished_at.present?
      assert_nil @run.lease_expires_at
    end

    test "a failed completion does not enqueue a merge" do
      assert_no_enqueued_jobs only: Pipelines::MergeStepBranchJob do
        Complete.call(step_run: @run, worker: @worker, epoch: "abc123", status: "failed")
      end
      assert_equal "failed", @run.reload.state
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

    test "a transient completion re-queues the run with backoff" do
      result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
        status: "transient", result: { "summary" => "session limit, resets 6pm" })

      assert result.success?
      @run.reload
      assert_equal "ready", @run.state
      assert_equal 2, @run.attempt
      assert_nil @run.worker_id
      assert_nil @run.epoch
      assert @run.available_at > 4.minutes.from_now
      assert @run.available_at < 6.minutes.from_now
      assert_match(/session limit/, @run.result["summary"])
    end

    test "transient backoff grows with attempts and caps at 30 minutes" do
      @run.update!(attempt: 7)
      Complete.call(step_run: @run, worker: @worker, epoch: "abc123", status: "transient")
      assert_in_delta 30.minutes.from_now.to_f, @run.reload.available_at.to_f, 10
    end

    test "transient retries exhaust into a real failure" do
      @run.update!(attempt: Complete::MAX_TRANSIENT_ATTEMPTS)
      result = Complete.call(step_run: @run, worker: @worker, epoch: "abc123",
        status: "transient", result: { "summary" => "still limited" })

      assert result.success?
      @run.reload
      assert_equal "failed", @run.state
      assert_match(/retries exhausted/, @run.result["summary"])
    end

    test "a transient completion does not enqueue a merge" do
      assert_no_enqueued_jobs only: Pipelines::MergeStepBranchJob do
        Complete.call(step_run: @run, worker: @worker, epoch: "abc123", status: "transient")
      end
    end
  end
end
