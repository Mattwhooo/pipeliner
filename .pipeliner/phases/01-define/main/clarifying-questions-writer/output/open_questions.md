# Open Questions — Dashboard UI

Context: "Dashboard" is the app root (`home#index`), today a titled placeholder that
says content "will appear here." The ask is to build it out, "probably similar to the
current Pipelines view" (`pipelines#index` — a table of the signed-in user's pipelines
with Title / Project / Status / Phase / Created). The questions below are the decisions
where a human's answer would materially change what we build. Each notes the default
we'll assume if there's no answer at the gate.

---

1. **Does the Dashboard duplicate the Pipelines list, or summarize across it?**
   The ask says "similar to Pipelines," but a landing page that is a second identical
   table is redundant with the existing Pipelines page (both reachable from the sidebar).
   *Default:* Build an at-a-glance **summary** — headline counts by status plus a short
   "recent / needs-attention" list — and link out to the full Pipelines table for the
   complete list, rather than reproducing that table verbatim.

2. **What is the data scope — the signed-in user's pipelines, or everything?**
   `pipelines#index` scopes strictly to pipelines the user is a member of (via
   `memberships`). A dashboard could keep that per-user scope or show org/project-wide
   totals.
   *Default:* Same scope as Pipelines — only pipelines the current user is a member of.

3. **Which metrics count as "at a glance"?**
   Candidates from the data model: pipeline counts by status, current-phase breakdown
   (Define/Plan/Build/Review), number of gates awaiting human approval, count of failed
   or stalled step runs, and online/offline worker count.
   *Default:* Show (a) pipeline totals by status, (b) a count of gates awaiting approval,
   and (c) online worker count — the three things someone checks first — and defer the
   rest.

4. **Should the Dashboard surface actionable items requiring a human (phase gates)?**
   The pipeline has human approval gates (`approvals`, `send_back`). A dashboard is the
   natural place to say "3 pipelines are waiting on you."
   *Default:* Yes — include a "Needs your attention" section listing pipelines paused at a
   gate the user can act on, linking to the phase. If a human says gates aren't the
   priority, we drop it to a simple count.

5. **Should it show worker health, or leave that to the Workers page?**
   A `workers#index` page already exists. Duplicating full worker detail is redundant, but
   a single "N workers online" indicator is cheap and useful.
   *Default:* Show only a compact online-worker count that links to the Workers page — no
   full worker table on the Dashboard.

6. **Do the metrics need to update live, or is on-load (refresh to update) fine?**
   The stack supports Turbo Streams / Solid Cable, and other views broadcast updates.
   Live tiles are more work and more moving parts.
   *Default:* Render on page load only (values current as of last visit/refresh); no live
   Turbo Stream updates in this first version.

7. **Is there a time window on "recent," or is it all-time?**
   "Recent activity / recently updated" needs a bound.
   *Default:* Show the 5 most recently updated pipelines, all-time (no date-range filter or
   controls).

8. **What should the empty / first-run state say and do?**
   The user may have zero pipelines. Pipelines#index handles this with a "No pipelines yet
   — create one from a project page" card.
   *Default:* Mirror that pattern — a friendly empty state pointing the user to Projects to
   create their first pipeline, rather than showing zeroed-out metric tiles.

9. **Should the sidebar "Dashboard" entry and the root route stay as-is?**
   Today root (`/`) is `home#index` and is already the "Dashboard." We assume we're
   enriching that existing page, not adding a new route or renaming nav.
   *Default:* Keep root `home#index` as the Dashboard and enrich it in place; no routing or
   navigation-label changes.
