# Pipeliner — UI Style Guide

> Persistent guide. Sensible defaults for now; refine as the product develops.
> Stack context: Rails 8, Hotwire (Turbo + Stimulus), Tailwind CSS. Server-rendered,
> no SPA. Every screen should feel **simple, elegant, and real-time**.

## Principles

1. **Calm surfaces, clear state.** This is an operations UI — the user's core
   question is always "what is happening right now?" State (running, stuck,
   awaiting human) must be legible at a glance without reading prose.
2. **Restraint over decoration.** Few colors, generous whitespace, consistent
   type scale. If an element doesn't communicate state or afford an action, cut it.
3. **Live by default.** Anything that changes server-side (step progress,
   heartbeats, phase status) updates in place via Turbo Streams — never require a
   manual refresh.
4. **Density where it earns it.** Lists/boards can be dense; forms and reading
   surfaces stay airy.

## Layout

- **App shell:** fixed left sidebar (nav: Projects, Pipelines, Workers, Step
  Library) + main content area. Sidebar collapses on small screens.
- **Content max-width:** `max-w-7xl` for boards/tables; `max-w-3xl` for forms and
  reading views.
- **Page structure:** page header (title, primary action, status) → content.
  One primary action per page, top-right.
- **Spacing scale:** stick to Tailwind steps `2, 4, 6, 8, 12` (`gap-4`,
  `p-6`, `mb-8`...). Avoid one-off values.

## Typography

- **Font:** system stack (`font-sans`, Tailwind default). No webfonts for now.
- **Scale (only these):**
  - Page title: `text-2xl font-semibold`
  - Section heading: `text-lg font-semibold`
  - Card title / row primary: `text-sm font-medium`
  - Body: `text-sm`
  - Meta/secondary: `text-xs text-gray-500`
  - Code/slugs/branches: `font-mono text-xs`
- Sentence case everywhere (headings, buttons, labels). No ALL CAPS except tiny
  eyebrow labels (`text-xs uppercase tracking-wide text-gray-400`), used sparingly.

## Color

- **Neutrals are semantic tokens, not raw grays.** Dark mode is implemented as
  CSS custom-property tokens (`app/assets/tailwind/application.css`), swapped
  under a `.dark` class on `<html>` via a class-based dark variant:
  ```css
  @custom-variant dark (&:where(.dark, .dark *));
  ```
  New UI **must** use these token utilities instead of raw `gray-*`/`white`
  utilities, so it repaints correctly in both themes automatically:

  | Utility | Purpose | Light | Dark |
  |---|---|---|---|
  | `bg-app` | root/body background | `gray-50` | `gray-950` |
  | `bg-surface` | cards, sidebar, auth panel | `white` | `gray-900` |
  | `bg-surface-hover` | table row / nav hover, subtle inset panels | `gray-50` | `gray-800` |
  | `border-default`, `divide-default`, `ring-default` | borders, dividers, input rings | `gray-200`/`gray-100` | `gray-800` |
  | `text-default` | primary text | `gray-900` | `gray-100` |
  | `text-muted` | secondary/meta text | `gray-500` | `gray-400` |
  | `text-subtle` | disabled / "coming soon" items | `gray-400`/`gray-300` | `gray-600` |
  | `bg-nav-active` / `text-nav-active` | active sidebar nav item | `indigo-50`/`indigo-700` | `indigo-500/15` / `indigo-300` |

  Status colors (below) and the brand accent are **not** tokenized — they're
  already a small, closed set and get explicit `dark:` variants instead (see
  `StatusHelper::TONE_CLASSES` for the pattern: soft badge, `dark:bg-{hue}-500/10
  dark:text-{hue}-400 dark:ring-{hue}-400/20`). Ad-hoc semantic callouts (e.g.
  amber "awaiting human" panels) follow the same soft-badge-on-dark pattern.
- **One brand accent:** `indigo-600` (hover `indigo-700`). Used for primary
  buttons, links, active nav, focus rings.
