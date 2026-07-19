require "application_system_test_case"

class ThemeToggleTest < ApplicationSystemTestCase
  test "toggling the theme applies immediately and persists across visits" do
    sign_in_via_ui

    assert_not dark_mode?

    toggle_theme
    assert dark_mode?
    assert_equal "true", theme_button["aria-pressed"]

    visit root_path
    assert dark_mode?, "manual theme choice should persist via the cookie across page loads"
    assert_equal "true", theme_button["aria-pressed"]

    toggle_theme
    assert_not dark_mode?
  end

  test "the toggle lives in the sidebar footer next to Sign out, not the header" do
    sign_in_via_ui

    within(".border-t.border-default") do
      assert_selector "button[aria-label='Toggle dark mode']"
      assert_button "Sign out"
    end
    assert_no_selector ".h-14 button[aria-label='Toggle dark mode']"
  end

  test "the toggle is keyboard reachable and responds to the keyboard" do
    sign_in_via_ui
    assert_not dark_mode?

    theme_button.send_keys(:return)

    assert dark_mode?
    assert_equal "true", theme_button["aria-pressed"]
  end

  private

  def sign_in_via_ui
    visit new_user_session_path
    fill_in "Email", with: users(:dev).email
    fill_in "Password", with: "password123"
    click_button "Sign in"
    assert_selector "h1", text: "Dashboard"
  end

  def theme_button
    find("button[aria-label='Toggle dark mode']")
  end

  def toggle_theme
    theme_button.click
  end

  def dark_mode?
    page.evaluate_script("document.documentElement.classList.contains('dark')")
  end
end
