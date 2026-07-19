# Review Report — Add Dark Mode Support

## Overall verdict

**Ship-ready with one note.** Two independent review critics examined the
change: the **requirements-conformance-critic** returned **pass** (all 13
business requirements satisfied), and the **code-quality-critic** returned
**needs_work** for a single *minor* finding (F1). On inspection of the merged
branch, the code already contains the exact remediation F1 recommends — see
[Open findings](#open-findings) — so no further code change is required to land
this. The build-phase test suite is green (185 runs, 0 failures) and RuboCop is
clean.

---

## What was asked

> Add a dark mode to the app. It should have a toggle for the user to switch
> back and forth, and it should default to the user's system settings.

Define decomposed this into 13 atomic business requirements (R1–R13):

| # | Requirement |
|---|---|
| R1 | First-time users (no stored choice) see the theme matching their device's system setting |
| R2 | If the system theme can't be determined, fall back to light |
| R3 | A visible toggle is reachable from anywhere in the app |
| R4 | Toggling in light switches to dark |
| R5 | Toggling in dark switches to light |
| R6 | The change applies immediately, no reload |
| R7 | The toggle visibly reflects the active theme |
| R8 | A manual choice is remembered on the next visit (not reverted to system) |
| R9 | A manual choice takes precedence over the system setting |
| R10 | With no manual choice, a live system-setting change updates the app |
| R11 | With a manual choice, a later system-setting change does **not** override it |
| R12 | In dark theme, every visible surface (text, backgrounds, buttons, icons, status) is styled — nothing left in light |
| R13 | Color-conveyed information (status) stays distinguishable in both themes |

## What was built

A presentation-layer implementation with **zero backend/schema changes** — the
choice is stored per-device in a first-party `theme` cookie, not a `users`
column.

**New files**

- `app/assets/tailwind/application.css` — a semantic **CSS custom-property token
  layer**. A class-based `@custom-variant dark (&:where(.dark, .dark *))` opts
  out of Tailwind's default media-query dark mode (required for a manual
  override). Tokens (`--color-app`, `--color-surface`, `--color-text`,
  `--color-border`, …) are declared at `:root` (light) and redeclared under
  `.dark` (dark), and exposed as `@utility` classes (`bg-surface`,
  `text-default`, `border-default`, …). Redeclaring a token under `.dark`
  repaints every element using its utility — **no per-view `dark:` duplication**.
- `app/helpers/theme_helper.rb` — `dark_theme?` reads `cookies[:theme] == "dark"`
  for server-side (SSR) class stamping.
- `app/views/shared/_theme_init_script.html.erb` — a synchronous inline `<head>`
  script (rendered first, before the stylesheet) that reads the cookie, else
  `matchMedia('(prefers-color-scheme: dark)')`, and sets the `dark` class
  **before first paint** (no flash of the wrong theme).
- `app/javascript/controllers/theme_controller.js` — the app's first custom
  Stimulus controller. `connect()` syncs `aria-pressed` and, *only when no
  preference is stored*, attaches a `matchMedia` `change` listener that follows
  live OS changes. `toggle()` flips the `dark` class, writes the 1-year
  `SameSite=Lax` cookie, and tears the listener down. `disconnect()` also
  removes it.
- `app/views/shared/_theme_toggle.html.erb` — an icon button (sun/moon) with
  `aria-pressed`, `aria-label`, and `title`, rendered in the sidebar (logged-in)
  and the auth layout header (logged-out) so it's reachable on every screen.

**Modified files**

- `app/helpers/status_helper.rb` — each of the five `TONE_CLASSES` (info /
  success / attention / danger / muted) gains a `dark:` variant, preserving the
  same hue→meaning mapping. As the single source of truth for status color, this
  one file covers every status badge in the app.
- `app/views/layouts/application.html.erb` & `auth.html.erb` — render the init
  script first in `<head>`; `<html>` carries `bg-app` + `dark` (from
  `dark_theme?`).
- **25 view templates** converted from raw `bg-white`/`gray-*` utilities to the
  semantic tokens (mechanical "token sweep").
