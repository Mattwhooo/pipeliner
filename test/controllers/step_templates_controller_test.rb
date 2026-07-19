require "test_helper"

class StepTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "index lists templates" do
    StepTemplate.create!(name: "Implementer", step_type: "builder", role: "code")
    get step_templates_url
    assert_response :success
    assert_select "td", /Implementer/
  end

  test "create sets the editable fields; artifact contract is not form-editable" do
    post step_templates_url, params: { step_template: {
      name: "Design Writer", step_type: "builder", role: "code",
      requirement: "required", system_prompt: "Write the design.",
      default_outputs: [ { "artifact" => "hacked" } ]
    } }
    assert_redirected_to step_templates_url
    template = StepTemplate.find_by!(name: "Design Writer")
    assert_equal [], template.default_outputs, "artifact contract must not be settable from the form"
  end

  test "create sets the phase and project scope" do
    post step_templates_url, params: { step_template: {
      name: "Define Extra", step_type: "builder", role: "code",
      requirement: "conditional", phase: "define", project_id: projects(:pipeliner).id
    } }
    assert_redirected_to step_templates_url
    template = StepTemplate.find_by!(name: "Define Extra")
    assert_equal "define", template.phase
    assert_equal projects(:pipeliner), template.project
  end

  test "index groups templates under phase headings and shows scope" do
    StepTemplate.create!(name: "Global Planner", step_type: "planner", role: "plan", phase: "plan")
    StepTemplate.create!(name: "Scoped Builder", step_type: "builder", role: "code",
      phase: "build", project: projects(:pipeliner))

    get step_templates_url

    assert_response :success
    assert_select "h2", /Plan/
    assert_select "h2", /Build/
    assert_select "td", /Global/
    assert_select "td", /Pipeliner/
  end

  test "invalid create re-renders" do
    post step_templates_url, params: { step_template: { name: "", step_type: "builder" } }
    assert_response :unprocessable_entity
  end

  test "update and destroy" do
    template = StepTemplate.create!(name: "Temp", step_type: "critic", role: "review")
    patch step_template_url(template), params: { step_template: { name: "Renamed" } }
    assert_redirected_to step_templates_url
    assert_equal "Renamed", template.reload.name

    delete step_template_url(template)
    assert_not StepTemplate.exists?(template.id)
  end
end
