# Technical Design — Dark Mode Support

Inputs: `docs/../requirements.md` (R1–R13), `codebase-explorer` discovery notes,
`clarifying-questions-writer` open questions (assumed defaults, since unresolved),
`guides/ui-style-guide.md`, `guides/backend-guide.md`.

## 1. Key decisions

These resolve the open questions from Define using the stated defaults (no
human response received), and shape everything below.

| # | Decision | Source |
|---|---|---|
| D1 | Theme choice is **per-device**, stored in a first-party, non-httpOnly cookie (`theme`), not a `users` column. No migration, model change, controller, route, or service is needed. | Open Q1 default; keeps backend footprint at zero per [[backend-guide]] ("don't validate/build for scenarios that can't happen") |
| D2 | The **toggle is two-state** (light ⇄ dark). "Follow system" is not a third UI state — it is simply *the state before the cookie exists*. Presence of the cookie = manual override; absence = follow system. This satisfies R8–R11 without a tri-state control. | Open Q2 default |
| D3 | Dark mode applies to **all screens**, including the logged-out Devise layout. | Open Q3 default |
| D4 | Web UI only — mailers, PDFs, PWA manifest `theme_color` are out of scope. | Open Q4 default |
| D5 | **Zero-flash**: theme is applied before first paint via a synchronous inline `<head>` script, on every layout. | Open Q5 default |
| D6 | Exactly two themes now, but implemented as swappable **CSS custom-property tokens** rather than scattered `dark:` utilities, so a third theme is additive later. This is also what `guides/ui-style-guide.md` explicitly directs ("Dark mode later — don't hand-roll it per view"). | Open Q6 default + UI guide §Color |
| D7 | Contrast target: **WCAG AA** (≥4.5:1 text) in both themes, matching the UI guide's existing accessibility baseline. | Open Q7 default; UI guide §Accessibility |

## 2. Architecture overview

No new server-side business capability is introduced — this is presentation-layer
work. Data flow:

```
Request (any page)
   │
   ├─ ApplicationController#layout_by_context → "application" or "auth"
   │
   ▼
Layout renders <html class="... <%= 'dark' if dark_theme? %>">
   │  (dark_theme? reads cookies[:theme] — server-rendered best-effort;
   │   nil cookie ⇒ no class server-side, resolved client-side next)
   │
   ├─ <head> first child: inline script (shared/_theme_init_script)
   │    reads cookie[theme] ⇒ if set, force class to match (source of truth)
   │    if unset, read matchMedia('(prefers-color-scheme: dark)') and set class
   │    (no cookie written yet — still "following system")
   │
   ├─ CSS (application.css): tokens defined at :root, re-declared under .dark
   │    Tailwind utilities (bg-surface, text-default, ...) reference the tokens,
   │    so every already-styled element repaints correctly with zero dark:
   │    duplication.
   │
   └─ Stimulus theme_controller (mounted on the toggle button, one instance
        per page since sidebar/auth-header render it):
        - connect(): sync toggle's visual state from current class;
          if no cookie present, attach a matchMedia 'change' listener
          (R10) that re-applies the system class live (never writes a cookie)
        - toggle(): flip documentElement's "dark" class, write the cookie
          (this is the moment a "manual choice" is created — R8/R9),
          update visual state (R7), all synchronously (R6)
```

## 3. Data model

**No schema changes.** `users` table is untouched (confirmed no
preferences/theme column exists today — see discovery notes). The only
"stored state" is the `theme` cookie:

| Attribute | Value |
|---|---|
| Name | `theme` |
| Values | `"light"` \| `"dark"` (absent = no manual choice yet) |
| Scope | `path=/`, `max-age=31536000` (1 year), `SameSite=Lax` |
| Written by | client JS only (`theme_controller.js`, on toggle) |
| Read by | client JS (init script, controller) **and** server (`ThemeHelper#dark_theme?`, for SSR class + zero-flash on non-JS-cold loads) |
| httpOnly | No — must be readable by JS |

If cross-device sync is wanted later, this is the seam: swap the cookie read/
write for a `current_user.theme_preference` column + a `Users::UpdateThemePreference`
service, without touching the CSS/token layer.

## 4. Components

