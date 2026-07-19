module ThemeHelper
  def dark_theme?
    cookies[:theme] == "dark"
  end
end
