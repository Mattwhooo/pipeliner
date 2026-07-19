# Open Questions — Human-in-the-Loop Pause (Define phase)

These are the decisions where your input would change the shape of the feature.
Each has an assumed default we'll build if you don't weigh in.

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

6. **What does "Repeat from the beginning" do with prior work?**
   The system keeps only the latest version of each artifact (no per-round
   snapshots). When you restart Define, should earlier discovery notes and
   requirements be *replaced* by the fresh run, or should the new run build on
   what's there as added context?
   *Assumed default:* Restart re-runs from the first step and overwrites with
   fresh output, carrying your answers/notes forward as feedback (no snapshot of
   the discarded version).

7. **When you pick a menu action, does the loop keep auto-advancing?**
   After you trigger, say, a re-run of Clarifying Questions, should the automatic
   Define loop resume and carry on to the next steps, or should it stop again and
   return you to the menu after each action so you drive every step by hand?
   *Assumed default:* Return to the menu after each action; the automatic loop
   stays paused until you choose **Done**. (You step through manually.)

## Exit & interaction

8. **What counts as "done"?**
   Is "done" the same as the existing approval that ends Define and moves to the
   next phase, or a separate "I'm finished pausing" that then still needs a final
   approval?
   *Assumed default:* "Done" = the existing Define approval; choosing it ends the
   pause and advances the phase.

9. **How does pause relate to the automatic "needs more work" loop and the
   iteration cap?**
   Define already loops automatically and stops for you when it can't converge or
   hits its retry cap. Should a manual pause suspend that automatic loop entirely
   until you resume, and should manual re-runs you trigger count against the
   retry cap?
   *Assumed default:* A manual pause suspends the automatic loop until you
   resume; human-triggered re-runs do **not** count against the automatic cap.

10. **Is pause a Define-only feature, or the start of a general capability?**
    The ask is scoped to Define. Should we build this specifically for Define, or
    design it so the same pause/menu could later apply to Plan/Build/Review?
    *Assumed default:* Build for Define now, but structure it so it can generalize
    later without a rewrite.
