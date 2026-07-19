# Open Questions — Dashboard UI

These are the decisions where a person's context would materially change what
gets built. Each has an assumed default; if the default is right, no answer is
needed. Grounded where relevant in what the current data model actually supports.

---

## Worker fleet health

**Q1. Should every user see the same global worker fleet, or only workers
relevant to their own projects?**
Workers today are a shared, global pool — they carry no project association
(`workers` has no `project_id` and no membership link). So "worker fleet health"
is inherently the whole fleet, identical for every signed-in user, not something
scoped to the viewer's projects like the rest of the dashboard.
*Assumed default:* Show the single global fleet to every signed-in user, and word
the section so it's clearly shared infrastructure rather than "your" workers.

**Q2. What makes a worker count as unhealthy — its stored status, or a stale
heartbeat?**
A worker has both a `status` (online / draining / offline) and a
`last_heartbeat_at`. A worker could read "online" but have gone silent past its
lease (~60s per the design docs). R27 says "not heard from recently enough."
*Assumed default:* Treat a worker as unhealthy/offline if it is not `online`
**or** its last heartbeat is older than the lease window (~60s), so a crashed
"online" worker still shows as down. Confirm the exact staleness threshold.

**Q3. For R28 ("work waiting that no worker can pick up"), is the role-matching
check in scope for v1?**
Detecting this means cross-referencing queued/claimable step_runs against the
`supported_roles` of currently-online workers — a real computation, not just a
count.
*Assumed default:* Yes — flag a warning when there is claimable work whose role
no online worker supports. If that's too much for v1, we'd fall back to only the
simpler signal "work is waiting and zero workers are online."

## Recent activity

**Q4. What counts as an "activity event," given there is no activity log to read
from?**
There is no events/activity table. A feed has to be assembled from existing
records — e.g. `approvals`, `manager_decisions`, `rework_events`, completed
`step_runs`, and pipeline start/finish transitions.
*Assumed default:* Build the feed from exactly those sources, surfacing the event
types named in R19 (phase approved, sent back for rework, pipeline finished, a
piece of work completing). Adding a dedicated activity/audit table is out of
scope for this dashboard.

**Q5. Is "recent" a fixed count or a time window?**
R24 wants a digestible window ("latest handful").
*Assumed default:* Show the latest N events (assume 15) across all the user's
projects, with no time cutoff, newest first. Confirm N and whether a time cap
(e.g. last 7 days) should also apply.

## Active pipelines

**Q6. Which concrete pipeline states map to "needs a person's attention"?**
R6, R13, and R14 lean on this both for the headline count and for visual
emphasis, but "needs attention" isn't a single stored field.
*Assumed default:* Count a pipeline as needing attention when it is waiting on a
human gate/approval, or is blocked/stuck (cannot self-progress). "Running
normally" is everything else active. Confirm this grouping and the exact wording
of the status labels shown to users.

**Q7. How many active pipelines before we paginate / "see the rest" (R18)?**
*Assumed default:* Show up to ~10 on the dashboard, ordered attention-first then
most-recently-active, with a link to a full pipelines list for the remainder.

**Q8. Should the aggregated multi-project view include a project filter/switcher,
or stay purely combined?**
R3 asks for all projects together with each item labeled by project.
*Assumed default:* Purely aggregated with per-item project labels; no filter or
per-project toggle in v1.

## Live updates and landing

**Q9. Must all three areas update live via push, or is periodic refresh
acceptable for some?**
R31 asks for updates without manual reload. Pipeline and activity changes fit
Turbo Stream broadcasts naturally; worker heartbeats change every ~15s and could
thrash a live feed.
*Assumed default:* Push live updates for active-pipeline status and new activity
via Turbo Streams; refresh worker-fleet health on a light periodic cadence rather
than streaming every heartbeat. Confirm this split is acceptable.

**Q10. Does the dashboard become the authenticated app root, replacing the
current landing page?**
R1 says a signed-in user should land here by default.
*Assumed default:* Yes — the dashboard becomes the post-sign-in root. Confirm
there's no existing landing screen that must remain the root instead.
