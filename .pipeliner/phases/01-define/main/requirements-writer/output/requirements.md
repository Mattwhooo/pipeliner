# Business Requirements — Dashboard UI

## The ask

Add a dashboard that gives an at-a-glance overview of the system: the active
pipelines and where each one stands, a feed of recent activity, and the health
of the worker fleet doing the work.

## Scope and vocabulary (plain language)

- A **project** is one codebase. A **pipeline** is one unit of work moving through
  four fixed stages — **Define → Plan → Build → Review** — called **phases**.
- A pipeline is **active** when it is still being worked on (it has not finished
  successfully and has not been abandoned).
- A pipeline can be **waiting for a person** to make a decision, or **stalled**
  because it is blocked or because no available worker can pick up its next task.
- **Workers** are the machines/agents that actually do the steps. Each worker is
  **available**, **winding down**, or **not connected**, and each advertises the
  kinds of tasks it can handle. Work only gets done if an available worker can
  handle the task at hand.

These requirements describe *what* the dashboard must do, in non-technical terms.
They do not prescribe layout or technology.

---

## Access and scoping

- **R1.** When a signed-in person opens the dashboard, the system should show them
  an overview built only from the projects they are a member of, and never include
  pipelines, activity, or workers belonging to projects they cannot access.

- **R2.** When a person who is a member of more than one project opens the
  dashboard, the system should let them see the overview across all their projects
  and also narrow it to a single project.

- **R3.** When a person who has no accessible projects (or no pipelines yet) opens
  the dashboard, the system should show a friendly empty state that explains there
  is nothing to display yet, rather than a blank or broken screen.

---

## At-a-glance summary

- **R4.** When the dashboard loads, it should show a small set of headline counts
  at the top: how many pipelines are active, how many are waiting for a person, how
  many are stalled and need attention, and how many workers are currently
  available.

- **R5.** When any headline count is greater than zero for an item that needs
  attention (pipelines waiting for a person, or stalled pipelines), the dashboard
  should make that count stand out so it is noticeable at a glance.

---

## Active pipelines and their status

- **R6.** When there are active pipelines the person can access, the dashboard
  should list each one and, for each, show which project it belongs to, which of
  the four phases it is currently in, and its current status.

- **R7.** When a pipeline is shown, the dashboard should indicate its progress
  through the four phases (Define, Plan, Build, Review) so a person can tell how
  far along it is without opening it.

- **R8.** When a pipeline is waiting for a person to make a decision, the dashboard
  should clearly flag it as needing human input and make it easy to find among the
  other pipelines.

- **R9.** When a pipeline is stalled — because it is blocked, or because no
  available worker can handle its next task — the dashboard should clearly flag it
  as needing attention and, where known, briefly say why it is stalled.

- **R10.** When a pipeline has finished successfully or been abandoned, the
  dashboard should leave it out of the active list by default, so the active list
  stays focused on work still in progress.

- **R11.** When a person selects a pipeline from the dashboard, the system should
  take them to that pipeline's detailed view.

- **R12.** When there are no active pipelines to show, the dashboard should show a
  clear empty state in place of the active-pipelines list rather than an empty gap.

- **R13.** When a pipeline's status is shown, the dashboard should convey that
  status in a way that does not rely on color alone, so the meaning is clear to
  people who cannot distinguish colors.

---

## Recent activity

- **R14.** When notable events happen across the person's accessible pipelines —
  for example a pipeline is started, a phase is completed or approved, work is sent
  back to an earlier phase, a person makes a decision, or a task fails — the
  dashboard should record them in a recent-activity feed.

- **R15.** When the recent-activity feed is shown, it should list events with the
  most recent first.

- **R16.** When an activity entry is shown, it should say in plain language what
  happened, which pipeline and project it relates to, and how long ago it occurred.

- **R17.** When there has been a lot of activity, the dashboard should show only a
  recent, bounded set of events (for example the most recent handful, or those from
  a recent time window) rather than an unbounded history, and should make clear that
  older events are not all shown.

- **R18.** When a person selects an activity entry that refers to a specific
  pipeline, the system should take them to that pipeline.

- **R19.** When there has been no recent activity, the dashboard should show a clear
  empty state for the activity feed.

---

## Worker fleet health

- **R20.** When the dashboard loads, it should show the current state of the worker
  fleet: how many workers are available, how many are winding down, and how many are
  known but not currently connected.

- **R21.** When workers are connected, the dashboard should show which kinds of
  tasks the fleet can currently handle (the roles the available workers cover).

- **R22.** When there is a task ready to run whose required kind of work is not
  covered by any available worker, the dashboard should surface this coverage gap as
  a warning, so a person understands why affected pipelines cannot progress.

- **R23.** When a worker stops reporting in (its check-ins go stale), the dashboard
  should reflect that worker as not connected rather than continuing to count it as
  available.

- **R24.** When the dashboard loads, it should show how much work the fleet is
  currently doing — for example how many tasks are actively being worked on right
  now.

- **R25.** When no workers are connected at all, the dashboard should clearly warn
  that no work can be picked up until a worker connects.

---

## Freshness and live updates

- **R26.** When the underlying state changes while a person is viewing the dashboard
  — a pipeline advances, an event occurs, or a worker connects or drops — the
  dashboard should reflect the change promptly without the person having to manually
  reload the page.

- **R27.** When time-based information is shown (such as how long ago an event
  happened or when a worker last checked in), the dashboard should express it in
  clear relative terms (for example "2 minutes ago").

- **R28.** When the dashboard cannot currently load one of its sections, it should
  show a clear, contained message for that section and still display the sections
  that are available, rather than failing the whole page.
