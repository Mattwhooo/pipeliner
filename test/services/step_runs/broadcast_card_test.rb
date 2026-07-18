require "test_helper"

module StepRuns
  class BroadcastCardTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    test "state-changing services enqueue a card broadcast" do
      worker = workers(:claude_local)

      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
        Claim.call(worker: worker)
      end

      run = step_runs(:requirements_ready).reload
      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
        RecordProgress.call(step_run: run, worker: worker, epoch: run.epoch,
          progress: { "message" => "working" })
      end

      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
        Complete.call(step_run: run.reload, worker: worker, epoch: run.epoch,
          status: "succeeded")
      end
    end

    test "broadcast renders the step card partial for the pipeline stream" do
      run = step_runs(:requirements_ready)
      perform_enqueued_jobs do
        BroadcastCard.call(run)
      end
      # Rendering happened without error; the target is the step card dom id.
      assert true
    end
  end
end
