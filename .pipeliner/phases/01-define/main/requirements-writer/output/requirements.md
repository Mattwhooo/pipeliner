# Business Requirements — Human-in-the-Loop Pause (Define phase)

These requirements describe the desired behavior in plain, non-technical language.
Each is written as "When X happens, Y should happen." They are grounded in the
ask, the discovery notes, and the assumed defaults recorded in the open-questions
artifact. Where a requirement depends on one of those assumed answers, it is noted.

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

**R9.** When the person chooses **Clarifying Questions** from the paused menu, the
system should re-run the step that generates the clarifying questions and produce
a fresh set of open questions.

**R10.** When the person chooses **Ask Human** from the paused menu, the system
should show them the agent's current open clarifying questions and let them submit
answers.

**R11.** When the person submits answers or free-form notes through **Ask Human**,
those answers and notes should be carried into the next re-run as feedback so the
agent takes them into account.

**R12.** When the person chooses **Repeat from the Beginning** from the paused
menu, the system should restart the Define phase from its first step.

**R13.** When the Define phase is restarted from the beginning, the freshly
produced results should replace the earlier results (the system keeps only the
latest version of each artifact), while the person's previously submitted
answers and notes are carried forward as feedback.

**R14.** When the person chooses **Done** from the paused menu, the system should
treat that as the existing approval that ends the Define phase and advances the
pipeline to the next phase.

## Stepping through, one action at a time

**R15.** When the person completes any single menu action other than Done, the
system should return them to the paused menu rather than automatically continuing
through the remaining Define steps.

**R16.** When the person triggers a re-run of a step from the paused menu, the
phase should remain paused after that re-run finishes so the person stays in
control until they choose Done.

**R17.** When the person keeps choosing menu actions, they should be able to repeat
this loop as many times as they want until they choose Done.

## Interaction with the automatic loop and safeguards

**R18.** When the Define phase's automatic "needs more work" loop would normally
retry, and the phase is paused, that automatic retrying should be suspended until
the person resumes or finishes.

**R19.** When the person triggers a re-run of a step from the paused menu, that
manual re-run should not count against the automatic retry limit that the system
uses to decide when to stop on its own.

**R20.** When the person requests a menu action at the same moment the system's
automatic loop would act, the system should ensure only one of them takes effect,
so the person's action and the automatic loop never conflict or double up.

**R21.** When a menu action would start work while a step is still in progress,
the system should prevent starting the new work until the current step has
settled, so two runs of the same step never overlap.

## Non-technical integrity and existing behavior

**R22.** When any pause or menu action is shown to the person, the wording should
stay in plain, non-technical language consistent with the rest of the Define
phase.

**R23.** When the pause feature is in use, the existing ways of ending or revising
Define at its normal decision point (approving, sending back, and answering
questions at the settled gate) should continue to work unchanged.

## Assumptions carried from open questions

These requirements reflect the following assumed answers; a human may override
them, which would revise the affected requirements:

- Pause is available anytime the Define phase is running, surfaced most
  prominently around the clarifying-questions step (R1, R7).
- "Pause" means finish the current step, then hold — not an immediate hard stop
  (R3).
- Anyone who can view the pipeline can pause, resume, and use the menu (R1, R6).
- The menu is exactly the five items listed; "Ask Human" means the person answers
  the agent's questions, with free-form notes folded in as feedback (R7, R10, R11).
- "Repeat from the Beginning" overwrites with fresh output and carries answers
  forward; no snapshot of the discarded version is kept (R12, R13).
- After each menu action the person returns to the menu; the automatic loop stays
  paused until they choose Done (R15, R16, R18).
- "Done" equals the existing Define approval that advances the phase (R14).
- Manual re-runs do not count against the automatic retry cap (R19).
- The feature is built for Define now but should be structured so the same
  pause-and-menu idea can later extend to the other phases without a rewrite.
