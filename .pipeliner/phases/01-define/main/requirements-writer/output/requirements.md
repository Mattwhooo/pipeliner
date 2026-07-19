# Business Requirements — Live Pipeline Status Summary

Task: Add a single, prominent, real-time plain-language status summary for each
pipeline on the pipeline board.

Note: No discovery notes were provided to this step (iteration 3, empty
inputs); these requirements are derived from the ask alone.

## Requirements

- **R1.** When a user views the pipeline board, each pipeline should show one
  prominent status summary that describes in plain language what that pipeline
  is doing right now.

- **R2.** When a user reads the status summary, it should be written in
  everyday language a non-technical person can understand, not in internal
  codes or abbreviations.

- **R3.** When a pipeline has a step actively working, the status summary
  should say which phase the pipeline is in, which step is working, what that
  step is doing, and which iteration it is on (for example: "Define:
  requirements-writer is drafting requirements, iteration 3").

- **R4.** When a pipeline is waiting for a person to approve or reject
  something, the status summary should say that it is waiting on human
  approval and name the place where approval is needed (for example: "Waiting
  on human approval at the Plan gate").

- **R5.** When a pipeline has work ready but no one has picked it up yet, the
  status summary should say the pipeline is waiting for a worker to start that
  work.

- **R6.** When a pipeline finishes one phase and is preparing to start the
  next, the status summary should describe that transition rather than showing
  stale information from the finished phase.

- **R7.** When more than one step in a pipeline is working at the same time,
  the status summary should still read as a single plain-language sentence
  that fairly reflects the concurrent activity (for example, by naming the
  activities together or summarizing them).

- **R8.** When all of a pipeline's work is finished, the status summary should
  say the pipeline is complete.

- **R9.** When a pipeline stops because something went wrong, the status
  summary should say in plain language that the pipeline needs attention and
  briefly why.

- **R10.** When anything about a pipeline's current activity changes (a step
  starts, finishes, retries, moves to a new iteration, or becomes blocked),
  the status summary on the board should update by itself right away, without
  the user refreshing the page.

- **R11.** When a user opens or reloads the pipeline board page, every status
  summary shown should reflect the true current state of its pipeline at that
  moment — never a cached or out-of-date message.

- **R12.** When several pipelines appear on the board at once, each pipeline's
  status summary should show and update independently; a change in one
  pipeline should not alter another pipeline's summary.

- **R13.** When a status summary changes on screen, only the summary itself
  should update; the rest of the page should stay as it is so the user does
  not lose their place.

- **R14.** When a user looks at a status summary, they should be able to tell
  the pipeline's condition (working, waiting, complete, needs attention) from
  the words themselves, so that someone who cannot distinguish colors still
  understands the status.

- **R15.** When the existing per-step cards are shown, they should continue to
  work as before; the new status summary is in addition to them, not a
  replacement.
