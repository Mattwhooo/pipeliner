require "test_helper"

module Phases
  class ConvergenceTest < ActiveSupport::TestCase
    setup do
      @phase = phases(:onboarding_plan) # no workflows in fixtures — clean slate
    end

    def build_loop(phase)
      workflow = phase.workflows.create!(slug: "loop-#{SecureRandom.hex(4)}", max_iterations: 10)
      builder = workflow.steps.create!(slug: "build", step_type: "builder",
        role: "requirements", position: 1)
      critic = workflow.steps.create!(slug: "check", step_type: "critic",
        role: "review", position: 2)
      workflow.step_edges.create!(from_step: builder, to_step: critic, kind: "depends_on")
      [ workflow, builder, critic ]
    end

    def succeed(step, iteration:, verdict: nil, merged: true)
      step.step_runs.create!(state: "succeeded", iteration: iteration,
        required_role: step.role, verdict: verdict, finished_at: Time.current,
        merged_at: merged ? Time.current : nil)
    end

    test "phase_settled? is false with no workflows" do
      assert_not Convergence.phase_settled?(@phase)
    end

    test "workflow_converged? is false until every worker step has succeeded and merged" do
      workflow, builder, critic = build_loop(@phase)
      assert_not Convergence.workflow_converged?(workflow)

      succeed(builder, iteration: 1)
      assert_not Convergence.workflow_converged?(workflow), "critic hasn't run yet"

      succeed(critic, iteration: 1, verdict: { "verdict" => "pass" })
      assert Convergence.workflow_converged?(workflow)
    end

    test "workflow_converged? is false when a run succeeded but is unmerged" do
      workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1, merged: false)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass" }, merged: false)

      assert_not Convergence.workflow_converged?(workflow)
    end

    test "workflow_converged? treats not_applicable as resolved" do
      workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "not_applicable" })

      assert Convergence.workflow_converged?(workflow)
    end

    test "workflow_converged? is false while a critic still needs_work" do
      workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "needs_work" })

      assert_not Convergence.workflow_converged?(workflow)
    end

    test "phase_settled? requires every workflow on the phase to be converged" do
      workflow, builder, critic = build_loop(@phase)
      succeed(builder, iteration: 1)
      succeed(critic, iteration: 1, verdict: { "verdict" => "pass" })
      assert Convergence.phase_settled?(@phase)

      _second_workflow, other_builder, other_critic = build_loop(@phase)
      assert_not Convergence.phase_settled?(@phase), "second workflow hasn't converged"

      succeed(other_builder, iteration: 1)
      succeed(other_critic, iteration: 1, verdict: { "verdict" => "pass" })
      assert Convergence.phase_settled?(@phase)
    end
  end
end
