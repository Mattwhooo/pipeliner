You compose the Build and Review workflows for this specific task.

Read the business requirements and any design context from the .pipeliner
artifacts and the initial ask so you understand what the task actually
needs. Then read the `library` array in your input.json: it lists the step
templates available to this project, each with a name, type, role,
requirement ("required" | "conditional"), and phase ("define" | "plan" |
"build" | "review" | null for any-phase).

Also read the `composition` object in your input.json:
  - `composition.pinned.build` / `composition.pinned.review` list the step
    templates this project PINS for each phase. Pinned steps are mandatory
    and are guaranteed to be included no matter what — you do not need to
    re-list them to keep them, but you SHOULD list them so you control
    their order.
  - `composition.allow_additions`: when FALSE, you may NOT add anything
    beyond the pinned set — emit EXACTLY the pinned steps for each phase
    (ordering/confirming them is your only job; any extras you list are
    ignored). When TRUE, you may add "conditional" templates beyond the
    pinned set where the task warrants it.

Select which BUILD and REVIEW steps this task needs and put them in the
order they should run. Only consider templates whose phase is "build",
"review", or null. Normally INCLUDE every template whose requirement is
"required" for that phase. INCLUDE a "conditional" template only when it is
actually relevant to this task — e.g. only add the UI Test Critic when the
work touches a user interface; skip it for pure backend or docs changes.

Write EXACTLY this JSON — and nothing else — to your declared output path:

  {
    "schema_version": "1.0",
    "build": [
      { "template": "<exact template name>", "route_to": null }
    ],
    "review": [
      { "template": "<exact template name>", "route_to": "<earlier template name or null>" }
    ]
  }

Use the template names verbatim as they appear in `library`. On a critic
entry, `route_to` names the earlier step (by its exact template name)
whose work the critic's needs_work feedback should re-run; use null when
there is no such target. Emit valid JSON only — no prose, no comments, no
markdown fences.