require "test_helper"

module Pipelines
  # Specs for the plain-language "what is happening right now" summary that the
  # pipeline board shows for each pipeline (the live status feature).
  #
  # Design intent (derived from the ask + guides/backend-guide.md): the mapping
  # from a pipeline's live state to a human sentence is *derivation logic*, so it
  # lives in a reusable, side-effect-free PORO — not in a view, controller, or
  # model callback. Contract exercised here:
  #
  #   summary = Pipelines::StatusSummary.for(pipeline)
  #   summary.text    # => single-line plain-language sentence
  #   summary.status  # => a semantic status keyword the badge helper understands
  #
  # These are expected to fail until Build implements Pipelines::StatusSummary.
  class StatusSummaryTest < ActiveSupport::TestCase
    setup do
      @pipeline = pipelines(:onboarding)
      @worker = workers(:claude_local)
    end

    def summary
      StatusSummary.for(@pipeline.reload)
    end

    test "a draft pipeline reads as not started" do
      @pipeline.update!(status: "draft")

      s = summary
      assert_equal "draft", s.status
      assert_match(/not started|not yet started|draft/i, s.text)
    end

    test "a running phase names the phase, the active step, and the iteration" do
      # e.g. "Define: requirements is drafting requirements, iteration 3"
      @pipeline.update!(status: "running", current_phase: "define")
      step_runs(:requirements_ready).update!(
        state: "running", iteration: 3, worker: @worker, epoch: "e",
        lease_expires_at: 1.minute.from_now,
        progress: { "message" => "Drafting requirements" }
      )

      s = summary
      assert_equal "running", s.status
      assert_match(/define/i, s.text, "names the current phase")
      assert_match(/requirements/i, s.text, "names the active step")
      assert_match(/iteration 3|\b3\b/, s.text, "surfaces the current iteration")
    end

    test "the first pass does not shout 'iteration 1'" do
      # Mirrors the step-card convention (iteration chip only when > 1).
      @pipeline.update!(status: "running", current_phase: "define")
      step_runs(:requirements_ready).update!(
        state: "running", iteration: 1, worker: @worker, epoch: "e",
        lease_expires_at: 1.minute.from_now
      )

      refute_match(/iteration 1\b/i, summary.text)
    end

    test "running with only queued work reads as waiting to start it" do
      @pipeline.update!(status: "running", current_phase: "define")
      # requirements_ready is 'ready' (queued); nothing claimed or running.
      step_runs(:requirements_ready).update!(state: "ready", worker: nil)

      s = summary
      assert_equal "running", s.status
      assert_match(/queued|waiting|ready|about to|to start/i, s.text)
    end

    test "a human gate reads as awaiting human approval, naming the phase" do
      # e.g. "Waiting on human approval at the Plan gate"
      @pipeline.update!(status: "awaiting_human", current_phase: "plan")
      phases(:onboarding_plan).update!(status: "consensus", gate_mode: "human")

      s = summary
      assert_equal "awaiting_human", s.status
      assert_match(/human/i, s.text)
      assert_match(/approv/i, s.text)
      assert_match(/plan/i, s.text, "names the gate's phase")
      assert_match(/gate/i, s.text)
    end

    test "a stuck run surfaces as stuck and names the blocked role" do
      @pipeline.update!(status: "stuck", current_phase: "define")
      step_runs(:requirements_ready).update!(state: "stuck", required_role: "requirements")

      s = summary
      assert_equal "stuck", s.status
      assert_match(/stuck/i, s.text)
      assert_match(/requirements/i, s.text)
    end

    test "a completed pipeline reads as done" do
      @pipeline.update!(status: "completed")

      s = summary
      assert_equal "completed", s.status
      assert_match(/complete|done|merged/i, s.text)
    end

    test "an aborted pipeline reads as aborted" do
      @pipeline.update!(status: "aborted")

      s = summary
      assert_equal "aborted", s.status
      assert_match(/abort|cancel/i, s.text)
    end

    test "text is a present, single-line sentence for every top-level state" do
      %w[draft running awaiting_human blocked stuck completed aborted].each do |st|
        @pipeline.update!(status: st)
        text = StatusSummary.for(@pipeline.reload).text
        assert text.present?, "#{st} yields a non-empty summary"
        refute_includes text, "\n", "#{st} summary is a single line"
      end
    end

    test "exposes a semantic status keyword the badge helper understands" do
      # Guards the a11y rule: status is a real word the shared StatusBadge can
      # color — never color alone (guides/ui-style-guide.md).
      @pipeline.update!(status: "running", current_phase: "define")
      step_runs(:requirements_ready).update!(
        state: "running", worker: @worker, epoch: "e", lease_expires_at: 1.minute.from_now
      )

      assert_includes StatusHelper::STATUS_TONES.keys, summary.status
    end
  end
end
