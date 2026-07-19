# Business Requirements — Dashboard UI

## Purpose

Give a signed-in user a single landing screen that answers, at a glance: what
pipelines are running right now and where each one stands, what has happened
recently, and whether the fleet of workers doing the work is healthy. Everything
below is written as observable behavior in non-technical terms.

## Scope note

The dashboard summarizes information the user already has the right to see (the
projects they belong to). It is a read-and-navigate surface: it shows status and
lets the user jump to the relevant detail screen. It does not create, edit, or
delete pipelines, workers, or activity itself.

---

## Access and landing

- **R1.** When a signed-in user opens the application, they should land on the
  dashboard by default.
- **R2.** When a user who is not signed in tries to open the dashboard, they
  should be sent to sign in first, and returned to the dashboard once signed in.
- **R3.** When a user belongs to more than one project, the dashboard should show
  information for all of their projects together, and each item should clearly
  indicate which project it belongs to.
- **R4.** When a user belongs to no projects yet, the dashboard should show a
  friendly empty state that explains there is nothing to display and points them
  toward creating or joining a project.

## Overall layout and at-a-glance summary

- **R5.** When the dashboard loads, it should present three clearly separated
  areas: active pipelines, recent activity, and worker fleet health.
- **R6.** When the dashboard loads, it should show a short summary of headline
  numbers — for example, how many pipelines are currently active, how many need a
  person's attention, and how many workers are online — so the overall state is
  readable without scrolling.
- **R7.** When any count in the headline summary is zero, that figure should still
  be shown (as zero) rather than hidden, so the user can trust the numbers are
  complete.

## Active pipelines overview

- **R8.** When there are pipelines that are active (not finished, cancelled, or
  still an unstarted draft), each should appear in the active-pipelines area.
- **R9.** When a pipeline is shown, it should display its title and the project it
  belongs to.
- **R10.** When a pipeline is shown, it should display which of the four phases it
  is currently in — Define, Plan, Build, or Review — and make clear how far along
  the four phases it is.
- **R11.** When a pipeline is shown, it should display its current status (for
  example: running, waiting for a person, blocked, or stuck) in plain language.
- **R12.** When a pipeline's status is conveyed visually, its meaning should not
  rely on color alone — a label or icon should also carry the meaning so it is
  readable by everyone.
- **R13.** When a pipeline needs a person to act (for example, it is waiting for a
  human approval), it should be visually distinguished so the user can spot it
  immediately.
- **R14.** When a pipeline is stuck or blocked (it cannot make progress on its
  own), it should be clearly flagged as needing attention and stand apart from
  pipelines that are progressing normally.
- **R15.** When a pipeline is shown, it should indicate when it was last active, so
  the user can tell whether it is moving or has gone quiet.
- **R16.** When the user selects a pipeline in the overview, they should be taken
  to that pipeline's own detailed screen.
- **R17.** When there are no active pipelines, the active-pipelines area should
  show an empty state saying so, rather than appearing broken or blank.
- **R18.** When there are more active pipelines than can be comfortably shown at
  once, the dashboard should present the most relevant ones first (those needing
  attention, then the most recently active) and offer a way to see the rest.

## Recent activity

- **R19.** When notable events happen across the user's projects — such as a phase
  being approved, a pipeline being sent back for rework, a pipeline finishing, or a
  piece of work completing — they should appear in the recent-activity area.
- **R20.** When a recent activity item is shown, it should describe in plain
  language what happened, which pipeline and project it relates to, and when it
  happened.
- **R21.** When recent activity is listed, the most recent events should appear
  first.
- **R22.** When the user selects a recent activity item, they should be taken to
  the pipeline or detail screen that the event relates to.
- **R23.** When there has been no recent activity, the recent-activity area should
  show an empty state saying there is nothing recent, rather than appearing broken.
- **R24.** When activity is displayed, it should be limited to a recent, digestible
  window (for example, the latest handful of events) rather than the full history,
  keeping the dashboard an at-a-glance view.

## Worker fleet health

- **R25.** When the dashboard loads, the worker-fleet area should show how many
  workers are currently online, and how many are offline or unavailable.
- **R26.** When individual workers are shown, each should display its name, whether
  it is online, offline, or winding down, and when it was last heard from.
- **R27.** When a worker has not been heard from recently enough to be considered
  healthy, it should be clearly flagged as offline or unhealthy.
- **R28.** When work is waiting that no available worker is able to pick up, the
  fleet area should surface this as a warning, so the user understands why
  pipelines may be stuck.
- **R29.** When there are no workers registered at all, the fleet area should show
  an empty state explaining that no workers are connected.
- **R30.** When the overall fleet is unhealthy (for example, no workers are online
  while work is waiting), the dashboard should make this prominent rather than
  burying it.

## Freshness and live updates

- **R31.** When the underlying information changes while the user is viewing the
  dashboard — a pipeline advances a phase, a new activity event occurs, or a
  worker goes online or offline — the affected part of the dashboard should update
  to reflect the change without the user having to manually reload the page.
- **R32.** When the dashboard shows time-based information (such as "last active"
  or "last heard from"), it should be expressed in a way that stays meaningful as
  time passes (for example, relative to now).
- **R33.** When the dashboard cannot load a piece of information, it should show a
  clear message for that section and still display the sections that did load,
  rather than failing the whole screen.

## Responsiveness and accessibility

- **R34.** When the dashboard is viewed on a smaller screen, its three areas should
  reflow to remain readable and usable rather than overflowing.
- **R35.** When status is communicated anywhere on the dashboard, it should be
  understandable without relying on color alone, consistent with R12.
