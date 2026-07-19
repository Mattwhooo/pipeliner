require "test_helper"

# Specs for the live status summary as it appears on the pipeline board (show)
# and the pipeline list (index).
#
# Requirements (the ask + R1, R2, R14, R15, R17, R18): a single, prominent,
# plain-language status per pipeline that (a) always reflects true current state
# on page load — no socket required (R15) — (b) subscribes to the pipeline's
# Turbo stream so it updates live (R14), and (c) shows the same state compactly
# on the list as fully on the detail page (R2, R18).
#
# The repo has no configured system-test base class, so these full-stack request
# specs live in test/integration, matching worker_api_lifecycle_test.rb.
#
# Expected to fail until Build renders the summary region and its subscriptions.
class PipelineLiveStatusTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:dev)
    @pipeline = pipelines(:onboarding)
    @worker = workers(:claude_local)
    @summary_id = ActionView::RecordIdentifier.dom_id(@pipeline, :summary)
  end

  # --- R1, R15, R17: prominent, true-on-load, word-not-color ---------------

  test "show renders the true live status on page load, without the socket" do
    @pipeline.update!(status: "running", current_phase: "define")
    step_runs(:requirements_ready).update!(
      state: "running", iteration: 3, worker: @worker, epoch: "e",
      lease_expires_at: 1.minute.from_now,
      progress: { "message" => "Drafting requirements" }
    )

    get pipeline_url(@pipeline)
    assert_response :success

    assert_select "##{@summary_id}", 1, "the board has one live status region"
    assert_select "##{@summary_id}", /define/i, "names the current phase"
    assert_select "##{@summary_id}", /requirements/i, "names the active step"
    assert_select "##{@summary_id}", /iteration 3|\b3\b/, "surfaces the iteration"
  end

  test "the status region is a polite live region for assistive tech" do
    @pipeline.update!(status: "running", current_phase: "define")

    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "##{@summary_id}[aria-live=?]", "polite"
  end

  # --- R14: subscribes so it can update live -------------------------------

  test "show subscribes to the pipeline stream so the status updates live" do
    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "turbo-cable-stream-source"
    assert_select "##{@summary_id}"
  end

  # --- R7: awaiting-human wording on the board -----------------------------

  test "a human gate reads as awaiting human approval on the board" do
    @pipeline.update!(status: "awaiting_human", current_phase: "plan")
    phases(:onboarding_plan).update!(status: "consensus", gate_mode: "human")

    get pipeline_url(@pipeline)
    assert_response :success
    assert_select "##{@summary_id}", /human/i
    assert_select "##{@summary_id}", /approv/i
  end

  # --- R2, R18: the list shows the same state compactly, and stays live -----

  test "the pipeline list shows a live compact summary for each row" do
    @pipeline.update!(status: "running", current_phase: "define")
    step_runs(:requirements_ready).update!(
      state: "running", iteration: 3, worker: @worker, epoch: "e",
      lease_expires_at: 1.minute.from_now,
      progress: { "message" => "Drafting requirements" }
    )

    get pipelines_url
    assert_response :success

    # Same stable target as the detail page, so the two surfaces cannot disagree.
    assert_select "##{@summary_id}", 1, "the row carries the compact summary"
    assert_select "##{@summary_id}", /define/i, "the compact form conveys the same state"
    assert_select "##{@summary_id}", /requirements/i
    # The list subscribes too, so it is never stale/static.
    assert_select "turbo-cable-stream-source"
  end
end
