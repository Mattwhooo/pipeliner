# Open Questions — Human-in-the-Loop Pause (Define phase)

These are the decisions where your input would change the shape of the feature.
Each has an assumed default we'll build if you don't weigh in.

*Iteration 3 — the requirements-completeness critic found two real ambiguities
in the requirements: whether "resume" is meant to be a separate action from
"Done" (no code today distinguishes them — see new question 11), and what you
see while a single-step re-run (Explore, Clarifying Questions) is still in
flight, as opposed to the multi-step restart which already has an answer (see
new question 7). Both are added below; everything else carries forward
unchanged.*

## Scope & trigger

1. **Which steps can be paused at?**
   The ask calls out the clarifying-questions step "especially," but also says
   "anytime during the Define phase." Should the pause control be available at
   *every* Define step (Explore, Requirements, Clarifying Questions, Critic), or
   only at the clarifying-questions step for now?
   *Assumed default:* Available anytime the Define phase is running, with the
   menu surfaced most prominently around the clarifying-questions step.

2. **What does "pause" actually stop?**
   A step already running on a worker can't be frozen mid-flight (workers hold a
   short lease). Pause realistically means "stop starting new work and wait for
   you," letting any in-flight step finish first. Is "finish the current step,
   then hold" acceptable, or do you expect an immediate hard stop?
   *Assumed default:* Finish the current in-flight step, then hold before
   starting anything new.

3. **Who can pause, and from where?**
   Should any human viewing the pipeline be able to pause/resume, and should the
   control live in the existing Define panel on the pipeline page?
   *Assumed default:* Anyone who can view the pipeline can pause/resume, via a
   control in the Define panel.

## The menu loop

4. **Confirm the menu items.**
   We read the loop as four actions plus an exit: **Explore** (re-run the
   codebase exploration), **Clarifying Questions** (re-generate the open
   questions), **Ask Human** (surface questions and capture your answers),
   **Repeat from the Beginning** (restart Define from the first step), and
   **Done** (finish Define and move on). Is that the right set — anything missing
   or unwanted?
   *Assumed default:* Exactly those five.

5. **What does "Ask Human" mean — you answer, or you ask?**
   Today the system only supports the human *answering* the agent's clarifying
   questions. Do you also want to *pose your own* questions/notes for the agent
   to incorporate, or is answering the agent's questions enough?
   *Assumed default:* You answer the agent's clarifying questions (existing
   behavior); free-form notes from you are folded in as feedback on the re-run.

6. **Do you need to see the fresh output before deciding what's next?**
   Nothing in the current app shows you the *result* of a re-run today except
   open questions — discovery notes and other artifacts aren't displayed
   anywhere. If pausing is about giving you feedback, do you want each menu
   action's fresh output (updated discovery notes, updated open questions,
   replaced requirements after a restart) shown to you right there in the
   paused view before you pick the next action, or is it enough to know the
   action finished and look elsewhere if you're curious?
   *Assumed default:* Show the fresh output inline in the paused view,
   extending the same display already used for open questions, so you can read
   it before choosing your next move.

7. **What do you see while Explore or Clarifying Questions is still re-running?**
   Unlike "Repeat from the Beginning" (see question 8, which already has a
   defined "restart in progress" state), nothing yet says what the paused view
   looks like *while* a single-step re-run — Explore or Clarifying Questions —
   is in progress. The closest precedent elsewhere in the app hides a step's
   "re-run" control entirely and shows a live progress line instead, for as
   long as that step is running. Should the whole menu disappear the same way
   (with a live progress line in its place), stay visible but disabled, or stay
   fully active with a separate "in progress" note next to it?
   *Assumed default:* Hide the menu and show a live progress line while the
   single-step re-run is in flight, matching both the existing step-card
   pattern and how "Repeat from the Beginning" already behaves — so the paused
   view treats every in-flight re-run the same way, one step or many.

