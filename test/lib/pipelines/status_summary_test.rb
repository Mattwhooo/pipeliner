require "test_helper"

module Pipelines
  # Specs for the plain-language "what is happening right now" summary that the
  # pipeline board shows for each pipeline (the live status feature).
  #
  # Design intent (docs + guides/backend-guide.md): turning a pipeline's live
  # state into a human sentence is *derivation logic*, so it lives in a reusable,
  # side-effect-free domain PORO in app/lib — not in a view, controller, or model
  # callback. It is a pure query-by, so it uses `.for` (not the service `.call`).
  #
  # Contract exercised here (Summary is an immutable value):
  #
  #   summary = Pipelines::StatusSummary.for(pipeline)
  #   summary.text        # => single-line plain-language sentence, never blank
  #   summary.tone        # => a StatusHelper tone symbol the dot/badge understands
  #   summary.phase_label # => humanized current phase ("Define") or nil
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

    # Leases a run so it counts as an actively-working step (state running/claimed
    # with a worker on it).
    def lease!(run, state: "running", iteration: 1, progress: nil, epoch: "e#{run.id}")
      run.update!(
        state: state, iteration: iteration, worker: @worker, epoch: epoch,
        lease_expires_at: 1.minute.from_now, progress: progress
      )
      run
    end

    # --- R10: not started -------------------------------------------------

    test "a draft pipeline reads as not started, in a muted tone" do
      @pipeline.update!(status: "draft")

      s = summary
      assert_match(/not started|not yet started/i, s.text)
      assert_equal :muted, s.tone
    end

    # --- R3 / R4: one active step -----------------------------------------

    test "one working step names the phase, the step, what it's doing, and (2nd+ pass) the iteration" do
      # e.g. "Define: requirements is drafting requirements, iteration 3"
      @pipeline.update!(status: "running", current_phase: "define")
      lease!(step_runs(:requirements_ready), iteration: 3,
        progress: { "message" => "Drafting requirements" })

      s = summary
      assert_equal :info, s.tone
      assert_match(/define/i, s.text, "names the current phase")
      assert_match(/requirements/i, s.text, "names the active step")
      assert_match(/iteration 3|\b3\b/, s.text, "surfaces the current iteration")
      assert_match(/define/i, s.phase_label.to_s, "exposes the humanized phase label")
    end

    test "with no progress message a type verb describes the work" do
      # requirements_writer is a builder -> "building" when it reports no message.
      @pipeline.update!(status: "running", current_phase: "define")
      lease!(step_runs(:requirements_ready), iteration: 1, progress: nil)

      s = summary
      assert_match(/define/i, s.text)
      assert_match(/requirements/i, s.text)
      assert_match(/building/i, s.text, "falls back to a builder's type verb")
    end

    test "the first pass does not shout 'iteration 1'" do
      # Mirrors the step-card convention (iteration only when > 1) — R4.
      @pipeline.update!(status: "running", current_phase: "define")
      lease!(step_runs(:requirements_ready), iteration: 1)

      refute_match(/iteration/i, summary.text)
    end

    # --- R5: two active steps -> name both --------------------------------

    test "two working steps are both named" do
      @pipeline.update!(status: "running", current_phase: "define")
      lease!(step_runs(:requirements_ready))
      completeness = steps(:completeness_critic).step_runs.create!(
        state: "ready", iteration: 1, required_role: "review")
      lease!(completeness, epoch: "e-review")

      s = summary
      assert_equal :info, s.tone
      assert_match(/requirements/i, s.text, "names the first step")
      assert_match(/review/i, s.text, "names the second step")
      assert_match(/\band\b/i, s.text, "joins the two with 'and'")
    end

    # --- R6: three or more -> phase + count, no individual names -----------

    test "three or more working steps collapse to the phase and a count" do
      # e.g. "Build: 4 steps are running" (here: Define).
      @pipeline.update!(status: "running", current_phase: "define")
      workflow = workflows(:define_main)
      4.times do |i|
        step = workflow.steps.create!(slug: "extra-#{i}", step_type: "builder",
          role: "code", position: 10 + i)
        run = step.step_runs.create!(state: "running", iteration: 1,
          required_role: "code")
        lease!(run, epoch: "e-#{i}")
      end

      s = summary
      assert_equal :info, s.tone
      assert_match(/define/i, s.text, "names the current phase")
      assert_match(/4 steps/i, s.text, "states the count of working steps")
      refute_match(/is building|is drafting|is running\b/i, s.text,
        "does not name individual steps past the threshold")
    end

    # --- R7: awaiting human ------------------------------------------------

    test "a human gate reads as awaiting human approval, naming the phase" do
      # e.g. "Waiting on human approval at the Plan gate"
      @pipeline.update!(status: "awaiting_human", current_phase: "plan")
      phases(:onboarding_plan).update!(status: "consensus", gate_mode: "human")

      s = summary
      assert_equal :attention, s.tone
      assert_match(/human/i, s.text)
      assert_match(/approv/i, s.text)
      assert_match(/plan/i, s.text, "names the gate's phase")
      assert_match(/gate/i, s.text)
    end

    test "an escalation reads as paused for human guidance, naming the phase" do
      # ManagerTick parks a phase at awaiting_human when it hits max iterations.
      @pipeline.update!(status: "awaiting_human", current_phase: "plan")
      phases(:onboarding_plan).update!(status: "awaiting_human")

      s = summary
      assert_equal :attention, s.tone
      assert_match(/plan/i, s.text, "names where it is parked")
      assert_match(/human|guidance/i, s.text)
    end

    # --- R8: completed -----------------------------------------------------

    test "a completed pipeline reads as done, in a success tone" do
      @pipeline.update!(status: "completed")

      s = summary
      assert_equal :success, s.tone
      assert_match(/complete|done/i, s.text)
    end

    # --- R9: failed error stop names where it stopped ----------------------

    test "a failed pipeline says it failed and names the phase and step" do
      @pipeline.update!(status: "running", current_phase: "define")
      phases(:onboarding_define).update!(status: "failed")
      step_runs(:requirements_ready).update!(state: "failed")

      s = summary
      assert_equal :danger, s.tone
      assert_match(/fail/i, s.text, "uses failure wording")
      assert_match(/define/i, s.text, "names the phase where it stopped")
      assert_match(/requirements/i, s.text, "names the step where it stopped")
    end

    # --- design branch 5 (R12): blocked / stuck, recoverable ---------------

    test "a stuck pipeline reads as blocked waiting on a worker, naming the phase" do
      @pipeline.update!(status: "stuck", current_phase: "define")
      # No failed phase and no failed/stuck run -> this is the recoverable wait.

      s = summary
      assert_equal :danger, s.tone
      assert_match(/define/i, s.text, "names the current phase")
      assert_match(/block|worker/i, s.text)
    end

    # --- R11: deliberately canceled ---------------------------------------

    test "an aborted pipeline reads as canceled, in a muted tone" do
      @pipeline.update!(status: "aborted")

      s = summary
      assert_equal :muted, s.tone, "a deliberate stop is muted, not danger"
      assert_match(/cancel/i, s.text)
    end

    # --- R12: totality — never blank, always a single truthful line --------

    test "running with no leased step still yields a truthful, non-blank line" do
      # A momentary lull: pipeline is running but nothing is claimed/running.
      @pipeline.update!(status: "running", current_phase: "define")
      step_runs(:requirements_ready).update!(state: "ready", worker: nil,
        lease_expires_at: nil)

      s = summary
      assert s.text.present?, "never blank even mid-transition"
      assert_match(/define/i, s.text, "still scoped to the current phase")
    end

    test "every top-level status yields a present, single-line summary" do
      %w[draft running awaiting_human blocked stuck completed aborted].each do |st|
        @pipeline.update!(status: st)
        text = StatusSummary.for(@pipeline.reload).text
        assert text.present?, "#{st} yields a non-empty summary"
        refute_includes text, "\n", "#{st} summary is a single line"
      end
    end

    # --- R17: tone is a real, centralized semantic key ---------------------

    test "tone is a StatusHelper tone the dot/badge can color" do
      # Guards the a11y rule: color stays semantic and centralized; the word
      # carries the meaning (guides/ui-style-guide.md). Every reachable state
      # resolves to a known tone.
      %w[draft running awaiting_human blocked stuck completed aborted].each do |st|
        @pipeline.update!(status: st)
        tone = StatusSummary.for(@pipeline.reload).tone
        assert_includes StatusHelper::TONE_CLASSES.keys, tone,
          "#{st} resolves to a known tone symbol"
      end
    end

    # --- R13: everyday language, no internal codes -------------------------

    test "the summary uses plain language with no internal codes or ids" do
      @pipeline.update!(status: "awaiting_human", current_phase: "plan")
      phases(:onboarding_plan).update!(status: "consensus", gate_mode: "human")

      text = summary.text
      refute_match(/awaiting_human|step_run|dom_id|_/i, text,
        "no raw enum codes, identifiers, or underscores leak into the sentence")
      refute_includes text, @pipeline.public_id
    end
  end
end