### 4.1 `ThemeHelper` (new) — `app/helpers/theme_helper.rb`
- `dark_theme?` → boolean, reads `cookies[:theme] == "dark"`. Used only for
  best-effort server-side class rendering (SSR consistency on non-cold-cache
  reloads and no-JS clients); the inline script is the actual correctness
  guarantee for R1/R2/R5. This is view/presentation logic (not a business
  action), so a plain helper is appropriate — no service needed per
  [[backend-guide]].
- Satisfies: R1, R2, R5 (partially — belt-and-suspenders with the inline script).

### 4.2 Inline theme-init script (new) — `app/views/shared/_theme_init_script.html.erb`
- Rendered as the **first child of `<head>`**, before `csrf_meta_tags`, before
  the stylesheet link — order matters, this must execute before CSS paints.
- Logic: `if (cookie theme exists) → apply it; else → apply matchMedia result
  (default light if matchMedia unsupported/returns false)`. Never writes a
  cookie itself (only reads).
- Shared between both layouts via a single partial so the FOUC-prevention logic
  has one source of truth (not duplicated across `application.html.erb` /
  `auth.html.erb`).
- Satisfies: R1, R2, R5.

### 4.3 Stimulus controller (new, first custom controller in the app) — `app/javascript/controllers/theme_controller.js`
- No importmap change needed — `config/importmap.rb` already does
  `pin_all_from "app/javascript/controllers"` and `index.js` eager-loads
  everything in that directory.
- `connect()`: reflect current `documentElement.classList.contains("dark")`
  into the toggle's visual/`aria-pressed` state. If `cookies.theme` is absent,
  register a `matchMedia('(prefers-color-scheme: dark)').addEventListener('change', ...)`
  listener that re-applies the class live and re-syncs the toggle — removed
  implicitly on page unload (Turbo Drive navigations keep `documentElement`
  alive across visits, so this does not leak duplicate listeners across a
  single page's lifetime, but does re-attach fresh per full-page load, which is
  correct).
- `toggle()`: flips the `dark` class on `documentElement`, writes the `theme`
  cookie (creating the "manual choice" — this is what makes R8/R9 stick and
  disables the system-change listener on the *next* page load, since the
  cookie will now be present), updates the toggle's visual state.
- Satisfies: R4, R5 (no reload), R6, R7, R8, R9, R10, R11.

### 4.4 Theme toggle partial (new) — `app/views/shared/_theme_toggle.html.erb`
- A small icon button (sun/moon), `data-controller="theme"`,
  `data-action="click->theme#toggle"`, `aria-pressed`, `aria-label="Toggle dark mode"`.
  Per UI guide, icon-only buttons need `aria-label` + tooltip — reused here.
- Rendered in **two places** so it's reachable on every screen (R3):
  - `app/views/shared/_sidebar.html.erb`, bottom block, alongside the
    sign-out button (only place with persistent per-user chrome today).
  - `app/views/layouts/auth.html.erb`, near the "Pipeliner" header, since the
    auth layout has no sidebar and is reachable while logged out (D3).
- Satisfies: R3, R4, R5, R6, R7.

### 4.5 CSS token layer — `app/assets/tailwind/application.css`
Tailwind v4 is CSS-first (no `tailwind.config.js`). Two additions:

1. **Class-based dark variant** (v4 defaults `dark:` to a media query; a
   manual-override toggle requires opting into class-based matching):
   ```css
   @custom-variant dark (&:where(.dark, .dark *));
   ```