8. **How hands-on is "Repeat from the Beginning"?**
   Restarting Define means re-running all of its steps in sequence (Explore →
   Requirements → Clarifying Questions → Critic), which isn't instant — it can
   take a couple of minutes as each step completes in turn. Once you trigger a
   restart, should it run through all those steps automatically while you wait
   and then show you the final fresh results, or should it stop and return you
   to the menu after *each* of those steps too, so you're approving the restart
   step-by-step?
   *Assumed default:* Run automatically through all the restart's steps once
   triggered; you see a "restart in progress" state and land back on the full
   menu with fresh results when it's done — you don't have to click through
   each intermediate step.

9. **What does "Repeat from the beginning" do with prior work?**
   The system keeps only the latest version of each artifact (no per-round
   snapshots). When you restart Define, should earlier discovery notes and
   requirements be *replaced* by the fresh run, or should the new run build on
   what's there as added context?
   *Assumed default:* Restart re-runs from the first step and overwrites with
   fresh output, carrying your answers/notes forward as feedback (no snapshot of
   the discarded version).

10. **When you pick a menu action, does the loop keep auto-advancing?**
    After you trigger, say, a re-run of Clarifying Questions, should the
    automatic Define loop resume and carry on to the next steps, or should it
    stop again and return you to the menu after each action so you drive every
    step by hand?
    *Assumed default:* Return to the menu after each action; the automatic loop
    stays paused until you choose **Done**. (You step through manually.)

11. **Is there a separate "Resume" action, or is Done the only way out of the
    paused menu?**
    The drafted requirements describe the automatic loop staying off "until you
    resume or finish," which reads as if resuming and finishing are two
    different things. But nothing in the app has anything like a "hand back to
    fully automatic, without ending Define" button today — every existing way
    out of a held phase is bundled with an action (approve, or re-run something
    specific). So: do you want a distinct **Resume** control that lets Define go
    back to running fully on its own (no more menu, but Define isn't finished
    either), separate from Done — or is "resume" just loose wording for "you
    picked a menu action, which reopens that one step and then returns you to
    the paused menu," with Done as the only true exit?
    *Assumed default:* No separate Resume action. There are exactly two ways to
    leave the paused state: trigger a menu action (which does its thing and
    brings you back to the paused menu, still paused) or choose Done (which
    requires Define to be settled and ends the pause by finishing Define).
    "Resume" isn't a control you'll see — it's just what happens automatically
    once Done is chosen and Define's normal loop takes over for the next phase.

## Exit & interaction

12. **Can you choose "Done" before Define has actually settled?**
    Today, finishing Define requires it to have reached a settled state
    (consensus, or waiting on you) — the approval action is hard-blocked outside
    that state. If you pause mid-loop and choose Done before the steps have
    converged on their own, should that force-finish Define with whatever
    output currently exists (with a clear warning that it's not fully settled),
    or should Done simply not be available yet, prompting you to keep working
    the menu (or wait) until it settles?
    *Assumed default:* Done requires Define to have reached its normal settled
    state first; if you choose Done too early, we tell you it's not ready yet
    rather than force-finishing on unconverged work.

13. **What should you see if a menu action's re-run fails?**
    A re-run you trigger (Explore, Clarifying Questions, a restart step) can
    fail or time out like any other step run. Do you want that called out to
    you directly — kept on the paused menu with a clear failure message — or is
    it acceptable to rely on the same status indicator used elsewhere today,
    which you'd need to notice yourself?
    *Assumed default:* A failed or timed-out menu re-run keeps the phase paused
    and shows a clear failure message in the paused view (label, not just a
    color change) rather than retrying silently or leaving you to spot a badge.

14. **How does pause relate to the automatic "needs more work" loop and the
    iteration cap?**
    Define already loops automatically and stops for you when it can't converge
    or hits its retry cap. Should a manual pause suspend that automatic loop
    entirely until you resume, and should manual re-runs you trigger count
    against the retry cap?
    *Assumed default:* A manual pause suspends the automatic loop until you
    resume; human-triggered re-runs do **not** count against the automatic cap.

15. **Is pause a Define-only feature, or the start of a general capability?**
    The ask is scoped to Define. Should we build this specifically for Define, or
    design it so the same pause/menu could later apply to Plan/Build/Review?
    *Assumed default:* Build for Define now, but structure it so it can generalize
    later without a rewrite.
