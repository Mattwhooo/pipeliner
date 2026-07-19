# Open questions — Move dark mode toggle

No open questions — the task is fully defined.

The requester's answers in the previous round resolved every material
ambiguity:

- **Placement:** Move the dark mode toggle to sit **near the "Sign out"
  button** — the sidebar footer block in `app/views/shared/_sidebar.html.erb`
  that currently shows the user's email + "Sign out". It leaves its current
  spot in the sidebar's top header row.
- **No top bar:** Do **not** introduce any viewport-spanning or content-area
  top bar. This is a move within the existing sidebar, not a new layout region.
- **Auth/sign-in screen:** Leave it **unchanged** — the toggle on
  `app/views/layouts/auth.html.erb` keeps its current position.

Sensible defaults cover anything trivial that remains (e.g. the exact
adjacency / right-alignment of the toggle relative to the "Sign out" control
within the footer, and reusing the existing `shared/_theme_toggle` partial as
the single source of truth) — these belong to Plan/Build, not the requester.
