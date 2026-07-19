# Open Questions — Dashboard UI

These are the decisions where human context would materially change the build.
Each has an **assumed default** we will proceed with if there is no answer at the
gate.

## Placement & navigation

1. **Should the dashboard become the default landing page after sign-in, or live
   as its own nav destination alongside the current landing?**
   *Assumed default:* A dedicated `/dashboard` destination linked from the main
   nav; the current post-sign-in landing is left unchanged.

2. **For a person in more than one project, should the dashboard open aggregated
   across all their projects or scoped to a single (e.g. last-viewed) project?**
   R2 requires both to be reachable; this is only about the initial view.
   *Assumed default:* Open aggregated across all accessible projects, with a
   filter to narrow to one; no per-user "remembered" selection in v1.

## Interaction model

3. **Is the dashboard view-only (navigate to detail views to act), or should
   people be able to act inline — e.g. approve a gate that is waiting for a
   person, or retry a failed task — directly from a card?**
   *Assumed default:* View-only. Every item deep-links to the pipeline detail
   view where the existing actions live (R11, R18).

4. **Should completed and abandoned pipelines be reachable from the dashboard at
   all (e.g. a toggle or "recently finished" strip), or fully out of scope?**
   R10 keeps them out of the active list; this asks whether they are viewable
   anywhere here.
   *Assumed default:* Out of scope for this dashboard; active pipelines only.

## Recent activity

5. **Is there an existing event/activity log to read from, or must this feature
   introduce a persisted record of notable events?**
   This materially changes scope — deriving from current state vs. adding an
   event model and writing to it from services.
   *Assumed default:* Introduce a lightweight, append-only activity/event record
   written from the services that already effect these transitions, and read the
   feed from it.

6. **How should the activity feed be bounded — a fixed count or a time window,
   and roughly what size?** (R17 requires a bound and a "more not shown" cue.)
   *Assumed default:* Most recent 20 events across accessible pipelines, with a
   note that older activity is not shown.

## "Stalled" and worker semantics

7. **What exactly makes a pipeline "stalled"?** e.g. an explicit blocked flag, a
   ready task with no matching available worker, and/or a time-in-state
   threshold before we flag it.
   *Assumed default:* Stalled = explicitly blocked **or** it has a ready step_run
   whose required role no available worker covers; no elapsed-time threshold.

8. **Should worker "not connected" reuse the existing heartbeat/lease timing
   (15s heartbeat, 60s lease), i.e. lease-expired = not connected?**
   *Assumed default:* Yes — a worker past its lease/heartbeat window is shown as
   not connected and excluded from the "available" count (R23).

9. **For the coverage-gap warning (R22), how much detail is wanted — a single
   "some work is uncovered" banner, or the specific uncovered roles named?**
   *Assumed default:* Name the specific uncovered role(s) that have ready work,
   so a person knows what kind of worker to bring online.

10. **What should the "how much work the fleet is doing" metric count (R24)?**
    e.g. only step_runs actively being worked right now, or also queued/ready
    work depth.
    *Assumed default:* Count of currently in-progress (claimed/leased) step_runs;
    queue depth is not shown in v1.

## Freshness & reach

11. **How live must updates be, and by what mechanism?** Real-time push (Turbo
    Streams/Cable) vs. periodic refresh, and what staleness is acceptable if
    push is unavailable. (R26)
    *Assumed default:* Real-time via Turbo Streams over Solid Cable, with a
    periodic (~15–30s) refresh fallback for counts/health.

12. **What device reach is expected — desktop-first, or must the dashboard be
    fully usable on phones?**
    *Assumed default:* Responsive and usable down to tablet width; phone is
    best-effort, not a primary target for v1.