- `guides/ui-style-guide.md` — §Color updated with the token table, the
  `@custom-variant` rule, and a mandate that new UI use the semantic tokens
  rather than raw grays (per CLAUDE.md's "update the guide alongside the code").

## Evidence of conformance

| Req | Evidence |
|---|---|
| R1, R2 | `_theme_init_script.html.erb`: `match ? … : matchMedia(...)` with `!!dark` fallback → light when `matchMedia` unsupported. Belt-and-suspenders SSR via `ThemeHelper#dark_theme?`. |
| R3 | `_theme_toggle` rendered in `_sidebar` (logged-in) **and** `auth.html.erb` header (logged-out). |
| R4–R6 | `theme_controller#toggle` flips `document.documentElement` class in place — synchronous, no reload. |
| R7 | `syncPressedState()` keeps `aria-pressed` in sync; toggle partial swaps sun/moon via `dark:hidden` / `dark:block`. |
| R8, R9 | `toggle()` writes `theme` cookie (`max-age=31536000`); init script and `dark_theme?` both treat the cookie as source of truth over `matchMedia`. |
| R10 | `connect()` attaches the `matchMedia` change listener **only** when `!hasStoredPreference()`. |
| R11 | Once a choice exists, `connect()` never attaches the listener; and `toggle()` calls `stopWatchingSystemTheme()` to stop following the OS mid-session. |
| R12 | Token layer redeclared under `.dark`; **25 views** converted; a scan for orphaned `bg-white`/`gray-*`/`border-gray-*` in `app/views` returns **none**. |
| R13 | `StatusHelper::TONE_CLASSES` carry dark variants for all five tones; the status word is always rendered as text, so meaning survives independent of color. |

**Quality gates (build phase):**
- `bin/rails test:all` — **185 runs, 667 assertions, 0 failures, 0 errors, 0 skips** (includes the new `test/helpers/theme_helper_test.rb` and the new system test `test/system/theme_toggle_test.rb`).
- `bin/rubocop` — **145 files, no offenses.**
- The system test is deterministic across host OS appearance: `test/application_system_test_case.rb` pins `prefers-color-scheme: light` via a CDP `Emulation.setEmulatedMedia` call in setup (verified passing on a Dark-mode host).

**Security:** No concerns raised. CSP is fully commented out (inline script runs
without a nonce); the inline script has no interpolation and is regex-restricted
to `dark|light`; the cookie is non-sensitive and `SameSite=Lax`. *(Follow-up: if
CSP is enabled later, the inline script must switch to a nonce'd
`javascript_tag` — flagged in the design, not actioned since CSP is off.)*

## Open findings

**F1 — OS-preference listener teardown after a manual toggle** · severity: minor
· source: code-quality-critic (`needs_work`)

> *As reported:* `connect()` attaches a `matchMedia` `change` listener when no
> cookie exists; the critic flagged that `toggle()` writes the cookie but never
> removes that listener, so a mid-session OS theme change could override the
> user's manual choice (contradicting R11).

**Status on the merged branch: already remediated.** The recommended fix —
"remove the listener in `toggle()` once a preference is stored" — is present in
the current code:

- `toggle()` calls `this.stopWatchingSystemTheme()`, which
  `removeEventListener`s and nulls `this.media`, so the OS-change handler is torn
  down the moment the user makes a manual choice (in-session, no navigation
  needed).
- `disconnect()` independently removes the listener on teardown.
- `connect()` never attaches the listener in the first place when
  `hasStoredPreference()` is true.

The requirements-conformance-critic independently confirmed R11 as satisfied on
the same code. The finding reads as a stale/false-positive against an earlier
iteration (the controller's `stopWatchingSystemTheme` teardown landed in
implementer iteration 4). **No code change required to land this PR**; recommend
resolving F1 as already-addressed.

## Requirements traceability summary

- **13 / 13 requirements** satisfied (requirements-conformance-critic: pass, 0 findings).
- **Code quality:** 1 minor finding (F1), already remediated on the branch.
- **Tests & lint:** green.
- Out of scope by design (D4): mailers, PWA `theme_color`, service worker.
  Cross-device sync (D1) intentionally deferred; the cookie→column seam is
  documented for a future ask.
