# Discovery notes — Move dark mode toggle to top right corner

## What exists today

The dark mode toggle is a single shared partial rendered in two places:

- **`app/views/shared/_theme_toggle.html.erb`** — icon-only button (sun/moon
  SVGs swapped via `dark:hidden` / `dark:block`), `data-controller="theme"`,
  `aria-pressed`/`aria-label`/`title` for a11y. This is the only toggle
  markup; no duplication to worry about.
- **`app/javascript/controllers/theme_controller.js`** — Stimulus controller:
  toggles the `dark` class on `<html>`, writes a `theme` cookie (1yr,
  `SameSite=Lax`), watches `prefers-color-scheme` until the user makes an
  explicit choice, keeps `aria-pressed` in sync.
- **`app/helpers/theme_helper.rb`** — `dark_theme?` reads the cookie, used by
  both layouts to pre-set the `dark` class on `<html>` (avoids FOUC) and by
  the partial to set initial `aria-pressed`.
- **`app/views/shared/_theme_init_script.html.erb`** — inline `<script>` in
  `<head>` that applies the class before first paint, independent of the
  Stimulus controller (belt-and-suspenders against flash of wrong theme).

### Current placement (two call sites, two different layouts)

1. **`app/views/shared/_sidebar.html.erb:5`** — inside the sidebar's header
   row (`h-14` bar, indigo dot + "Pipeliner" wordmark), pinned right via
   `class="ml-auto"`. This sidebar is used by the main app shell
   (`app/views/layouts/application.html.erb`), a **fixed left sidebar**
   (`w-56`) next to a scrollable main content area. So today the toggle sits
   at the **top of the far-left column**, not the top-right of the viewport.
2. **`app/views/layouts/auth.html.erb:20`** — inline next to the "Pipeliner"
   heading, centered in the sign-in card (no sidebar on this layout).

## What the ask touches

"Top right corner" is ambiguous given the current structure — there's no
persistent top bar spanning the viewport width today. Relevant structural
facts:

- `application.html.erb` has **no app-wide header** — just
  `<sidebar><main>`. `main` (`app/views/layouts/application.html.erb:27`)
  scrolls independently and starts directly with flash + page content
  (`max-w-7xl` container).
- Each page builds its **own** local header row (`flex items-center
  justify-between`, e.g. `home/index.html.erb`, `projects/index.html.erb`,
  `pipelines/index.html.erb`, `projects/show.html.erb`,
  `step_templates/index.html.erb`) with title + one primary action. Per
  `guides/ui-style-guide.md:26-27`: *"Page header (title, primary action,
  status) → content. One primary action per page, top-right."* — that
  top-right slot is already reserved for each page's primary action, so
  putting the toggle there would compete with it on several pages.
- No existing "app shell top bar" component to drop the toggle into for a
  true viewport-top-right placement — one would need to be introduced (e.g.
  a slim bar spanning the main content area, or a fixed/absolute-positioned
  element), which is a layout decision beyond a one-line move.
- The auth layout has no sidebar, so "top right corner" there is
  straightforward (currently it's inline/centered next to the heading, not
  right-aligned at all).

## Open questions

1. **Scope: one layout or both?** Should this change apply to the main app
   shell only (`application.html.erb`/sidebar), or also the auth/sign-in
   layout (`auth.html.erb`)? They currently place the toggle differently and
   have no shared header.
2. **What does "top right corner" mean given there's no app-wide header bar?**
   - (a) Top-right of the **sidebar** (i.e., keep it where it is structurally
     — sidebar top row already right-aligns it via `ml-auto` — this may
     already satisfy the ask if "corner" was read loosely), or
   - (b) Top-right of the **whole viewport**, which requires introducing a
     persistent element outside/above the sidebar+main flex layout, or
   - (c) Top-right of **each page's local header row**, which conflicts with
     the guide's existing "one primary action, top-right" slot on pages that
     have one (home, projects, pipelines, step_templates, etc.).
3. If a new persistent top bar is introduced, should it also host anything
   else (breadcrumbs, user menu — currently the "Sign out" control lives at
   the bottom of the sidebar, not in a top bar)?

## Constraints

- **`guides/ui-style-guide.md`** is mandatory for this change: reuse the
  existing `_theme_toggle` partial as the one source of truth (no
  duplicating the button markup); any new container must use semantic color
  tokens (`bg-surface`, `border-default`, etc.), not raw grays; icon-only
  button already has `aria-label`/tooltip per the guide's button rules.
- **`guides/backend-guide.md`** — this is a pure view/layout change; no
  service/controller logic involved, so backend rules aren't in play unless
  positioning needs a new helper (unlikely).
- **Test coverage**: `test/system/theme_toggle_test.rb` locates the button via
  `find("button[aria-label='Toggle dark mode']")` — a DOM-position-agnostic
  selector, so repositioning shouldn't break this test, but the test signs in
  and asserts against the authenticated (sidebar) layout only, not the auth
  layout.
- **No FOUC regression**: `_theme_init_script` and the `dark_theme?`
  pre-render class on `<html>` are independent of the toggle's position and
  don't need to change.
- Accessibility baseline (`guides/ui-style-guide.md:146-153`) requires the
  moved control to remain keyboard-reachable with a visible focus ring —
  already present on the button (`focus-visible:outline-2 ...`); must be
  preserved wherever it moves.
