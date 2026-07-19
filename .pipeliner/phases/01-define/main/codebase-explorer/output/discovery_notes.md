# Discovery Notes — Add Dark Mode Support

## The ask (verbatim)

> I want to add a dark mode to the app. It should have a toggle for the user to
> switch back and forth and it should default to the user's system settings.

Three concrete requirements:
1. A dark visual theme for the app.
2. A user-facing **toggle** to switch between light and dark.
3. **Default = system setting** (`prefers-color-scheme`) until the user overrides.

---

## What exists today

### Stack (relevant slice)
- **Rails 8**, server-rendered, Hotwire (Turbo + Stimulus). No SPA, no Node bundler.
- **Tailwind CSS v4** via `tailwindcss-rails 4.6.0` / `tailwindcss-ruby 4.3.2`
  (standalone CLI compile, **not** PostCSS/JS-bundled).
- **JS via import maps** (`config/importmap.rb`) — Stimulus loaded from pinned
  vendored files; `eagerLoadControllersFrom("controllers", …)`. There is **no
  npm/node build step** and no `tailwind.config.js` (v4 is CSS-first config).
- Assets: Propshaft. CSS entry is `app/assets/tailwind/application.css`, whose
  entire contents are `@import "tailwindcss";` (no theme block, no custom
  variants, no `@layer` overrides).

### Layouts (2 — both hard-code light mode)
- `app/views/layouts/application.html.erb` — main app shell. Root element:
  `<html class="h-full bg-gray-50">`, `<body class="h-full">`, sidebar + main.
- `app/views/layouts/auth.html.erb` — Devise/login shell. Also
  `<html class="h-full bg-gray-50">`; card uses `bg-white`, text `text-gray-900/500`.
- Both include `csp_meta_tag`, `stylesheet_link_tag :app`, and
  `javascript_importmap_tags` in `<head>`. There is a `<%= yield :head %>` hook
  in the application layout (none in auth).
- `mailer.html.erb` is unrelated (email).

### Where colors live now
- **No `dark:` variants anywhere.** The only pre-existing hit for
  dark/theme/color-scheme in `app/` + `config/` is `pwa/manifest.json.erb`
  (`"theme_color": "red"`, unrelated to CSS dark mode).
- Light-mode utility classes are **hard-coded inline across ~23 of 28 ERB views**
  (`bg-white`, `bg-gray-50`, `text-gray-900`, `text-gray-500`, `border-gray-200`,
  etc.). Examples: `shared/_sidebar.html.erb`, `pipelines/_step_card.html.erb`,
  all board/table views.
- **One partial semantic-color source of truth:** `app/helpers/status_helper.rb`
  centralizes status-badge tones (`bg-blue-50 text-blue-700 ring-blue-600/20`,
  etc.). Everything else is duplicated inline per view — there is **no** shared
  Button/Card/Badge component. `app/components/` does not exist; the guide
  mentions ViewComponents but the app uses plain partials.

### User / persistence
- `User` (`app/models/user.rb`) is Devise-only
  (`database_authenticatable, registerable, recoverable, rememberable,
  validatable`). Associations: memberships, projects, approvals.
- `users` table (`db/schema.rb`) has **no preferences/settings/theme column**.
- **No settings/preferences controller, route, view, or Stimulus controller
  exists.** `config/routes.rb` has `devise_for :users`, `root "home#index"`, and
  resource routes for projects/pipelines/etc. — nothing user-preference-shaped.
- `app/javascript/controllers/` contains **only** the Stimulus scaffolding
  (`application.js`, `index.js`) — **zero custom controllers** today. A theme
  toggle would be the first.

### App shell touchpoints for a toggle
- `shared/_sidebar.html.erb` has the only persistent per-user chrome: it renders
  the signed-in user's email + a "Sign out" `button_to` in a bottom
  `border-t` block. This is the natural home for a theme toggle. The sidebar is
  **not** rendered on the auth layout (logged-out pages).

### CSP
- `config/initializers/content_security_policy.rb` is **entirely commented out**
  (CSP disabled). `csp_meta_tag` therefore emits nothing restrictive today, so an
  inline `<head>` script (see FOUC below) would work without a nonce — *but* the
  commented template shows the intended future policy uses
  `script-src :self :https` with a session-id nonce generator, which **would**
  block an un-nonced inline script if later enabled.

---

## What the ask touches (surface area)

1. **Tailwind config (CSS):** `app/assets/tailwind/application.css` — needs a dark
   strategy. Tailwind v4 defaults `dark:` to the `prefers-color-scheme` media
   query; a **manual toggle overriding system** requires declaring a custom
   variant (e.g. `@custom-variant dark (&:where(.dark, .dark *))`) and toggling a
   `.dark` class on `<html>`.
2. **Both layouts** — root `<html>` background/text classes must become
   theme-aware; the `.dark` class must be applied to `<html>` early.
3. **~23 views + `status_helper.rb`** — every hard-coded light color
   (`bg-white`, `text-gray-*`, `border-gray-*`, badge tones) needs a paired
   `dark:` variant, OR a refactor to semantic tokens so it's set in one place.
   This is the bulk of the work and the main risk of inconsistency.
