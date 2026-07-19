# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The "software" step template pack (docs/phase-playbooks.md, M17): global,
# reusable step definitions covering the four phases. Idempotent by name.
SOFTWARE_PACK = [
  # ── Define ──────────────────────────────────────────────────────────────
  { name: "Codebase Explorer", phase: "define", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Explore the repository and the initial ask. Produce discovery notes: what exists today, what the ask touches, open questions, and constraints. Stay factual.",
    default_outputs: [ { "artifact" => "discovery_notes", "kind" => "artifact", "path" => "output/discovery_notes.md" } ] },
  { name: "Requirements Writer", phase: "define", step_type: "builder", role: "requirements", requirement: "required",
    system_prompt: "From the ask and discovery notes, write detailed, atomic business requirements in the form 'When X happens, Y should happen'. Non-technical language only. Number them (R1, R2...).",
    default_outputs: [ { "artifact" => "business_requirements", "kind" => "artifact", "path" => "output/requirements.md" } ] },
  { name: "Requirements Completeness Critic", phase: "define", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Review the business requirements for completeness and atomicity. Are any user needs missed? Is each requirement testable and singular? Emit a structured verdict with findings." },
  { name: "Clarifying Questions Writer", phase: "define", step_type: "builder", role: "requirements", requirement: "conditional",
    system_prompt: "From the ask and the draft requirements, write the open questions where human context would materially change the outcome: ambiguities, unstated preferences, tradeoffs only the requester can decide. Number them, keep each answerable in a sentence or two, and note your assumed default for each. These are presented to a human at the phase gate. Also emit the same questions as structured JSON: an array of { \"question\", \"default\" } objects (question text only, no numbering) — the product UI renders one input per entry.",
    default_outputs: [
      { "artifact" => "open_questions", "kind" => "artifact", "path" => "output/open_questions.md" },
      { "artifact" => "open_questions_structured", "kind" => "artifact", "path" => "output/open_questions.json" }
    ] },
  # ── Plan ────────────────────────────────────────────────────────────────
  { name: "Workflow Composer", phase: "plan", step_type: "planner", role: "code", requirement: "required",
    system_prompt: <<~PROMPT.strip,
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
    PROMPT
    default_outputs: [ { "artifact" => "workflow_plan", "kind" => "artifact", "path" => "output/workflow_plan.json" } ] },
  { name: "Technical Approach Planner", phase: "plan", step_type: "planner", role: "code", requirement: "required",
    system_prompt: "Read the business requirements and the codebase. Decide the technical approach: what to change, where, and why. Weigh alternatives briefly and commit to one.",
    default_outputs: [ { "artifact" => "technical_approach", "kind" => "artifact", "path" => "output/approach.md" } ] },
  { name: "Design Writer", phase: "plan", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Turn the approach into a technical design: components, data model, interfaces, and a file-level plan of the changes. Cite the requirements each part satisfies.",
    default_outputs: [ { "artifact" => "technical_design", "kind" => "artifact", "path" => "output/design.md" } ] },
  { name: "Work Partitioner", phase: "plan", step_type: "planner", role: "code", requirement: "conditional",
    system_prompt: "Split the design into build tasks with explicitly DISJOINT file scopes so they can run in parallel safely. Shared files (routes, lockfiles, migrations) go to a single integrator task.",
    default_outputs: [ { "artifact" => "build_task_plan", "kind" => "artifact", "path" => "output/build_task_plan.md" } ] },
  { name: "Design Coverage Critic", phase: "plan", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Check the technical design against the business requirements: is every requirement addressed? Anything designed that no requirement asks for? Emit a structured verdict." },
  { name: "Spec Writer", phase: "plan", step_type: "builder", role: "code", requirement: "conditional",
    system_prompt: "From the technical design, write executable specs (this repo uses Minitest) that capture the requirements' observable behavior. Put them in the repo's test directory following its conventions. It is expected that some fail or are skipped until Build implements the design — they define done. Do not implement production code.",
    default_outputs: [ { "artifact" => "specs", "kind" => "repo" } ] },
  { name: "Developer Docs Updater", phase: "plan", step_type: "builder", role: "code", requirement: "conditional",
    system_prompt: "Update the repository's developer documentation (e.g. docs/developer-guide.md) with any new information introduced by this design: new subsystems, models, endpoints, workflows, or conventions a developer would need. Edit the real docs in the repo; keep their existing tone and structure. Do not document things that are unchanged.",
    default_outputs: [ { "artifact" => "developer_docs", "kind" => "repo" } ] },
  { name: "Guide Alignment Critic", step_type: "critic", role: "review", requirement: "conditional",
    system_prompt: "Read guides/backend-guide.md and guides/ui-style-guide.md in this repository, then check the work under review (design, specs, or diff) against them: service/Result patterns, thin controllers, model rules, Tailwind scale and semantic status colors, Turbo conventions, testing expectations. Cite the specific guide rule for each finding. Emit a structured verdict." },
  # ── Build ───────────────────────────────────────────────────────────────
  { name: "Implementer", phase: "build", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Implement the technical design (or your assigned task from the build plan) as real changes to the repository. Follow the repo's conventions and stay within your declared scope.",
    default_outputs: [ { "artifact" => "implementation", "kind" => "repo" } ] },
  { name: "Test Critic", step_type: "critic", role: "code", requirement: "required",
    system_prompt: "Run the repository's tests and linters. Verify the implementation builds and passes. If there is nothing runnable, return not_applicable. Emit a structured verdict with failures as findings. CRITICAL SAFETY RULE: run tests ONLY with the project's standard test command (e.g. bin/rails test — the test environment). NEVER run db:fixtures:load, db:reset, db:drop, db:setup, db:seed, or ANY command that reads or writes a development or production database — the repository you are testing may be the live system orchestrating you, and its development database is shared. If the test suite cannot run safely, return not_applicable with an explanation instead." },
  # ── Review ──────────────────────────────────────────────────────────────
  { name: "Requirements Conformance Critic", phase: "review", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Compare what was built (the diff) against the business requirements from Define. For each requirement: satisfied or not, with evidence. Emit a structured verdict." },
  { name: "Code Quality Critic", phase: "review", step_type: "critic", role: "code-review", requirement: "conditional",
    system_prompt: "Review the diff for correctness bugs, security issues, and quality problems. Ignore style covered by linters. Emit a structured verdict with file-anchored findings." },
  { name: "UI Test Critic", phase: "review", step_type: "critic", role: "ui-tests", requirement: "conditional",
    system_prompt: "Verify the affected UI behaves per the requirements. If a browser is available, exercise the real flows. If NOT, do what is verifiable statically: read the changed views/partials/JS, check states/labels/links against the requirements, and run any UI-relevant unit tests — then report findings for what you could check and return not_applicable ONLY if nothing was verifiable. Never fail solely because a browser is missing. Emit a structured verdict." },
  { name: "Review Report Writer", phase: "review", step_type: "builder", role: "review", requirement: "required",
    system_prompt: "Compile the review critics' verdicts into a single review report suitable for a PR description: what was asked, what was built, evidence of conformance, and open findings.",
    default_outputs: [ { "artifact" => "review_report", "kind" => "artifact", "path" => "output/review_report.md" } ] }
].freeze

if Rails.env.development?
  user = User.find_or_create_by!(email: "dev@pipeliner.local") do |u|
    u.password = "password123"
    u.password_confirmation = "password123"
  end
  puts "Seeded dev user: dev@pipeliner.local / password123"

  SOFTWARE_PACK.each do |attrs|
    template = StepTemplate.find_or_initialize_by(name: attrs[:name], project_id: nil)
    template.assign_attributes(attrs)
    template.save!
  end
  puts "Seeded software template pack (#{StepTemplate.global.count} templates)"

  if ENV["PIPELINER_SEED_DEMO"] == "1"
    # Demo project/pipeline: opt-in only (PIPELINER_SEED_DEMO=1) — real projects
    # are created through the app and must not be resurrected by reseeds.
    project = Project.find_by(repo_url: "https://github.com/mattwatson/pipeliner")
    if project.nil?
      result = Projects::Create.call(owner: user, attributes: {
        name: "Pipeliner",
        repo_url: "https://github.com/mattwatson/pipeliner",
        default_branch: "main",
        project_type: "software"
      })
      raise "Seed failed: #{result.record&.errors&.full_messages}" if result.failure?
      project = result.value
      puts "Seeded default project: #{project.name}"
    end

    # Default pipeline: a sensible first task so the app opens with real content.
    if project.pipelines.none?
      result = Pipelines::Create.call(
        project: project,
        title: "Add a CONTRIBUTING guide",
        initial_prompt: <<~PROMPT
          Add a CONTRIBUTING.md to the repository that explains how to propose a
          change: setting up the dev environment, following the design guides in
          guides/, running tests and rubocop, and what a good PR looks like.
        PROMPT
      )
      raise "Seed failed: #{result.record&.errors&.full_messages}" if result.failure?
      puts "Seeded default pipeline: #{result.value.title}"
    end

    # A starter Define workflow (per docs/phase-playbooks.md) so the board shows
    # real steps and a locally-registered worker has something to claim.
    pipeline = project.pipelines.first
    define_phase = pipeline.phases.find_by!(kind: "define")
    workflow = define_phase.workflows.find_or_create_by!(slug: "main")

    if workflow.steps.none?
      requirements = workflow.steps.create!(
        slug: "requirements", step_type: "builder", role: "requirements", position: 1,
        system_prompt: "From the initial ask, write detailed, atomic business " \
          "requirements in the form 'When X happens, Y should happen'. Stay " \
          "non-technical.",
        outputs: [ { "artifact" => "business_requirements", "kind" => "artifact",
                     "path" => "output/requirements.md" } ]
      )
      completeness = workflow.steps.create!(
        slug: "completeness", step_type: "critic", role: "review", position: 2,
        system_prompt: "Review the business requirements for completeness and " \
          "atomicity. Emit a structured verdict with findings.",
        inputs: [ { "artifact" => "business_requirements", "from" => "../requirements/output" } ]
      )
      workflow.step_edges.create!(from_step: requirements, to_step: completeness,
        kind: "depends_on")
      workflow.step_edges.create!(from_step: completeness, to_step: requirements,
        kind: "route_to")

      requirements.step_runs.create!(state: "ready", required_role: "requirements")
      define_phase.update!(status: "running")
      pipeline.update!(status: "running")
      puts "Seeded Define workflow with #{workflow.steps.count} steps (1 run ready to claim)"
    end
  end
end
