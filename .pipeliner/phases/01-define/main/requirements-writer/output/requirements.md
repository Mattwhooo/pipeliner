# Business Requirements — Dark Mode Support

## The ask

Add a dark mode to the app. It should have a toggle that lets the user switch
back and forth, and it should default to the user's system settings.

## Requirements

Each requirement is atomic and written in plain, non-technical language.

### Default behavior

- **R1.** When a user opens the app for the first time and has never chosen a
  color theme, the app should display in the theme that matches their device's
  current system setting (dark if the device is set to dark, light if the device
  is set to light).

- **R2.** When the user's device is set to a system theme the app cannot
  determine, the app should display in light theme.

### Switching themes with the toggle

- **R3.** When a user is anywhere in the app, they should be able to find a
  visible control (toggle) that lets them switch the color theme.

- **R4.** When the user activates the toggle while the app is showing the light
  theme, the app should switch to the dark theme.

- **R5.** When the user activates the toggle while the app is showing the dark
  theme, the app should switch to the light theme.

- **R6.** When the user switches the theme with the toggle, the change should be
  applied immediately across the app without the user having to reload or
  restart.

- **R7.** When the theme changes, the toggle should visibly reflect which theme
  is currently active so the user can tell the app's current state at a glance.

### Remembering the user's choice

- **R8.** When the user has manually chosen a theme with the toggle, the app
  should remember that choice and continue to use it the next time the user
  returns to the app, instead of reverting to the system setting.

- **R9.** When the user has manually chosen a theme, that choice should take
  precedence over the device's system setting until the user changes it again.

### Reacting to system changes

- **R10.** When the user has never made a manual theme choice and their device's
  system setting changes (for example, the device switches to dark mode in the
  evening), the app should update to match the new system setting.

- **R11.** When the user has already made a manual theme choice and their
  device's system setting later changes, the app should keep the user's chosen
  theme and should not override it with the system setting.

### Consistency and readability

- **R12.** When the app is showing the dark theme, all parts of the app the user
  can see (text, backgrounds, buttons, icons, and status indicators) should
  appear in their dark-theme styling so that everything remains readable and no
  area is left in the light theme.

- **R13.** When the app is showing either theme, information that is conveyed by
  color (such as status) should remain distinguishable, so that meaning is never
  lost because of the chosen theme.
