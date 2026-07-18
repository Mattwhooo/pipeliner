require "test_helper"

module Steps
  class AddToWorkflowTest < ActiveSupport::TestCase
    setup { @phase = phases(:onboarding_plan) }

    test "creates the default workflow when the phase has none" do
      result = AddToWorkflow.call(phase: @phase,
        attributes: { slug: "design", step_type: "builder", role: "code" })

      assert result.success?
      assert_equal "main", result.value.workflow.slug
      assert_equal @phase, result.value.workflow.phase
      assert_equal 1, result.value.position
    end

    test "fills blanks from the template and records provenance" do
      template = StepTemplate.create!(name: "Design Writer", step_type: "builder",
        role: "code", system_prompt: "Write the design.",
        default_outputs: [ { "artifact" => "technical_design" } ])

      result = AddToWorkflow.call(phase: @phase, attributes: { slug: "" }, template: template)

      assert result.success?
      step = result.value
      assert_equal "design-writer", step.slug
      assert_equal "builder", step.step_type
      assert_equal "Write the design.", step.system_prompt
      assert_equal [ { "artifact" => "technical_design" } ], step.outputs
      assert_equal template, step.step_template
    end

    test "wires depends_on from the previously-last step and route_to for critics" do
      first = AddToWorkflow.call(phase: @phase,
        attributes: { slug: "design", step_type: "builder", role: "code" }).value
      result = AddToWorkflow.call(phase: @phase,
        attributes: { slug: "coverage", step_type: "critic", role: "review" },
        route_to_step_id: first.id)

      critic = result.value
      workflow = critic.workflow
      assert workflow.step_edges.exists?(from_step: first, to_step: critic, kind: "depends_on")
      assert workflow.step_edges.exists?(from_step: critic, to_step: first, kind: "route_to")
    end

    test "fails with :invalid on bad attributes" do
      result = AddToWorkflow.call(phase: @phase, attributes: { slug: "x", step_type: "builder" })
      assert result.failure?
      assert result.record.errors[:role].any?
    end
  end
end