4. **New toggle UI** — a control (likely in `shared/_sidebar.html.erb`) + a first
   **Stimulus controller** to flip the theme and persist the choice.
5. **Persistence layer** — where the choice + "follow system" state is stored
   (client-only vs. server; see open questions). May touch `User` model,
   a migration, a controller, routes, and strong params.
6. **FOUC prevention** — an inline `<head>` script (before CSS paint) that reads
   the stored preference / system setting and sets `.dark` on `<html>` to avoid a
   light flash on load. Import-map JS is deferred, so a Stimulus controller alone
   runs too late to prevent the flash.

---

## Open questions

1. **Persistence scope:** per-browser (localStorage / cookie) or per-user
   cross-device (new `users` column)? The ask says "the user" but doesn't
   specify cross-device. DB persistence adds a migration + controller + route +
   strong params; localStorage is client-only and won't survive a new device or
   inform server-rendered HTML. A cookie is a middle ground the server can read to
   set `.dark` server-side (helps FOUC).
2. **Toggle states:** two-state (light ⇄ dark) or three-state
   (light / dark / system)? "Default to system" plus "toggle back and forth"
   suggests users need a way to return to system-follow — a pure 2-state toggle
   loses the "follow system" state once touched.
3. **Toggle placement & form:** sidebar user block (proposed) — switch, or
   icon button? And what happens on the **auth/login pages**, which have no
   sidebar and no `current_user`?
4. **Styling strategy:** hand-add `dark:` variants across ~23 views, or first
   refactor to semantic color tokens / shared components (Card, Badge, Button)?
   The UI guide leans toward the latter (see constraints); the former is faster
   but entrenches duplication the guide warns against.
5. **Scope of coverage:** in scope for logged-out/Devise screens, mailers, PWA
   manifest `theme_color`, error pages (`public/*.html`)? Assume app screens
   (both layouts) unless told otherwise.
6. **Contrast/a11y target:** guide mandates ≥4.5:1 text contrast and status never
   by color alone — dark palette must hit the same bar (the current
   `text-*-700 on bg-*-50` badges invert non-trivially).

---

## Constraints (from repo guides + stack)

- **`guides/ui-style-guide.md` explicitly anticipates this and sets direction:**
  > "Neutrals do the work. … **Dark mode later — don't hand-roll it per view.**"
  Read as a directive: implement dark mode **centrally** (tokens/variants/shared
  components), not by scattering ad-hoc overrides in individual templates.
- The guide fixes a **restricted palette** (neutrals + `indigo-600` accent) and a
  **semantic, reserved status-color table** (running=blue, success=green,
  attention=amber, failed=red, idle=gray) with the soft badge form
  `bg-{c}-50 text-{c}-700 ring-{c}-600/20`. A dark theme must provide dark
  equivalents for **each** without breaking the semantic mapping or color-alone-
  never-carries-meaning rule.
- Any deviation/addition to the guide must be **proposed as a guide edit in the
  same PR** (per `CLAUDE.md` and the guide's own "propose a guide addition" rule).
- **`guides/backend-guide.md` (per CLAUDE.md):** business logic lives in POROs
  with `.call` → `Result`; controllers stay thin; no logic in callbacks/jobs;
  Minitest. So any server-side preference update (if chosen) should go through a
  service, not fat controller/model code.
- **No JS build pipeline:** the toggle must be plain Stimulus (vanilla JS via
  import maps) — no npm packages, no bundler-only APIs.
- **Tailwind v4 specifics:** CSS-first config (no `tailwind.config.js`); manual
  class-based dark mode needs an explicit `@custom-variant` declaration — it is
  **not** the v4 default (default is media-query only).
- **FOUC / correctness:** deferred import-map JS runs after first paint; theme
  must be applied pre-paint (inline head script or server-set class from a
  cookie). If CSP is ever enabled (template already staged), an inline script
  needs the session nonce.
- **Local-first, Minitest:** no cloud deploy; changes verified via
  `bin/rails test` (+ `test:system`). Note repo memory: plain `bin/rails test`
  reportedly needs a specific local runner setup.
- **Testability:** a JS-driven visual toggle is hard to unit-test; system tests
  (Capybara) would be the path to verify toggle + persistence behavior.

---

## Factual summary

The app is a server-rendered Rails 8 + Hotwire + Tailwind **v4** codebase with
**no existing dark-mode, theme, or user-preference machinery** of any kind: no
`dark:` variants, no theme CSS, no settings column on `users`, no
settings/preferences route or controller, and no custom Stimulus controllers.
Light-mode colors are hard-coded inline across ~23 of 28 views, with the single
exception of status-badge tones centralized in `status_helper.rb`. Delivering the
ask requires (a) a Tailwind v4 class-based dark strategy, (b) theme-aware styling
across both layouts + all views (ideally via central tokens/components, which the
UI guide explicitly mandates over per-view hand-rolling), (c) a new toggle UI +
the app's first Stimulus controller, (d) a persistence decision (client-only vs. a
new `users` column with a service-backed update), and (e) FOUC prevention via a
pre-paint theme application. Key undecided points: persistence scope
(per-browser vs. cross-device), 2- vs. 3-state toggle (system-follow default),
toggle placement (sidebar; and behavior on sidebar-less auth pages), and whether
to refactor to semantic tokens first.
