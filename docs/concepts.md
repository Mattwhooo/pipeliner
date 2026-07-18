# Pipeliner — Core Concepts

> Working draft. This document defines the domain vocabulary and structural model
> for Pipeliner. It is the reference other design docs build on. Anything marked
> **[OPEN]** is unresolved.

## What Pipeliner is

Pipeliner is an application for managing **agentic pipelines**: structured,
agent-driven processes that take a unit of work from an initial ask all the way
through to a reviewed implementation. Agents (LLMs) do the work inside the
pipeline; Pipeliner orchestrates, sequences, and captures the artifacts.

## The hierarchy

```
Project             the root object; tied 1:1 to a single git repo
└── Pipeline        an end-to-end run; a branch/PR within the project's repo
    └── Phase       one of four fixed stages (see below)
        └── Workflow one or more per phase; a compiled sequence of steps
            └── Step the atomic unit of work
```

- A **Project** is tied **1:1 to a single git repo** and owns **many Pipelines**.
  Pipeliner supports **multiple Projects**. A Project has a **type → template
  pack** (M17) that supplies the default critic set and canonical artifacts —
  `software` is the default; non-code repos (e.g. a `wiki`) select another pack.
  When a Project is added, a **worker onboarding assessment** (C2) verifies the
  repo-native environment is runnable before any pipeline runs.
- A **Pipeline** belongs to one Project and has exactly **four Phases** (fixed,
  ordered, always present).
- A **Phase** contains **one or more Workflows**.
- A **Workflow** is **compiled from one or more Steps**.
- A **Step** is the atomic unit executed within a workflow.

## The four fixed phases

Each phase consumes the artifacts produced by the phases before it.

Directory slugs are fixed: `01-define`, `02-plan`, `03-build`, `04-review`.

| # | Phase       | Dir          | Intent                                                            | Primary inputs          | Primary outputs                      |
|---|-------------|--------------|------------------------------------------------------------------|-------------------------|--------------------------------------|
| 1 | **Define**  | `01-define`  | Iterate until the ask is well-defined and fully explored (non-technical). | The initial ask  | A clear, explored problem definition + business requirements |
| 2 | **Plan**    | `02-plan`    | Convert the definition into technical requirements, design, and documentation. | Phase 1 outputs | Technical design/plan + docs         |
| 3 | **Build**   | `03-build`   | Implement based on the technical plan.                           | Phase 2 outputs         | The implemented code changes         |
| 4 | **Review**  | `04-review`  | Validate what was built against the outputs of Phases 1 & 2.    | Phases 1, 2 & 3 outputs | A pass/fail assessment + findings    |

Key principle: **phase artifacts are first-class data.** Review reads the Define
and Plan outputs directly to judge whether the build matches intent, so every
phase's outputs must be durably captured, versioned, and referenceable.

## Configurable steps: templates, library, and instances

The four phases are **fixed rails**, but **the steps inside them are dynamic** —
configurable in the UI and even selectable by an agent at runtime.

- **Step Template** — a reusable, UI-configurable definition: **type**
  (planner/builder/critic/…), **role** (arbitrary matching label — see below),
  system prompt, default inputs/outputs, and whether it is required or
  conditional. Examples: "Requirements Writer", "Completeness Critic", "UI Testing".
- **Step Library** — the catalog of Step Templates a user can draw from. Users can
  **add, edit, and remove** templates in the UI.
- **Step Instance** — a template placed into a specific pipeline's phase/workflow,
  with resolved inputs/outputs/scope. This is what `step.json` represents on disk
  (see [artifact-schema.md](./artifact-schema.md)).

**Workflow composition has two modes (and a hybrid):**
- **Manual (UI):** the user assembles steps — add/remove/order, edit prompts, wire
  dependencies.
- **Agentic (Planner):** a Planner step examines the task and the **available Step
  Library** and **decides which steps are needed** (e.g. "this task touches the
  UI → include the UI Testing step"), producing the workflow DAG dynamically.
- **Hybrid:** the user pins required/default steps; a Planner conditionally adds
  the rest.

So step *selection* can itself be a step. See *Workflow composition* in
[execution-model.md](./execution-model.md).

## Git binding (foundational constraint)

Pipeliner is exclusively for **software development work against a git codebase.**

- **A Project is bound 1:1 to a git repo.** All of a project's pipelines target
  that one repo. (Repo credentials/remote are configured at the Project level.)
- **A Pipeline is bound 1:1 to a git branch and a PR** in its project's repo, both
  created at pipeline creation time. This **pipeline branch is the pipeline's own
  trunk** (its
  "main") — cut from the repo's real master at creation.
- **All work for a pipeline is confined to that branch.** Every artifact, doc, and
  code change lives on it — the branch is the pipeline's workspace boundary.
- **Each Step runs on its own branch** cut from the pipeline branch and **merges
  back** when done (branch-per-step; see [architecture.md](./architecture.md)).
- **At the end of all four phases**, the pipeline branch *is* the PR — reviewed by
  a human and merged into the repo's real master.
- **The PR is the durable, auditable record** of the pipeline: discovery notes,
  requirements, design docs, the implementation diff, and review findings can all
  be captured on the branch / posted to the PR.
- Consequences per phase:
  - **Phase 3 (Build)** commits code to the branch.
  - **Phase 4 (Review)** reviews the branch/PR diff against Phase 1 & 2 artifacts —
    the PR diff *is* the review surface.
- This also clarifies Steps: they operate against a working tree on a known
  branch, so **git operations are a native part of what a Step can do.**

## Artifacts

An **Artifact** is a durable output produced by a step/workflow/phase (e.g. a
discovery summary, a design doc, a diff, a review report). Downstream phases
reference upstream artifacts as inputs. **[OPEN]** exact artifact types & format.

## Resolved (were open in early drafts)

- **Loops** → both: an intra-phase Manager consensus loop *and* inter-phase rework
  routing. See [execution-model.md](./execution-model.md).
- **Step at runtime** → the atomic unit a Worker pulls and runs (agent invocation +
  its role/inputs/branch/toolset, incl. git ops). See [worker.md](./worker.md).
- **Executor** → model-agnostic Workers (Claude Code or other LLM).
- **"Compiled" workflow** → resolving Steps into an executable DAG (dependencies,
  parallelizable sets, fan-in points, exit conditions).

The live open-questions list is consolidated in [README.md](./README.md).
