# Business Requirements — Dashboard UI

Task: Add UI for the Dashboard
Phase: Define · Step: requirements-writer · Iteration 1

These are atomic business requirements written in plain, non-technical language,
in the form *"When X happens, Y should happen."* They are derived from the ask
("a UI for the Dashboard, probably similar to the Pipelines view, with sensible
defaults for what someone would want to see at a glance") and from the discovery
notes and open-question defaults produced earlier in this phase.

Scope note: the Dashboard is the page a signed-in person lands on first. Its job
is to answer "what should I look at right now?" at a glance and send the person
to the right place for detail. It is a summary, not a second copy of the
Pipelines list.

---

## Access and scope

**R1.** When a signed-in person opens the application, they should land on a
Dashboard page that is clearly titled "Dashboard".

**R2.** When a person who is not signed in tries to open the Dashboard, they
should be asked to sign in first and should not see any Dashboard content.

**R3.** When the Dashboard shows information about pipelines, it should only
include pipelines that belong to projects the signed-in person is a member of,
and should never show pipelines from projects they are not a member of.

## At-a-glance summary numbers

**R4.** When the Dashboard loads, it should show a set of headline summary
numbers near the top of the page so the person can understand the overall state
without scrolling or clicking.

**R5.** When the Dashboard loads, it should show how many of the person's
pipelines are in each status (for example: how many are running, waiting on a
person, blocked or stuck, completed, and draft), so the person can see the shape
of their work at a glance.

**R6.** When one or more of the person's pipelines are paused waiting for a
person to approve or act on them, the Dashboard should show a count of how many
pipelines are currently waiting on a person.

**R7.** When the Dashboard loads, it should show how many workers are currently
online, so the person can tell at a glance whether work can be picked up.

**R8.** When a summary number is zero (for example, no pipelines are waiting on a
person), the Dashboard should still present that number clearly rather than
hiding it, so the person can trust that "zero" means "nothing to worry about
here."

**R9.** When a status or state is shown on the Dashboard, its meaning should
always be conveyed in words and not by color alone, so the information is
readable by everyone regardless of how they perceive color.

## Things that need attention

**R10.** When one or more of the person's pipelines are paused waiting for that
person to approve or act, the Dashboard should show a short "needs your
attention" list of those pipelines so the person knows exactly what is waiting
on them.

**R11.** When a pipeline appears in the "needs your attention" list, selecting it
should take the person to the place where they can review and act on that
pipeline.

**R12.** When none of the person's pipelines are waiting on them, the Dashboard
should make it clear that there is nothing currently needing their attention,
rather than showing an empty area with no explanation.

## Recent activity

**R13.** When the Dashboard loads, it should show a short list of the person's
most recently updated pipelines (the five most recent) so they can quickly return
to what they were last working on.

**R14.** When a recent pipeline is listed, it should show enough at a glance to
identify it — at least its title, the project it belongs to, its current status,
which phase it is in, and how recently it was updated.

**R15.** When a person selects a pipeline in the recent list, they should be
taken to that pipeline's full detail.

**R16.** When a person wants to see the complete list of their pipelines rather
than just the recent few, the Dashboard should provide a clear way to get to the
full Pipelines view.

## Worker health

**R17.** When the Dashboard shows the online-worker count, selecting it should
take the person to the full Workers view for more detail, so the Dashboard stays
a summary rather than duplicating the Workers page.

## First-run and empty states

**R18.** When a signed-in person has no pipelines yet, the Dashboard should show
a friendly first-run message that explains what the page is for and points them
toward creating their first pipeline, rather than showing a page full of zeros.

**R19.** When a section of the Dashboard has nothing to show (for example, no
recent pipelines), that section should show a brief, plainly worded message
explaining that there is nothing there yet, rather than appearing broken or
blank.

## Freshness and reliability

**R20.** When the Dashboard is opened or refreshed, the numbers and lists it
shows should reflect the current state of the person's pipelines and workers at
that moment.

**R21.** When the underlying data changes after the page has loaded, it is
acceptable in this first version for the person to refresh the page to see the
updated numbers; live, automatic updating is not required for this version.

## Consistency with the rest of the app

**R22.** When the Dashboard presents pipeline status, project names, timestamps,
and similar information, it should use the same visual language and wording
already used elsewhere in the application (such as on the Pipelines view), so the
person sees a consistent product.

**R23.** When the person moves between the Dashboard and other pages, the
Dashboard should remain the first item in the main navigation and continue to be
the page reached at the application's home location, with no change to how the
person navigates the app.
