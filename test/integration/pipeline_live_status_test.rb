require "test_helper"

# Specs for the live status summary as it appears on the pipeline board (show).
#
# Requirements (the ask): a single, prominent, plain-language status per pipeline
# that (a) always reflects true current state on page load — no socket required —
# and (b) subscribes to the pipeline's Turbo stream so it updates live.
#
# Expected to fail until Build renders the status region and subscription.
class PipelineLiveStatusTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:dev)
    @pipeline = pipelines(:onboarding)
    @worker = workers(:claude_local)
    @status_id = ActionView::RecordIdentifier.dom_id(@pipeline, :status)
  end

  test "show renders the true live status on page load, without the socket" do
    @pipeline.update!(status: "running", current_phase: "define")
    step_runs(:requirements_ready).update!(
      state: "running", iteration: 3, worker: @worker, epoch: "e",
      lease_expires_at: 1.minute.from_now,
      progress: { "message" => "Drafting requirements" }
    )

    get pipeline_url(@pipeline)
    assert_response :success

    assert_select "##{@status_id}", 1, "the board has one live status region"
    assert_select "##{@status_id}", /define/i, "names the current phase"
    assert_select "##{@status_id}", /requirements/i, "names the active step"
    assert_select "##{@status_id}", /iteration 3|\b3\b/, "surfaces the iteration"
    # The semantic status word is present (a11y: never color alone).
    assert_select "##{@status_id}", /running/i
  end

  test "the status region is a polite live region for assistive tech" do
    @pipeline.update!(status: "running", current_phase: "define")

    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "##{@status_id}[aria-live=?]", "polite"
  end

  test "show subscribes to the pipeline stream so the status updates live" do
    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "turbo-cable-stream-source"
    assert_select "##{@status_id}"
  end

  test "a human gate reads as awaiting human approval on the board" do
    @pipeline.update!(status: "awaiting_human", current_phase: "plan")
    phases(:onboarding_plan).update!(status: "consensus", gate_mode: "human")

    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "##{@status_id}", /human/i
    assert_select "##{@status_id}", /approv/i
  end
end
