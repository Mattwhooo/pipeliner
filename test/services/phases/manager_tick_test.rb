require "test_helper"

module Phases
  class ManagerTickTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @pipeline = pipelines(:onboarding)
      @phase = phases(:onboarding_plan) # no workflows in fixtures — clean slate
    end

    # A phase with a lone builder step — a valid inter-phase rework target.
    def add_builder(phase)
      workflow = phase.workflows.create!(slug: "impl-#{SecureRandom.hex(4)}",
        max_iterations: 10, status: "converged")
      workflow.steps.create!(slug: "impl", step_type: "builder", role: "code", position: 1)
    end

    # A phase whose only worker step is a critic with NO route_to edge, already
    # returning the given verdict — the routeless needs_work case.
    def add_lone_critic(phase, verdict:)
      workflow = phase.workflows.create!(slug: "crit-#{SecureRandom.hex(4)}",
        max_iterations: 10, status: "running")
      critic = workflow.steps.create!(slug: "review-check", step_type: "critic",
        role: "review", position: 1)
      succeed(critic, iteration: 1, verdict: verdict)
      [ workflow, critic ]
    end

    # Builds a builder -> critic consensus loop under the phase:
    #   builder --depends_on--> critic   (critic runs after the builder)
    #   critic  --route_to----> builder  (needs_work re-runs the builder)
    def build_loop(phase, max_iterations: 10)
      workflow = phase.workflows.create!(slug: "loop-#{SecureRandom.hex(4)}",
        max_iterations: max_iterations)
      builder = workflow.steps.create!(slug: "build", step_type: "builder",
        role: "requirements", position: 1)
      critic = workflow.steps.create!(slug: "check", step_type: "critic",
        role: "review", position: 2)
      workflow.step_edges.create!(from_step: builder, to_step: critic, kind: "depends_on")
      workflow.step_edges.create!(from_step: critic, to_step: builder, kind: "route_to")
      [ workflow, builder, critic ]
    end

    def succeed(step, iteration:, verdict: nil, merged: true)
      step.step_runs.create!(state: "succeeded", iteration: iteration,
        required_role: step.role, verdict: verdict, finished_at: Time.current,
        merged_at: merged ? Time.current : nil)
    end

    def run!(phase = @phase)
      ManagerTick.call(phase: phase)
    end

    test "a hard-failed step escalates the phase to the human gate" do
      @phase.update!(status: "running")
      _workflow, builder, _critic = build_loop(@phase)
      builder.step_runs.create!(state: "failed", iteration: 1, required_role: builder.role,
        result: { "summary" => "claude exited 1: boom" }, finished_at: Time.current)

      run!

      assert_equal "awaiting_human", @phase.reload.status
      assert @pipeline.reload.awaiting_human?
      decision = @phase.manager_decisions.escalate_decision.last
      assert_match(/latest run failed/, decision.rationale)
    end

    test "routeless needs_work with no earlier builder phase escalates instead of spinning" do
      define = phases(:onboarding_define)
      define.update!(status: "running")
      define.workflows.first&.steps&.each { |st| st.step_runs.destroy_all }
      add_lone_critic(define, verdict: { "verdict" => "needs_work", "findings" => [] })

      ManagerTick.call(phase: define)

      assert_equal "awaiting_human", define.reload.status
      assert_match(/no earlier builder phase/, define.manager_decisions.escalate_decision.last.rationale)
    end

    test "needs_work persisting after a spent rework escalates to the human gate" do
      @phase.update!(status: "running")
      add_builder(phases(:onboarding_define))
      _workflow, critic = add_lone_critic(@phase, verdict: { "verdict" => "needs_work", "findings" => [] })
      # A rework from this phase already happened after the verdict — no move left.
      ReworkEvent.create!(pipeline: @pipeline, from_phase: @phase,
        target_phase: phases(:onboarding_define), reason: "prior rework", mode: "automated",
        raised_by: "agent", feedback: [], created_at: critic.latest_run.finished_at + 1.minute)

      run!

      assert_equal "awaiting_human", @phase.reload.status
      assert_match(/rework/, @phase.manager_decisions.escalate_decision.last.rationale)
    end

    test "refuses a phase that is not running" do
      @phase.update!(status: "pending")
      result = run!
      assert result.failure?
      assert_equal :not_running, result.error
    end

    test "dispatches a dependent step only after its predecessor succeeds" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase)

      run!
      builder.reload
      critic.reload
      assert_equal 1, builder.step_runs.count, "root builder is dispatched"
      assert_equal "ready", builder.latest_run.state
      assert_equal 0, critic.step_runs.count, "critic waits on the builder"

      builder.latest_run.update!(state: "succeeded", finished_at: Time.current,
        merged_at: Time.current)
      run!
      critic.reload
      assert_equal 1, critic.step_runs.count, "critic dispatched once builder succeeded"
      assert_equal "ready", critic.latest_run.state
      assert_equal 1, critic.latest_run.iteration
    end

    test "a succeeded but unmerged predecessor does not dispatch its dependent" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase)

      # Builder succeeded but its branch has not been merged yet — the critic's
      # worktree would not contain the builder's artifacts, so it must wait.
      succeed(builder, iteration: 1, merged: false)
      run!
      assert_equal 0, critic.reload.step_runs.count, "critic waits for the merge"

      builder.latest_run.update!(merged_at: Time.current)
      run!
      assert_equal 1, critic.reload.step_runs.count, "critic dispatched once merged"
    end

    test "routes critic needs_work feedback to a new builder run at iteration+1" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      findings = [ { "id" => "F1", "target_artifact" => "business_requirements",
                     "issue" => "R-4 is not atomic", "severity" => "major" } ]
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work", "findings" => findings })

      run!

      builder.reload
      assert_equal 2, builder.latest_run.iteration
      assert_equal "ready", builder.latest_run.state
      assert_equal findings, builder.latest_run.feedback, "findings routed as feedback"

      decision = @phase.manager_decisions.route_to_decision.last
      assert decision, "a route_to ManagerDecision is recorded"
      assert_equal [ "build" ], decision.route_to
      assert_equal 2, decision.iteration

      # Feedback is delivered to the worker via the context bundle's input.json.
      bundle = StepRuns::ContextBundle.build(builder.latest_run)
      assert_equal findings, bundle[:step_run][:feedback]
    end

    test "re-runs the critic once the routed builder succeeds" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work", "findings" => [] })

      run! # routes -> builder iteration 2 (ready)
      builder.reload.latest_run.update!(state: "succeeded", finished_at: Time.current,
        merged_at: Time.current)

      run! # builder@2 succeeded -> critic re-dispatched at iteration 2
      critic.reload
      assert_equal 2, critic.latest_run.iteration
      assert_equal "ready", critic.latest_run.state
    end

    test "converges then auto-advances the pipeline to the next phase" do
      @phase.update!(status: "running", gate_mode: "auto")
      workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass", "findings" => [] })

      run!

      assert_equal "converged", workflow.reload.status
      assert_equal "approved", @phase.reload.status
      assert @phase.manager_decisions.consensus_decision.exists?

      @pipeline.reload
      assert @pipeline.in_build?, "current_phase advanced plan -> build"
      assert @pipeline.running?
      assert_equal "running", phases(:onboarding_build).reload.status
    end

    test "human gate parks the pipeline at awaiting_human on consensus" do
      @phase.update!(status: "running", gate_mode: "human")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass" })

      run!

      assert_equal "consensus", @phase.reload.status
      assert @pipeline.reload.awaiting_human?
      assert @pipeline.in_plan? == false || @pipeline.in_define?, "phase not advanced on human gate"
    end

    test "not_applicable critic verdict still counts as converged" do
      @phase.update!(status: "running", gate_mode: "human")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "not_applicable" })

      run!

      assert_equal "consensus", @phase.reload.status
    end

    test "escalates to a human when max_iterations would be exceeded" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase, max_iterations: 1)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work", "findings" => [] })

      run!

      assert_equal "awaiting_human", @phase.reload.status
      assert @pipeline.reload.awaiting_human?
      assert_equal 1, builder.reload.step_runs.count, "no over-limit run is created"
      escalation = @phase.manager_decisions.escalate_decision.last
      assert escalation, "an escalate ManagerDecision is recorded"
      assert_equal 2, escalation.iteration
    end

    test "auto gate on the review phase completes the pipeline" do
      review = phases(:onboarding_review)
      review.update!(status: "running", gate_mode: "auto")
      _workflow, builder, critic = build_loop(review)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass" })

      assert_enqueued_with(job: Pipelines::FinalizeJob, args: [ @pipeline ]) do
        run!(review)
      end

      assert_equal "approved", review.reload.status
      # Completed is set by Finalize after archive/strip, not inline (finalization).
      assert_not @pipeline.reload.completed?
    end

    # --- Inter-phase rework (automated trigger) -----------------------------

    test "a routeless needs_work critic routes back to the nearest earlier builder phase, once across two ticks" do
      review = phases(:onboarding_review)
      build = phases(:onboarding_build)
      @pipeline.update!(status: "running", current_phase: "review")
      impl = add_builder(build)
      review.update!(status: "running")
      finds = [ { "id" => "F9", "issue" => "R-7 export unimplemented", "severity" => "blocker" } ]
      add_lone_critic(review, verdict: { "verdict" => "needs_work", "findings" => finds })

      run!(review)

      assert_equal 1, @pipeline.rework_events.count, "one rework routed back"
      event = @pipeline.rework_events.last
      assert_equal review, event.from_phase
      assert_equal build, event.target_phase
      assert event.automated_mode?
      assert event.raised_by_agent?

      assert_equal "running", build.reload.status, "target re-opened"
      assert_equal "pending", review.reload.status, "deciding phase reset (forward-only)"

      feedback_run = impl.step_runs.order(:iteration).last
      assert_equal "ready", feedback_run.state
      assert_equal "rework:review", feedback_run.feedback.first["from"]

      # Re-trigger guard: even if the phase is re-activated while the same critic
      # verdict still stands, the tick must not raise a duplicate rework.
      review.update!(status: "running")
      run!(review)
      assert_equal 1, @pipeline.rework_events.count, "guard prevents a duplicate rework"
    end

    test "a critic with a route_to edge routes in-phase and raises no inter-phase rework" do
      @pipeline.update!(status: "running")
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work", "findings" => [] })

      run!

      assert_equal 0, @pipeline.rework_events.count, "in-phase route, no bounce backward"
      assert_equal 2, builder.reload.latest_run.iteration
    end

    test "a routeless needs_work critic with no earlier builder phase does nothing" do
      # onboarding_plan (position 2) has no earlier phase with a builder in
      # fixtures except define — remove define's builder so there is no target.
      phases(:onboarding_define).workflows.destroy_all
      @pipeline.update!(status: "running", current_phase: "plan")
      @phase.update!(status: "running")
      add_lone_critic(@phase, verdict: { "verdict" => "needs_work", "findings" => [] })

      run!

      assert_equal 0, @pipeline.rework_events.count
    end

    test "escalation flushes the phase-column broadcast after the transaction commits" do
      @phase.update!(status: "running")
      _workflow, builder, critic = build_loop(@phase, max_iterations: 1)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work", "findings" => [] })

      # The escalate path collects the phase and broadcasts it only after
      # commit; the dashboard fan-out (Dashboard::Broadcast) renders
      # synchronously, so only the original phase-column replace is enqueued.
      assert_enqueued_jobs 1, only: Turbo::Streams::ActionBroadcastJob do
        run!
      end
      assert_equal "awaiting_human", @phase.reload.status
    end

    # F3 regression guard (see Dashboard::BroadcastTest): the consensus/
    # escalate dashboard broadcast must fire only after ManagerTick's own
    # transaction commits, never from inside it. Uses the human-gate path
    # (no Advance.call involved) to isolate ManagerTick's own transaction
    # boundary from Advance's separate one.
    test "the consensus dashboard broadcast fires only after the transaction commits" do
      @phase.update!(status: "running", gate_mode: "human")
      _workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass", "findings" => [] })
      boom = Class.new(StandardError)
      original = Dashboard::Broadcast.method(:call)

      Dashboard::Broadcast.define_singleton_method(:call) { |**| raise boom }
      begin
        assert_raises(boom) { run! }
      ensure
        Dashboard::Broadcast.define_singleton_method(:call, original)
      end

      assert_equal "consensus", @phase.reload.status
      assert @phase.manager_decisions.consensus_decision.exists?
    end
  end
end
