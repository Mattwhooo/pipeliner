require "test_helper"

class PipelineTemplateTest < ActiveSupport::TestCase
  setup do
    @template = projects(:pipeliner).create_pipeline_template!(allow_manager_additions: false)
    @step_template = StepTemplate.create!(name: "Implementer T", step_type: "builder",
      role: "code", phase: "build")
  end

  test "one template per project" do
    dup = PipelineTemplate.new(project: projects(:pipeliner))
    assert_not dup.valid?
  end

  test "entries are unique per (step_template, phase) and ordered" do
    @template.pipeline_template_steps.create!(step_template: @step_template,
      phase: "build", position: 2)
    dup = @template.pipeline_template_steps.new(step_template: @step_template,
      phase: "build", position: 3)
    assert_not dup.valid?

    other = StepTemplate.create!(name: "Test Critic T", step_type: "critic",
      role: "code", phase: "build")
    @template.pipeline_template_steps.create!(step_template: other, phase: "build", position: 1)
    assert_equal [ "Test Critic T", "Implementer T" ],
      @template.entries_for("build").map { |e| e.step_template.name }
  end

  test "phase must be a known kind" do
    entry = @template.pipeline_template_steps.new(step_template: @step_template,
      phase: "shipping", position: 1)
    assert_not entry.valid?
  end
end
