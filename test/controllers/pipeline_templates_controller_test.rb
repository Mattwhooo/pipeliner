require "test_helper"

class PipelineTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:dev)
    @project = projects(:pipeliner)
    @template = @project.create_pipeline_template!(allow_manager_additions: true)
    @implementer = StepTemplate.create!(name: "Implementer", step_type: "builder",
      role: "code", phase: "build")
    @critic = StepTemplate.create!(name: "Test Critic", step_type: "critic",
      role: "code", phase: "build")
    @entry = @template.pipeline_template_steps.create!(step_template: @implementer,
      phase: "build", position: 1)
  end

  test "show renders phase sections with pinned entries and the toggle" do
    get project_pipeline_template_url(@project)
    assert_response :success
    assert_select "h2", /Build/
    assert_select "li", /Implementer/
    assert_select "input[type=checkbox][name=?]", "pipeline_template[allow_manager_additions]"
    assert_select "option", text: "Test Critic" # available, not yet pinned
    assert_select "option", text: "Implementer", count: 0 # already pinned
  end

  test "update toggles manager additions" do
    patch project_pipeline_template_url(@project),
      params: { pipeline_template: { allow_manager_additions: "0" } }
    assert_redirected_to project_pipeline_template_url(@project)
    assert_not @template.reload.allow_manager_additions
  end

  test "pinning a step appends it to the phase" do
    post project_pipeline_template_steps_url(@project), params: {
      pipeline_template_step: { step_template_id: @critic.id, phase: "build" }
    }
    assert_redirected_to project_pipeline_template_url(@project)
    entry = @template.pipeline_template_steps.find_by!(step_template: @critic)
    assert_equal 2, entry.position
  end

  test "duplicate pin is rejected with an alert" do
    post project_pipeline_template_steps_url(@project), params: {
      pipeline_template_step: { step_template_id: @implementer.id, phase: "build" }
    }
    assert_equal 1, @template.pipeline_template_steps.where(phase: "build").count
    assert_match(/Could not pin/, flash[:alert])
  end

  test "unpinning removes the entry" do
    delete project_pipeline_template_step_url(@project, @entry)
    assert_not PipelineTemplateStep.exists?(@entry.id)
  end

  test "move swaps positions within the phase" do
    second = @template.pipeline_template_steps.create!(step_template: @critic,
      phase: "build", position: 2)
    post move_project_pipeline_template_step_url(@project, second, direction: "up")
    assert_equal 1, second.reload.position
    assert_equal 2, @entry.reload.position
  end

  test "scoped to the user's projects" do
    other = Project.create!(name: "NotMine", repo_url: "https://github.com/example/notmine")
    other.create_pipeline_template!
    get project_pipeline_template_url(other)
    assert_response :not_found
  end
end
