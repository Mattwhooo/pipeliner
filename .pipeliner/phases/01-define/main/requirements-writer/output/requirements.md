# Business requirements — Move dark mode toggle to top right corner

## Context

The dark mode toggle currently sits in the top header row of the app
sidebar. The requester has clarified that "top right corner" means moving
the toggle down into the sidebar's footer area, next to the "Sign out"
control, rather than introducing a new top bar. The sign-in screen is not
affected.

## Requirements

**R1.** When a signed-in person views any page in the app, the dark mode
toggle should no longer appear in the top row of the sidebar.

**R2.** When a signed-in person views any page in the app, the dark mode
toggle should appear in the sidebar's bottom area, next to the "Sign out"
control, rather than at the top of the sidebar.

**R3.** When a signed-in person looks at the sidebar's bottom area, the
dark mode toggle and the "Sign out" control should appear together as a
clearly related pair, so it's obvious both controls belong to the same
footer section.

**R4.** When a person clicks or taps the dark mode toggle in its new
location, it should switch the app between light and dark mode exactly as
it does today — only its position is changing, not its behavior.

**R5.** When a person uses the keyboard to navigate the sidebar, the dark
mode toggle should remain reachable by keyboard and show a visible focus
indicator in its new location, the same as it does today.

**R6.** When a person visits the sign-in screen, the dark mode toggle
should stay exactly where it is today. This change does not affect the
sign-in screen.

**R7.** When the dark mode toggle is moved, no other sidebar element
(navigation links, the "Sign out" control, the user's displayed email)
should change position or behavior as a result.
