# Define summary — Move the dark mode toggle

**The ask:** "I want to move the dark mode toggle to the top right corner."

**In one line:** The dark mode toggle will move out of the sidebar's top row and
down to the sidebar's footer, sitting next to the **"Sign out"** button. Nothing
else changes — same toggle, same behavior, and the sign-in screen is untouched.

---

## 1. What was decided

When we looked at the app, there is **no top bar across the top of the screen**
today. The toggle currently lives in the top row of the left sidebar. So "top
right corner" needed clarification, and a few questions were raised. Here is
what you told us and what each answer settled:

| Question raised | Your answer | Decision it drove |
| --- | --- | --- |
| What should "top right corner" mean, since there's no top bar today? (a) add a new slim top bar, (b) keep it in the sidebar's top-right, or (c) put it in each page's header row? | *"Let's actually put it near the sign out button instead."* | The toggle moves to the **sidebar footer**, paired with the "Sign out" control. It leaves its current top-row spot. |
| Should a **new top bar** be added to hold the toggle? | *"No top bar."* | **No new top bar or layout region** is introduced. This stays a move within the existing sidebar. |
| Even if a top bar sat *above* each page's existing "New Project / New Pipeline" button so they don't compete — is that acceptable? | *"No top bar."* | Confirmed: no top bar under any variation. Each page's own primary action stays where it is. |
| Which layouts should change? The toggle also appears on the **sign-in screen**. | *"None"* (i.e. leave the sign-in screen alone). | The **sign-in / auth screen is unchanged** — its toggle keeps its current position. |

**No open questions remain.** The task is fully defined.

---

## 2. Business requirements

These are the requirements this task will be judged "done" against, verbatim:

**R1.** When a signed-in person views any page in the app, the dark mode toggle
should no longer appear in the top row of the sidebar.

**R2.** When a signed-in person views any page in the app, the dark mode toggle
should appear in the sidebar's bottom area, next to the "Sign out" control,
rather than at the top of the sidebar.

**R3.** When a signed-in person looks at the sidebar's bottom area, the dark
mode toggle and the "Sign out" control should appear together as a clearly
related pair, so it's obvious both controls belong to the same footer section.

**R4.** When a person clicks or taps the dark mode toggle in its new location,
it should switch the app between light and dark mode exactly as it does today —
only its position is changing, not its behavior.

**R5.** When a person uses the keyboard to navigate the sidebar, the dark mode
toggle should remain reachable by keyboard and show a visible focus indicator in
its new location, the same as it does today.

**R6.** When a person visits the sign-in screen, the dark mode toggle should
stay exactly where it is today. This change does not affect the sign-in screen.

**R7.** When the dark mode toggle is moved, no other sidebar element (navigation
links, the "Sign out" control, the user's displayed email) should change
position or behavior as a result.

---

## 3. What the downstream work looks like

This is a small, contained front-end change: one toggle button moves from the
top of the sidebar to its footer, reusing the existing toggle exactly as-is
(there is only one copy of it in the code, so there's nothing to duplicate). The
Workflow Planner laid out a lightweight but properly reviewed path through the
next three phases:

### Plan phase — decide the approach before touching code
- **Design Writer** — writes down how the move should be done (where in the
  footer the toggle sits and how it pairs with "Sign out").
- **Design Coverage Critic** — checks that design covers every requirement
  above; sends it back to the Design Writer if anything's missing.
- **Technical Approach Planner** — nails down the concrete technical approach.
- **Workflow Composer** — finalizes the plan for the build.

### Build phase — make the change
- **Implementer** — makes the actual edit: moves the toggle into the sidebar
  footer next to "Sign out."
- **Test Critic** — verifies the change is properly tested; routes back to the
  Implementer if test coverage falls short.

### Review phase — confirm it's correct and on-standard
- **Guide Alignment Critic** — confirms the change follows the project's UI style
  guide (semantic colors, shared component reuse, accessibility).
- **Code Quality Critic** — checks the code is clean and well-structured.
- **UI Test Critic** — confirms the toggle still works and looks right in the UI
  (included because this task touches the user interface).
- **Requirements Conformance Critic** — checks the finished work against R1–R7
  above.
- **Review Report Writer** — writes the final review summary for approval.

**Why this shape fits:** the task is view-only (no backend, database, or business
logic), so the plan skips backend-heavy steps and keeps a single, focused build.
The UI Test Critic is included specifically because this is a visible UI change,
and every requirement — including the "don't break anything else" and
"keyboard/accessibility unchanged" ones (R5, R7) — has a critic that checks it
before the work is considered done.

---

*Approving Define confirms that the decisions in Section 1, the requirements in
Section 2, and the downstream plan in Section 3 correctly capture what "done"
means for moving the dark mode toggle.*
