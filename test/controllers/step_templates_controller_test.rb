require "test_helper"

class StepTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "index lists templates" do
    StepTemplate.create!(name: "Implementer", step_type: "builder", role: "code")
    get step_templates_url
    assert_response :success
    assert_select "td", /Implementer/
  end

  test "create with JSON defaults" do
    post step_templates_url, params: { step_template: {
      name: "Design Writer", step_type: "builder", role: "code",
      requirement: "required", system_prompt: "Write the design.",
      default_outputs_json: '[{"artifact":"technical_design","path":"output/design.md"}]',
      default_inputs_json: ""
    } }
    assert_redirected_to step_templates_url
    template = StepTemplate.find_by!(name: "Design Writer")
    assert_equal "technical_design", template.default_outputs.first["artifact"]
    assert_equal [], template.default_inputs
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
