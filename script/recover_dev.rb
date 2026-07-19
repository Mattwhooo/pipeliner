# Rebuilds the development database's real state after a wipe (an agent
# incident lineage this repo knows too well). Idempotent-ish: purges fixture
# debris, reseeds, recreates the two real projects and their pipelines.
#
#   bin/rails runner script/recover_dev.rb
#
# Durable truth lives in git (pipeline branches); this restores the DB records
# that point at it.
abort "development only" unless Rails.env.development?

rework_findings = ReworkEvent.order(:id).last&.feedback || []

Project.destroy_all
Worker.destroy_all
User.where.not(email: "dev@pipeliner.local").destroy_all

load Rails.root.join("db/seeds.rb")
user = User.find_by!(email: "dev@pipeliner.local")

github = Projects::Create.call(owner: user, attributes: {
  name: "Pipeliner (GitHub)", repo_url: "git@github.com:Mattwhooo/pipeliner.git",
  default_branch: "main", project_type: "software" }).value
Projects::Create.call(owner: user, attributes: {
  name: "11-2023 App", repo_url: "#{Dir.home}/.pipeliner-hubs/11-2023-app.git",
  default_branch: "master", project_type: "software" }).value

# --- pl_vuxykmag: Build re-opened by the review rework, iteration 2 pending ---
pl = Pipelines::Create.call(project: github, title: "Live pipeline status summary",
  initial_prompt: "Add a single, real-time, continuously-updating status for each " \
    "pipeline summarizing what is happening right now in plain language, prominent " \
    "on the pipeline board, live via Turbo Streams, true on page load. Follow " \
    "guides/ui-style-guide.md and guides/backend-guide.md.").value
pl.update!(public_id: "pl_vuxykmag", branch: "pipeliner/pl_vuxykmag")

pl.phases.where(kind: %w[define plan]).find_each do |ph|
  ph.update!(status: "approved")
  ph.workflows.each do |wf|
    wf.update!(status: "converged")
    wf.steps.each do |s|
      s.step_runs.create!(state: "succeeded", iteration: 1, required_role: s.role,
        merged_at: Time.current, finished_at: Time.current,
        verdict: s.type_critic? ? { "verdict" => "pass", "findings" => [] } : nil,
        result: { "summary" => "Recovered: merged on #{pl.branch}" })
    end
  end
end

build = pl.phases.find_by!(kind: "build")
review = pl.phases.find_by!(kind: "review")
compose = lambda do |phase, names, route_pairs = {}|
  added = {}
  names.each do |name|
    template = StepTemplate.available_to(github).find_by!(name: name)
    added[name] = Steps::AddToWorkflow.call(phase: phase, attributes: {},
      template: template, route_to_step_id: route_pairs[name] && added[route_pairs[name]]&.id).value
  end
  added
end
built = compose.call(build, [ "Implementer", "Test Critic" ], { "Test Critic" => "Implementer" })
built["Implementer"].step_runs.create!(state: "succeeded", iteration: 1,
  required_role: "code", commit_sha: "82bcb9f", merged_at: Time.current,
  finished_at: Time.current, result: { "summary" => "Iteration 1 (pre-rework): merged" })
built["Implementer"].step_runs.create!(state: "ready", iteration: 2, required_role: "code",
  feedback: rework_findings.map { |f| f.merge("from" => "rework:review") })
build.update!(status: "running")
compose.call(review, [ "Test Critic", "Guide Alignment Critic",
  "Requirements Conformance Critic", "Review Report Writer" ])
pl.update!(status: "running", current_phase: "build")
ReworkEvent.order(:id).last&.update!(pipeline: pl,
  from_phase: review, target_phase: build)

# --- Dashboard pipeline: fresh via the real creation path (auto-composes/starts) ---
Pipelines::Create.call(project: github, title: "Add UI for Dashboard",
  initial_prompt: "Add a dashboard UI that gives an at-a-glance overview: active " \
    "pipelines and their current phase/status, recent activity, worker fleet health.").value

puts "Recovered: #{Project.count} projects, #{Pipeline.count} pipelines, " \
  "#{StepTemplate.count} templates. Restart your worker (registrations were reset)."
