require "test_helper"

module Phases
  class SendBackTest < ActiveSupport::TestCase
    setup do
      @pipeline = pipelines(:onboarding)
      @define = phases(:onboarding_define)
      @requirements = steps(:requirements_writer) # position 1, builder
      @critic = steps(:completeness_critic)        # position 2, critic
    end

    test "sends a consensus phase back to its first worker step by default" do
      @define.update!(status: "consensus")
      @pipeline.update!(status: "awaiting_human")

      result = SendBack.call(phase: @define, user: users(:dev),
        feedback: "Requirement R-4 is not atomic.")

      assert result.success?
      run = result.value
      assert_equal @requirements, run.step
      assert_equal "ready", run.state
      assert_equal 2, run.iteration # requirements_ready fixture is iteration 1
      assert_equal [ { "from" => "human-gate", "issue" => "Requirement R-4 is not atomic.",
                       "severity" => "major" } ], run.feedback

      assert_equal "running", @define.reload.status
      assert_equal "running", @pipeline.reload.status

      approval = @define.approvals.sole
      assert approval.send_back_decision?
      assert_equal @define, approval.target_phase
      assert_equal "Requirement R-4 is not atomic.", approval.note
    end

    test "routes to an explicit target step when given" do
      @define.update!(status: "consensus")

      result = SendBack.call(phase: @define, user: users(:dev),
        feedback: "Redo the critique.", target_step_id: @critic.id)

      assert result.success?
      assert_equal @critic, result.value.step
    end

    test "works from an escalated awaiting_human phase" do
      @define.update!(status: "awaiting_human")
      result = SendBack.call(phase: @define, user: users(:dev), feedback: "Needs more.")
      assert result.success?
    end

    test "requires feedback" do
      @define.update!(status: "consensus")
      result = SendBack.call(phase: @define, user: users(:dev), feedback: " ")
      assert result.failure?
      assert_equal :blank_feedback, result.error
      assert_equal "consensus", @define.reload.status
    end

    test "refuses phases that are not at a gate" do
      @define.update!(status: "running")
      result = SendBack.call(phase: @define, user: users(:dev), feedback: "x")
      assert result.failure?
      assert_equal :not_sendable, result.error
    end

    test "fails when the target step is not a worker step of this phase" do
      @define.update!(status: "consensus")
      other = Pipelines::Create.call(project: projects(:pipeliner), title: "Other").value
      foreign_workflow = other.phases.first.workflows.create!(slug: "main")
      foreign_step = foreign_workflow.steps.create!(slug: "x", step_type: "builder",
        role: "code", position: 1)

      result = SendBack.call(phase: @define, user: users(:dev),
        feedback: "x", target_step_id: foreign_step.id)

      assert result.failure?
      assert_equal :no_target, result.error
    end
  end
end
