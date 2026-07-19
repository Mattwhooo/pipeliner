require "application_system_test_case"

class DashboardTest < ApplicationSystemTestCase
  setup do
    @pipeline = pipelines(:onboarding)
    @pipeline.update!(status: "running")
    sign_in_as(users(:dev))
  end

  test "shows active pipelines, recent activity, and fleet health populated from fixtures" do
    visit root_path

    assert_selector "h1", text: "Dashboard"
    within "#dashboard-summary" do
      assert_text(/active pipelines/i)
      assert_text(/workers online/i)
    end
    assert_text @pipeline.title
    # The fleet panel is a turbo-frame with a src, so it reloads its inline
    # content shortly after first paint — wait for that fetch to land.
    assert_text workers(:claude_local).name, wait: 5
  end

  test "a phase approval reflects on the open dashboard tab without a manual reload" do
    define = phases(:onboarding_define)
    define.update!(status: "consensus")

    visit root_path
    assert_text @pipeline.title
    assert_selector "##{ActionView::RecordIdentifier.dom_id(@pipeline, :dashboard_row)}"

    Phases::Approve.call(phase: define, user: users(:dev))

    # No manual reload — the row's phase indicator updates via the per-user
    # dashboard stream once Define is approved and Plan starts running.
    assert_text "Plan", wait: 5
  end

  private

  def sign_in_as(user)
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: "password123"
    click_on "Sign in"
    assert_selector "h1", text: "Dashboard", wait: 5
  end
end