- **Status colors are semantic and reserved** — never used decoratively:

  | State | Color | Usage |
  |---|---|---|
  | running / in progress | `blue-600` | spinners, active step chips |
  | success / converged / approved | `green-600` | check icons, pass badges |
  | needs attention / awaiting human | `amber-500` | gates, paused phases |
  | stuck / failed / blocked | `red-600` | stuck steps, failed runs |
  | pending / idle | `gray-400` | queued steps, offline workers |

- Badges use the soft form: `bg-{color}-50 text-{color}-700 ring-1 ring-{color}-600/20`.

## Core components (conventions)

Build as ViewComponents or partials — one source of truth per component.

- **Status badge** (`StatusBadge`): pill, `rounded-full px-2 py-0.5 text-xs
  font-medium`, soft colors above. Always paired with the status word — color
  alone never carries meaning (a11y).
- **Card:** `rounded-lg border border-default bg-surface p-6 shadow-sm`. No heavy
  shadows; elevation is for menus/modals only.
- **Buttons:**
  - Primary: `bg-indigo-600 text-white hover:bg-indigo-700 rounded-md px-3 py-2 text-sm font-semibold`
  - Secondary: `bg-surface ring-1 ring-default hover:bg-surface-hover ...`
  - Danger: red equivalents (with `dark:` variants), only for destructive
    actions (+ confirm).
  - Icon-only buttons get `aria-label` + tooltip.
- **Tables:** `divide-y divide-default`, header `text-xs font-semibold
  text-muted`, row hover `hover:bg-surface-hover`, whole row clickable when it
  navigates.
- **Forms:** labels above inputs (`text-sm font-medium`), help text below
  (`text-xs text-muted`), errors inline in `red-600`/`dark:text-red-400`
  attached to the field (not only a flash). Inputs: `rounded-md ring-1
  ring-default focus:ring-2 focus:ring-indigo-600`.
- **Theme toggle** (`shared/_theme_toggle`): icon-only button, two-state
  (light ⇄ dark), `aria-pressed` + `aria-label="Toggle dark mode"`. Rendered
  wherever there's persistent chrome (sidebar, auth layout header) so it's
  reachable on every screen. Backed by `theme_controller.js` — see
  `app/views/shared/_theme_init_script.html.erb` for the zero-flash
  first-paint logic.
- **Empty states:** icon + one sentence + primary action. Never a bare empty table.
- **Timestamps:** relative ("3m ago") with absolute on hover/`title`; `local-time`
  behavior via a small Stimulus controller.

## The pipeline board (signature view)

- Four phase columns (Define, Plan, Build, Review) left→right; the pipeline's
  current phase visually emphasized, future phases muted.
- Steps render as compact cards: name, type icon, role tag (`font-mono`), status
  badge, and — when running — live progress line + worker name.
- Iteration/rework indicated with a counter chip (`×3`), not repeated cards.
- Gates render as horizontal separators between phases with their state
  (auto ✓ / awaiting human, with the approve/send-back actions inline).

## Real-time behavior (Hotwire rules)

- **Turbo Streams broadcasts** for step/phase/worker state changes; target the
  smallest DOM unit (a badge, a card), not whole sections.
- Frequently-updating regions (progress lines, heartbeat dots) get stable DOM ids:
  `dom_id(step_run, :progress)`.
- **Never block on WebSocket delivery for correctness** — every page renders the
  true current state on load; streams are enhancement.
- Optimistic UI only for trivial local toggles; anything stateful waits for the
  server.
- Loading: skeletons (`animate-pulse`) for initial loads; small inline spinners
  for in-flight actions. Buttons disable while submitting
  (`data-turbo-submits-with`).

## Accessibility baseline

- All interactive elements keyboard-reachable, visible focus ring
  (`focus-visible:ring-2 ring-indigo-600`).
- Color contrast ≥ 4.5:1 for text; status never conveyed by color alone.
- Live regions: progress updates in `aria-live="polite"` containers.
- Semantic HTML first (`button`, `nav`, `table`, `time`); ARIA only when
  semantics fall short.