2. **Semantic tokens**, defined once at `:root` via `@theme` (light values) and
   re-declared under `.dark` (dark values). Because `<html>` is simultaneously
   `:root` and the element carrying `.dark`, both rules target the same
   element at equal specificity — **the `.dark` block must be declared after
   the `@theme` block** in source order so it wins the cascade tie. Utilities
   generated from `@theme --color-*` entries reference the variable
   (`background-color: var(--color-surface)`), so redeclaring the variable
   under `.dark` repaints every element using `bg-surface` with zero
   per-element `dark:` duplication.

   | Token | Utility | Light | Dark | Replaces |
   |---|---|---|---|---|
   | `--color-app` | `bg-app` | `gray-50` | `gray-950`-ish | root/body background |
   | `--color-surface` | `bg-surface` | `white` | `gray-900`-ish | cards, sidebar, auth panel |
   | `--color-surface-hover` | `bg-surface-hover` | `gray-50` | `gray-800`-ish | table row / nav hover |
   | `--color-border` | `border-default`, `divide-default`, `ring-default` | `gray-200`/`gray-100` | `gray-700`/`gray-800` | borders, dividers, input rings |
   | `--color-text` | `text-default` | `gray-900` | `gray-100` | primary text |
   | `--color-text-muted` | `text-muted` | `gray-500` | `gray-400` | secondary/meta text |
   | `--color-text-subtle` | `text-subtle` | `gray-400`/`gray-300` | `gray-600` | disabled ("coming soon") items |
   | `--color-nav-active-bg` / `--color-nav-active-text` | `bg-nav-active` / `text-nav-active` | `indigo-50`/`indigo-700` | `indigo-500/15`-ish / `indigo-300` | active sidebar nav item |

   Exact dark shade values are a build-time detail the Implementer should
   verify against WCAG AA (D7) with a contrast checker — the table above fixes
   the *mapping*, not final hex/oklch values.

   The reserved **brand accent (`indigo-600`) and status colors are
   intentionally NOT tokenized here** — they're already centralized (guide +
   `status_helper.rb`) and get explicit `dark:` variants instead (§4.6), since
   they're a small, closed set, not scattered across views.
- Satisfies: R12 (infrastructure for it), D6.

### 4.6 `StatusHelper` (existing, modified) — `app/helpers/status_helper.rb`
- Add a dark-mode variant to each `TONE_CLASSES` entry using the standard
  "soft badge on dark surface" form, e.g.:
  `info: "bg-blue-50 text-blue-700 ring-blue-600/20 dark:bg-blue-500/10 dark:text-blue-400 dark:ring-blue-400/20"`
  applied to all five tones (info/success/attention/danger/muted), preserving
  the same hue → meaning mapping in both themes.
- Because this is the single existing source of truth for status color, this
  one file covers every status badge in the app — no per-view changes needed
  for status.
- Satisfies: R12, R13 (status stays distinguishable + readable in dark).

### 4.7 Guide update (required alongside the code, per CLAUDE.md)
- `guides/ui-style-guide.md` §Color: replace "Dark mode later — don't hand-roll
  it per view" with the token table from §4.5, the `@custom-variant` rule, and
  a rule that new UI must use the semantic tokens (`bg-surface`, `text-default`,
  etc.) instead of raw `gray-*`/`white` utilities going forward.

## 5. File-level plan

| File | Change | Requirements |
|---|---|---|
| `app/assets/tailwind/application.css` | Add `@custom-variant dark`, `@theme` token block, `.dark` override block | R1, R2, R12, D6 |
| `app/helpers/theme_helper.rb` (new) | `dark_theme?` cookie reader | R1, R2 |
| `app/views/shared/_theme_init_script.html.erb` (new) | FOUC-prevention inline script | R1, R2, R5 |
| `app/views/shared/_theme_toggle.html.erb` (new) | Toggle button partial | R3, R4–R7 |
| `app/javascript/controllers/theme_controller.js` (new) | Toggle + system-change reactivity | R4–R11 |
| `app/views/layouts/application.html.erb` | Render init script first in `<head>`; `<html>` class uses `bg-app`/`dark_theme?`; render toggle partial in sidebar area (or leave to `_sidebar` include) | R1–R7, R12 |
| `app/views/layouts/auth.html.erb` | Same init-script + `<html>` class treatment; render toggle partial near header; card `bg-white`→`bg-surface`, text→tokens | R1–R7, R12, D3 |
| `app/views/shared/_sidebar.html.erb` | Replace `bg-white`/`border-gray-200`/`text-gray-*`/`bg-indigo-50 text-indigo-700` with tokens; add toggle render | R3, R12 |
| `app/helpers/status_helper.rb` | Add `dark:` classes to `TONE_CLASSES` | R12, R13 |
| `app/views/home/index.html.erb` | Token sweep | R12 |
| `app/views/phases/show.html.erb` | Token sweep | R12 |
| `app/views/pipeline_templates/show.html.erb` | Token sweep | R12 |
| `app/views/pipelines/_define_panel.html.erb` | Token sweep | R12 |
| `app/views/pipelines/_phase_column.html.erb` | Token sweep | R12 |
| `app/views/pipelines/_step_card.html.erb` | Token sweep | R12 |
| `app/views/pipelines/index.html.erb` | Token sweep | R12 |
| `app/views/pipelines/new.html.erb` | Token sweep | R12 |
| `app/views/pipelines/show.html.erb` | Token sweep | R12 |
| `app/views/projects/index.html.erb` | Token sweep | R12 |
| `app/views/projects/new.html.erb` | Token sweep | R12 |
| `app/views/projects/show.html.erb` | Token sweep | R12 |
| `app/views/shared/_flash.html.erb` | Token sweep | R12 |
| `app/views/step_templates/_form.html.erb` | Token sweep | R12 |
| `app/views/step_templates/edit.html.erb` | Token sweep | R12 |
| `app/views/step_templates/index.html.erb` | Token sweep | R12 |
| `app/views/step_templates/new.html.erb` | Token sweep | R12 |
| `app/views/steps/new.html.erb` | Token sweep | R12 |
| `app/views/workers/index.html.erb` | Token sweep | R12 |
| `app/views/devise/sessions/new.html.erb` | Token sweep (uses auth layout) | R12, D3 |
| `guides/ui-style-guide.md` | Document token table + `@custom-variant` + usage rule | D6 (guide-alignment requirement) |

