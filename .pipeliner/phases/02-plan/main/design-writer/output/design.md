# Technical design — Move dark mode toggle to sidebar footer

## 1. Summary

Move the existing `shared/_theme_toggle` partial out of the sidebar's top
header row (`app/views/shared/_sidebar.html.erb:5`) and into the sidebar's
footer block, alongside the "Sign out" control. No new component, no new
route/layout, no change to the toggle's markup or Stimulus behavior — this is
a pure relocation within one file. The auth layout (`auth.html.erb`) is not
touched. Satisfies **R1–R7**.

## 2. Components affected

| File | Change | Requirements |
|---|---|---|
| `app/views/shared/_sidebar.html.erb` | Remove toggle from header row; add it to the footer block next to "Sign out" | R1, R2, R7 |
| `app/views/shared/_theme_toggle.html.erb` | **No change** — reused as-is | R4 |
| `app/javascript/controllers/theme_controller.js` | **No change** | R4 |
| `app/helpers/theme_helper.rb` | **No change** | R4 |
| `app/views/shared/_theme_init_script.html.erb` | **No change** (FOUC prevention is position-independent) | — |
| `app/views/layouts/auth.html.erb` | **No change** | R6 |
| `test/system/theme_toggle_test.rb` | Add assertion(s) covering new footer placement | R2, R3, R5 |

No data model changes; no controller/service changes; this is a view-only
change per `guides/backend-guide.md` (not applicable here — no business logic
involved).

## 3. Layout design

### 3.1 Header row (before → after)

Current (`_sidebar.html.erb:1-6`):

```erb
<div class="flex h-14 items-center gap-2 border-b border-default px-4">
  <span class="inline-block h-2.5 w-2.5 rounded-full bg-indigo-600"></span>
  <span class="text-sm font-semibold text-default">Pipeliner</span>
  <div class="ml-auto"><%= render "shared/theme_toggle" %></div>
</div>
```

After: drop the `<div class="ml-auto">...</div>` wrapper and the toggle
render entirely. The header keeps only the wordmark (R1):

```erb
<div class="flex h-14 items-center gap-2 border-b border-default px-4">
  <span class="inline-block h-2.5 w-2.5 rounded-full bg-indigo-600"></span>
  <span class="text-sm font-semibold text-default">Pipeliner</span>
</div>
```

### 3.2 Footer block (before → after)

Current (`_sidebar.html.erb:27-33`):

```erb
<% if user_signed_in? %>
  <div class="border-t border-default p-3">
    <div class="truncate text-xs text-muted" title="<%= current_user.email %>"><%= current_user.email %></div>
    <%= button_to "Sign out", destroy_user_session_path, method: :delete,
          class: "mt-1 text-xs font-medium text-muted hover:text-default bg-transparent" %>
  </div>
<% end %>
```

After: the email stays full-width on its own line; a second row groups
"Sign out" and the toggle together in a flex row, toggle pinned to the end
with `ml-auto` (same right-alignment technique already used at the old call
site) so the pair reads as one related footer unit (R2, R3):

```erb
<% if user_signed_in? %>
  <div class="border-t border-default p-3">
    <div class="truncate text-xs text-muted" title="<%= current_user.email %>"><%= current_user.email %></div>
    <div class="mt-1 flex items-center gap-2">
      <%= button_to "Sign out", destroy_user_session_path, method: :delete,
            class: "text-xs font-medium text-muted hover:text-default bg-transparent" %>
      <div class="ml-auto"><%= render "shared/theme_toggle" %></div>
    </div>
  </div>
<% end %>
```

Notes:
- `gap-2` matches the spacing step already used in the removed header row
  (`gap-2`), per `guides/ui-style-guide.md:28` spacing scale.
- Wrapping the toggle in `ml-auto` (rather than restyling the shared
  `_theme_toggle` partial) keeps the partial's markup untouched — it remains
  the one source of truth per the guide's "Core components" rule, reused
  as-is, only its container changed.
- `button_to` renders a `<form>`, so `items-center` on the flex row is needed
  to vertically align the form's button with the icon-only toggle (both are
  inline-level at the same row height); no fixed heights required since both
  controls are naturally short.
- No new colors introduced — the container uses existing `border-default`,
  `text-muted`, semantic tokens already in the file. Nothing to add to
  `guides/ui-style-guide.md`.

## 4. Accessibility (R5)

- The toggle keeps its existing `aria-pressed`, `aria-label="Toggle dark
  mode"`, `title`, and `focus-visible:outline-2 focus-visible:outline-offset-2
  focus-visible:outline-indigo-600` classes unchanged — moving a DOM node
  does not remove its attributes or Stimulus bindings.
- New tab order: wordmark row → nav links → user email → "Sign out" → theme
  toggle (previously: wordmark → toggle → nav links → ... → "Sign out").
  Both controls remain reachable via Tab in document order; no `tabindex`
  overrides needed.
- Visible focus ring is unaffected since it's defined on the button itself,
  not by ancestor styles.

## 5. Non-goals / explicitly out of scope

Per the Define-phase decisions, confirmed here so the Build phase doesn't
reintroduce them:

- No new app-wide top bar or header region is introduced anywhere in
  `application.html.erb`.
- `auth.html.erb` (sign-in screen) is not modified — its toggle stays inline
  next to the "Pipeliner" heading exactly as today (R6).
- No change to each page's own local header row / primary-action slot
  (`home/index.html.erb`, `projects/index.html.erb`, etc.) — those are
  untouched (R7).
- No change to nav links or the displayed user email's markup/position
  beyond the footer's internal reflow described in §3.2 (R7).

## 6. Test plan

Extend `test/system/theme_toggle_test.rb` (selector `button[aria-label='Toggle
dark mode']` is already DOM-position-agnostic, so the existing toggle/persist
assertions keep passing unchanged):

- Add an assertion that the toggle button is a **sibling of** the "Sign out"
  button inside the sidebar footer container (e.g. assert both are found
  within the same `div.border-t` footer block, or assert the toggle is
  absent from the `h-14` header row) — covers R1, R2, R3.
- Existing click/persist/`aria-pressed` assertions cover R4 unchanged.
- Add a keyboard-reachability check: `send_keys` / focus assertion that the
  toggle is reachable via Tab and shows `:focus-visible` — covers R5. If the
  project has no existing pattern for asserting focus-visible in a system
  test, a simpler check (toggle receives DOM focus and responds to Enter/
  Space) satisfies the same requirement pragmatically.
- No new test file needed; the auth-layout toggle is unchanged and already
  untested here, consistent with current coverage (R6 needs no new test
  since nothing changes there).

## 7. File-level change list

1. `app/views/shared/_sidebar.html.erb` — remove toggle from header (§3.1),
   add to footer (§3.2).
2. `test/system/theme_toggle_test.rb` — add footer-pairing and
   keyboard-reachability assertions (§6).

No other files change.
