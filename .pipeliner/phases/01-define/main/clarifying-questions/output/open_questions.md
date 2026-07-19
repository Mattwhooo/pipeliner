# Open questions — Move dark mode toggle to top right corner

The app has **no viewport-spanning top bar today**. In the main app shell the
toggle currently lives in the top row of the fixed **left** sidebar (already
right-aligned within that sidebar); each page then builds its own local header
whose top-right slot is reserved for that page's primary action. So "top right
corner" can mean several different things, and which one you want changes how
much layout work this is. The following need your call:

1. **What should "top right corner" actually mean?** There's no persistent
   top bar spanning the screen today.
   - (a) Introduce a **new slim top bar across the top of the main content
     area** and put the toggle at its far right (true viewport top-right), or
   - (b) Keep it in the **sidebar** but ensure it sits at the sidebar's
     top-right (roughly where it is now), or
   - (c) Place it in **each page's existing header row**, top-right.
   *Assumed default:* (a) — add a slim top bar spanning the main content area
   and pin the toggle to its far right, since that's what "top right corner of
   the screen" most naturally means.

2. **Which layouts should change?** The toggle also appears on the
   sign-in/auth screen, which has no sidebar and currently shows it centered
   next to the "Pipeliner" heading.
   *Assumed default:* Change the **main app shell only**; leave the auth
   screen's toggle where it is.

3. **If a new top bar is added, should it hold anything besides the toggle**
   (e.g. breadcrumbs, page title, or the "Sign out" control that currently
   lives at the bottom of the sidebar)?
   *Assumed default:* **Toggle only** — a minimal bar with just the dark mode
   toggle at the right; nothing else moves.

4. **On pages whose header already has a top-right primary action** (New
   Project, New Pipeline, etc.), the toggle and that action would both sit
   top-right. Is a single shared top bar sitting *above* those page headers
   acceptable so they don't compete in the same row?
   *Assumed default:* **Yes** — the toggle lives in the shared top bar above
   the page content, so per-page primary actions keep their own top-right slot
   underneath it.
