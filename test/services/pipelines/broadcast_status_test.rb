require "test_helper"

module Pipelines
  # Specs for the live delivery of the pipeline status summary over Turbo Streams.
  #
  # Design intent (guides/ui-style-guide.md "Real-time behavior" +
  # guides/backend-guide.md "Real-time (Turbo) conventions"): a dedicated service
  # broadcasts a replace of the smallest DOM unit — the pipeline's status region,
  # keyed by a stable dom id — from the service layer (after commit), mirroring
  # StepRuns::BroadcastCard. Every step-run state change that alters "what is
  # happening right now" also refreshes the status.
  #
  # Contract:
  #   Pipelines::BroadcastStatus.call(pipeline)  # replaces dom_id(pipeline, :status)
  #
  # Expected to fail until Build adds Pipelines::BroadcastStatus and wires the
  # step-run services to it.
  class BroadcastStatusTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include Turbo::Broadcastable::TestHelper

    setup do
      @pipeline = pipelines(:onboarding)
      @worker = workers(:claude_local)
      @status_target = ActionView::RecordIdentifier.dom_id(@pipeline, :status)
    end

    # Targets of every turbo-stream message broadcast to the pipeline's stream.
    def broadcast_targets
      capture_turbo_stream_broadcasts(@pipeline).map { |el| el["target"] }
    end

    test "enqueues a turbo broadcast rather than rendering inline" do
      assert_enqueued_with(job: Turbo::Streams::ActionBroadcastJob) do
        BroadcastStatus.call(@pipeline)
      end
    end

    test "broadcast replaces the stable status dom id on the pipeline stream" do
      perform_enqueued_jobs { BroadcastStatus.call(@pipeline) }

      assert_includes broadcast_targets, @status_target
    end

    test "recording progress refreshes the live status" do
      run = step_runs(:requirements_ready)
      run.update!(state: "claimed", worker: @worker, epoch: "e1",
        lease_expires_at: 1.minute.from_now)

      perform_enqueued_jobs do
        StepRuns::RecordProgress.call(step_run: run, worker: @worker, epoch: "e1",
          progress: { "message" => "working" })
      end

      assert_includes broadcast_targets, @status_target
    end

    test "completing a run refreshes the live status" do
      run = step_runs(:requirements_ready)
      run.update!(state: "running", worker: @worker, epoch: "e2",
        lease_expires_at: 1.minute.from_now)

      perform_enqueued_jobs do
        StepRuns::Complete.call(step_run: run, worker: @worker, epoch: "e2",
          status: "succeeded")
      end

      assert_includes broadcast_targets, @status_target
    end

    test "claiming a run refreshes the live status" do
      perform_enqueued_jobs { StepRuns::Claim.call(worker: @worker) }

      assert_includes broadcast_targets, @status_target
    end
  end
end
