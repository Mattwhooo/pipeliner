require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  setup do
    # Pin prefers-color-scheme so tests are deterministic regardless of the
    # host/CI machine's OS appearance setting (dark mode defaults to it).
    page.driver.browser.execute_cdp(
      "Emulation.setEmulatedMedia",
      features: [ { name: "prefers-color-scheme", value: "light" } ]
    )
  end
end
