require "test_helper"

module Phases
  class ManagerTickTest < ActiveSupport::TestCase
    setup do
      @pipeline = pipelines(:onboarding)
      @phase = phases(:onboarding_plan) # no workflows in fixtures — clean slate
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

    def succeed(step, iteration:, verdict: nil)
      step.step_runs.create!(state: "succeeded", iteration: iteration,
        required_role: step.role, verdict: verdict, finished_at: Time.current)
    end

    def run!(phase = @phase)
      ManagerTick.call(phase: phase)
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

      builder.latest_run.update!(state: "succeeded", finished_at: Time.current)
      run!
      critic.reload
      assert_equal 1, critic.step_runs.count, "critic dispatched once builder succeeded"
      assert_equal "ready", critic.latest_run.state
      assert_equal 1, critic.latest_run.iteration
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
      builder.reload.latest_run.update!(state: "succeeded", finished_at: Time.current)

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

      run!(review)

      assert_equal "approved", review.reload.status
      assert @pipeline.reload.completed?
    end
  end
end
