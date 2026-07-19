# Open Questions — Dark Mode Support

These are the points where human context would materially change the outcome.
Each notes the default we will assume if we hear nothing back.

1. **Where should the theme choice be remembered — on the device or on the
   account?** If it's stored per device, a user who picks dark on their laptop
   still sees system default on their phone; if it's stored on their account, the
   choice follows them across every device and browser they log in from.
   *Assumed default:* per device (stored in the browser). Simplest, works for
   logged-out visitors, and matches how most web apps behave.

2. **Once a user has picked a theme, do they need a way to go back to "follow my
   system setting"?** R8/R9 say a manual choice sticks and overrides the system
   from then on. A plain two-state toggle (light ↔ dark) has no way to return to
   automatic once it's been used, so "default to system" only ever applies before
   the first tap. If returning to automatic matters, the control needs a third
   "System" option rather than a simple toggle.
   *Assumed default:* keep the simple two-state toggle described in the ask; no
   dedicated "return to system" option in this version.

3. **Should the theme apply to pages seen before a user logs in** (sign-in,
   sign-up, error, and any marketing/landing pages)?
   *Assumed default:* yes — these pages honor the system setting and the toggle
   too, using the same per-device storage as question 1.

4. **Does "the app" here mean the on-screen web UI only, or also things the app
   produces outside the browser** — transactional/notification emails, exported
   or printed PDFs, and print stylesheets?
   *Assumed default:* the on-screen web UI only. Emails, exports, and print output
   are out of scope for dark mode.

5. **Is a brief flash of the wrong theme on the very first page load acceptable,
   or must the correct theme show from the first frame?** Guaranteeing no flash
   constrains how early the theme is applied (e.g. inline detection before render)
   and is worth a little extra effort if it matters.
   *Assumed default:* eliminate the flash where reasonably possible; a rare
   one-frame flash on a cold load is acceptable if unavoidable.

6. **Is this strictly light and dark, or should it be built to allow more themes
   later** (e.g. a high-contrast or accessibility theme)?
   *Assumed default:* deliver exactly two themes now, but structure the work so
   additional themes could be added later without a rebuild.

7. **What readability bar should the dark theme meet?** R12/R13 require everything
   to stay readable and status to stay distinguishable, but not a specific
   standard. Committing to a contrast target (e.g. WCAG AA) sets a clear, testable
   bar for the build and review phases.
   *Assumed default:* meet WCAG AA contrast for text and interactive elements in
   both themes.
