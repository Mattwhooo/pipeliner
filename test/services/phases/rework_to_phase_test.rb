require "test_helper"

module Phases
  class ReworkToPhaseTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @pipeline = pipelines(:onboarding)
      @pipeline.update!(status: "running", current_phase: "review")
      @define = phases(:onboarding_define)  # position 1, has a builder (fixtures)
      @plan   = phases(:onboarding_plan)    # position 2
      @build  = phases(:onboarding_build)   # position 3
      @review = phases(:onboarding_review)  # position 4
      # A worker-executed loop under the build phase, so it can be a rework target.
      @build_workflow, @builder, @critic = build_loop(@build)
    end

    # builder --depends_on--> critic ; critic --route_to--> builder
    def build_loop(phase, status: "converged")
      workflow = phase.workflows.create!(slug: "loop-#{SecureRandom.hex(4)}",
        max_iterations: 10, status: status)
      builder = workflow.steps.create!(slug: "impl", step_type: "builder",
        role: "code", position: 1)
      critic = workflow.steps.create!(slug: "verify", step_type: "critic",
        role: "review", position: 2)
      workflow.step_edges.create!(from_step: builder, to_step: critic, kind: "depends_on")
      workflow.step_edges.create!(from_step: critic, to_step: builder, kind: "route_to")
      [ workflow, builder, critic ]
    end

    def findings
      [ { "id" => "F1", "target_artifact" => "code", "issue" => "R-7 export unimplemented",
          "severity" => "blocker" } ]
    end

    def rework!(from: @review, target: @build, mode: "automated", raised_by: "agent",
      reason: "Review found R-7 unimplemented", finds: findings)
      ReworkToPhase.call(from_phase: from, target_phase: target, findings: finds,
        reason: reason, mode: mode, raised_by: raised_by)
    end

    test "happy path: records the event, re-opens the target, and queues a feedback run" do
      @review.update!(status: "consensus")

      result = rework!

      assert result.success?
      run = result.value

      event = @pipeline.rework_events.last
      assert_equal @review, event.from_phase
      assert_equal @build, event.target_phase
      assert event.automated_mode?
      assert event.raised_by_agent?
      assert_equal findings, event.feedback

      @build.reload
      assert_equal "running", @build.status
      assert_equal 1, @build.rework_count
      assert_equal [ "running" ], @build.workflows.pluck(:status).uniq

      # The feedback run is the target's first worker-executed step.
      assert_equal @builder, run.step
      assert_equal "ready", run.state
      assert_equal 1, run.iteration
      assert_equal "code", run.required_role
      assert_equal "rework:review", run.feedback.first["from"]
      assert_equal "R-7 export unimplemented", run.feedback.first["issue"]

      decision = @review.manager_decisions.route_to_decision.last
      assert decision, "a route_to ManagerDecision is recorded on the from_phase"
      assert_equal [ "impl" ], decision.route_to

      @pipeline.reload
      assert @pipeline.in_build?, "current_phase moved to the target"
      assert @pipeline.running?
    end

    test "forward-only: from_phase and every phase between it and the target reset to pending" do
      @plan_workflow, = build_loop(@plan)
      @review_workflow, = build_loop(@review)

      result = rework!(from: @review, target: @define)
      assert result.success?

      assert_equal "running", @define.reload.status
      assert_equal "pending", @plan.reload.status,   "phase between target and from resets"
      assert_equal "pending", @build.reload.status,  "phase between target and from resets"
      assert_equal "pending", @review.reload.status, "the deciding phase itself resets"
      assert_equal [ "pending" ], @plan.workflows.pluck(:status).uniq
      assert_equal [ "pending" ], @review.workflows.pluck(:status).uniq
    end

    test "rejects a target that is not earlier than the from_phase" do
      result = rework!(from: @build, target: @review)
      assert result.failure?
      assert_equal :invalid_target, result.error
      assert_equal 0, @pipeline.rework_events.count
    end

    test "rejects rework on a closed pipeline" do
      @pipeline.update!(status: "completed")
      result = rework!
      assert result.failure?
      assert_equal :pipeline_closed, result.error
      assert_equal 0, @pipeline.rework_events.count
    end

    test "cap: escalates the from_phase and pipeline to awaiting_human, records no event" do
      @build.update!(rework_count: ReworkToPhase::MAX_REWORKS)
      @review.update!(status: "consensus")

      result = rework!
      assert result.failure?
      assert_equal :rework_cap, result.error

      assert_equal "awaiting_human", @review.reload.status
      assert @pipeline.reload.awaiting_human?
      assert_equal 0, @pipeline.rework_events.count, "no new bounce past the cap"
      escalation = @review.manager_decisions.escalate_decision.last
      assert escalation, "an escalate ManagerDecision is recorded"
    end

    test "broadcasts fire after commit on success and nothing is enqueued on a validation failure" do
      @review.update!(status: "consensus")

      # One card (the feedback run) + one column per changed phase (build + review).
      assert_enqueued_jobs 3, only: Turbo::Streams::ActionBroadcastJob do
        assert rework!.success?
      end

      # A pre-transaction failure commits nothing, so it broadcasts nothing.
      assert_no_enqueued_jobs only: Turbo::Streams::ActionBroadcastJob do
        assert rework!(from: @build, target: @review).failure?
      end
    end
  end
end
