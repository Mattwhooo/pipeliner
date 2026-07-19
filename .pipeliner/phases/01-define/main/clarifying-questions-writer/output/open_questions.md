# Open questions — Live pipeline status summary

Questions where human context would materially change the requirements. Each
lists the assumed default we will proceed with if unanswered.

1. **Which surfaces count as "the pipeline board"?** The pipeline show page has
   the phase-column board, but the pipelines index is a table with one row per
   pipeline. Should the live summary appear on the show page only, or also as a
   live-updating cell/line per row on the index?
   *Assumed default:* both — a prominent summary line in the show-page header
   area and a compact version replacing/augmenting the static Status + Phase
   columns on the index.

2. **What should the summary say when several step runs are active at once?**
   Workflows can run steps in parallel, so "X is drafting, iteration 3" may not
   be a single sentence. Pick one "most interesting" run, or aggregate?
   *Assumed default:* aggregate — name the steps when there are two or fewer
   ("Build: coder and tester are running"), otherwise a count ("Build: 3 steps
   running, iteration 2").

3. **Is the sentence composed deterministically from state, or do you want
   LLM-written summaries?** "Plain language" could mean template sentences built
   from pipeline/phase/step-run state, or a model-generated narrative.
   *Assumed default:* deterministic templates in a PORO (per backend guide) —
   cheap, testable, always truthful; no LLM involvement.

4. **How much detail for unhealthy states?** For `stuck`, `failed`, `blocked`,
   or a lease-expired run, should the summary include the cause ("coder's worker
   lease expired 2m ago", "attempt 3 failed") or stay at a neutral one-liner
   ("Build is stuck — needs attention")?
   *Assumed default:* one level of cause where it's cheaply available (step name
   + state, e.g. "Stuck: coder's worker stopped responding"), no error text.

5. **Should the summary call out "no worker available"?** A step run can sit in
   `ready` with no worker of the required role polling. That's actionable for
   the operator but noisier than "Waiting to start".
   *Assumed default:* yes — after a short grace period show "Waiting for a
   <role> worker" rather than a generic waiting message.

6. **Do you want elapsed-time / liveness in the text?** e.g. "…drafting
   requirements, iteration 3 (4m)". This requires client-side ticking or
   periodic re-broadcasts beyond pure Turbo Stream state changes.
   *Assumed default:* no timers in v1 — the summary changes only on state
   transitions, which keeps it strictly event-driven and always accurate on
   page load.

7. **Iteration wording:** always show the iteration number, or only once a
   consensus loop has actually looped (iteration ≥ 2)?
   *Assumed default:* only when iteration ≥ 2, to keep the common first-pass
   case short.

8. **Is the summary plain text or interactive?** e.g. should "Waiting on human
   approval at the Plan gate" link directly to the approval action?
   *Assumed default:* plain text with the standard status badge treatment
   (icon + color per the UI guide, never color alone); navigation stays where
   it is today. A direct link to the gate can be a follow-up.
