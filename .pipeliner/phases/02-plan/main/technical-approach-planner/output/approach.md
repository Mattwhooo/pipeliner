# Technical approach: move dark mode toggle to top-right corner

## Current state

The dark mode toggle is `shared/theme_toggle` (`app/views/shared/_theme_toggle.html.erb`),
an icon-only button wired to `theme_controller.js` (toggles `.dark` on `<html>`,
persists a `theme` cookie) plus `theme_helper.rb#dark_theme?` for the initial
server-rendered state. It is rendered in exactly two places:

- `shared/_sidebar.html.erb` — inside the sidebar's `h-14` header row, next to
  the "Pipeliner" logo. Since the sidebar is fixed to the **left** of the
  screen, the toggle currently sits in the top-**left** area of the app.
- `layouts/auth.html.erb` — inline next to the centered "Pipeliner" wordmark
  above the login card.

No other view references the partial, and the toggle's internal markup/behavior
doesn't need to change — this is a layout/positioning change, not a component
change.

## Constraint from the UI guide

`guides/ui-style-guide.md` reserves the page content's top-right for the
**per-page primary action** ("page header (title, primary action, status) →
content... One primary action per page, top-right."). Every list/show view
(`projects/index`, `pipelines/index`, etc.) already renders its own
`flex items-center justify-between` header with a primary action button
top-right, in-flow inside `main`'s `max-w-7xl px-6 py-8` wrapper.

This rules out two tempting options:
- **Per-view placement** (adding the toggle into each page's own header) — would
  require touching every view, collide with the existing primary-action slot,
  and violate "one primary action per page."
- **`fixed top-4 right-4` floating button** over the viewport — visually
  competes with per-page primary-action buttons at typical viewport widths
  (sidebar width + `max-w-7xl` content often puts the content's right edge near
  the viewport's right edge), and would render inconsistently across pages that
  scroll independently in `main`.

## Chosen approach

Introduce a slim, persistent **app-level top bar** rendered once per layout,
outside the scrollable content area, with the toggle right-aligned inside it —
architecturally the same idea as the sidebar's own `h-14` header row, just for
the right-hand region. This keeps the toggle in a single, layout-owned spot
(not duplicated per view), keeps it clear of every page's primary-action
button, and matches the literal ask: top-right corner of the screen.

1. **New shared partial** `app/views/shared/_topbar.html.erb`:
   ```erb
   <div class="flex h-14 shrink-0 items-center justify-end border-b border-default px-4">
     <%= render "shared/theme_toggle" %>
   </div>
   ```
   One source of truth for "the bar that holds the toggle," reused by both
   layouts instead of duplicating the height/border/alignment classes twice.

2. **`app/views/layouts/application.html.erb`**: remove the
   `render "shared/theme_toggle"` call from the sidebar row; add
   `render "shared/topbar"` as a sibling of `<main>`'s content, above the
   `shared/flash` / content wrapper, so it spans the full width to the right of
   the sidebar and sits above the scrollable region:
   ```erb
   <main class="flex-1 overflow-y-auto">
     <%= render "shared/topbar" %>
     <%= render "shared/flash" %>
     <div class="mx-auto max-w-7xl px-6 py-8">
       <%= yield %>
     </div>
   </main>
   ```
   Net effect: sidebar header row (left, logo only) + topbar row (right, toggle
   only) form one visual top strip at matching height, toggle now unambiguously
   in the top-right corner.

3. **`shared/_sidebar.html.erb`**: drop the toggle render and the now-unused
   `ml-auto` wrapper div from the header row, leaving just the logo + label.

4. **`app/views/layouts/auth.html.erb`**: same pattern — render
   `shared/topbar` above the centered card wrapper instead of inlining the
   toggle next to the wordmark:
   ```erb
   <body class="h-full">
     <%= render "shared/topbar" %>
     <main class="flex min-h-full flex-col justify-center px-6 py-12">
       <div class="flex items-center justify-center gap-2 sm:mx-auto sm:w-full sm:max-w-sm">
         <h1 ...>Pipeliner</h1>
         ...
       </div>
       ...
     </main>
   </body>
   ```
   This keeps behavior identical between authenticated and auth layouts (a
   requirement no other guide text calls out explicitly, but consistency avoids
   surprising users who toggle theme on the login page).

## Why not other alternatives

- **Move toggle into the sidebar's nav list** (e.g. as a bottom item) — rejected;
  the ask is specifically "top right," and sidebar is visually top/left regardless
  of where inside it the toggle sits.
- **CSS-only reposition (`order`/`float` within the existing sidebar header)** —
  can't move the toggle out of the sidebar's DOM region into the main content's
  visual right edge with CSS alone since they're different flex containers.
- **Fixed/absolute positioning** — considered and rejected above due to overlap
  with per-page primary actions and inconsistent behavior across independently
  scrolling regions.

## Files touched

- `app/views/shared/_topbar.html.erb` (new)
- `app/views/layouts/application.html.erb` (edit)
- `app/views/layouts/auth.html.erb` (edit)
- `app/views/shared/_sidebar.html.erb` (edit — remove toggle + wrapper)

No changes to `theme_controller.js`, `theme_helper.rb`, `_theme_toggle.html.erb`,
or `_theme_init_script.html.erb` — behavior is unchanged, only where the button
lives in the DOM/layout.

## Testing

- Existing system/integration tests (if any) that assert on toggle presence
  should be updated to look within the topbar rather than the sidebar — search
  `test/` for `theme_toggle` / "Toggle dark mode" references and adjust
  selectors accordingly.
- Manually verify: toggle renders top-right on authenticated pages, on the
  login page, persists across a Turbo navigation, and still reflects
  `dark_theme?` server-rendered state (no flash-of-wrong-theme).
