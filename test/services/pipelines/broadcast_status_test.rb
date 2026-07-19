require "test_helper"

module Pipelines
  # Specs for the live delivery of the pipeline status summary over Turbo Streams.
  #
  # Design intent (guides/ui-style-guide.md "Real-time behavior" +
  # guides/backend-guide.md "Real-time (Turbo) conventions"): a dedicated service
  # broadcasts a replace of the smallest DOM unit — the pipeline's summary region,
  # keyed by dom_id(pipeline, :summary) — from the service layer (after commit),
  # mirroring StepRuns::BroadcastCard. Every run transition that alters "what is
  # happening right now" also refreshes the summary.
  #
  # Contract:
  #   Pipelines::BroadcastStatus.call(pipeline)  # replaces dom_id(pipeline, :summary)
  #
  # Assertions inspect the enqueued Turbo::Streams::ActionBroadcastJob directly
  # (the app's established pattern — see StepRuns::BroadcastCardTest) rather than
  # via Turbo::Broadcastable::TestHelper, which this app cannot load: it's only
  # wired up by turbo-rails behind an :action_cable on_load hook that never fires
  # without an app/channels mount, so referencing it aborts the whole suite.
  class BroadcastStatusTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @pipeline = pipelines(:onboarding)
      @worker = workers(:claude_local)
      @summary_target = ActionView::RecordIdentifier.dom_id(@pipeline, :summary)
    end

    # Asserts that, among whatever jobs the block enqueues, at least one Turbo
    # broadcast targets the pipeline's summary dom id.
    def assert_summary_broadcast(&block)
      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob,
        args: ->(job_args) { job_args.any? { |arg| arg.is_a?(Hash) && arg[:target] == @summary_target } },
        &block)
    end

    test "enqueues a turbo broadcast rather than rendering inline" do
      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
        BroadcastStatus.call(@pipeline)
      end
    end

    test "broadcast replaces the stable summary dom id on the pipeline stream" do
      assert_summary_broadcast { BroadcastStatus.call(@pipeline) }
    end

    test "claiming a run refreshes the live summary" do
      assert_summary_broadcast { StepRuns::Claim.call(worker: @worker) }
    end

    test "recording progress refreshes the live summary" do
      run = step_runs(:requirements_ready)
      run.update!(state: "claimed", worker: @worker, epoch: "e1",
        lease_expires_at: 1.minute.from_now)

      assert_summary_broadcast do
        StepRuns::RecordProgress.call(step_run: run, worker: @worker, epoch: "e1",
          progress: { "message" => "working" })
      end
    end

    test "completing a run refreshes the live summary" do
      run = step_runs(:requirements_ready)
      run.update!(state: "running", worker: @worker, epoch: "e2",
        lease_expires_at: 1.minute.from_now)

      assert_summary_broadcast do
        StepRuns::Complete.call(step_run: run, worker: @worker, epoch: "e2",
          status: "succeeded")
      end
    end
  end
end
