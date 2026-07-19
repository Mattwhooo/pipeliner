require "application_system_test_case"

class DarkModeTest < ApplicationSystemTestCase
  setup do
    sign_in users(:dev)
    emulate_system_theme("light")
  end

  test "toggling switches the theme immediately, without a reload" do
    visit root_path
    assert_no_css "html.dark"

    find("[aria-label='Toggle dark mode']").click

    assert_css "html.dark"
    assert_equal "true", find("[aria-label='Toggle dark mode']")["aria-pressed"]
  end

  test "a manual choice is remembered on the next visit, overriding the system setting" do
    visit root_path
    find("[aria-label='Toggle dark mode']").click
    assert_css "html.dark"

    emulate_system_theme("light") # system stays light; the manual dark choice must still win
    visit root_path
    assert_css "html.dark"

    find("[aria-label='Toggle dark mode']").click
    assert_no_css "html.dark"
    visit root_path
    assert_no_css "html.dark"
  end

  test "a fresh session with no manual choice follows the system setting" do
    emulate_system_theme("dark")
    visit root_path
    assert_css "html.dark"
    assert_equal "true", find("[aria-label='Toggle dark mode']")["aria-pressed"]
  end

  private

  def emulate_system_theme(scheme)
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-color-scheme", value: scheme } ]
    )
  end
end
