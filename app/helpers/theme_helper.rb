module ThemeHelper
  # Best-effort server-side read of the theme cookie, used only to render the
  # correct <html class="dark"> on the first response. The inline init script
  # (shared/_theme_init_script) is the actual correctness guarantee — it also
  # covers the case where no cookie exists yet and the theme must follow the
  # device's system setting.
  def dark_theme?
    cookies[:theme] == "dark"
  end
end
