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
end
