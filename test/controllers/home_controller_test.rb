require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "unauthenticated visitor is redirected to sign in" do
    get root_url
    assert_redirected_to new_user_session_url
  end

  test "signed-in user sees the dashboard" do
    sign_in users(:dev)
    get root_url
    assert_response :success
    assert_select "h1", "Dashboard"
  end

  test "sign-in page renders" do
    get new_user_session_url
    assert_response :success
    assert_select "h2", "Sign in"
  end

  test "shows the no-projects empty state when the user has no memberships" do
    solo = User.create!(email: "solo@example.com", password: "password123")
    sign_in solo
    get root_url
    assert_response :success
    assert_match "No projects yet", @response.body
  end

  test "shows zero counts rather than hiding them when there is no activity" do
    pipelines(:onboarding).update!(status: "draft")
    Worker.destroy_all
    sign_in users(:dev)
    get root_url
    assert_response :success
    assert_match "No active pipelines", @response.body
    assert_match "No workers connected", @response.body
    assert_match "No recent activity", @response.body
  end

  test "each panel renders its own empty state independently, and a query failure does not 500 the page" do
    sign_in users(:dev)
    original = Dashboard::ActivePipelines.method(:new)
    Dashboard::ActivePipelines.define_singleton_method(:new) { |*| raise "boom" }
    begin
      get root_url
    ensure
      Dashboard::ActivePipelines.define_singleton_method(:new, original)
    end

    assert_response :success
    assert_match "Active pipelines couldn't load", @response.body
    # The other panels still rendered.
    assert_select "h2", text: "Worker fleet"
    assert_select "h2", text: "Recent activity"
  end

  test "fleet_health renders the pollable partial independently" do
    sign_in users(:dev)
    get dashboard_fleet_health_url
    assert_response :success
    assert_select "turbo-frame#fleet-health-frame"
  end
end
