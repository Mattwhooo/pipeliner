require "test_helper"

class WorkersControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in users(:dev) }

  test "index lists registered workers with roles and status" do
    get workers_url
    assert_response :success
    assert_select "td", /wk_claude_local/
    assert_select "span", "requirements"
  end

  test "pipelines index lists pipelines across the user's projects" do
    get pipelines_url
    assert_response :success
    assert_select "td a", text: pipelines(:onboarding).title
  end
end
