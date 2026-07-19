require "test_helper"

class ThemeHelperTest < ActionView::TestCase
  test "dark_theme? is true when the theme cookie is dark" do
    stub_cookie("dark")
    assert dark_theme?
  end

  test "dark_theme? is false when the theme cookie is light" do
    stub_cookie("light")
    assert_not dark_theme?
  end

  test "dark_theme? is false when the theme cookie is absent" do
    stub_cookie(nil)
    assert_not dark_theme?
  end

  private

  def stub_cookie(value)
    define_singleton_method(:cookies) { { theme: value } }
  end
end
