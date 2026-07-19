require "test_helper"

module Phases
  class ApproveTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    setup do
      @pipeline = pipelines(:onboarding)
      @define = phases(:onboarding_define)
    end

    test "approves a consensus phase and starts the next one" do
      @define.update!(status: "consensus")
      @pipeline.update!(status: "awaiting_human")

      result = Approve.call(phase: @define, user: users(:dev), note: "LGTM")

      assert result.success?
      assert_equal "approved", @define.reload.status
      assert_equal "running", phases(:onboarding_plan).reload.status
      @pipeline.reload
      assert_equal "plan", @pipeline.current_phase
      assert_equal "running", @pipeline.status
      approval = @define.approvals.sole
      assert_equal users(:dev), approval.user
      assert_equal "LGTM", approval.note
    end

    test "approving an escalated awaiting_human phase works (approve anyway)" do
      @define.update!(status: "awaiting_human")
      result = Approve.call(phase: @define, user: users(:dev))
      assert result.success?
      assert_equal "approved", @define.reload.status
    end

    test "approving review enqueues finalization (completed comes after archive/strip)" do
      review = phases(:onboarding_review)
      review.update!(status: "consensus")
      result = nil
      assert_enqueued_with(job: Pipelines::FinalizeJob, args: [ @pipeline ]) do
        result = Approve.call(phase: review, user: users(:dev))
      end
      assert result.success?
      assert_equal "approved", review.reload.status
      assert_not @pipeline.reload.completed?
    end

    test "refuses phases that are not at a gate" do
      @define.update!(status: "running")
      result = Approve.call(phase: @define, user: users(:dev))
      assert result.failure?
      assert_equal :not_approvable, result.error
    end

    test "approves a paused phase once every workflow has converged" do
      workflow = workflows(:define_main)
      requirements = steps(:requirements_writer)
      critic = steps(:completeness_critic)
      requirements.step_runs.destroy_all
      requirements.step_runs.create!(state: "succeeded", iteration: 1, required_role: "requirements",
        finished_at: Time.current, merged_at: Time.current)
      critic.step_runs.create!(state: "succeeded", iteration: 1, required_role: "review",
        verdict: { "verdict" => "pass" }, finished_at: Time.current, merged_at: Time.current)
      workflow.update!(status: "converged")
      @define.update!(status: "paused")

      result = Approve.call(phase: @define, user: users(:dev))

      assert result.success?
      assert_equal "approved", @define.reload.status
    end

    test "refuses Done on a paused phase that hasn't settled" do
      # requirements_ready fixture is still "ready" — the loop hasn't converged.
      @define.update!(status: "paused")

      result = Approve.call(phase: @define, user: users(:dev))

      assert result.failure?
      assert_equal :not_settled, result.error
      assert_equal "paused", @define.reload.status
    end

    test "approving with context seeds the next phase's entry steps with feedback" do
      plan = phases(:onboarding_plan)
      workflow = plan.workflows.create!(slug: "main", status: "pending")
      entry = workflow.steps.create!(slug: "explore", step_type: "builder",
        role: "code", position: 1)
      # A downstream step (depends on the entry step) must NOT be seeded.
      downstream = workflow.steps.create!(slug: "assemble", step_type: "builder",
        role: "code", position: 2)
      workflow.step_edges.create!(from_step: entry, to_step: downstream, kind: "depends_on")

      @define.update!(status: "consensus")
      result = Approve.call(phase: @define, user: users(:dev),
        context: "Ship it on Postgres, not MySQL.")

      assert result.success?
      run = entry.step_runs.sole
      assert_equal "ready", run.state
      assert_equal 1, run.iteration
      assert_equal [ { "from" => "human-gate", "issue" => "Ship it on Postgres, not MySQL.",
                       "severity" => "major" } ], run.feedback
      assert_empty downstream.step_runs
    end

    test "approving with context skips an entry step that already has an active run" do
      plan = phases(:onboarding_plan)
      workflow = plan.workflows.create!(slug: "main", status: "pending")
      entry = workflow.steps.create!(slug: "explore", step_type: "builder",
        role: "code", position: 1)
      existing = entry.step_runs.create!(state: "ready", iteration: 1, required_role: "code")

      @define.update!(status: "consensus")
      result = Approve.call(phase: @define, user: users(:dev), context: "some context")

      assert result.success?
      assert_equal [ existing ], entry.step_runs.to_a
      assert_empty existing.reload.feedback
    end

    test "approving without context does not seed the next phase" do
      plan = phases(:onboarding_plan)
      workflow = plan.workflows.create!(slug: "main", status: "pending")
      entry = workflow.steps.create!(slug: "explore", step_type: "builder",
        role: "code", position: 1)

      @define.update!(status: "consensus")
      Approve.call(phase: @define, user: users(:dev))

      assert_empty entry.step_runs
    end
  end
end
