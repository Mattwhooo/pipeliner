require "test_helper"

class StepsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "new renders the add-step form" do
    get new_phase_step_url(phases(:onboarding_plan))
    assert_response :success
    assert_select "h1", /Add step to Plan/
  end

  test "create adds a step from a template" do
    template = StepTemplate.create!(name: "Design Writer", step_type: "builder",
      role: "code", system_prompt: "Write the design.")

    post phase_steps_url(phases(:onboarding_plan)), params: { step: {
      step_template_id: template.id, slug: "", step_type: "", role: "", system_prompt: ""
    } }

    assert_redirected_to pipeline_url(pipelines(:onboarding))
    step = phases(:onboarding_plan).workflows.first.steps.sole
    assert_equal "design-writer", step.slug
    assert_equal "code", step.role
  end

  test "queue_run queues and redirects" do
    step_runs(:requirements_ready).update!(state: "succeeded")
    post queue_run_step_url(steps(:requirements_writer))
    assert_redirected_to pipeline_url(pipelines(:onboarding))
    assert_equal 2, steps(:requirements_writer).step_runs.where(state: "ready").sole.iteration
  end

  test "cannot add steps to phases of other users' pipelines" do
    other_project = Project.create!(name: "Other", repo_url: "https://github.com/example/other2")
    other_pipeline = Pipelines::Create.call(project: other_project, title: "X").value
    get new_phase_step_url(other_pipeline.phases.first)
    assert_response :not_found
  end
end
