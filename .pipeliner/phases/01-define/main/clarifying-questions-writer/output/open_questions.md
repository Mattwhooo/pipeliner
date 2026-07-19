# Open Questions — Live pipeline status summary

Questions where human context would materially change the outcome. Each notes
the default we will assume if unanswered.

1. **Which page is "the pipeline board"?** The pipeline show page has the
   four-phase column board; the pipelines index is a table with one row per
   pipeline. Should the live summary appear on the show page only, or also as a
   live-updating column/line per pipeline on the index?
   *Default: both — a prominent banner on the show page, and a compact live
   summary line per row on the index.*

2. **How much detail in the summary line?** The example shows phase + step +
   activity + iteration ("Define: requirements-writer is drafting requirements,
   iteration 3"). Should it also include elapsed time, worker identity, or
   attempt number (after retries)?
   *Default: phase, step, plain-language activity, and iteration only; add a
   relative timestamp ("updated 2m ago") but no worker identity or attempt.*

3. **What when multiple steps run concurrently?** A workflow can have several
   step runs leased at once (e.g. two builders in parallel). One line can't name
   them all. Summarize with a count ("Build: 2 builders running, iteration 2"),
   name the most recently active one, or show multiple lines?
   *Default: single line naming the most recently active step, with a count of
   others ("…and 1 other step running").*

4. **What should trigger a live update?** Options range from every worker
   heartbeat (15s, chatty) to only step_run/phase state transitions. Progress
   records (Steps::RecordProgress) sit in between and would let the summary say
   what a step is doing mid-run.
   *Default: update on state transitions and recorded progress events; ignore
   heartbeats.*

5. **How alarming should degraded states be?** For `stuck`, `blocked`, and
   lease-expired runs, should the summary explain the cause in plain language
   ("Build stuck: no worker with role 'builder' has claimed the step for 10m")
   or just state the status? Cause text risks being wrong or noisy.
   *Default: state the status plus the single most useful fact (which step,
   how long), not a diagnosed cause.*

6. **Should "waiting on human" summaries link to the action?** "Waiting on
   human approval at the Plan gate" could be plain text or include a link/button
   to the gate approval UI.
   *Default: the summary text links to the relevant phase/gate section but adds
   no button; approval stays where it lives today.*

7. **What do finished pipelines show?** For `completed`/`aborted`, should the
   summary area show a final static line ("Completed — merged to main"), or
   disappear entirely to reduce noise on the board?
   *Default: keep a static final line; never an empty/hidden state.*

8. **Step naming in prose.** Steps have kebab-case slugs (`requirements-writer`)
   and arbitrary roles. Should the summary show the raw slug (as in the ask's
   example) or a humanized form ("Requirements writer")?
   *Default: humanized slug, since the audience is a human reading plain
   language; raw slugs remain on the step cards.*

9. **Is "right now" enough, or is recent history wanted?** A single live line
   loses information every time it updates (e.g. you miss that a critic just
   failed a step). Is a short recent-activity ticker in scope, or strictly the
   current-state summary?
   *Default: current-state only; history is out of scope for this task.*
