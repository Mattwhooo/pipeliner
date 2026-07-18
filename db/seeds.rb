# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The "software" step template pack (docs/phase-playbooks.md, M17): global,
# reusable step definitions covering the four phases. Idempotent by name.
SOFTWARE_PACK = [
  # ── Define ──────────────────────────────────────────────────────────────
  { name: "Codebase Explorer", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Explore the repository and the initial ask. Produce discovery notes: what exists today, what the ask touches, open questions, and constraints. Stay factual.",
    default_outputs: [ { "artifact" => "discovery_notes", "kind" => "artifact", "path" => "output/discovery_notes.md" } ] },
  { name: "Requirements Writer", step_type: "builder", role: "requirements", requirement: "required",
    system_prompt: "From the ask and discovery notes, write detailed, atomic business requirements in the form 'When X happens, Y should happen'. Non-technical language only. Number them (R1, R2...).",
    default_outputs: [ { "artifact" => "business_requirements", "kind" => "artifact", "path" => "output/requirements.md" } ] },
  { name: "Requirements Completeness Critic", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Review the business requirements for completeness and atomicity. Are any user needs missed? Is each requirement testable and singular? Emit a structured verdict with findings." },
  # ── Plan ────────────────────────────────────────────────────────────────
  { name: "Technical Approach Planner", step_type: "planner", role: "code", requirement: "required",
    system_prompt: "Read the business requirements and the codebase. Decide the technical approach: what to change, where, and why. Weigh alternatives briefly and commit to one.",
    default_outputs: [ { "artifact" => "technical_approach", "kind" => "artifact", "path" => "output/approach.md" } ] },
  { name: "Design Writer", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Turn the approach into a technical design: components, data model, interfaces, and a file-level plan of the changes. Cite the requirements each part satisfies.",
    default_outputs: [ { "artifact" => "technical_design", "kind" => "artifact", "path" => "output/design.md" } ] },
  { name: "Work Partitioner", step_type: "planner", role: "code", requirement: "conditional",
    system_prompt: "Split the design into build tasks with explicitly DISJOINT file scopes so they can run in parallel safely. Shared files (routes, lockfiles, migrations) go to a single integrator task.",
    default_outputs: [ { "artifact" => "build_task_plan", "kind" => "artifact", "path" => "output/build_task_plan.md" } ] },
  { name: "Design Coverage Critic", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Check the technical design against the business requirements: is every requirement addressed? Anything designed that no requirement asks for? Emit a structured verdict." },
  # ── Build ───────────────────────────────────────────────────────────────
  { name: "Implementer", step_type: "builder", role: "code", requirement: "required",
    system_prompt: "Implement the technical design (or your assigned task from the build plan) as real changes to the repository. Follow the repo's conventions and stay within your declared scope.",
    default_outputs: [ { "artifact" => "implementation", "kind" => "repo" } ] },
  { name: "Test Critic", step_type: "critic", role: "code", requirement: "required",
    system_prompt: "Run the repository's tests and linters. Verify the implementation builds and passes. If there is nothing runnable, return not_applicable. Emit a structured verdict with failures as findings." },
  # ── Review ──────────────────────────────────────────────────────────────
  { name: "Requirements Conformance Critic", step_type: "critic", role: "review", requirement: "required",
    system_prompt: "Compare what was built (the diff) against the business requirements from Define. For each requirement: satisfied or not, with evidence. Emit a structured verdict." },
  { name: "Code Quality Critic", step_type: "critic", role: "code-review", requirement: "conditional",
    system_prompt: "Review the diff for correctness bugs, security issues, and quality problems. Ignore style covered by linters. Emit a structured verdict with file-anchored findings." },
  { name: "UI Test Critic", step_type: "critic", role: "ui-tests", requirement: "conditional",
    system_prompt: "Exercise the affected UI flows in a browser and verify they behave per the requirements. Requires a browser-equipped worker. Emit a structured verdict." },
  { name: "Review Report Writer", step_type: "builder", role: "review", requirement: "required",
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
    StepTemplate.find_or_create_by!(name: attrs[:name], project_id: nil) do |t|
      t.assign_attributes(attrs)
    end
  end
  puts "Seeded software template pack (#{StepTemplate.global.count} templates)"

  # Default project: Pipeliner itself (dogfooding).
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
