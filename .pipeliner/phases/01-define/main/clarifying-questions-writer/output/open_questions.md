# Open Questions — Dashboard UI

These are the decisions where a person's context would materially change what
gets built. Each has an assumed default; if the default is right, no answer is
needed. Grounded where relevant in what the current data model and existing
gate-approval code actually support.

---

## Confirmed at the previous gate — no action needed

The requester already reviewed and accepted these defaults ("Defaults look
good"), so they're settled and not being re-asked. Restated briefly for the
record; skip straight to the new section below unless something here needs to
change.

- **Worker fleet health** is shown as one shared, global fleet to every user
  (workers carry no project association); unhealthy = not `online` **or** a
  stale heartbeat past the lease window; the role-coverage warning (claimable
  work no online worker can serve) is in scope for v1.
- **Recent activity** is assembled from `approvals`, `manager_decisions`,
  `rework_events`, and `step_run` transitions (no new activity/audit table);
  shows the latest ~15 events across the user's projects, newest first, no
  time cutoff.
- **Active pipelines** count as "needing attention" when awaiting a human gate
  or blocked/stuck; up to ~10 shown, attention-first then most-recent, with a
  link to the full list; the multi-project view is purely aggregated (no
  filter/switcher in v1).
- **Live updates:** pipeline status and activity push live via Turbo Streams;
  worker-fleet health refreshes on a light periodic cadence rather than
  streaming every heartbeat.
- The dashboard becomes the signed-in app root (no separate landing page to
  preserve).

---

## New: answering open questions from the dashboard (R36–R50)

This section is genuinely new since the last gate. The feedback that drove it
("a nice UI... modal with dedicated input boxes... defaults as default text")
specifies the front end clearly. Better still, the mechanism it needs to
drive already exists: `Phases::AnswerQuestions`
(`app/services/phases/answer_questions.rb`), and an inline free-text version
of this exact box already lives today on the pipeline show page
(`app/views/pipelines/_define_panel.html.erb:73-84` — a `<textarea
name="answers">` posting to `answers_phase_path`). That's the "one big
free-text box" the requirements describe — not the separate `/phases/:id`
gate screen, which is a different, more general approve/send-back UI. What's
still open is how the new structured modal maps onto that one-string service.

**Q11. `Phases::AnswerQuestions` always routes answers to "the first
worker-executed step by position" (its own code comment names this "the
requirements writer") — not necessarily the step that authored
`open_questions.md`. Is reusing that exact targeting unchanged correct for
the dashboard modal?**
*Assumed default:* Yes — reuse the existing targeting as-is, with no
step-picker in the modal (unlike the generic `/phases/:id` gate screen, which
does expose a step dropdown for the unrelated free-form send-back case).

**Q12. `Phases::AnswerQuestions#call(answers:)` takes one plain string and
writes exactly one feedback item (`{"from" => "human", "issue" => <the whole
string>, "severity" => "major"}`) — there's no per-question attribution
today. R39 wants each question in its own labeled input; R43 wants all the
answers "sent together as a single submission." Should the modal compose its
structured per-question answers into one formatted string (e.g. numbered
"Q: ... / A: ..." pairs) and submit through the *existing* service unchanged,
or does the service / `StepRun#feedback` need extending to accept one item
per question?**
*Assumed default:* Compose one formatted text block and submit through
`Phases::AnswerQuestions` unchanged — keeps this a UI-only change with no
service or data-model edits. Confirm if per-question attribution in the
feedback array is wanted instead (cleaner signal for the next worker pass, at
the cost of touching `AnswerQuestions` and the `StepRun#feedback` shape).

**Q13. `Phases::AnswerQuestions#answerable?` hard-requires
`@phase.define_phase?` — answering is Define-only today, by validation, not
just convention. Should the dashboard modal likewise only ever appear for a
pipeline's Define-phase gate, or does v1 need it to work for any phase?**
*Assumed default:* Define-only for v1, matching the only phase that produces
an open-questions-style artifact and the only phase the existing service
supports. R50 already hides the action wherever it doesn't apply, so this
falls out naturally with no extra work. Extending answering to other phases
would be new scope, not just a UI change.

**Q14. Once the dashboard modal exists, does the inline free-text "answers"
box on the pipeline show page (`_define_panel.html.erb:73-84`) get removed,
or stay as a second way to do the same thing?**
*Assumed default:* Remove it — having two UIs for the same action (one
free-text, one structured) invites drift and confusion. The separate
`/phases/:id` approve/send-back screen is unaffected either way; it serves a
broader purpose than open-questions answering.

*(Note: R47's "loop busy" case is already a defined failure mode —
`Phases::AnswerQuestions` returns `Result.failure(:busy, ...)` whenever any
step in the phase has an active run. The dashboard modal just needs to
surface that failure and preserve the user's typed input, per R47; no new
decision needed here.)*
