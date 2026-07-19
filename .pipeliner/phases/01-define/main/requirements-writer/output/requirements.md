# Business Requirements — Live Pipeline Status Summary

These requirements describe a single, plain-language status summary for each
pipeline that tells a viewer what is happening right now, updates on its own as
work progresses, and is always truthful when a page is first opened.

## Where the summary appears

- **R1.** When a person opens a pipeline's detail page, a single status summary
  for that pipeline should appear above the per-step cards, in the pipeline's
  header area, so it is the first status information on the page.
- **R2.** When a person opens the page that lists all pipelines, each pipeline's
  row should include a compact version of the same status summary, so current
  activity is visible without opening each pipeline. Both surfaces — the
  pipeline detail page and the pipeline list — must show live, current
  summaries; neither may show stale, static status.

## What the summary says

- **R3.** When exactly one step in a pipeline is actively working, the summary
  should name the current phase, the step doing the work, and what that step is
  doing, in plain language (for example: "Define: requirements-writer is
  drafting requirements").
- **R4.** When a step is working on its second or later attempt at its task,
  the summary should also state the attempt number (for example: "iteration 3").
  When a step is on its first attempt, no attempt number should be shown, so the
  common first pass stays short.
- **R5.** When two steps in a pipeline are actively working at the same time,
  the summary should name both steps.
- **R6.** When three or more steps in a pipeline are actively working at the
  same time, the summary should state the current phase and the count of steps
  working (for example: "Build: 4 steps are running") rather than naming each
  one.
- **R7.** When a pipeline is stopped waiting for a person to approve or reject
  something, the summary should say that it is waiting on human approval and
  where (for example: "Waiting on human approval at the Plan gate").
- **R8.** When a pipeline has finished all of its work successfully, the
  summary should say the pipeline is complete.
- **R9.** When a pipeline has stopped because something went wrong and it
  cannot continue on its own, the summary should say the pipeline has failed
  and name the phase or step where it stopped.
- **R10.** When a pipeline exists but has not yet started any work, the summary
  should say it has not started yet.
- **R11.** When a pipeline has been deliberately paused or canceled by a
  person, the summary should say so plainly (for example: "Paused" or
  "Canceled").
- **R12.** When a pipeline is in any state not covered above (including states
  added in the future), the summary should still show a defined, truthful
  plain-language description of that state — the summary must never be blank,
  missing, or describe a state the pipeline is not actually in.
- **R13.** When a summary is shown anywhere, it should use everyday language a
  non-technical reader can understand, with no internal codes, identifiers, or
  jargon.

## How the summary stays current

- **R14.** When any event changes what a pipeline is doing (a step starts,
  finishes, fails, retries, or a gate starts or stops waiting on a person), the
  summary on every open page showing that pipeline should change to the new
  state without the viewer doing anything — the change is pushed to the page as
  a consequence of the event itself, not fetched by the viewer refreshing or
  clicking, and it appears within a few seconds of the event.
- **R15.** When a page showing a summary is first loaded or reloaded, the
  summary should already reflect the pipeline's true state at that moment,
  even if no further events ever arrive.
- **R16.** When events arrive out of order or in quick succession, the summary
  should end up showing the pipeline's actual latest state, never an older
  state overwriting a newer one.

## How the summary looks and reads

- **R17.** When the summary indicates a status (working, waiting, complete,
  failed, paused), that status should be recognizable by its words, not by
  color alone, so it is understandable to people who cannot distinguish colors.
- **R18.** When the summary is shown in its compact form on the pipeline list,
  it should convey the same current state as the full version on the detail
  page — the two surfaces must never disagree about what a pipeline is doing.