"Token sweep" means: replace `bg-white`→`bg-surface`, `bg-gray-50`→`bg-app`
(or `bg-surface` for cards, contextual), `text-gray-900`→`text-default`,
`text-gray-500`→`text-muted`, `text-gray-400`/`text-gray-300`→`text-subtle`,
`border-gray-200`/`divide-gray-100`→`border-default`/`divide-default`,
`ring-gray-300`→`ring-default`, `hover:bg-gray-50`→`hover:bg-surface-hover`.
Because these are token *names*, not per-view color decisions, a view needing
this swap is mechanical — the Implementer does not need to re-derive dark
shades per file, only apply the already-defined tokens from §4.5.

**Explicitly out of scope** (D4): `app/views/layouts/mailer.html.erb`,
`app/views/layouts/mailer.text.erb`, `app/views/pwa/manifest.json.erb`
(`theme_color`), `app/views/pwa/service-worker.js`.

## 6. Testing plan

- `test/helpers/theme_helper_test.rb` (new): `dark_theme?` true/false/absent-cookie
  cases.
- System test (new — `test/system` does not exist yet in this app, this is the
  first): toggle click flips visible state without a full reload, a second
  visit with the cookie set reopens in the chosen theme regardless of system
  preference (R8/R9), and — where the driver allows emulating
  `prefers-color-scheme` — a fresh session with no cookie matches system
  default (R1/R10). Run via `bin/rails test:system`.
- No new service/model tests are needed (D1 — no business-logic surface added).
- Manual/visual check: confirm status badges (`status_helper`) remain
  distinguishable and ≥4.5:1 contrast in both themes (D7) — a contrast checker
  run at build time, not an automated Minitest assertion.

## 7. Risks / follow-ups (not part of this design's build scope)

- **CSP**: `config/initializers/content_security_policy.rb` is currently fully
  commented out, so the inline init script needs no nonce today. If CSP is
  enabled later using the initializer's own staged template
  (`content_security_policy_nonce_generator`), the inline script must switch to
  `<%= javascript_tag nonce: true do %>...<% end %>` at that time — flagged
  here, not addressed now, since CSP is off (nothing to guard against yet).
  See discovery notes for the original CSP note.
  <br>Why noted: it's a real future gotcha for whoever enables CSP; not
  actioned because CSP is disabled and adding nonce-handling code for a
  disabled feature would be validating a scenario that can't currently happen.
- **Dark shade values** in §4.5's token table are a mapping, not final colors —
  the Implementer must pick concrete gray-900/gray-950/etc. shades and verify
  WCAG AA before merging (D7).
- **Cross-device sync** is explicitly out of scope (D1); the seam to add it
  later is noted in §3 if a future ask requires it.
