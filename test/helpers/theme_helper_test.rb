require "test_helper"

class ThemeHelperTest < ActionView::TestCase
  test "dark_theme? is true when the theme cookie is dark" do
    cookies[:theme] = "dark"
    assert dark_theme?
  end

  test "dark_theme? is false when the theme cookie is light" do
    cookies[:theme] = "light"
    assert_not dark_theme?
  end

  test "dark_theme? is false when no theme cookie is present" do
    assert_not dark_theme?
  end
end
