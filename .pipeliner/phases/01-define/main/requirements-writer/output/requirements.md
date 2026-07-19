# Business Requirements — Human-in-the-Loop Pause (Define phase)

These requirements describe the desired behavior in plain, non-technical language.
Each is written as "When X happens, Y should happen." They are grounded in the
ask, the discovery notes (including the iteration-2 findings that ground the
completeness critic's feedback), and the assumed defaults recorded in the
open-questions artifact. Where a requirement depends on one of those assumed
answers, it is noted.

*Iteration 2 — revises the requirements below to close five gaps the
requirements-completeness critic found: fresh output from a menu action was
never shown to the person (R9, R11, R18 below); "Repeat from the Beginning"
being a multi-step restart was unaddressed (R15–R18); a menu re-run's failure
path was unspecified (R24–R25); "Done" being available before Define has
settled was unresolved (R19–R20); and two requirements bundled multiple
independently-testable behaviors, now split (R16/R17, R31/R32/R33).*

## Pausing

**R1.** When a person is viewing a pipeline whose Define phase is running, a
control to pause the Define phase should be visible to them.

**R2.** When a person chooses to pause the Define phase, the system should stop
starting any new work in that phase and should not begin the next step.

**R3.** When a person pauses the Define phase while a step is already in progress,
that in-progress step should be allowed to finish, and the phase should hold only
after it completes rather than being forcibly stopped mid-step.

**R4.** When the Define phase has finished the in-progress step and reached the
held state, the system should clearly show the person that the phase is paused
and waiting for them, using a label and not color alone.

**R5.** When the Define phase is paused, the automatic loop that normally advances
Define from one step to the next should not run again until the person resumes or
finishes.

**R6.** When the Define phase is paused, any human who can view the pipeline should
be able to see the pause state and the available choices.

## The menu of choices while paused

**R7.** When the Define phase is paused, the system should present the person with
a menu offering: Explore, Clarifying Questions, Ask Human, Repeat from the
Beginning, and Done.

**R8.** When the person chooses **Explore** from the paused menu, the system should
re-run the codebase exploration step and produce fresh discovery notes.

**R9.** When the codebase exploration step re-run from **Explore** finishes
successfully, the system should show the person the fresh discovery notes in the
paused view before they choose their next action.

**R10.** When the person chooses **Clarifying Questions** from the paused menu, the
system should re-run the step that generates the clarifying questions and produce
a fresh set of open questions.

**R11.** When the clarifying-questions step re-run from **Clarifying Questions**
finishes successfully, the system should show the person the fresh open questions
in the paused view before they choose their next action.

**R12.** When the person chooses **Ask Human** from the paused menu, the system
should show them the agent's current open clarifying questions and let them submit
answers.

**R13.** When the person submits answers or free-form notes through **Ask Human**,
those answers and notes should be carried into the next re-run as feedback so the
agent takes them into account.

**R14.** When the person chooses **Repeat from the Beginning** from the paused
menu, the system should restart the Define phase from its first step.

**R15.** While the restart triggered by **Repeat from the Beginning** is running
through its steps, the system should show the person a "restart in progress"
state and should not offer the paused menu again until every step of the restart
has finished, since the restart runs several steps in sequence rather than
completing in one action.

**R16.** When the restart triggered by **Repeat from the Beginning** has finished
running all of its steps, the freshly produced results should replace the earlier
results for each affected artifact, with the system keeping only the latest
version.

**R17.** When the Define phase is restarted from the beginning, the person's
previously submitted answers and notes should be carried forward as feedback into
the restart.

**R18.** When the restart triggered by **Repeat from the Beginning** has finished,
the system should return the person to the paused menu and show them the fresh,
replaced results before they choose their next action.

**R19.** When the person chooses **Done** from the paused menu and the Define
phase has reached its normal settled state, the system should treat that as the
existing approval that ends the Define phase and advances the pipeline to the
next phase.

**R20.** When the person chooses **Done** from the paused menu before the Define
phase has reached its normal settled state, the system should tell the person
that Define is not ready to finish yet, rather than ending the phase on
unsettled work.

## Stepping through, one action at a time

**R21.** When the person completes **Explore**, **Clarifying Questions**, or
**Ask Human** from the paused menu, the system should return them to the paused
menu rather than automatically continuing through the remaining Define steps.

**R22.** When the person triggers a re-run of a step from the paused menu, the
phase should remain paused after that re-run finishes so the person stays in
control until they choose Done.

**R23.** When the person keeps choosing menu actions, they should be able to
repeat this loop as many times as they want until they choose Done.

## When a menu-triggered re-run fails

**R24.** When a re-run triggered from the paused menu — Explore, Clarifying
Questions, or a step within a Repeat-from-the-Beginning restart — fails or times
out, the phase should remain paused rather than silently retrying or moving
forward on its own.

**R25.** When a re-run triggered from the paused menu fails or times out, the
system should show the person a clear failure message in the paused view, using
a label and not color alone, and return them to the paused menu so they can
choose what to do next.

## Interaction with the automatic loop and safeguards

**R26.** When the Define phase's automatic "needs more work" loop would normally
retry, and the phase is paused, that automatic retrying should be suspended until
the person resumes or finishes.

**R27.** When the person triggers a re-run of a step from the paused menu, that
manual re-run should not count against the automatic retry limit that the system
uses to decide when to stop on its own.

**R28.** When the person requests a menu action at the same moment the system's
automatic loop would act, the system should ensure only one of them takes effect,
so the person's action and the automatic loop never conflict or double up.

**R29.** When a menu action would start work while a step is still in progress,
the system should prevent starting the new work until the current step has
settled, so two runs of the same step never overlap.

## Non-technical integrity and existing behavior

**R30.** When any pause or menu action is shown to the person, the wording should
stay in plain, non-technical language consistent with the rest of the Define
phase.

**R31.** When the pause feature is in use, the existing way of approving Define
at its normal settled gate should continue to work unchanged.

**R32.** When the pause feature is in use, the existing way of sending Define
back for rework at its normal settled gate should continue to work unchanged.

**R33.** When the pause feature is in use, the existing way of answering
clarifying questions at Define's normal settled gate should continue to work
unchanged.

## Assumptions carried from open questions

These requirements reflect the following assumed answers; a human may override
them, which would revise the affected requirements:

- Pause is available anytime the Define phase is running, surfaced most
  prominently around the clarifying-questions step (R1, R7).
- "Pause" means finish the current step, then hold — not an immediate hard stop
  (R3).
- Anyone who can view the pipeline can pause, resume, and use the menu (R1, R6).
- The menu is exactly the five items listed; "Ask Human" means the person answers
  the agent's questions, with free-form notes folded in as feedback (R7, R12,
  R13).
- Fresh output from Explore, Clarifying Questions, and a completed restart is
  shown to the person inline in the paused view before they choose their next
  action, rather than the person having to look elsewhere for it (R9, R11, R18).
- "Repeat from the Beginning" runs through all of its steps automatically once
  triggered, showing a "restart in progress" state, rather than returning to the
  menu after each intermediate step; it overwrites with fresh output and carries
  answers forward, with no snapshot kept of the discarded version (R15, R16,
  R17).
- After each single-step menu action, the person returns to the menu; the
  automatic loop stays paused until they choose Done (R21, R22, R26).
- A failed or timed-out menu re-run keeps the phase paused and is called out
  clearly to the person, rather than retrying silently or requiring them to
  notice a status indicator on their own (R24, R25).
- "Done" is only available once Define has reached its normal settled state; if
  chosen too early, the person is told it isn't ready rather than the phase
  being force-finished on unconverged work (R19, R20).
- Manual re-runs do not count against the automatic retry cap (R27).
- The feature is built for Define now but should be structured so the same
  pause-and-menu idea can later extend to the other phases without a rewrite.
